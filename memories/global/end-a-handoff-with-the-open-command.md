---
name: end-a-handoff-with-the-open-command
description: The user 2026-08-25 — every response that hands work to another session must END with the copy-paste command to open that session; a handoff she cannot open in one paste is not delivered
metadata:
  type: feedback
  scope: global
---

The user, 2026-08-25: *"every time u handoff can u give me command to open handoff session at bottom of ur response?"*

**Why:** a handoff is only useful if she can get into it. Digging the session id out of a `.dispatch` record, then remembering whether it is `attach` or `--resume`, is friction she should never pay — and the ids are exactly the thing that silently break (see below). The command belongs at the BOTTOM because that is where her eye lands last and where a copy-paste is nearest the prompt.

**How to apply:**
- End every response that DISPATCHED work to another session with a fenced, copy-pasteable command, last thing before the state line. Not linked, not described — the literal command.
- **The two commands take DIFFERENT identifiers for the same seat.** Verified 2026-08-25 by a paste that failed with `No job matching '<uuid>'`:
  - `claude attach <SHORT>` — a LIVE background seat, where SHORT is the **8-hex job id**, i.e. the name of the `~/.claude/jobs/<SHORT>/` directory and the first segment of the UUID. `attach` resolves *jobs*, not sessions; handing it the full UUID fails. It opens the seat in the terminal, keeps it running either way, Ctrl+Z drops back to the shell. **No `--` before the id** — `claude attach -- <id>` is rejected as an unknown option.
  - `claude --resume <FULL-UUID>` — a session that has FINISHED. This one wants the full `sessionId` stored *inside* that job's `state.json`, not the short id.
  - `fleet <SHORT>` read-only tail · `fleet open <SHORT>` writable picker narrowed to it · `fleet who` which seats can actually receive a reply.
  - Derive both from the job dir, never by eye: `ls ~/.claude/jobs` gives the SHORT ids; `state.json` in each gives `sessionId` for the resume form.
- If more than one session was dispatched, give one line per session, each labelled with what that seat is doing.
- If the turn ended RUNNING or BLOCKED rather than HANDED OFF, say so — do not invent a session to attach to. The command appears when, and only when, there is a real seat behind it — [[a-report-is-not-a-stopping-point]], [[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]].
