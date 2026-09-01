---
name: global-config-repo
description: Global Claude config is a symlinked private dotfiles repo with cross-machine auto-sync (commit+pull+push) via sync.sh
metadata: 
  node_type: memory
  type: reference
  scope: global
  originSessionId: 6a537bfa-8fc7-45db-a0c0-923bc6715478
---

The user's global Claude config lives in a private GitHub repo: **your-org/claude-config**, checked out at `~/dotfiles/claude/` (source of truth).

- `~/.claude` is the canonical config dir; `~/.claude1` (the active `CLAUDE_CONFIG_DIR`) mirrors it. CLAUDE.md, AGENTS.md, settings(.linux).json, and the tracked skills (email-drafter, codex-converge, no-mistakes, scientific-figures) are all symlinks resolving into the repo. On Linux/WSL the repo lives at `~/claude-config/`, not `~/dotfiles/claude/`.
- **settings is per-OS:** `settings.json` (macOS) and `settings.linux.json` (Linux) both link to `~/.claude/settings.json`; `install.sh` picks by `uname`. They differ because hooks reference OS-specific tools/paths (osascript on macOS, notify.sh on Linux). Windows uses `settings.windows.json`.
- **Windows is the copy-not-symlink node.** `install.sh` is unix-only (symlinks + launchd/systemd) — never run it there. The repo still sits at `~/dotfiles/claude`, but `CLAUDE.md`, `AGENTS.md`, `settings.windows.json` → `settings.json`, and `skills/` are **copied** into `~/.claude`, because symlinks need Developer Mode or admin. Consequence both ways: edits made inside `~/.claude` do NOT flow back to the repo, and a `git pull` does NOT refresh the live copies — re-copy after pulling, or the live config silently rots (it had drifted from Jun 26 to Aug 4 before anyone noticed). Windows hooks are `powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "…"` strings using `$env:USERPROFILE` (never a literal `C:\Users\<name>`, which would break the shared file on every other machine) and only single quotes inside the `-Command` argument — nested escaped double quotes get mangled by the cmd-level hook runner.
- **Cross-machine auto-sync** runs `sync.sh` (commit local changes → pull `--rebase` ONLY if `git ls-remote` shows the remote advanced → push if ahead; mkdir-locked, portable). It is **event-driven, no polling**: a tracked-file change fires it (macOS launchd `com.your-org.claude-config-autopush` WatchPaths; Linux systemd `.path` unit `claude-config-sync.path`, linger enabled; Windows logon Task Scheduler task `ClaudeConfigSync` running `watch.ps1`, a resident FileSystemWatcher that calls `sync.ps1` — log at `%LOCALAPPDATA%\claude-config-sync.log`), and an async Claude `SessionStart` hook runs it on session start. So editing tracked files — even outside Claude — silently creates `auto: sync config <ts>` commits. Pull happens at session start + on any local edit; a remote push during an idle open session isn't pulled until next session start. Expected, not a bug.
- Push auth: macOS keychain as **your-org** (not your-org); Linux via its own git credentials. `install.sh` recreates the symlinks + sync scheduler on a new machine.
- The `-axi` CLIs (`lavish-axi`, `gh-axi`, `chrome-devtools-axi`) are npm globals, not vendored: `npm i -g gh-axi chrome-devtools-axi` (want Node ≥ 20). `lavish-axi` is NOT installed from npm — the mandated fork is unpublished, so `bin/install-lavish-fork.sh` clones, builds and `npm link`s it; a plain `npm i -g lavish-axi` silently installs upstream instead.

**How to apply:** if edits to ~/.claude config files produce surprise git commits, that's the auto-sync. Pause it on macOS with `launchctl bootout "gui/$(id -u)/com.your-org.claude-config-autopush"`, on Linux with `systemctl --user stop claude-config-sync.path`.
