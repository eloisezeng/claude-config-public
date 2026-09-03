---
name: a-denylist-only-holds-what-someone-typed
description: "a hand-maintained forbidden list can only contain what someone typed — derive the candidate set from the world, and control the derivation against the name it exists to catch"
metadata:
  type: feedback
  scope: global
---

A hand-maintained deny list is a record of what someone remembered.
It cannot contain the name nobody typed, and its "zero forbidden tokens survived" reads like a statement about safety while being a statement about that list.
Measured: a product codename reached the public mirror in 14 files — 11 memories, a skill, and a real CI workflow file disclosing a package path and its job names — because no rule named it.

**Why:** the failure is structural, not an oversight, so another careful pass adds another remembered name and closes nothing.
The repair is to DERIVE the candidate set from the world: here, the top-level tracked entry names of every local repo, with the discriminator that a name at the top level of ONE repo is that project's and a name in many repos is infrastructure.
That half needs no judgement at all.

**How to apply:**
- Derive, then subtract only what you can subtract MECHANICALLY (a dictionary, the publishing repo's own `git ls-files` vocabulary). A hole you can read beats a clever rule that removes a class you cannot see, so keep the leftover exclusions as an explicit measured list.
- Control every normalizing filter against the target itself. Mine deleted it: the codename was two short dictionary words joined, so an unbounded compound-splitting rule dismissed it as ordinary English and the scan read green. Bound such a rule (both halves >= 4 chars) and re-measure what it drops. A filter that removes exactly what you are hunting is not a tail-trimmer.
- Collect across every worktree but COUNT once per repository. Deduping made the set blind to the name; per-worktree counting made ~97 hits look like infrastructure — the same miss from both directions.
- Cut false positives with derived vocabulary, not by relaxing the rule: 830 hits (631 of them one word) is a guard that gets switched off.
- Expect the guard to catch its own docstring, and reword the docstring rather than widen the rule.
- Fail CLOSED on every incomplete-scan path, including an EMPTY derived set — a scan that can hit nothing is not a scan — and pin it with a planted name plus a PARTIAL mutant.

Related: [[a-token-sanitizer-cannot-see-a-topic-leak]] · [[absence-needs-a-probe-that-could-see-presence]] · [[a-guard-must-be-satisfiable-not-just-failable]] · [[enumerate-the-transforms-between-authoring-and-use]]
