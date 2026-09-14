#!/usr/bin/env node
// UserPromptSubmit hook: when the user says she is updating her Claude config, and the
// repo she is standing in has GitHub Actions workflows that have not been cost-audited
// recently, tell the session to ask her whether to re-audit.
//
// Why this trigger. Updating the Claude config does not change a repo's Actions bill,
// so the two are not causally linked. The link is a CADENCE one: a config update is a
// recurring housekeeping moment the user actually reaches, and a CI bill is a RECURRING
// cost that drifts back up as workflows are added. Anchoring the reminder to a moment
// she reaches beats anchoring it to an event nobody watches for.
//
// Three guards keep it from becoming a nag, because a prompt that is usually answered
// "no" gets ignored and then the mechanism is dead:
//   1. It stays silent unless the cwd's repo actually HAS workflow files. In the config
//      repo itself, or any repo with no CI, there is nothing to audit and nothing is said.
//   2. It stays silent unless that repo's last audit (or last ask) is older than the
//      window below. One ask per repo per window, whatever the answer was.
//   3. It fails SILENT. Any error at all emits nothing. A hook that throws on every
//      prompt is worse than no hook.
//
// State lives in ~/.claude/ops/ci-cost-audits/, deliberately OUTSIDE ~/dotfiles/claude:
// that repo default-publishes to the public mirror, and these records carry the names of
// private repositories.

import { readFileSync, writeFileSync, mkdirSync, readdirSync, realpathSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { homedir } from 'node:os';
import { execFileSync } from 'node:child_process';

const WINDOW_DAYS = 30;              // monthly, because the Actions bill is monthly
const STATE_DIR = join(homedir(), '.claude', 'ops', 'ci-cost-audits');

// Both an update verb and a config noun, within a short span of each other, so that
// "update the deploy config" or a passing mention of "claude config" does not fire.
const VERB = String.raw`(?:updat|sync|syncing|edit|chang|tweak|revis|refresh|publish|push)\w*`;
const NOUN = String.raw`(?:claude(?:\s+code)?\s+config\w*|claude\s+settings|my\s+config\w*|my\s+dotfiles|the\s+dotfiles)`;
const NEAR = String.raw`[^.?!\n]{0,40}`;
const TRIGGER = new RegExp(`(?:${VERB}${NEAR}${NOUN}|${NOUN}${NEAR}${VERB})`, 'i');

function gitRepoKey(cwd) {
  // --git-common-dir so every worktree of one repo shares a single audit record:
  // auditing from a worktree is auditing the repo.
  const common = execFileSync('git', ['-C', cwd, 'rev-parse', '--git-common-dir'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  const abs = realpathSync(resolve(cwd, common));
  const top = execFileSync('git', ['-C', cwd, 'rev-parse', '--show-toplevel'],
    { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim();
  const key = abs.replace(/[^A-Za-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(-120);
  return { key, top, common: abs };
}

// The workflows live beside the repo's main checkout, which for a worktree is not the
// worktree itself. Look in both, and count only files GitHub would actually run.
function workflowCount(top, commonDir) {
  for (const r of [top, dirname(commonDir)]) {
    const d = join(r, '.github', 'workflows');
    try {
      const n = readdirSync(d).filter((f) => /\.ya?ml$/i.test(f)).length;
      if (n > 0) return { n, where: r };
    } catch { /* not there; try the next root */ }
  }
  return { n: 0, where: null };
}

function main() {
  let hook;
  try { hook = JSON.parse(readFileSync(0, 'utf8')); } catch { return; }
  if ((hook.hook_event_name || '') !== 'UserPromptSubmit') return;

  const prompt = String(hook.prompt || '');
  if (!TRIGGER.test(prompt)) return;

  const cwd = hook.cwd || process.cwd();
  let repo;
  try { repo = gitRepoKey(cwd); } catch { return; }   // not a git repo: nothing to audit

  const { n: workflows, where } = workflowCount(repo.top, repo.common);
  if (workflows === 0) return;                         // no CI here: say nothing

  const stateFile = join(STATE_DIR, `${repo.key}.json`);
  let state = {};
  try { state = JSON.parse(readFileSync(stateFile, 'utf8')); } catch { /* first time */ }

  const now = Date.now();
  const last = Math.max(Number(state.lastAuditedAt) || 0, Number(state.lastPromptedAt) || 0);
  const days = last ? Math.floor((now - last) / 86400000) : null;
  if (days !== null && days < WINDOW_DAYS) return;     // asked or audited recently

  try {
    mkdirSync(STATE_DIR, { recursive: true });
    writeFileSync(stateFile, JSON.stringify(
      { ...state, repo: repo.top, lastPromptedAt: now }, null, 2));
  } catch { return; }   // cannot record the ask, so do not make it: otherwise it repeats

  const name = repo.top.split('/').pop();
  const since = days === null
    ? 'It has never been cost-audited.'
    : `Its last CI cost audit or ask was ${days} days ago.`;

  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: 'UserPromptSubmit',
      additionalContext:
        `[ci-cost-reaudit] the user is updating her Claude config, and this repo (${name}, ` +
        `${workflows} workflow file(s) under ${where}/.github/workflows) is due a CI cost ` +
        `check. ${since} A GitHub Actions bill drifts back up as workflows are added, so ` +
        `this is a recurring cost worth re-measuring roughly monthly.\n` +
        `Do her config work FIRST. Then, in the same reply, ask her ONE plain question: ` +
        `whether to re-audit ${name}'s CI cost now. Ask once, with your recommendation, ` +
        `and do not raise it again this session whatever she answers.\n` +
        `If she says yes, invoke the \`ci-cost\` skill in Mode B (auditing an existing ` +
        `repository), measure before proposing anything, and change no workflow file until ` +
        `she approves a specific lever.\n` +
        `When an audit actually completes, record it so this does not fire again for ` +
        `${WINDOW_DAYS} days: \`~/dotfiles/claude/bin/ci-cost-audit-record.sh\` (run it from ` +
        `inside the repo).\n` +
        `This reminder is throttled to one per repo per ${WINDOW_DAYS} days and has already ` +
        `been recorded, so it will not repeat even if she declines.`,
    },
  }));
}

try { main(); } catch { /* fail silent: never break a prompt over a reminder */ }
