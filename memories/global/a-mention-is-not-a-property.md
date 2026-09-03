---
name: a-mention-is-not-a-property
description: A guard predicate that tests for a MENTION ("this function names stripAnsi") passes on a site that names it and still misuses it — only a structural/AST predicate distinguishes, and a mutation control is what tells the two apart
scope: global
metadata:
  type: feedback
---

When a guard enumerates sites and asserts each one is correct, the predicate is doing all the work.
**A text-level predicate — "the enclosing function mentions `X`" — is not a test that `X` was applied to the value that matters.**
It is satisfied by a site that mentions `X` once and leaks the value somewhere else, which is precisely the shape a half-done fix has.

**Measured 2026-08-30, your-module phase-0 impl, CI red cycle 1 (finding F3).**
Four test sites spawned a child `vitest` and asserted on its stdout; CI colourises, so all four needed `stripAnsi` and a no-colour env, and only one of the four had it.
The fix went into one shared module and a guard was written to keep it there.
The guard's first predicate was `enclosingFunctionText.includes('stripAnsi')`.
A control that mutated a COPY of one site — stripping the wrapper off ONE of its two captures while leaving the other wrapped — **survived**: the function still mentioned `stripAnsi`, so the guard still passed on a site that was now broken.
Only the structural predicate caught it: parse the file, find every capture expression reachable from the child's output, and assert each is lexically inside a `stripAnsi(...)` call.

**How to apply**
- State the property you actually want in one sentence, then ask whether your predicate would separate a site that HAS it from a site that merely NAMES it. If both read the same to the predicate, it is a mention test.
- Prefer structure over text: parse and walk. "Every text-producing capture is inside a `stripAnsi` call" is checkable; "the function mentions `stripAnsi`" is not.
- **The mutation control is the only thing that tells you which one you wrote.** Arm the *partially* broken variant, not the fully broken one — a fully broken site fails both predicates, so it proves nothing about the difference. See `[[a-surviving-mutant-may-mean-the-property-is-unobservable]]` for the other reading of a survivor, and `[[absence-needs-a-probe-that-could-see-presence]]` for the general form.
- Mutate a COPY and assert every tracked file unchanged in the same script — `[[never-arm-a-fault-in-an-auto-syncing-tree]]`.
- Derive the site list from the repo (`git ls-files`), never from a hand-written array, and write the derivation's BOUND next to the assertion: which sites it deliberately does not sweep, and why — `[[a-guard-must-be-satisfiable-not-just-failable]]`.
