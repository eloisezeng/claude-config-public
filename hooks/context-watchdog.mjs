#!/usr/bin/env node
// context-watchdog.mjs — nudge a deliberate handoff before the context window gets expensive.
//
// Wired in ~/dotfiles/claude/settings.json as UserPromptSubmit + PostToolUse.
// Reads the session transcript's most recent main-chain assistant `usage` block,
// which records the EXACT context window sent on the last request (input +
// cache_read + cache_creation) — no estimation.
//
// Bands (absolute tokens, so behaviour is identical on 200K and 1M models):
//   WARN   >= 120K  → at the next task boundary, write a handoff and /clear
//   URGENT >= 150K  → auto-compact (autoCompactWindow 200K) is imminent; hand off NOW
//                     via hooks/handoff.sh, which spawns a verified+watched
//                     `claude --bg` successor. The hook can only INSTRUCT this;
//                     it cannot dispatch, because only the model can author the
//                     handoff file's contents. Treat the band as advisory.
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
// Replaces every "write a handoff file and dispatch a successor" instruction in
// this file. There are five of them and the guard has to dominate ALL five --
// the two UserPromptSubmit bands, the PostToolUse band, and both halves of the
// degraded path -- because any one that survives re-arms the loop on its own.
//
// It deliberately does NOT name the launcher script, even to cite it. That makes
// "the guarded output mentions handoff.sh nowhere" a checkable invariant, so the
// test catches a re-introduced invocation however it is worded, instead of
// matching one exact phrasing that the next edit walks around.
const HANDED_OFF_ADVICE = 'This session has ALREADY handed its remaining work to a background successor (the handoff launcher recorded a verified dispatch), so do NOT write another handoff file and do NOT dispatch a second successor — a second one would duplicate work already in flight. Finish or checkpoint only what is already started, report where the work went and under which record, then end the turn. This window can be /cleared whenever.';

const WARN = 120_000;
// Auto-compact (autoCompactWindow 200K) can fire from ~166K (83% of the window).
// URGENT must sit BELOW that so the deliberate handoff gets its chance strictly
// before the lossy backstop.
const URGENT = 150_000;
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
  const advice = ho ? HANDED_OFF_ADVICE : `This session's context window is UNKNOWN — read the bands (warn ${WARN / 1000}K, urgent ${URGENT / 1000}K) as UNREPORTED, never as "under threshold", and do not state or guess a token count. Two things produce this and they differ: a single main-chain record larger than the cap (the window is very large, and lossy auto-compact near 200K may be close), or more than that much trailing subagent (isSidechain) output (which says nothing about this window). Judge the boundary yourself instead of waiting for a band that will not arrive: at the next natural task boundary write a short handoff file and hand the next item to a fresh session — \`~/dotfiles/claude/hooks/handoff.sh "<handoff-file>" -- "<objective>"\` — rather than continuing here.`;

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
        additionalContext: `[context-watchdog] This session resumed with a ~${k}K-token window after a >1h gap: the prompt cache has lapsed and the entire window is being re-written at the higher cache-write rate. Unless the old context is genuinely needed for this request, offer you a two-paragraph handoff summary of the session state and suggest you /clear and restate the task in a fresh session.`,
      };
    } else if (windowTokens >= URGENT) {
      out.systemMessage = ho
        ? `context-watchdog: context at ~${k}K tokens — this session has already handed off; /clear this window when convenient (auto-compact near 200K is the backstop).`
        : `context-watchdog: context at ~${k}K tokens — Claude is handing remaining work to a fresh context; /clear this window when convenient (auto-compact near 200K is the backstop).`;
      out.hookSpecificOutput = {
        hookEventName: 'UserPromptSubmit',
        additionalContext: ho
          ? `[context-watchdog] Context window is at ~${k}K tokens (urgent threshold ${URGENT / 1000}K). ${HANDED_OFF_ADVICE}`
          : `[context-watchdog] Context window is at ~${k}K tokens (urgent threshold ${URGENT / 1000}K). Auto-compact will fire lossily near 200K. Hand off AUTONOMOUSLY — do not ask permission: (1) finish or checkpoint only the current step; (2) write a handoff file (key facts, decisions, live state, next steps) at an ABSOLUTE path; (3) if work remains, dispatch a fresh SESSION to it by running \`~/dotfiles/claude/hooks/handoff.sh "<absolute-handoff-path>" -- "<one-line objective>"\` — that spawns a \`claude --bg\` successor with its own ~60K window, verifies it against \`claude agents --json\`, and watches it for blocked/stalled; an in-session subagent would leave THIS ~${k}K window loaded and cache-read on every later turn, and a fork copies it outright (never a fork). Report the record path the launcher prints, or its error verbatim — a dispatch you did not see confirmed did not happen; (4) tell you what moved where and that this window can be /cleared whenever. Start no new work in this window. EXCEPTION — if this session runs a recurring loop or scheduled wakeups that cannot move to a new session, skip the dispatch: checkpoint state to the handoff file and keep working; built-in auto-compact will reclaim the window without pausing. NEVER stop work to wait for your input.`,
      };
    } else if (windowTokens >= WARN) {
      out.hookSpecificOutput = {
        hookEventName: 'UserPromptSubmit',
        additionalContext: ho
          ? `[context-watchdog] Context window is at ~${k}K tokens (warn threshold ${WARN / 1000}K). ${HANDED_OFF_ADVICE}`
          : `[context-watchdog] Context window is at ~${k}K tokens (warn threshold ${WARN / 1000}K). At the next natural task boundary, write a short handoff file and hand the next item to a fresh session — \`~/dotfiles/claude/hooks/handoff.sh "<handoff-file>" -- "<objective>"\`, or suggest you /clear and restate (handoff-at-boundaries-saves-tokens). Finish the current item first; do not drop work mid-step.`,
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
    if (band <= lastBand) return;
    try { mkdirSync(stateDir, { recursive: true }); writeFileSync(stateFile, String(band)); } catch { return; }
    const urgency = ho
      ? HANDED_OFF_ADVICE
      : windowTokens >= URGENT
      ? `Auto-compact fires lossily near 200K. Hand off AUTONOMOUSLY — do not ask permission: checkpoint the current step, write a handoff file (key facts, decisions, live state, next steps) at an ABSOLUTE path, then dispatch any remaining work to a fresh SESSION by running \`~/dotfiles/claude/hooks/handoff.sh "<absolute-handoff-path>" -- "<one-line objective>"\` (a \`claude --bg\` successor boots its own ~60K window and is verified + watched; an in-session subagent leaves THIS window loaded for every later turn, and a fork copies it — never a fork). Report the record path it prints, or its error verbatim, then end the turn reporting what moved where. Begin no further work in this window. EXCEPTION — if this session runs a recurring loop or scheduled wakeups that cannot move to a new session, skip the dispatch: checkpoint state to the handoff file and keep working; built-in auto-compact will reclaim the window without pausing. NEVER stop work to wait for your input.`
      : `At the next task boundary, write a short handoff file and hand the next item to a fresh session yourself — \`~/dotfiles/claude/hooks/handoff.sh "<handoff-file>" -- "<objective>"\` — instead of continuing here (handoff-at-boundaries-saves-tokens).`;
    out.hookSpecificOutput = {
      hookEventName: 'PostToolUse',
      additionalContext: `[context-watchdog] Context window has grown to ~${k}K tokens. ${urgency}`,
    };
    if (windowTokens >= URGENT) {
      out.systemMessage = ho
        ? `context-watchdog: context at ~${k}K tokens — this session has already handed off; auto-compact near 200K is the backstop.`
        : `context-watchdog: context at ~${k}K tokens — Claude is handing off to a fresh context; auto-compact near 200K is the backstop.`;
    }
  }

  if (out.hookSpecificOutput || out.systemMessage) {
    process.stdout.write(JSON.stringify(out));
  }
}

try { main(); } catch { /* never break the session */ }
