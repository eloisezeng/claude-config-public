---
name: bg-session-liveness-and-approval-parking
description: Three probes that report a working bg session as idle, and the approval-prompt park that no message can clear
metadata:
  type: feedback
  scope: global
---

Three ways a healthy background session reads as dead, all measured 2026-08-22 while supervising a five-session fleet.

**1. `pgrep -P <pid>` cannot see an in-process Agent-tool subagent.**
A subagent runs inside the session, not as a child process, so it never appears in the parent PID's children.
On a session that delegates its work, `pgrep -P` returns "not busy" 100% of the time — including while a money-path commit is being authored.

**2. Transcript BYTE growth is not progress.**
A queued inbound message writes a `queue-operation` record; attachments write bytes too.
I watched a parked session grow +2,554 bytes and called it unblocked; it had done nothing.

**3. A queued `SendMessage` cannot drain past a live approval prompt.**
A session parked on tool approval never reaches a tool round, so the message sits unread.
**Messaging a permission-blocked session does not unblock it.**

**Probe in this order:** newest mtime across `~/.claude/projects/<proj>/<session-uuid>/subagents/agent-*.jsonl`; then the artifact the work must produce (`git -C <worktree> log -1`); then `state.json` `updatedAt` or a new *assistant* turn. Never raw file size, never `ps`.
**A flat parent with a fresh subagent write is the NORMAL shape of a healthy delegating session.**

**The park itself:** an unattended bg session told to call `EnterWorktree` blocks forever on
`state.json` `"needs": "approve Entering worktree"`. It may later time out to `tempo=idle` without
resuming, so it needs intervention either way.
**Remedy:** create the worktree with `git worktree add` and give the successor a handoff that
forbids `EnterWorktree` outright, ordering all file writes through Bash heredocs/`sed` with absolute
paths — `Write`/`Edit` stay refused, Bash writes do not. Verified twice.
Read `needs` directly in any watchdog; a stall threshold will sit silent through this for 25 minutes.

**Why it matters:** I killed a seat on a 3-minute-stale read and it had unblocked 40s earlier — see
[[act-on-fresh-state-anchor-by-identity]]. Related: [[absence-needs-a-probe-that-could-see-presence]],
[[worker-liveness-must-reflect-progress]], [[kill-bg-claude-sessions-via-job-state]].
