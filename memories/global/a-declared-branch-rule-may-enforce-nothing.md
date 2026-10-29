---
name: a-declared-branch-rule-may-enforce-nothing
description: An ACTIVE GitHub ruleset that names a requirement is a CLAIM, not a gate — count the merges it was supposed to prevent before repeating what it says, and rule out pattern scope, admin bypass and indirect landing by measurement before naming a cause
metadata:
  type: feedback
  scope: global
---

A branch ruleset reads like a gate and is really a declaration: `enforcement: active` plus a named requirement tells you what somebody INTENDED, never what GitHub does.
The requirement can sit in a field that is not the one being enforced — measured 2026-10-26 on one private team repo, a ruleset on `main` carried `required_approving_review_count: 0` beside a separate `required_reviewers` entry asking for one approval from a team over file pattern `*`, and `required_review_thread_resolution: true`.
Over the same window, 28 of the 48 pull requests merged into that branch carried no approving review at all and two landed with a review thread still open, which the rule says cannot happen.
The repository's own CONTRIBUTING.md asserted in three places that GitHub required these things.

**Never quote the rule as the practice.** The measurement is the merges, not the settings: list every merge into the protected branch with its reviews and thread states and count the violations. Both halves are cheap and only one of them is evidence. The same applies to any prose in the repo that describes its own protection; that prose is a third claim, not a check.

**Rule the obvious mechanisms out by measurement, not by plausibility**, because each one is a different repair and a wrong guess sends the reader to the wrong screen.
Three worth testing, in the order they cost least:
- **Pattern scope** — a `*` file pattern plausibly matches only the repository root, so a project living under one subdirectory would be ungoverned. Test it by finding a merge that touched a ROOT-level file; one that merged unapproved kills the hypothesis.
- **Admin bypass** — test it on who performed the merges, not on who could. Any merge by a non-admin collaborator kills it. `current_user_can_bypass` answers only for your own token, so it is not a reading of the ruleset's bypass list.
- **Indirect landing** — a pull request is marked MERGED when its commits reach the base by any route, and a rule evaluated at the merge button never ran for one that arrived another way. Test it on `mergeCommit.oid`: one per pull request, all distinct, none null, kills it.

What survives is reported as the place to look, never as a proven cause: "this field is set to zero, that screen is where it is decided" is honest, and a confident mechanism you did not measure is the thing a reader will check first and disbelieve you over.

Related: `[[measure-a-lanes-inlet-not-its-enable-flag]]` is the same shape in a pipeline (a switched-on stage whose inlet nothing writes reads green while producing nothing), and `[[verify-claims-against-artifacts]]` is the general rule.
`[[a-gate-may-not-read-its-verdict-from-the-gated-party]]` is the neighbouring failure where the gate reads the wrong source rather than no source.
