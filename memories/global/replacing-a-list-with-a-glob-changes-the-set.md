---
name: replacing-a-list-with-a-glob-changes-the-set
description: A glob replacing a hand-typed list silently DROPS every member the pattern misses — count both sides and pin the exemptions, and remember a test list defined twice diverges on the developer's machine first
metadata:
  type: feedback
scope: global
---

Deriving a set (a glob, a directory scan, a query) instead of enumerating it fixes *additions* —
a new member is covered by existing — and quietly breaks *subtractions*: every existing member
the pattern does not match leaves the set with no diff line to point at, because the diff shows
one list replaced by one pattern.

So **count both sides before and after, and reconcile the difference by name.** If the counts
differ, each missing member is a decision to make out loud: covered elsewhere, deliberately
exempt, or a regression. An exemption is only safe while every caller still names the exempt
member, so pin that with a guard that DERIVES the exempt list from the world (the directory)
rather than restating it — otherwise the guard is a second hand-typed list with the same defect.

**Why:** measured on your-university_scheduler — `npm test` was an eleven-command hand-typed chain, and
replacing it with `agents/run_checks.sh`'s glob took it to ten files. The two it dropped,
`run_agents.mjs` and `run_scenarios.mjs`, were the only tests that drive a real browser. Nothing
failed; the suite reported 247 passing either way. The count was the whole signal.

The same arc's root cause is the companion rule: **"the tests" defined twice diverges on the
developer's machine first.** A glob in CI plus a hand-typed chain in `package.json` means a new
test runs in CI and is silently skipped by the person who wrote it — worse than being out of CI,
because it hides where nobody looks. One definition, both callers use it, and the guard asserts
neither caller has grown its own copy.

And check *when* the suite runs, not only what it contains: that workflow triggered on
push-to-main only, so every green tick beside a pull request was measuring the commit before the
merge. Tests that run after landing report on a break; tests that run on the pull request prevent
one.

**The same rule applies to the assertion's MESSAGE, and to which tree each side is derived from.**
A set comparison that reports only cardinalities (`expected 283 to be 285`) gives the next session
nothing to act on, and the usual cause is not a real violation at all but the two sides reading
DIFFERENT trees — a name list derived from a fixed base against the PR head sha, and a file list
from `git ls-files` over the checked-out merge ref. Intersect and NAME the member, and derive both
sides from one tree: `[[a-count-only-assertion-cannot-name-what-is-missing]]`.

Related: [[a-guard-must-be-satisfiable-not-just-failable]] · [[a-mention-is-not-a-property]] ·
[[counting-a-set-is-not-classifying-it]] · [[verify-claims-against-artifacts]] ·
[[a-subset-run-is-not-a-suite-run]] · [[a-count-only-assertion-cannot-name-what-is-missing]]
