---
name: a-job-with-no-steps-never-started
description: A CI job that fails in seconds with steps:[] and no runner never ran — read its check-run ANNOTATION, because there is no log to fetch
metadata:
  type: reference
scope: global
---

A GitHub Actions job whose API record shows `steps: []`, `runner_id: 0`,
`runner_name: ""` and a `started_at`/`completed_at` two or three seconds apart
did not run and then fail — it was never assigned a runner. `gh run view
--log-failed` and `--job <id> --log` both answer `log not found: <id>`, which
reads like a tooling fault and is not one: no log exists because no step
executed.

The cause is carried in the check run's single annotation, and nowhere else:

    gh api repos/<owner>/<repo>/actions/runs/<run_id>/jobs      # get job ids
    gh api repos/<owner>/<repo>/check-runs/<job_id>/annotations # get the reason

Measured 2026-09-07: every your-web-app run after ~20:20 UTC died this way, and the
annotation said *"The job was not started because recent account payments have
failed or your spending limit needs to be increased."* Nothing in the diff, and
the same shape on an unrelated branch — which is the tell that it is account-level
rather than code-level, so **check a second, unrelated branch before diagnosing
your own commits**. Re-running is a cheap, honest probe: a billing block fails
again in the same three seconds and spends nothing.

The block is per-ACCOUNT, not per-repo: the same hour, `your-org/your-project` was
failing identically across two unrelated branches. So the second branch you check
can be in a different repository, and one confirmation covers every repo you own.

**Three causes share this shape; separate them before reporting, because they
need different actions.** *Billing* — every job everywhere, ~2s, no runner, and
githubstatus.com reports operational. *A GitHub incident* — same shape, but
githubstatus.com shows the Actions component degraded; wait rather than escalate.
*A real failure* — the job carries a `runner_name` and burned real minutes; that
is the only one that is about the code, and mistaking it for the other two hides
a genuine red.

**Verify recovery on the runner, not on the rollup.** After the limit is raised,
re-run and read the job records for an actual `runner_name: GitHub Actions <n>`.
A rollup can turn green for reasons unrelated to what was fixed —
[[verify-claims-against-artifacts]].

While Actions cannot start, every "merge when green" gate in the account is
unsatisfiable, so the useful move is to run each CI job's own command locally,
read straight out of the workflow file, and say in the PR exactly which job you
could not reproduce and why. Note that build steps often need env the workflow
supplies (an `AUTH_SECRET`, an empty `NEXT_PUBLIC_*`), so a local build failing
on a missing variable is your setup, not the branch.

An Actions billing block is the user's to clear (Settings → Billing & plans) — it
is her money, so never raise a spending limit or add a payment method to unblock
yourself, and never take a repo public to buy free minutes. Report it and stop:
see [[no-extra-cash-without-permission]] and
[[a-report-is-not-a-stopping-point]] for what to do with the rest of the window.
Related: [[conflicted-pr-gets-no-ci]] is the other way a PR shows red for a
reason that is not its code.
