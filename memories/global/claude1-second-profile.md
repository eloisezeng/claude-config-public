---
name: claude1-second-profile
description: "How the `claude1` command launches a second Claude Code profile (gmail account) separate from the default `claude` (your-company)"
metadata: 
  node_type: memory
  type: reference
  scope: global
  originSessionId: a20cde08-e7f2-48ca-90c3-799e1a06aef4
---

Set up 2026-06-15. The user runs two Claude Code identities on this Mac:

- `claude` (default) → **your-company** account (you@example.com), auth via macOS Keychain entry `Claude Code-credentials` / acct `user`. Untouched by the setup.
- `claude1` → **gmail** account, via isolated `CLAUDE_CONFIG_DIR=~/.claude1` + a long-lived OAuth token injected as `CLAUDE_CODE_OAUTH_TOKEN`.

**Mechanism:**
- `claude1` is a zsh function in `~/.zshrc` that reads the gmail token from Keychain service `Claude Code-gmail-token` and launches `command claude` with the two env vars. Guards (errors out) if no token stored.
- `~/.local/bin/claude1-login` mints the gmail token: backs up the your-company Keychain entry, temporarily clears it to force a fresh login, runs `claude setup-token` (user signs in with gmail in browser), stores the `sk-ant-oat…` token in Keychain `Claude Code-gmail-token`, and restores your-company on exit (trap on EXIT/INT/TERM). Re-run it to rotate/refresh the token.
- `~/.claude1` shares tooling with `~/.claude` **by symlink, not by copy** (corrected 2026-08-07 — the original copy-based seeding silently drifted for ~2 months: divergent `model`, hook scripts, statusline, and plugin versions).
  Run `./install.sh ~/.claude ~/.claude1` to (re)establish it; the mirror pass links `CLAUDE.md`, `AGENTS.md`, the four repo skills, and `settings.json` from `~/.claude` into `~/.claude1`. `hooks/` and `plugins/` are linked by hand (the installer deliberately excludes plugins).
  Keep separate: login, `projects/`, `sessions/`, `history.jsonl`, `.claude.json`, context-mode runtime state.
  **Never symlink `~/.claude1/skills` wholesale** — the installer links individual skills *into* `$MIRROR/skills/`, so a directory link makes it write a self-referential link (ELOOP). Same trap bit context-mode's `context-mode-cache-heal.mjs`, whose `statSync().isDirectory()` follows symlinks and so counted a symlink as a version dir, tying `1.0.151 ⇄ 1.0.169` into a cycle that broke every `PreToolUse` hook until the real tree was restored from `plugins/marketplaces/context-mode`.

**Why this approach:** macOS keeps ONE shared Keychain login across all `CLAUDE_CONFIG_DIR` values, so two OAuth subscription logins can't coexist there — the env-var token bypasses the Keychain. Verified empirically on this machine that running with `CLAUDE_CODE_OAUTH_TOKEN` set does NOT delete or overwrite the shared `Claude Code-credentials` entry (the reported claude-code#37512 bug does NOT reproduce here), so `claude1` is safe for the your-company login.
