---
name: eval-clauses-are-code-not-prose
description: Any pass/fail rule in a spec (gate, threshold, disposition table) ships as a property-tested pure function in the same commit — prose versions of decision rules invite one wordsmithing finding per review round
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When a spec defines a DECISION RULE — a pass/fail gate, a threshold with bands, a disposition table, degenerate-input handling — write it as a pure function with an exhaustive property test in the same commit the clause lands.
The spec's prose becomes commentary on the function; wording disputes are settled by the function, not by another round of prose edits.

**Why:** measured on the C2 spec convergence (2026-08-19): rounds 4–7 EACH returned one edge-case finding against the same clause's prose (aggregate-vs-proxy scope, zero denominators, an undefined diagnosis band, an unpinned "≈"), ~3 of 9 rounds burned.
The findings stopped the moment the clause became a total-function case table pinned by a property test enumerating every input class.
A frontier reviewer at high effort is the most expensive prose-linter money can buy; a 20-line function retires the whole finding family permanently.

**How to apply:** at spec-writing time, scan for the words "if", "threshold", "band", "gate", "counts as", "unless" — each such sentence either names the function+test that implements it or is rewritten as a case table with a plan task to pin it.
Degenerate inputs (zeros, nulls, empty sets, both-sides-degenerate) are table rows, never afterthoughts.
Pairs with [[codex-parallel-lenses-beat-serial-rounds]] (the treadmill exit: assert the property, not the shape).
