#!/usr/bin/env node
// UserPromptSubmit hook: when a session's prompt reads as a request to BUILD, FIX or AUDIT
// something, remind the session once to invoke the `codex-converge` skill before starting.
//
// Why. The standing directive in CLAUDE.md says to invoke codex-converge BY DEFAULT at the
// start of any build, fix or audit, and nothing mechanical prompts it. Measured 2026-10-28
// over 2026-09-13..10-28: the skill was invoked in 2 of 22 interactive sessions whose first
// message was a build/fix/audit request (same keyword rule as BUILD below). A written rule
// that fires at a moment nobody is watching for is a rule that does not fire.
//
// Guards, each because a reminder that fires when it should not gets ignored, and then the
// mechanism is dead:
//   1. ONCE PER SESSION. The first build/fix/audit prompt fires it; nothing after does.
//   2. Silent when the session ALREADY invoked the skill (a Skill tool_use, or the
//      /codex-converge slash command, in the transcript), or the prompt names it itself.
//   3. Silent for a dispatched seat (a "Read the handoff file..." pointer, or a seat's
//      CLAUDE_HANDOFF_LANE in the environment): the seat follows the plan it was handed.
//      A seat's first prompt marks the whole session, so a later nudge cannot fire it.
//   4. Silent for automated prompts (task notifications, security-review and tool-probe
//      prompts), other slash commands, and plain questions ("why does X fail?").
//   5. FAIL SILENT. Any error emits nothing; never break a prompt over a reminder.
//
// State is one small file per session under the OS temp dir, like context-watchdog.mjs.

import { readFileSync, writeFileSync, mkdirSync, existsSync, statSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';

// The census's classification rule, kept identical so the reminder fires on exactly the
// population the 2-of-22 figure was measured over.
const BUILD = /\b(build|implement|add|create|fix|fixes|fixing|repair|debug|audit|refactor|ship|migrate|port|wire|bug|broken|regression|make (it|the|a|this|sure))\b/i;
const AUTOMATED = /^\s*(Review this change for security vulnerabilities|You previously flagged these candidate vulnerabilities|First list the names of all tools)/;
const DISPATCH = /HANDOFF[-_A-Za-z0-9]*\.md|it is your only context|Your lane:|handoff\.sh|You are (a|the) (successor|dispatched)|^\s*Read the handoff (file|doc)/i;
const WRAPPERS = /<(system-reminder|local-command-[a-z]+|task-notification|bash-[a-z]+|command-message)>[\s\S]*?<\/\1>/g;
// A question opener whose first sentence ends in '?'. "Can/could/would you fix X?" is a
// request and deliberately NOT listed.
const QUESTION = /^(why|what|how|where|when|who|which|is|are|does|do|did|was|were|should|has|have)\b[^.!\n]*\?/i;
const MENTIONS_SKILL = /codex-converge/i;
// Transcripts can be large; the already-invoked scan reads at most this many bytes.
const MAX_SCAN_BYTES = 64 * 1024 * 1024;

const REMINDER =
  '[codex-converge] This reads as a build/fix/audit request. Standing directive: invoke the ' +
  '`codex-converge` skill (Skill tool) now, before other work. Shown once per session.';

function classify(raw) {
  const text = String(raw || '').replace(WRAPPERS, '').trim();
  if (!text) return 'automated';
  if (AUTOMATED.test(text)) return 'automated';
  if (DISPATCH.test(text)) return 'dispatch';
  if (MENTIONS_SKILL.test(text)) return 'names-skill';
  if (text.startsWith('/')) return 'slash-command';
  if (QUESTION.test(text)) return 'question';
  return BUILD.test(text) ? 'build' : 'other';
}

function alreadyInvoked(transcriptPath) {
  if (!transcriptPath || !existsSync(transcriptPath)) return false;
  if (statSync(transcriptPath).size > MAX_SCAN_BYTES) return true;  // cannot tell: stay quiet
  for (const line of readFileSync(transcriptPath, 'utf8').split('\n')) {
    if (!line.includes('codex-converge')) continue;
    if (line.includes('<command-name>/codex-converge')) return true;
    let e;
    try { e = JSON.parse(line); } catch { continue; }
    if (e.type !== 'assistant') continue;
    for (const b of (e.message && e.message.content) || []) {
      if (b && b.type === 'tool_use' && b.name === 'Skill'
          && String((b.input && b.input.skill) || '').endsWith('codex-converge')) return true;
    }
  }
  return false;
}

function main() {
  let hook;
  try { hook = JSON.parse(readFileSync(0, 'utf8')); } catch { return; }
  if ((hook.hook_event_name || '') !== 'UserPromptSubmit') return;

  const stateDir = join(tmpdir(), 'claude-codex-converge-reminder');
  const stateFile = join(stateDir, `${String(hook.session_id || 'unknown').replace(/[^A-Za-z0-9_-]/g, '_')}.done`);
  if (existsSync(stateFile)) return;                                 // guard 1
  const settle = (why) => {
    try { mkdirSync(stateDir, { recursive: true }); writeFileSync(stateFile, why); return true; }
    catch { return false; }
  };

  if (process.env.CLAUDE_HANDOFF_LANE) { settle('dispatch'); return; } // guard 3
  const kind = classify(hook.prompt);
  if (kind === 'dispatch' || kind === 'names-skill') { settle(kind); return; }
  if (kind !== 'build') return;                                      // guard 4: wait for one
  if (alreadyInvoked(hook.transcript_path)) { settle('invoked'); return; } // guard 2
  // Record BEFORE speaking: a reminder that cannot be recorded would repeat every prompt.
  if (!settle('reminded')) return;

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: { hookEventName: 'UserPromptSubmit', additionalContext: REMINDER },
  }));
}

try { main(); } catch { /* guard 5: fail silent */ }
