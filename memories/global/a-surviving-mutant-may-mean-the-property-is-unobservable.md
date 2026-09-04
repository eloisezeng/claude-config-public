---
name: a-surviving-mutant-may-mean-the-property-is-unobservable
description: When a mutant survives, ask whether ANY outcome test could see the difference before calling the test weak — a tolerant search or default often makes the property unobservable, and then only its INTENT can be pinned
scope: global
metadata:
  type: feedback
---

A surviving mutant has two very different causes, and treating them the same wastes a round.
Either the tests are weak, or **the property has no observable effect** — some tolerant search, default, or fallback silently supplies whatever the mutated code was providing, so no test on OUTCOMES could ever have caught it.

Diagnose before strengthening: delete the thing, then ask what would have to differ downstream. If the answer is "nothing", stop writing outcome tests.

**Why:** in MFFP round 4 a reviewer deleted a per-dataset `dataset_dirs` mapping and the suite was unchanged. That was recorded as "the skip guard masks the bug" and accepted-but-not-fixed. When the skipped data came back, the mutant *still* survived — because of 30 mappings exactly one was non-identity, and the loader's `_find_npz_root` scans one level deep, silently finishing the job. No outcome test could ever have seen it. This is `[[vendor-what-the-code-searches-for]]` one layer out: a search path that quietly succeeds hides the fall-through completely.

**How to apply:**
- Before strengthening a test against a surviving mutant, name the downstream value that a positive case would change — the `[[absence-needs-a-probe-that-could-see-presence]]` move.
- If nothing downstream changes, pin the **intent** instead: assert the invariant the config/code exists to guarantee (here: every configured path lands ON the array root, never leaning on the tolerant scan). That IS falsifiable.
- Measure the invariant across the whole population BEFORE authoring the guard, so you pin a real property rather than codifying whatever the tree happens to contain — `[[reduce-token-burn]]`'s "check a guard before authoring against it".
- Mutation-verify without editing a frozen surface: patch the loader/config in-process, never the vendored file.
- Say plainly in the record that the earlier diagnosis was wrong and why, rather than letting "closed by the data restore" stand.

## The second reading: the mutation is a semantic NO-OP, and it names which half of your fix was the fix

A survivor can also mean the thing you mutated never carried behaviour — and that is the most useful survivor there is, because it settles a question you would otherwise close by assumption.
Measured 2026-09-03 on `codex-converge/loop.py`: a live bug ("repeat until no findings remain, across 3 tracks" was accepted as a bounded stop) was repaired with TWO changes at once — the ban was moved ahead of the bound check, and the bound regex was tightened so a digit only counts when it counts the thing being bounded.
I recorded the ORDER as the fix and armed a mutant against it. It survived, and not because the test was weak: with the ban written `if banned and not bound`, that branch is reachable only when `bound` is falsy, which is exactly when the early return would not have fired, so the two orders cannot differ. Verified over 139 generated stop strings, then independently over a smaller cross-product: zero behavioural differences.
Only the regex tightening was load-bearing; re-arming the mutant there killed it immediately.

- When a fix bundles two changes, a mutant per change ATTRIBUTES it. Do not write the ordering, the rename or the reshuffle into the record as "the fix" until a mutant says it carries behaviour.
- Before calling a survivor a weak test, try to prove the mutation is unobservable BY CONSTRUCTION — a short reachability argument over the branch conditions beats another test.
- Then correct the comment. A code comment that says "the reverse order was a live bug" teaches the next reader that the ordering is the guard; if a five-line proof contradicts it, the comment is the defect. Keep the honest reading order, and say plainly that it is reading order and not the guard — `[[verification-claims-are-earned-per-item]]`.
- A control for a guarded path must break EVERY guard, or enumerate them: a probe that breaks one of two independent refusals reads as the wrong refusal, not as SURVIVED — `[[a-control-must-match-the-probes-shape]]`.
