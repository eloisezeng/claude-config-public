---
name: convergence-loop-speed-rules
description: Four levers that shorten a codex-converge implementation loop without lowering the bar — census-close a region and name the last panel, overlap the frozen-sha stages, reuse the round mechanics (mutate.py, make-prompts.py), start the human's clock at first green
metadata:
  type: feedback
scope: global
---

The user asked on 2026-09-01, mid-way through a six-round diff review of one validator, "any way to speed up implementation" and then to make the answer durable in the skill and memory.
The loop's cost was not the number of stages — it was that rounds 3–6 all landed in ONE region (a Unicode fold pipeline), findings 15→10→14→9→7→6: a rate that fell every round and never reached zero, because each round's fix minted the next round's boundary case.

**The four levers, in the order they pay:**

1. **Census-close the region and name the last panel.**
   After three consecutive rounds in one region, enumerate its input space by code (every assigned code point / enum value / call site), derive the accepted and refused sets from the CODE, pin both directions in the test and the spec, and write in the scorecard that the next panel is the LAST for that region.
   After it, findings in that region are dispositioned against the census — admitted-by-rule is declined with the rule cited; missed-by-census is a census bug — rather than reopening the region.
   This is what the trigger in [[enumerate-recurring-defect-classes]] produces; without the "last panel" line the region absorbs rounds 7, 8, 9.
2. **Overlap the stages that read a frozen sha.**
   The micro-review of a fix diff reads a COMMITTED sha; Phase C mutation runs on a COPY.
   Commit, launch the micro-review in a second linked worktree, run Phase C in the working worktree meanwhile.
   The only real serialisation is "never edit tracked files while a lens or mutation run reads them".
3. **Reuse the round mechanics.**
   `~/dotfiles/claude/skills/codex-converge/mutate.py` is the vendored mutation harness (mutants JSON → `KILLED`/`SURVIVED`/`MISARMED` per expectation, armed on a copy, `--census 'REGEX=N'` completeness guard, sha256 asserts on tracked files; use a session-unique copy dir).
   One `make-prompts.py` per arc, written at round 1 and parameterised by round/HEAD/previous results — hand-editing three lens prompts per round costs wall-clock comparable to a lens run.
4. **Start the human's clock at first green.**
   A human-gated ship step (an inbox card whose approval releases N of the affected items) surfaced at first green runs in parallel with the loop; surfaced in the final report it runs after it.

**What is NOT a lever:** tier downshift (spend-only, and the skill's "full reviewer strength" rule forbids it on the gate), skipping Phase C, skipping the freeze check.

**Why:** a review loop that is converging slowly is not a reviewer problem; it is a region whose acceptance set nobody has written down, so every lens re-derives a piece of it.
Writing the set down once (the census) is cheaper than the fourth round and ends the treadmill by construction.

**How to apply:** at the end of any round, count rounds-in-region; at three, do lever 1 before dispatching the next panel.
At every fix commit, do lever 2.
At round 1 of every arc, set up lever 3.
At the first green suite, do lever 4.
Related: [[codex-parallel-lenses-beat-serial-rounds]], [[eval-clauses-are-code-not-prose]], [[never-arm-a-fault-in-an-auto-syncing-tree]].
