---
name: a-write-run-may-answer-with-a-design-and-stop
description: A codex --write lane can reply "please confirm this design" and write nothing, and the launcher exits 0 — gate on commits, and always ship an <autonomy> block.
metadata:
  type: feedback
scope: global
---

A `run-codex.sh --write` lane will sometimes reply with a design and the sentence *"Please confirm
this design so I can implement it"*, then stop, having written nothing.

**The launcher exits 0 for that.** A non-empty verdict did land, which is all exit 0 asserts. The
worktree is clean and holds zero commits, so on every mechanical signal it is indistinguishable from
a lane that correctly found nothing to do — you only learn the difference by reading the prose,
which is exactly the step the gate exists to let you skip.

**Why:** the prompt's `<action_safety>` block reads as a permissions boundary, and a model that has
just been told what it may not touch reasonably checks before touching anything. Nothing in the
standard block says whether anyone is listening.

**How to apply:**
- Ship an `<autonomy>` block on every `--write` prompt: no human will answer; asking is a FAILED run;
  where the task leaves a genuine choice, pick the one that best fits the stated constraints and
  record the alternative under `## Left undone`; refuse only for an out-of-lane edit or a settled
  decision, and even then commit the part you could do.
- Make the gate name it: `exit 0` + clean tree + **zero commits** is this failure, not a no-op. Grep
  the final message for the ask so the gate prints "asked for confirmation", not "no commit".
- Relaunching is the whole lane's cost again, so the block is cheaper than the check.

Measured 2026-09-02: one of four concurrent lanes did this. Codified into
`~/dotfiles/claude/skills/codex-converge/SKILL.md` under "Contract for a write-capable run".

Related: [[codex-may-implement-never-self-review]] · [[codex-parallel-lenses-beat-serial-rounds]]
