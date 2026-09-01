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
