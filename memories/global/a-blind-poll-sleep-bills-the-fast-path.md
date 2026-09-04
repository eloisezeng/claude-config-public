---
name: a-blind-poll-sleep-bills-the-fast-path
description: A watchdog's `sleep INTERVAL` is paid in full by every run that finishes early, and neither the wedge test nor its live control can see it — profile the loop, and pin the fast path with its own upper bound
scope: global
metadata:
  type: feedback
---

A supervision loop written as `while kill -0 "$PID"; do sleep "$POLL"; ...judge...; done`
charges the FULL interval to every child that exits early — once per attempt, and again on every
retry. The interval is chosen for the slow case and then billed to the fast one, so the cost is
invisible in the code and enormous in aggregate: `run-codex.sh` at `POLL=10` cost
`tests/codex-loop.test.sh` ~300s across ~33 launcher calls whose stub exits in milliseconds —
more than twice its 94-mutant mutation battery — and pushed the suite to 841s, 93% of its 900s
ceiling, where it read as a TIMEOUT with no assertion to point at. `29% cpu` in `time`'s output
is the whole diagnosis: the suite was asleep for 71% of its runtime.

**The trap is that the existing tests cannot see it.** A wedge test (silent child must be killed)
passes whether the poll sleeps or busy-spins, and its live control (chatty child must survive)
passes either way too, because its log refreshes faster than the idle window in both. So the
timing has NO assertion in either direction and can regress freely. Pin both: an instant-exit run
at a deliberately large `POLL` must return well inside it (a 15x margin on a measured ~1s, not a
duration the machine has to be fast enough to meet), and a silent child must still be killed but
NOT before `POLL x STALL_LIMIT` — a lower bound on a sleep the code was TOLD to take, which a
busy-spin fails. `[[a-control-must-match-the-probes-shape]]` `[[wall-clock-ceilings-measure-the-machine]]`

**Why:** the fix — wait in 1s steps and return the moment the child is gone — buys 36% of the
suite (841s → 539s) and speeds every production run too, while changing nothing that is verified:
the idle/stall accounting still runs once per COMPLETED poll of a LIVING child, and an early
return only hands it a fresher log. A speedup that changes what is verified is not one
`[[optimize-the-loop-unprompted]]`.

**How to apply:** when a suite creeps toward its ceiling, profile before raising it — the gap
histogram names the cause, and a pile of gaps at exactly the poll interval (and at
interval x attempts) is this bug, not slow code. Raising the cap, splitting the suite, or shrinking
the workload would each have moved something that was never the problem. And check the loop's own
exit path while you are there: a child that exits inside what turns out to be the FINAL idle
window is still judged by the body once more and can be reported killed with its verdict discarded
`[[verify-claims-against-artifacts]]`.
