---
name: a-hoisted-dependency-becomes-every-modes-dependency
description: "Sourcing a shared library at a tool's TOP LEVEL makes it a requirement of every mode, including the ones that never use it — and a tool that is legitimately copied away from its tree (every mutant control) then refuses entirely; load it where present and report its absence at the single site that needs it"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Two consumers needed one rule, so I put the rule in a shared library and sourced it from the tool's
**prologue**, refusing to run when it could not be read — the right instinct about duplication
dependency is **every mode's** dependency. Exactly one of that tool's functions asked the shared
question; the other dozen modes — watch, status, dispatch — never did, and all of them now refused.

The first victims are the controls, and they are invisible until you run the whole suite: the house
rule for arming a fault is to mutate a **copy** of the tool
(`[[never-arm-a-fault-in-an-auto-syncing-tree]]`), and a copy in `$TMPDIR` has no `lib/` beside it.
Measured: 44 of 48 reds in one full run were this, every one of them a `sed`-built mutant whose
`exit 2` landed before the thing under test ever ran. The diff that caused it was six lines and
touched no case in the suite.

**Where a dependency is loaded decides who it can break.** Load it when present, and report its
absence at the one site that needs it, saying in words which part of the answer is therefore missing —
not in silence, because a scan that reports nothing is indistinguishable from a clean scan, and not by
guessing either way, because one direction floods the report and the other hides the exact item the
scan exists to find. Pin the degradation with a case that runs a copy without the library and asserts
both halves: the unrelated mode still works, and the dependent site says it could not answer.

**Why:** a shared rule is correct, and hoisting its load site to the top is a separate decision that
nothing reviews.

**How to apply:** before sourcing anything at a script's top level, name the modes that never call it;
if any does, load it conditionally and degrade at the point of use. Then ask what else runs a COPY of
this file.

Related: [[a-self-locating-guard-cannot-be-mutated-by-copying]],
[[never-arm-a-fault-in-an-auto-syncing-tree]], [[enumerate-the-transforms-between-authoring-and-use]],
