---
name: gui-launched-tools-get-no-shell
description: A GUI-launched command (VS Code terminal profile, Automator, LaunchAgent, .app) runs with NO shell — ~/.zshrc never runs, so PATH is launchd's bare four dirs and every tool you installed is missing
metadata:
  type: reference
scope: global
---

When a GUI launches a command directly — a VS Code `terminal.integrated.profiles` entry with a
`path`, a LaunchAgent, an Automator action, an `.app` — **no shell is involved**. `~/.zshrc`,
`~/.zprofile` and `~/.bash_profile` never run. The process inherits launchd's PATH, which on macOS is
just `/usr/bin:/bin:/usr/sbin:/sbin`.

Everything installed anywhere else is invisible: `~/.local/bin`, `/opt/homebrew/bin`, and anything
under `~/.nvm/versions/node/*/bin`. Measured 2026-08-21 — a wrapper that worked perfectly in every
terminal died instantly under a GUI profile because both `node` and `claude` failed to resolve.

**The symptom is silence, not an error.** A VS Code profile tab closes the moment its process exits,
so a `command not found` scrolls past faster than it can be read. The user reports *"it never opens"*
and there is nothing to paste. Do not diagnose this from the launch you can reproduce in your own
shell — a shell-spawned test passes while the GUI path fails, every time.

**Reproduce it in one line** rather than guessing:

```bash
env -i HOME="$HOME" PATH="/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm-256color /abs/path/to/tool <args>
```

**Build any GUI-launchable wrapper to survive it:**

1. **Never trust PATH for a dependency.** Resolve each binary by trying `command -v`, then an explicit
   list of real locations, then a glob for version-managed installs (`ls -td ~/.nvm/versions/node/*/bin/node | head -1`).
2. **Never exit silently.** On failure print the reason, append it to a log file, and — when stdout is
   a TTY — `read` to hold the window open so the message survives the tab closing.
3. **Ship a `doctor` subcommand** that prints resolved paths, PATH, TTY status and recent errors, so
   the next report is a paste instead of a guess.

Related: install a tool as an executable on PATH, never as a shell function in `.zshrc` — a function
only exists in shells started after the edit, so already-open terminals report `command not found`
and every fix you make appears not to work.

**The VS Code EXTENSION HOST is one of these processes too.** An extension that shells out inherits
launchd's bare PATH, so `node`, `claude` and any `~/.local/bin` tool are invisible to it — and an
extension that fails there produces a button that does nothing when clicked, which is the same silent
failure as the tab that closes before you can read it. Resolve every binary absolutely, and surface
failures with `showErrorMessage`, never a swallowed throw. Related: never block the host thread on a
timer — poll with `promisify(execFile)`, not `execFileSync`.
