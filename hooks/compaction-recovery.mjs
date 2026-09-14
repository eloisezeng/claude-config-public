#!/usr/bin/env node
// compaction-recovery.mjs — SessionStart hook, source == "compact" ONLY.
//
// WHY THIS EXISTS. Auto-compaction was thrashing: a session would compact, spend its
// reclaimed window re-reading the files the summary had just replaced, refill, and compact
// again. Measured 2026-09-14 over one real session transcript of 45,733 records:
//
//   * 232 compactions in ONE session.
//   * Median window immediately BEFORE a compaction: 166K tokens. Median window of the first
//     request AFTER it: 117K. A compaction therefore reclaims ~49K of a 200K ceiling.
//   * The re-injection at the boundary is a FLOOR of ~137 KB of context-visible bytes
//     (~34K tokens): invoked_skills 43.2 KB, instructions 31.3 KB, the compact summary
//     30.0 KB, file attachments 10.9 KB, hook_additional_context 9.1 KB, the rest smaller.
//     That floor is spent before the session does anything.
//   * ~49K of headroom is about ten tool calls. In the 25 main-chain assistant records
//     following each boundary there were 2,282 Bash calls, 278 Reads, 138 Edits and 82
//     Writes; one source file was re-read 34 times across the session and one spec 32 times.
//
// The floor is mostly harness-controlled (skills, CLAUDE.md, the summary itself). The
// BEHAVIOUR is not: nothing anywhere in this configuration told a session what to do after a
// compaction, so every standing re-verification directive ("re-measure at ACT TIME", "fetch
// before you diagnose", "verify claims against artifacts") fired again from zero, with no
// memory of having already fired. This hook is that missing instruction, plus a circuit
// breaker so repeated rapid compactions STOP the recovery reads instead of looping.
//
// Thresholds are measured, not chosen. From the same corpus, minutes between consecutive
// compactions: p10 6.6, p25 8.1, median 10.0, p75 13.4, p90 26.0. Counting compactions
// inside a trailing 60-minute window, the failing session reached 9, and >=3-in-an-hour held
// at 200 of its 232 boundaries. A session compacting once an hour is working; one compacting
// three times an hour is rebuilding context it just discarded.
//
// Contract: prints NOTHING on startup/resume/clear, so a normal boot is untouched. Never
// throws, never blocks, always exits 0 — a hook that breaks a session is worse than the bug.

import { readFileSync, openSync, readSync, fstatSync, closeSync } from 'node:fs';

// Trailing wall-clock window the breaker counts compactions inside. 60 minutes because the
// measured healthy gap (p90 26 min) and the measured pathological rate (up to 9/hour) are
// separated cleanly at this width; a 10-minute window saw >=3 at only 1 of 232 boundaries and
// would have missed the pathology almost entirely.
const WINDOW_MS = 60 * 60 * 1000;

// Tail-read budget. The breaker asks "how many compactions RECENTLY", so a bounded tail is
// semantically right as well as cheap. It grows only until a boundary older than the window
// is in hand (which proves the count is complete) or the cap is reached.
const TAIL_BYTES = 2 * 1_048_576;
const MAX_TAIL_BYTES = 16 * 1_048_576;

const MARKER = '"compact_boundary"';

// Read a growing tail of the transcript and return the timestamps (ms) of every
// compact_boundary record found, plus whether the scan is known-complete for the window.
function boundaryTimes(path) {
  let fd;
  try { fd = openSync(path, 'r'); } catch { return null; }
  try {
    const size = fstatSync(fd).size;
    const cutoff = Date.now() - WINDOW_MS;
    for (let want = TAIL_BYTES; ; want *= 2) {
      const start = Math.max(0, size - want);
      const len = size - start;
      const buf = Buffer.allocUnsafe(len);
      readSync(fd, buf, 0, len, start);
      let text = buf.toString('utf8');
      // Drop a partial first line unless the tail already covers the whole file.
      if (start > 0) {
        const nl = text.indexOf('\n');
        text = nl === -1 ? '' : text.slice(nl + 1);
      }
      const times = [];
      let sawOlder = false;
      for (const line of text.split('\n')) {
        if (!line.includes(MARKER)) continue;
        let rec;
        try { rec = JSON.parse(line); } catch { continue; }
        if (rec.subtype !== 'compact_boundary') continue;
        const t = Date.parse(rec.timestamp || '');
        if (!Number.isFinite(t)) continue;
        times.push(t);
        if (t < cutoff) sawOlder = true;
      }
      // Complete when a boundary older than the window is in hand, or the tail is the file.
      if (sawOlder || start === 0 || want >= MAX_TAIL_BYTES) {
        return { times, complete: sawOlder || start === 0, cutoff };
      }
    }
  } catch {
    return null;
  } finally {
    try { closeSync(fd); } catch { /* already gone */ }
  }
}

// Every tier says the same thing about WHAT the summary is worth; they differ only in how
// much reading is still permitted. Written as one shared preamble so the tiers cannot drift.
const PREAMBLE =
  'This session has just auto-compacted. The summary above IS the durable state of the work: ' +
  'it was written by you, from the full context, for exactly this moment. Treat it as authoritative ' +
  'and continue from the NEXT ACTION it names. Do not rebuild the discarded window.';

const NEVER =
  'Never re-read a whole file to "restore context", never re-run a search you have already run, and ' +
  'never re-derive a fact the summary already states (a path, a measured number, a decision, a command ' +
  'that worked). If the summary names a value, that value is the answer; re-measuring it is the loop. ' +
  'Where the summary is genuinely silent on something you need, say so in one line and proceed on a ' +
  'stated assumption rather than reading until you find it.';

const BOUNDED =
  'Freshness checks survive, but BOUNDED: read the specific span you are about to edit (an offset and a ' +
  'limit, a single grep with a pattern, one `git show`), never the whole file, and never more than a few ' +
  'such reads before your next real action. A read that exists to remind you of something, rather than to ' +
  'decide the step in front of you, is the read to skip.';

function tierAdvice(n, complete) {
  const seen = complete ? `${n}` : `at least ${n}`;
  if (n <= 1) {
    return {
      tier: 1,
      system: null,
      text:
        `${PREAMBLE} ${NEVER} ${BOUNDED} ` +
        'Your first act after this message should be the next step of the work itself, not an orientation pass.',
    };
  }
  if (n === 2) {
    return {
      tier: 2,
      system:
        'compaction-recovery: second compaction within the hour — recovery reads are off. Claude will act from the summary.',
      text:
        `${PREAMBLE} CIRCUIT BREAKER, TIER 2: this window has compacted ${seen} times in the last hour, which means the ` +
        'previous cycle spent its reclaimed context without finishing the work. Recovery reads are now FORBIDDEN — ' +
        'take NO read whose purpose is to restore context. ' + NEVER + ' ' +
        'Only a read the very next edit or command cannot be written without is permitted, and it must be a targeted ' +
        'span, not a file. Act on the summary as it stands; if that is not enough to act, that is a reason to ask or ' +
        'to checkpoint, never a reason to read more.',
    };
  }
  return {
    tier: 3,
    system:
      `compaction-recovery: ${seen} compactions within the hour — context is thrashing. Claude will checkpoint durable state and stop expanding context.`,
    text:
      `${PREAMBLE} CIRCUIT BREAKER, TIER 3: this window has compacted ${seen} times in the last hour. The compaction ` +
      'cycle is no longer buying progress — each one reclaims roughly a quarter of the window, which the next ' +
      'orientation pass spends immediately. STOP EXPANDING CONTEXT NOW. Take no recovery read of any kind. Do not ' +
      'start a new investigation, a new search sweep, or a new file. Instead, in this turn: (1) write the durable ' +
      'state of the work — what is done, what is next, the exact paths and commands — into the artifact that already ' +
      'owns it (the lane file under ~/.claude/ops/, the handoff document, or the plan), so nothing lives only in this ' +
      'window; (2) finish or abandon the single action already in flight; (3) then either hand the remainder to a ' +
      'fresh session at this boundary with `~/dotfiles/claude/hooks/handoff.sh "<handoff-file>" -- "<objective>"`, or ' +
      'tell the user plainly that the task does not fit this window and name what you would need to narrow it. ' +
      'Continuing to read here produces another compaction, not an answer.',
  };
}

function main() {
  if (process.stdin.isTTY) return;
  let hook;
  try { hook = JSON.parse(readFileSync(0, 'utf8')); } catch { return; }
  if (!hook || hook.source !== 'compact') return;

  // Default to tier 1 when the transcript cannot be read: the protocol is the part that always
  // applies, and an unreadable transcript must not silently escalate a session to "stop working".
  let n = 1;
  let complete = true;
  if (hook.transcript_path) {
    const found = boundaryTimes(hook.transcript_path);
    if (found) {
      n = found.times.filter((t) => t >= found.cutoff).length || 1;
      complete = found.complete;
    }
  }

  const { tier, system, text } = tierAdvice(n, complete);
  const out = {
    hookSpecificOutput: {
      hookEventName: 'SessionStart',
      additionalContext: `[compaction-recovery tier ${tier}] ${text}`,
    },
  };
  if (system) out.systemMessage = system;
  process.stdout.write(JSON.stringify(out));
}

try { main(); } catch { /* a hook must never break a session */ }
