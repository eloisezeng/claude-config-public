---
name: a-poll-loop-inherits-its-predicate
description: A watch/hold loop inherits every side effect of the predicate it calls, so audit the predicate before arming; a script's own "READ-ONLY"/"cannot orphan" comment is a claim, never evidence
metadata:
  type: feedback
---

Before arming any polling loop, read the thing it calls and ask what that call *does* — not what the loop intends.
A hold armed to watch a document ran `node gate.mjs` every 120 s for over four hours; `gate.mjs` line 128 was an unconditional `git fetch`, which was on that lane's prohibition list.
The loop's own header said `READ-ONLY. Never mutates anything.` One line below, it shelled out to a network write.

**Why:** a loop multiplies its predicate's side effects by its iteration count, so a single tolerable action becomes a hundred prohibited ones, silently, with nobody reading the output.
The same audit answers a second question for free: if the predicate's success condition is unreachable (an unsatisfiable gate, a fixed-point hash), the loop can never fire on it, so the call is pure cost — drop it and **hash** the predicate instead of executing it. Hashing detects a *replaced* predicate, which is usually the only reachable signal anyway, and it costs no network.

**How to apply:**
- Read the predicate's source for network/mutation verbs (`fetch`, `clone`, `push`, `write`, `rm`) BEFORE arming, and prove afterwards that none fired — pin a witness artifact (`.git/FETCH_HEAD` mtime, a byte hash) before and after.
- Treat a script's self-description as an untested claim. `READ-ONLY`, `harness-tracked`, `dies with the session, cannot orphan` — each of these was false in the same file. Verify the claim, then fix the comment where the false one is written.
- On a **shared** artifact, the witness cannot be attributed to you (someone else's write moves the same mtime): stamp the breach from your own transcript's tool calls and say which — see [[re-read-cannot-tell-wrong-from-acted-on]] and [[stage-immediately-verify-commits-from-the-object]].
- Liveness of the loop is whether its READER turns, never PPID and never its own comment — [[liveness-ages-from-the-last-turn-not-file-mtime]], [[worker-liveness-must-reflect-progress]].
- Control-test all directions before arming, including that TRUE baselines do **not** fire — [[absence-needs-a-probe-that-could-see-presence]], [[delegate-waits-must-be-harness-tracked]].
