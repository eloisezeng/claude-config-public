---
name: a-pre-push-hook-cannot-attest-its-own-commit
description: "A pre-push hook cannot post a GitHub commit status for the commit it is pushing — the objects are not on the remote yet, so the API 422s; git has no post-push hook and `git push` cannot be aliased"
metadata:
  node_type: memory
  type: reference
  scope: global
---

The natural design for "CI runs on my machine, and GitHub records that it ran" is: the `pre-push` hook runs the checks and posts a `local-check` commit status on the pushed commit, which the merge gate then requires. **It cannot work as written.**

`pre-push` runs *before* git transfers any objects, so at the only moment the hook gets, the commit is not in the GitHub repository. Measured 2026-09-23:

```
gh api --method POST repos/{owner}/{repo}/statuses/<sha-not-on-github> -f state=success
  -> HTTP 422  {"message":"No commit found for SHA: ..."}
```

And there is no way back into the same `git push`: git offers **no `post-push` hook**, and `git push` cannot be shadowed by a git alias (aliases never override built-ins).

Three ways out, in the order they should be preferred:

1. **A wrapper** (`scripts/push.sh`) that runs `git push "$@"` — the hook still does the checking inside it — and posts the status once the push has landed. Synchronous, visible, testable. The cost is a new habit; make the cost of forgetting it a *blocked merge with a message naming the wrapper*, never an unchecked merge, so the whole thing stays fail-closed.
2. **Push the objects to a side ref from inside the hook** (`git push --no-verify origin <sha>:refs/checked/<sha>`), which puts the commit in the repository so the status POST succeeds, then post, then delete the ref. Keeps `git push` working with no new habit, at the price of two pushes and debris on a failed real push.
3. A detached child that polls until the commit appears and then posts — **rejected**: a background poster that fails reports nothing, and silent failure is the one mode an attestation gate may not have.

Whichever is chosen, the hook should still refuse up front when `gh` cannot authenticate, so a machine that cannot attest fails loudly at push time rather than pushing something no gate will ever accept. Write that as **one** predicate (`gh auth status`) rather than a missing-gh branch plus an authentication branch: a hook that appends `/opt/homebrew/bin` to its own PATH makes the missing-gh branch unreachable on any machine that has gh, so the second branch is one no test can ever enter. One question, one message naming both causes, every branch exercised.

Option 1 was built and proved end to end on 2026-09-23: the wrapper posts, the merge script refuses a head carrying no status, and the proof was run against a real pull request — refused for want of a status, then pushed again through the wrapper, then merged pinned with `--match-head-commit`. The refusal names the wrapper, which is the only thing that clears it; **never hand-post the status to unblock a merge**, which is the gate reading its verdict from the party it gates.

Related: [[merge-green-prs-without-asking]] · [[a-gate-may-not-read-its-verdict-from-the-gated-party]].
