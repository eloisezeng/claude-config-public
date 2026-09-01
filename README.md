# claude-config

Portable Claude Code global configuration.
This repo is the single source of truth; config directories symlink into it.

## What's tracked

- `CLAUDE.md` — global agent instructions (the real file).
- `AGENTS.md` — symlink to `CLAUDE.md`, so tools that look for either name resolve to the same content.
- `settings.json` — global settings for **macOS** (hooks, permissions, env). No secrets.
- `settings.linux.json` — global settings for **Linux/WSL**. Hooks reference
  OS-specific tools (`osascript` on macOS, `notify.sh` on Linux), so a single
  shared file can't serve both. `install.sh` picks the right one by `uname`
  and links it to `~/.claude/settings.json`.
- `settings.windows.json` — global settings for **Windows**. Same per-OS reason:
  its `SessionStart` hook runs `sync.ps1` via `powershell.exe`. There is no
  Windows `install.sh`; it is **copied** (not symlinked) to
  `~/.claude/settings.json` — see the Windows note under "Cross-machine auto-sync".
- `sync.ps1` / `watch.ps1` — the **Windows** auto-sync core and file watcher,
  PowerShell ports of `sync.sh` and the launchd/systemd watcher.
- `skills/` — personally authored/adopted skills (`email-drafter`, `codex-converge`, `no-mistakes`, `scientific-figures`).
- `plugins/` — reinstall manifest only, not the plugin code itself.

## What's NOT tracked, and why

- **Plugins** come from marketplaces and are reinstalled, not vendored.
  See `plugins/known_marketplaces.json` (the 3 marketplaces) and
  `plugins/installed_plugins.json` (5 installed: skill-creator, superpowers,
  frontend-design, context-mode, claude-mem — claude-mem **disabled**
  2026-07-31 via `enabledPlugins` in `settings.json`; redundant with the
  hand-curated memory system and its observer pipeline burned tokens).
- **GSD** (`gsd-*` skills/agents/hooks) was **retired 2026-07-31** (unused: no
  `.planning/` anywhere). Archived to `~/.claude/{skills,agents}-archive` on
  the original machine; do not reinstall anywhere. The last reference
  (the `gsd-statusline.js` statusLine) was removed from `settings.json`
  2026-07-31; `settings.windows.json` still carries gsd hooks and is cleaned
  up on the Windows side.
- **`-axi` CLI tools** — `lavish-axi` (human review / visualization),
  `gh-axi` (GitHub), `chrome-devtools-axi` (browser automation), the tools
  `CLAUDE.md` mandates. Two are plain npm globals, not Claude plugins:
  `npm i -g gh-axi chrome-devtools-axi`. **`lavish-axi` is the exception** —
  `CLAUDE.md` mandates a fork that is not published to npm, so install it with
  `bin/install-lavish-fork.sh` (clone + build + `npm link`); a plain
  `npm i -g lavish-axi` silently gives you the upstream package instead. They want **Node ≥ 20**
  (they run on 18 but warn); install Node 20+ (e.g. via nvm) if anything misbehaves.
  No-sudo tip: `npm config set prefix ~/.local` puts the binaries in
  `~/.local/bin` (usually already on `PATH`).
- **State** — `projects/`, `history.jsonl`, caches, `daemon*`, `file-history/`,
  `backups/`, credentials — is machine-local and never belongs in git.

## OpenSuperWhisper (dictation)

`install.sh` also installs [OpenSuperWhisper](https://github.com/starmel/OpenSuperWhisper),
a local Whisper dictation app for macOS, via `brew install --cask opensuperwhisper`
(macOS 14+ on Apple Silicon). Skip it with `SKIP_OPENSUPERWHISPER=1 ./install.sh`.
After install, launch the app and grant the microphone / accessibility permissions
it requests.

## Setup on a new machine

```sh
git clone <this-repo> ~/dotfiles/claude
cd ~/dotfiles/claude
./install.sh                 # links repo -> ~/.claude
```

The `~/dotfiles/claude` location is load-bearing twice over: the tracked hook
commands and `sync-memories.sh` point there via `$HOME`, and on macOS the
TCC-protected folders (`~/Documents`, `~/Desktop`, `~/Downloads`) are unreadable
to the launchd auto-sync watcher — a clone there fails with
"Operation not permitted" and never auto-pushes.

Then reinstall plugins (per the manifest) and install the `-axi` CLI tools
(`npm i -g gh-axi chrome-devtools-axi`, then `bin/install-lavish-fork.sh` for the
forked `lavish-axi`).

`install.sh` also sets up cross-machine auto-sync (see below) so every machine
keeps the newest config and pushes its own edits automatically.

### This machine's layout

`~/.claude` is the canonical config dir. `~/.claude1` (used here via
`CLAUDE_CONFIG_DIR`) mirrors it. That was set up with:

```sh
./install.sh ~/.claude ~/.claude1
```

## Collaborators use forks, not write access

This is one person's config. `CLAUDE.md`, `memories/` and `skills/` encode
The user's preferences, her machines' Codex profiles, and her account's model
availability — none of which are portable.

Because autosync pushes every tracked edit with **no review step**, a second
person with write access silently rewrites the first person's live agent config.
That is not hypothetical: a Windows machine's Codex routing (`-p terrax`,
`-p terramax`) was autosynced into `codex-converge` on 2026-08-13. Those
profiles do not exist on the Mac, and codex does not error on an unknown `-p` —
it silently falls back. Every high-stakes review on the Mac ran at reasoning
effort `none` for four days while reporting normal verdicts.

So each person autosyncs to **their own fork**:

- `your-org/claude-config` is canonical. Only the user pushes to it.
- A collaborator forks it, sets their fork as `origin` and this repo as
  `upstream` (push-disabled), and autosyncs freely to their own fork.
- They pull improvements from `upstream` whenever they like.
- Anything coming back arrives as a **pull request**, never automatically.

Setup runbook: [`docs/fork-setup-for-collaborators.md`](docs/fork-setup-for-collaborators.md).

Two guard rails back this up, since a convention alone would not have caught the
case above:

- `skills/codex-converge/run-codex.sh` refuses a `-p` naming a profile with no
  matching `$CODEX_HOME/<name>.config.toml`, and prints the tier the run
  actually used from codex's own banner.
- `sync.sh` / `sync.ps1` no longer swallow git errors — see below.

## Cross-machine auto-sync

One portable script, `sync.sh`, does the whole loop: commit local changes →
pull (rebase) **only when the remote has actually advanced** (a cheap
`git ls-remote` tip check, so an idle tick is one ref lookup, not a full pull) →
push if ahead. It no-ops when clean, and serializes itself with an atomic mkdir
lock so overlapping triggers can't race the index.
Commits it makes are titled `auto: sync config <timestamp>`. It is **purely
event-driven — there is no periodic poll.** Two kinds of event fire it:

**Failures are never silent.** Both scripts previously ran every git step as
`... 2>/dev/null || true`, so a rebase conflict between two machines was
indistinguishable from a clean no-op and the repo could stop syncing for days
unnoticed. Now each step is checked: a real failure logs with its stderr, raises
a desktop notification, exits non-zero, and **leaves the repo mid-operation**
rather than auto-aborting, so the collision can be diagnosed. A repo already
mid-rebase is refused rather than compounded. Being offline is not a failure —
it logs a skip and exits 0. Logs: `~/Library/Logs/claude-config-sync.log`
(macOS), `${XDG_STATE_HOME:-~/.local/state}/claude-config-sync.log` (Linux),
`%LOCALAPPDATA%\claude-config-sync.log` plus a `.FAILED` marker (Windows).
Pinned by `tests/sync-failure-visibility.test.sh`.

- **A tracked file changes** → push your edit immediately (and pull anything new
  in the same run, since `sync.sh` checks the remote tip).
  - **macOS** — a launchd agent (`com.your-org.claude-config-autopush`) with
    `WatchPaths`. Log: `~/Library/Logs/claude-config-autopush.log`. Manage:
    ```sh
    launchctl bootout   "gui/$(id -u)/com.your-org.claude-config-autopush"
    launchctl bootstrap "gui/$(id -u)" ~/Library/LaunchAgents/com.your-org.claude-config-autopush.plist
    ```
  - **Linux/WSL** — a systemd user `.path` unit (`claude-config-sync.path`,
    inotify, no `inotify-tools` needed); linger is enabled so it survives logout.
    Manage: `systemctl --user {status,stop,disable} claude-config-sync.path`.
  - **Windows** — a logon Task Scheduler task (`ClaudeConfigSync`) runs
    `watch.ps1`, a resident `FileSystemWatcher` that ignores `.git/`, debounces,
    and calls `sync.ps1`. Log: `%LOCALAPPDATA%\claude-config-sync.log`. Manage:
    ```powershell
    Get-ScheduledTask ClaudeConfigSync | Get-ScheduledTaskInfo   # status
    Stop-ScheduledTask  -TaskName ClaudeConfigSync               # stop now
    Start-ScheduledTask -TaskName ClaudeConfigSync               # start now
    Unregister-ScheduledTask -TaskName ClaudeConfigSync -Confirm:$false  # remove
    ```
- **A Claude session starts** → an async `SessionStart` hook runs `sync.sh`
  (`sync.ps1` on Windows), so you open on the newest config.

**Why no poll:** git/GitHub can't push a notification to a NAT'd laptop without a
public webhook endpoint (a tunnel/relay), so a client only learns of a remote
push by asking. We skip that ask and instead pull at session start and on any
local edit. **Trade-off:** a push from another machine while you have an idle
session open here isn't pulled until your next session start or next local edit.
(Directory watches aren't recursive, so a deeply-nested edit made entirely
outside Claude is likewise caught at the next session start.)

Skip the watcher at install time with `SKIP_WATCHER=1 ./install.sh`.

## Caveat: settings.json

`settings.json` is symlinked. If a tool rewrites it via atomic replace (temp
file + rename), the symlink is replaced by a real file and changes stop syncing
to the repo. If that happens, re-run `install.sh` to restore the link, then
commit any wanted changes.

## Caveat: Windows uses copies, not symlinks

Windows can't create the symlinks `install.sh` relies on without Developer Mode
or admin, so on Windows the tracked files (`CLAUDE.md`, `AGENTS.md`,
`settings.windows.json` → `settings.json`, `skills/`) are **copied** into
`~/.claude` rather than linked.
Consequence: edits made inside `~/.claude` do **not** flow back to the repo, and
a `git pull` updating the repo does **not** update the live `~/.claude` copies.
The `ClaudeConfigSync` watcher syncs **the repo** (edit the files under the repo
checkout, e.g. on the Desktop, and they auto-commit + push); re-copy into
`~/.claude` after pulling, or enable Developer Mode and switch to symlinks for
true live-sync.
