---
name: encode-the-invariant-in-the-shape-not-another-guard
description: "A review finding of the form 'X can be invalid here' is a TYPE bug — narrow X once at the boundary so no interior site needs the check; a codebase that converges by growing throws is re-fixing one design defect at N sites"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When a lens says "this can be undefined / out of range / the wrong variant here", there are two fixes: add a check at that site, or change the shape so the bad value cannot arrive. The check closes the *finding*; only the shape closes the *class*. A loop scored per finding picks the check every round, and a design defect is quietly converted into N runtime defects that each pass review.

**Why:** measured 2026-09-02 over four weeks of the YOUR-MODULE `provider-data` arc — 28 `fix(your-module)` commits, titled almost uniformly "harden / enforce / validate / lock / bind … invariants". Twelve sampled fixes added **~110 `throw` statements against ~27 type-or-schema constructs**, ending at **316 `throw`s in 8,725 lines of source, one every 28 lines**. Every round was individually correct and converged. The arc still finished with its invariants living as scattered runtime checks inside the module that most needed a boundary. This is not the loop failing — it is the loop doing exactly what it was told: the `codex-converge` rule "encode constraints as guards, not prose" moves prose → guard and stops one step short of guard → shape.

**How to apply:**
- **Parse at the boundary, don't validate in the interior.** One function turns untrusted input into a narrowed type (a discriminated union, a branded id, a non-empty array, a required non-optional field) and every downstream signature takes that type. A `throw` at depth 3 means the type at depth 0 was too wide.
- **Prefer impossible to loud.** A required parameter fails in CI at every call site at once; `assert(x !== undefined)` fails on one production path, later, in front of the user.
- **Tally throws-added vs types-added per round**, in the scorecard next to severity, the same way remedy shape is tallied — `[[document-rounds-end-when-findings-turn-code-shaped]]`. A round that is mostly throws is a round that deferred the design; say so and spend the next fix on the shape.
- A guard is genuinely right where the constraint is **dynamic** — a live budget, a clock, a vendor response, anything only knowable at call time. It is wrong wherever the caller could simply have been unable to say the invalid thing.
- Pairs with [[fix-the-class-not-the-reported-instance]] (the same instinct, one level up: the class is often "this type is too wide", not "these six sites lack a check") and [[eval-clauses-are-code-not-prose]] (the step this one continues).
