#!/usr/bin/env node
// context-watchdog.mjs — make the window disposable before auto-compact fires,
// and keep handoffs at task boundaries.
//
// Wired in ~/dotfiles/claude/settings.json as UserPromptSubmit + PostToolUse.
// Reads the session transcript's most recent main-chain assistant `usage` block,
// which records the EXACT context window sent on the last request (input +
// cache_read + cache_creation) — no estimation.
//
// the user's decision 2026-09-15, replacing the 2026-08-31 lifecycle decision: do NOT
// assume compaction is preferable to a handoff. Compaction is the right move only
// when it preserves valuable working context AND buys meaningful runway. Where the
// state of the work is already durable on disk, or where compaction has started to
// recur, a checkpointed handoff is preferable.
//
// The 2026-08-31 wording this replaces claimed a compaction cost a "~52K re-warm,
// about a fresh boot's 46–50K", and told every session to NEVER dispatch merely
// because context was high. Both halves were measured wrong on 2026-09-14 over 5,660
// automatic boundaries in ~/.claude + ~/.claude1. The "~52K" was the summary's own
// postTokens, not the post-compaction window; the real window after a boundary is a
// median 107.7K, the re-injected floor a median 85.5K, the reclaimed runway a median
// 54K, and the stall a median 144 s (239.7 h across the corpus). Half of every
// post-compaction window is material re-injected before the session does anything.
//
// What this hook nudges is unchanged: durable-state hygiene. Everything this window
// knows must be on disk (the lane ledger ~/.claude/ops/ and the lane's own file)
// before the boundary hits, so the summary is never the only carrier of an
// unresolved item. What changed is that once the state IS on disk, handing the
// remainder to a fresh session is a legitimate — often preferable — choice.
//
// Bands are DERIVED from autoCompactWindow, never written down here; see
// lib/compaction-window.mjs for the measured 83.5% trigger fraction and the proof
// that the derivation reproduces the old hand-picked 120K/150K at a 200K setting.
//   WARN   (72% of the trigger)  → at the next task boundary, sync durable state,
//                     then choose: continue through one compaction, or hand a
//                     separable next item to a fresh session.
//   URGENT (90% of the trigger)  → the boundary is imminent; write all unresolved
//                     knowledge to durable state NOW, then make that choice
//                     deliberately rather than by default.
// Resume case (UserPromptSubmit only): last activity > 60 min ago with a big
// window → the whole cache must be re-written before any work happens; suggest
// /clear + restate instead of continuing.
//
// PostToolUse fires constantly, so it only re-emits when the window crosses a
// new 25K band (state file per session). UserPromptSubmit always reports when
// over WARN — one small reminder per user turn is cheap and load-bearing.
//
// A measurement that FAILS is not the same as a window that is small: if the
// reader hits its read cap with no complete main-chain record in sight, the hook
// says so (once per session on PostToolUse) rather than going quiet — see
// reportDegraded.
//
// This hook must NEVER break a session: any error → exit 0 with no output.

import { readFileSync, openSync, readSync, closeSync, fstatSync, mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';
import { homedir, tmpdir } from 'node:os';
import { bands } from './lib/compaction-window.mjs';

// A seat that has ALREADY dispatched a successor must not be told to dispatch
// another. hooks/handoff.sh writes this sentinel the moment a dispatch verifies,
// BEFORE it marks its own state terminal, so the guard is live even where the
// retirement's process stop is slow, refused, or rolled back. Without it this
// hook tells the retiring seat to hand off again on its very next tool call --
// including the tool calls the retirement itself provokes -- and a second
// successor duplicates the work the first one is already doing.
//
// The two env vars, in this order, are the same ones hooks/handoff.sh reads for
// STATE_DIR. A guard and its writer that compute the path differently is a guard
// that reads absent forever.
const STATE_DIR = process.env.CLAUDE_HANDOFF_STATE_DIR
  || join(process.env.CLAUDE_CONFIG_DIR || join(homedir(), '.claude'), 'session-state');
function handedOff(sessionId) {
  if (!sessionId) return false;
  try { readFileSync(join(STATE_DIR, `${sessionId}.handed-off`), 'utf8'); return true; }
  catch { return false; }
}
// Replaces every instruction in this file that could lead to a dispatch (even
// the boundary-only kind). There are five output paths and the guard has to
// dominate ALL five --
// the two UserPromptSubmit bands, the PostToolUse band, and both halves of the
// degraded path -- because any one that survives re-arms the loop on its own.
//
// It deliberately does NOT name the launcher script, even to cite it. That makes
// "the guarded output mentions handoff.sh nowhere" a checkable invariant, so the
// test catches a re-introduced invocation however it is worded, instead of
// matching one exact phrasing that the next edit walks around.
const B = bands();

const HANDED_OFF_ADVICE = 'This session has ALREADY handed its remaining work to a background successor (the handoff launcher recorded a verified dispatch), so do NOT write another handoff file and do NOT dispatch a second successor — a second one would duplicate work already in flight. Finish or checkpoint only what is already started, report where the work went and under which record, then end the turn. This window can be /cleared whenever.';

// The two band texts, shared by UserPromptSubmit and PostToolUse so the two
// events cannot drift apart. Each band cites ONE launcher form and not the
// other's — the test's containment assertions key on exactly that.
const URGENT_ADVICE = `Auto-compact fires near ${B.triggerK} (autoCompactWindow ${B.configuredK}). Measured 2026-09-14 over 5,660 boundaries: a median 144-second stall, and it reclaims only a median 54K of runway because a median 85.5K floor is re-injected immediately. ONE compaction is normal and is not worth avoiding. What is not automatic is what happens next, so decide it deliberately now rather than by default: (1) write every unresolved item, decision, ownership change, and newly discovered piece of work this session knows about into durable state — the lane ledger (~/.claude/ops/, see its README.md) and/or the lane's own handoff/progress file; nothing may exist only in this window; (2) checkpoint the current step into the artifact it belongs to; (3) then choose. If the work's state is now fully on disk and the next item is separable, a checkpointed handoff to a fresh session is PREFERABLE to riding through the boundary — \`~/dotfiles/claude/hooks/handoff.sh "<absolute-handoff-path>" -- "<one-line objective>"\` — because the summary carries less than the disk does. If the live context genuinely still holds something the artifacts do not, continue and let the compaction fire. Do not treat either choice as the automatic one. NEVER stop work to wait for the user's input.`;
const WARN_ADVICE = `At the next natural task boundary: sync durable state (record anything unresolved that exists only in this window into the lane ledger ~/.claude/ops/ or the lane's own file), then choose between continuing and handing off — \`~/dotfiles/claude/hooks/handoff.sh "<handoff-file>" -- "<objective>"\` (handoff-at-boundaries-saves-tokens). A single auto-compact near ${B.triggerK} is normal and costs a median 144-second stall for a median 54K of reclaimed runway; it is worth taking when the live context still holds something the artifacts do not. Where the state is already durable on disk, or where this window has already compacted once, hand the remainder to a fresh session instead. Finish the current item first; do not drop work mid-step.`;
// Both bands are derived from the LIVE autoCompactWindow, so raising the setting
// moves them with it. URGENT sits below the measured trigger so the durable-state
// sync gets its chance strictly before the boundary — the sync is only worth
// anything if it lands first.
const WARN = B.warn;
const URGENT = B.urgent;
const RESUME_GAP_MS = 60 * 60 * 1000;
const RESUME_MIN = 100_000;
const BAND = 25_000;
// The first read. A transcript is appended to, so the last complete main-chain
// record is almost always inside this much of the tail.
const TAIL_BYTES = 1_048_576;
// ...but not always: a single assistant record can be LARGER than the tail (one
// measured at 1,100,158 bytes). A reverse read that begins in the middle of a
// record parses nothing at all, and this hook's failure mode is silence — so the
// window GROWS until a whole main-chain record is inside it. Reporting "no usage"
// there would silence WARN and URGENT on exactly the sessions that are nearest
// the auto-compact cliff, which is the only situation the hook exists for.
// Bounded, because this runs on every PostToolUse: a record beyond this is not a
// transcript this hook can serve, and reading further costs more than it buys.
const MAX_TAIL_BYTES = 16 * 1_048_576;

function scanForUsage(lines) {
  for (let i = lines.length - 1; i >= 0; i--) {
    let e;
    try { e = JSON.parse(lines[i]); } catch { continue; }
    if (e.isSidechain) continue; // subagent usage describes the subagent's window, not ours
    const u = e.message && e.message.usage;
    if (u && typeof u.input_tokens === 'number') {
      return { usage: u, timestamp: e.timestamp ? Date.parse(e.timestamp) : NaN };
    }
  }
  return null;
}

function lastMainChainUsage(transcriptPath) {
  const fd = openSync(transcriptPath, 'r');
  try {
    const size = fstatSync(fd).size;
    for (let want = TAIL_BYTES; ; want *= 2) {
      const partial = want < size;
      // One byte BEFORE the window is read deliberately. It turns "is the first
      // line a fragment?" into a question the split answers by itself: a
      // preceding newline yields an empty leading element, anything else yields
      // the fragment. Either way lines[0] is dropped — so no parse ever begins
      // in the middle of a record, and no COMPLETE record is dropped either.
      const from = partial ? size - want - 1 : 0;
      const len = size - from;
      const buf = Buffer.alloc(len);
      readSync(fd, buf, 0, len, from);
      const lines = buf.toString('utf8').split('\n');
      if (partial) lines.shift();
      const hit = scanForUsage(lines);
      if (hit) return hit;
      // Nothing usable in this window. Grow — unless the window already IS the
      // whole file, or we have hit the cap. Those two are NOT the same answer and
      // must not share a return value: the whole file having no main-chain usage
      // record is a measurement that succeeded and found nothing (a fresh or
      // subagent-only transcript — stay silent), while hitting the cap is a
      // measurement that FAILED with the window still partial. Collapsing the
      // second into `null` is how the cap re-introduced this hook's own worst
      // failure mode (silence) on the transcripts most likely to be enormous.
      if (!partial) return null;
      if (want >= MAX_TAIL_BYTES) return { degraded: 'cap', bytes: want, size };
    }
  } finally {
    closeSync(fd);
  }
}

// The read cap was reached with no complete main-chain usage record inside it.
// TWO different situations produce this and the hook cannot tell them apart:
//   (a) a single main-chain record larger than the cap — the window is enormous
//       and auto-compact may be near;
//   (b) more than the cap's worth of trailing isSidechain records — a subagent
//       fan-out, which says nothing about this session's own window.
// So report the measurement failure and the action, and state NO token count in
// either direction: a fabricated number is worse than the honest "unknown",
// whichever way it is rounded.
function degradedOutput(hook, info, ho) {
  const event = hook.hook_event_name || '';
  const mib = (n) => `${(n / 1_048_576).toFixed(1)} MiB`;
  const what = `the last ${mib(info.bytes)} of a ${mib(info.size)} transcript contains no complete main-chain assistant usage record`;
  const advice = ho ? HANDED_OFF_ADVICE : `This session's context window is UNKNOWN — read the bands (warn ${WARN / 1000}K, urgent ${URGENT / 1000}K) as UNREPORTED, never as "under threshold", and do not state or guess a token count. Two things produce this and they differ: a single main-chain record larger than the cap (the window is very large, and auto-compact near ${B.triggerK} may be close), or more than that much trailing subagent (isSidechain) output (which says nothing about this window). Judge the boundary yourself instead of waiting for a band that will not arrive: sync durable state now (record anything unresolved that exists only in this window into the lane ledger ~/.claude/ops/ or the lane's own file), then choose deliberately — continue through one compaction if the live context still holds what the artifacts do not, or, once the state is on disk, hand the remainder to a fresh session with \`~/dotfiles/claude/hooks/handoff.sh "<handoff-file>" -- "<objective>"\`.`;

  if (event === 'UserPromptSubmit') {
    return {
      systemMessage: `context-watchdog: cannot measure this session's context window (${what}); size warnings are unavailable until that changes.`,
      hookSpecificOutput: {
        hookEventName: 'UserPromptSubmit',
        additionalContext: `[context-watchdog] MEASUREMENT FAILED: ${what}, so the window size could not be read. ${advice}`,
      },
    };
  }
  if (event === 'PostToolUse') {
    // Once per session, in a marker file of its OWN. The numeric band file must
    // not carry a sentinel: whatever integer it parsed to would suppress every
    // real band at or below it for the rest of the session, so a transcript that
    // recovers (the next main-chain record lands inside the cap) would go quiet
    // exactly when it started having something true to say.
    const stateDir = join(tmpdir(), 'claude-context-watchdog');
    const marker = join(stateDir, `${hook.session_id || 'unknown'}.degraded`);
    try { readFileSync(marker, 'utf8'); return null; } catch { /* first sighting */ }
    try { mkdirSync(stateDir, { recursive: true }); writeFileSync(marker, '1'); } catch { return null; }
    return {
      hookSpecificOutput: {
        hookEventName: 'PostToolUse',
        additionalContext: `[context-watchdog] MEASUREMENT FAILED: ${what}, so the window size could not be read (reported once per session). ${advice}`,
      },
    };
  }
  return null;
}

function main() {
  let hook;
  try { hook = JSON.parse(readFileSync(0, 'utf8')); } catch { return; }
  if (!hook || !hook.transcript_path) return;

  // Computed BEFORE the first branch that can emit, so no output path can be
  // added later that reaches an instruction without passing the guard.
  const ho = handedOff(hook.session_id);

  let found;
  try { found = lastMainChainUsage(hook.transcript_path); } catch { return; }
  if (!found) return;
  if (found.degraded) {
    const degraded = degradedOutput(hook, found, ho);
    if (degraded) process.stdout.write(JSON.stringify(degraded));
    return;
  }

  const u = found.usage;
  const windowTokens = (u.input_tokens || 0) + (u.cache_read_input_tokens || 0) + (u.cache_creation_input_tokens || 0);
  const k = Math.round(windowTokens / 1000);
  const event = hook.hook_event_name || '';
  const out = {};

  if (event === 'UserPromptSubmit') {
    const gapMs = Number.isFinite(found.timestamp) ? Date.now() - found.timestamp : 0;
    if (gapMs > RESUME_GAP_MS && windowTokens >= RESUME_MIN) {
      out.systemMessage = `context-watchdog: this session carries ~${k}K tokens and has been idle >1h — the prompt cache has lapsed, so continuing re-writes the whole window before any work happens. Consider /clear + restating (or resume-from-summary) instead.`;
      out.hookSpecificOutput = {
        hookEventName: 'UserPromptSubmit',
        additionalContext: `[context-watchdog] This session resumed with a ~${k}K-token window after a >1h gap: the prompt cache has lapsed and the entire window is being re-written at the higher cache-write rate. Unless the old context is genuinely needed for this request, offer the user a two-paragraph handoff summary of the session state and suggest she /clear and restate the task in a fresh session.`,
      };
    } else if (windowTokens >= URGENT) {
      out.systemMessage = ho
        ? `context-watchdog: context at ~${k}K tokens — this session has already handed off; /clear this window when convenient (auto-compact near ${B.triggerK} is the backstop).`
        : `context-watchdog: context at ~${k}K tokens — Claude will sync durable state, then choose between one compaction (near ${B.triggerK}) and a checkpointed handoff.`;
      out.hookSpecificOutput = {
        hookEventName: 'UserPromptSubmit',
        additionalContext: ho
          ? `[context-watchdog] Context window is at ~${k}K tokens (urgent threshold ${URGENT / 1000}K). ${HANDED_OFF_ADVICE}`
          : `[context-watchdog] Context window is at ~${k}K tokens (urgent threshold ${URGENT / 1000}K). ${URGENT_ADVICE}`,
      };
    } else if (windowTokens >= WARN) {
      out.hookSpecificOutput = {
        hookEventName: 'UserPromptSubmit',
        additionalContext: ho
          ? `[context-watchdog] Context window is at ~${k}K tokens (warn threshold ${WARN / 1000}K). ${HANDED_OFF_ADVICE}`
          : `[context-watchdog] Context window is at ~${k}K tokens (warn threshold ${WARN / 1000}K). ${WARN_ADVICE}`,
      };
    }
  } else if (event === 'PostToolUse') {
    if (windowTokens < WARN) return;
    // Throttle: only speak when we cross into a new 25K band this session.
    const band = Math.floor(windowTokens / BAND);
    const stateDir = join(tmpdir(), 'claude-context-watchdog');
    const stateFile = join(stateDir, `${hook.session_id || 'unknown'}.band`);
    let lastBand = -1;
    try { lastBand = parseInt(readFileSync(stateFile, 'utf8'), 10); } catch { /* first sighting */ }
    // The high-water mark must RESET when the window is reclaimed, or this hook goes silent for
    // the rest of any session that auto-compacts. Measured 2026-09-14 on a transcript with 232
    // compactions: the median window before a compaction is 166K and the median window of the
    // first request after it is 117K, so the post-compaction cycle climbs back through bands it
    // has already recorded and never exceeds the pre-compaction peak. Under a plain `band <=
    // lastBand` throttle that is permanent silence after the FIRST compaction -- on exactly the
    // sessions nearest the cliff, which is the only situation this hook exists for.
    //
    // A DOWNWARD crossing of a full 25K band is the reclaim signal, and it needs no extra I/O:
    // compaction and /clear both produce it, and ordinary turn-to-turn jitter does not, because
    // jitter is far smaller than a band. Treat it as a new cycle -- record the new floor and
    // speak, so each cycle gets its own WARN/URGENT advice.
    if (band === lastBand) return;
    try { mkdirSync(stateDir, { recursive: true }); writeFileSync(stateFile, String(band)); } catch { return; }
    const urgency = ho
      ? HANDED_OFF_ADVICE
      : windowTokens >= URGENT
      ? URGENT_ADVICE
      : WARN_ADVICE;
    out.hookSpecificOutput = {
      hookEventName: 'PostToolUse',
      additionalContext: `[context-watchdog] Context window has grown to ~${k}K tokens. ${urgency}`,
    };
    if (windowTokens >= URGENT) {
      out.systemMessage = ho
        ? `context-watchdog: context at ~${k}K tokens — this session has already handed off; auto-compact near ${B.triggerK} is the backstop.`
        : `context-watchdog: context at ~${k}K tokens — Claude will sync durable state, then choose between one compaction (near ${B.triggerK}) and a checkpointed handoff.`;
    }
  }

  if (out.hookSpecificOutput || out.systemMessage) {
    process.stdout.write(JSON.stringify(out));
  }
}

try { main(); } catch { /* never break the session */ }
