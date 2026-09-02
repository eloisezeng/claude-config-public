---
name: a-conflicted-pr-gets-no-ci-run
description: A PR with merge conflicts gets NO workflow run at all (no merge ref to build), silently and with no error — while GitHub attaches the branch's PREVIOUS green run to the new PR, so "is the PR green?" answers yes about code CI never saw; read mergeable/mergeable_state before diagnosing a missing run
metadata:
  type: feedback
scope: global
---

When a push lands, the PR is open, and **no workflow run is ever created**, check
`mergeable` / `mergeable_state` on the PR *before* theorising about anything else.

**The mechanism.** `pull_request` workflows run against the computed merge commit. A conflicted PR
has no merge ref — `merge_commit_sha: null`, `mergeable: false`, `mergeable_state: "dirty"` — so
GitHub cannot create one, and it therefore creates **no run at all**. There is no error, no
annotation, no red check, nothing in the Actions tab. The absence is the only symptom.

**The trap that makes it dangerous.** GitHub associates runs with a PR by *head branch*, not by
SHA. So the branch's previous, unrelated green run gets listed under the new PR. Measured
2026-09-02 on PR #350: `gh pr checks` said the PR had no checks configured, while
`actions/runs?branch=…` listed one `success` run — at a **stale sha**, from the branch's previous
merged PR. A per-PR "is it green?" reading would have returned green for code CI had never
compiled. Only a **per-commit** detector keyed on the exact head sha (and failing closed) catches
it — this is the concrete payoff of `[[control-a-settle-detector-on-captured-output]]`.

**How the state arises without anyone doing anything wrong.** A branch whose PR was merged by
*squash* still carries its original commits. If you keep working on that same branch, it now
re-applies content main already has under a different sha, and the next PR conflicts. Cause and
symptom are far apart: the squash happened hours earlier, in someone else's merge.

**Diagnosing it — order the cheap checks by what they can rule out.**

- `mergeable` / `mergeable_state` / `merge_commit_sha` on the PR — the answer, one call.
- `actions/runs?branch=<branch>` as the **control** for a `?head_sha=` query that returns zero. An
  empty filtered result can mean "no run" or "the filter is wrong"; the branch listing separates
  them and shows the stale-run association at the same time.
- `check-suites` on the sha names the *app* that owns each suite. A suite from a PR-commenting
  GitHub App is not an Actions suite — `total_count: 1` there is easily misread as "CI is queued"
  when Actions has produced nothing.

**What NOT to conclude.** Do not reach for token-suppression, an Actions outage, a spending limit,
or a workflow-config filter until mergeability is ruled out. I burned ~20 minutes on all four,
including closing/reopening the PR and pushing an empty commit to force a `synchronize` event —
none of which can work, because the blocker is upstream of event delivery entirely. The status
page said "All Systems Operational" and it was telling the truth.

**The fix is an ordinary merge**, not a force-push or a rebase: merge the base branch in, resolve,
push. Verify afterwards that `mergeable` flipped to `true` and that `changed_files` collapsed to
your real change (21 → 8 in the measured case) — a still-inflated file count means the duplicate
history is still there. Then confirm a run actually exists **at the new head sha**, per
`[[absence-needs-a-probe-that-could-see-presence]]`.
