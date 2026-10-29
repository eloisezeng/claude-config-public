---
name: a-merge-may-deploy-even-where-the-runbook-says-manual
description: Establish the deploy state by comparing the LIVE artifact to the base commit, not from a runbook sentence about how deploys are triggered
metadata:
  type: feedback
  scope: global
---

Where no freeze script exists, the gate is UNESTABLISHED and you must establish
the deploy state another way. A sentence in a handoff or runbook — "deploy here
is manual" — is a CLAIM about the mechanism, and the mechanism is exactly the
thing that drifts: a Cloudflare Workers Build, a Vercel hook or a GitHub Pages
action can be connected to the repo long after the sentence was written, and
nothing in the tree records it.

Establish it from the ARTIFACT instead, in one measurement that answers both
questions at once: read the live build's identity token and compare it to the
one in the tree at your MERGE BASE.

- Equal → production is exactly main, nothing is in flight, and the gate passes
  on evidence rather than on the sentence.
- Different → somebody's change is live that main does not have, or main has one
  production does not. Either way, find out whose before merging.

Then watch YOUR merge sha's deploy and confirm by fetching the deployed file and
grepping for a symbol only your change introduces — a new token proves a build
ran, not that it built your commit.

Measured 2026-10-04 (your-university_scheduler PR #72): the lane file said deploy was
manual via `npx wrangler deploy` and that merging does not restart production.
The live token was `2a258b1804`, byte-identical to the base commit's — so the
gate passed. The merge then deployed by itself within 30 seconds, because a
Workers Build was connected to the repo. Had I trusted the sentence instead of
the comparison, I would have merged believing production was untouched and
reported the change as undeployed.

Related: [[watch-the-run-you-triggered]] · [[merging-is-restarting-production]] ·
[[merge-green-prs-without-asking]] · [[verify-claims-against-artifacts]]
