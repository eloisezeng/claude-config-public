---
name: an-absent-required-check-is-not-a-red-one
description: a settle detector's NOT-GREEN over a job that never registered is ABSENCE, and the repair is to dispatch the workflow at your ref so the check exists
metadata:
  type: feedback
scope: global
---

A fail-closed CI settle detector reports **NOT-GREEN for two different facts**: a check that
RAN AND FAILED, and a check that **never registered at all**. They are opposite situations and
the verdict line does not distinguish them, so read the job list before reading the verdict:
`ci-green.sh` printing `VERDICT: NOT-GREEN -- workflow jobs never registered: ['fleet']` is
saying the signal is ABSENT, never that the code is bad.

**Absence is usually structural, so measure the TRIGGERS before concluding anything about your
branch.** Read every `on:` block: a repo whose workflows are all `schedule` / `workflow_dispatch`,
plus one `push: branches: [main]`, has **no pre-merge CI at all** — no branch push and no pull
request can ever make the expected job appear, for your branch or for any merge that preceded it.
The gate was written by someone who had not measured that, and it is unsatisfiable by construction.

**Then repair it rather than arguing past it: `workflow_dispatch` makes the absent check exist.**
`gh workflow run <file> --ref <your-branch>` runs the SAME job the push trigger runs, and its
`headSha` is your branch head, so the run is correctly pinned and the detector then reads GREEN on
its own derived expected set — an absent signal converted into a measured one, with no change to
what is verified. Confirm the `headSha` equals the head you are merging before believing it.

Never read an unsatisfiable gate as permission, and never read it as a red either. Both readings
are wrong in the expensive direction: one merges on no evidence, the other parks finished work for
ever. Say plainly which of the two facts you measured, and if a dispatch is genuinely impossible,
name the verification standing in for it — a full local suite is MORE than most repos' CI runs, and
the one check that did appear may be a PREVIEW build that proves nothing about production.

See also [[control-a-settle-detector-on-captured-output]] ·
[[watch-the-run-you-triggered]] · [[a-guard-must-be-satisfiable-not-just-failable]] ·
[[merge-green-prs-without-asking]]
