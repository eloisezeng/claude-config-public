---
name: a-standdown-must-disarm-the-shell-watchers
description: A fleet stand-down that only marks seats leaves the shell-side watchers armed — they are orphaned (ppid=1), outlive every seat, and are the residual ignition source; sweep processes, not state.json
metadata:
  type: feedback
  scope: global
---

Marking seats `failed`/`blocked` and guarding corpses with DO-NOT-REVIVE stands down the *seats*.
It does nothing to the **shell-side watchers**, which are separate processes that survive their owning session, reparent to `ppid=1`, and keep polling — and some can still **dispatch a fresh token-spending seat**.

Measured 2026-08-25, one day after a stand-down that read fully complete on `state.json` (92 blocked / 40 failed / 163 done / 1 working, 69 corpses guarded): a process sweep still found **nine** live residues —
two armed `handoff.sh --watch` dispatchers on objectives that had *completed* (their `.dispatch` records stuck at `state=launching`, so the watcher never saw the finish and stayed armed with `--heartbeat-min 20`);
a `lavish-axi poll --agent-reply` writing into a blocked seat's job dir (an `--agent-reply` poll emits **model** replies, so it bills);
a 300s `git ls-remote` gate watch, 2d old, whose stdout was a dead session's socket;
a **15s** `git status` sampler, 3d old, on handed-off work;
and four zsh holds permanently wedged on `until [ "$(pgrep -f killall30 | wc -l)" -eq 0 ]` — **the `pgrep -f` pattern matches the waiter's own argv**, so the predicate can never reach 0 and the loop cannot exit.

Rules:
- A stand-down is not complete until you have swept `ps`, not `state.json`. Grep for `handoff.sh --watch`, `*-watch*.sh`, `poll`, `sampler`, `until`/`while true` holds — then for each ask **whose objective already finished** and **whether anyone still reads its stdout** (`lsof -p <pid>` fd 1: a dead session's `unix` socket or a blocked seat's job dir = nobody).
- `state=launching` in a `.dispatch` record is not "starting" — on an hours-old record it means the watcher never observed the finish, so it is **armed indefinitely on completed work**. That is the ignition source, not a leftover.
- Never write a hold as `until pgrep -f <pat>`; the waiter matches itself. Anchor on a PID, or pattern the child cannot satisfy.
- Distinguish cost classes before killing: a shell-side poll is **zero-token** (kill it for hygiene and for what it can *dispatch*), an `--agent-reply` poll and an armed dispatcher are **token igniters** (kill them first).
- Keep the stall-watchdog of any seat that is genuinely still working — verify it ages from the **last assistant turn**, then leave it alone.

`blocked` protects against the daemon's auto-revival only. A SendMessage wave still wakes a blocked seat regardless of `state.json`, so dormant seats carrying large contexts remain live exposure — see [[a-revival-wave-must-read-detail-before-nudging]] and [[fleet-burn-budget]]; the guard that a wave is supposed to read lives in `detail`, not in `state`.

A `--bg` **seat** does not stand down by `kill` at all: the daemon owns it and respawns it. Measured 2026-09-23 — both processes of a stalled duplicate seat killed, `0 survivors` verified at +2s, and the daemon had it back under a new pid **15 s later**, still reachable in `ListAgents`, still carrying merge-and-publish authority on the same PR as the live seat. `claude stop <8-hex>` (alias `kill`) is the durable retirement and keeps the conversation — `claude attach` still works afterwards — so there is no reason to reach for `claude rm`, which also deletes the job dir, tmp and **worktree** that sibling seats may be standing in. Same lesson as `[[pausing-a-service-is-not-pausing-the-mechanism]]`, one layer down: ask what can restart this, and the answer for a seat is always the daemon.

Retire a **duplicate** seat by stopping it, never by messaging it: the message is itself the wake you are trying to prevent, and it arrives as live instructions. Find duplicates by objective, not by name — two seats dispatched onto one lane carry the *same* `intent` under different auto-generated names, and only one is the successor the lane record names.
