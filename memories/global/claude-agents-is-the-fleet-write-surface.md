---
name: claude-agents-is-the-fleet-write-surface
description: `claude agents` is the only supported way to SEND to a running background session — arrow to it and press space to reply; it gates on folder trust so never launch it from $HOME
metadata:
  type: reference
scope: global
---

`claude agents` opens the fleet view, and it is **not** only a launcher for new sessions. Verified by
driving the TUI under a real pty on 2026-08-21:

- **↑/↓** selects an existing session row; the footer changes to `open · space to reply · ctrl+x to delete`.
- **space** opens a `❯ reply` composer **bound to that session**, showing its last message for context.
  Delivery is verified end-to-end, not just "the composer opens": a probe typed here reached a
  pre-existing 631k-token session, woke it from state `done`, and it acted on the message. A reply
  resumes a finished session as readily as it nudges a running one.
- **enter** opens the session; **esc** backs out sending nothing; **ctrl+s** switches views; **?** lists shortcuts.

The visible prompt reads *"describe a task for a new session"*, which makes the view look
write-only-for-new-work. That prompt is the composer for a NEW session; replying to an existing one is
the space binding on a selected row. Do not conclude from the prompt text that you cannot write to a
running session — probe the shortcuts.

**The default focus is the WRONG box.** The cursor starts in the bottom composer, whose placeholder
reads *"describe a task for a new session"*. Typing there and pressing enter **spawns a new session**
— it is not a reply, and it looks exactly like "writing to my sessions doesn't work". You must select
a row first. Check this before diagnosing anything deeper.

**A listed row is not necessarily reachable.** A row appears when it has a LIVE PID **or** a
non-terminal `state`; `claude agents --json` prints `pid` only for the former. So the list has two
populations, and they are cleared by opposite means — read `pid` first, never `state` alone:

- **pid-less + non-terminal** (`blocked`) — a dead record, no process at all. It lingers purely
  because `blocked` is non-terminal. Clear it by writing a TERMINAL state (`failed`/`done`) into
  `~/.claude/jobs/<short>/state.json`; measured 2026-08-25, this dropped 92 of 102 rows.
- **live pid + terminal state** (`done`/`failed`) — process residue outliving its own record. State
  is already terminal, so only the PROCESS KILL clears it. `bg-spare` traps SIGTERM: escalate to
  SIGKILL and kill the `bg-pty-host` parent and the `context-mode` node child too (~500MB each).

Prove the mechanism with a two-arm control before a batch write — flip ONE row terminal, confirm the
count drops by exactly 1 and that id vanishes, then revert and confirm it comes BACK. Marking terminal
is reversible and non-destructive: it never touches the transcript, so `claude --resume <sessionId>`
still works. Prefer `failed` + a "retired by decision" detail over `done`, since `failed` is the state
whose two readings a revival wave is required to disambiguate from `detail` —
`[[a-revival-wave-must-read-detail-before-nudging]]`. Transcripts age out (~2 months) independently of
job records, so an old row can be unresumable before you ever touch it — check, don't infer.

Cross-check reachability against `~/.claude/daemon/roster.json` (key `workers`) AND the rendezvous
socket `/tmp/cc-daemon-<uid>/<id>/rv/<short>.sock` — both present means reachable. A row blocked on a
PERMISSION PROMPT (detail like `approve Bash: …`) also cannot be cleared by typed text. **`ppid=1` does
NOT mean dead** — the daemon restarts and reparents live hosts to init, so an orphaned-looking tree can
hold the one seat that is genuinely working.

**Two things make it fail to launch, and neither prints an obvious cause:**

1. **Folder trust.** Launched from an untrusted directory — `$HOME` especially — it shows *"Quick
   safety check: Is this a project you created or one you trust?"* instead of the fleet. Always `cd`
   to a trusted repo first. This is the single most likely reason a wrapper "doesn't work".
2. **No TTY.** It refuses with `'claude agents' requires an interactive terminal (stdout is not a TTY)`.
   Piped keystrokes cannot drive it either; to automate or probe it, allocate a real pty
   (`python3 -c` with the `pty` module, or `script -q /dev/null <cmd>`).

**Do not build a message-sender on the daemon's private sockets**
(`/tmp/cc-daemon-<uid>/<id>/rv/<short>.sock`, `~/.claude/daemon/control.key`). The protocol is
unstable and a malformed frame lands in a live session mid-run. `claude agents` is the supported door.

Wrapper installed at `~/.local/bin/fleet` (`fleet` watch-all · `fleet <short>` tail one · `fleet write`
· `fleet doctor`). It lives on PATH rather than in `.zshrc` deliberately: a shell function only exists
in shells started after the edit, so already-open terminals report `command not found` and the fix
looks like it failed — `[[install-tools-on-path-not-in-shell-rc]]`.
