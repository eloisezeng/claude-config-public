---
name: windows-hook-commands-avoid-env-vars
description: "On Windows with Git Bash installed, Claude Code hook commands run through bash, so $env:VAR in a hook string is silently mangled — use literal absolute paths."
metadata: 
  node_type: memory
  scope: global
  type: feedback
  originSessionId: 392b87c5-6ae2-4364-b4de-44bf2c0843b9
---

Never put `$env:VAR` (or any `$`) inside a Claude Code hook `command` string on Windows.
Hook commands default to running through Git Bash when it is installed, and bash expands `$...` inside double quotes before PowerShell ever sees the string.
`$env:USERPROFILE` becomes `:USERPROFILE`, because bash reads `$env` as an unset variable and `:` cannot be part of a bash variable name.
Use literal absolute paths with forward slashes instead — PowerShell accepts forward slashes, and they also avoid bash's backslash-escaping rules.

**Why:** This failure is completely silent.
PowerShell *parses* `(:USERPROFILE + '/path')` without complaint, then throws `CommandNotFoundException` at runtime, and the hook's stderr is not surfaced.
On 2026-08-21 all six of the user's global hooks were dead this way — notifications, dotfiles sync, `inject-global-memory.mjs`, and `sync-memories.sh` — and it read as "the notifications got disabled" rather than as a bug.
Memory injection and memory sync had silently stopped working, so the global memory directories were empty.

**How to apply:** After writing or editing any hook command on Windows, grep the command string for `$` and replace every interpolation with a literal path.
Verify the exact string survives the shell by running `printf '%s\n' "<command>"` through the Bash tool and confirming it comes back byte-identical.
Then prove the hook actually fires by having it write a sentinel file — absence of that file is the cleanest signal that the command never reached its target.
Related: [[verify-claims-against-artifacts]], [[unambiguous-status-and-logs]].
