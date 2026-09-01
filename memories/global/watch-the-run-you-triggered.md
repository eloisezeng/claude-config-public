---
name: watch-the-run-you-triggered
description: "gh run list --limit 1" grabs whoever pushed last — pin a CI/deploy run by its own commit, or you verify someone else's deploy
metadata:
  type: feedback
scope: global
---

`gh run list --workflow X --limit 1` returns the **newest** run, not **your** run. On any repo with concurrent merges, that is routinely somebody else's push.

**Why:** 2026-07-31, your-other-project. Merged a PR, took the latest deploy run, watched it go green, then verified the live site and found the change absent. The run belonged to a PR another session had merged ~2 minutes earlier; my deploy was still `in_progress`. The green tick was real — it just wasn't mine. Nearly reported a working change as broken.

**How to apply:**
- Resolve the run by identity: match on the head SHA you merged, or on the PR title, and assert the match before watching. `gh run list --json databaseId,headSha,displayTitle` then filter.
- After it goes green, confirm the deployed artifact actually contains your change (a live query, a rendered element, a version string) — not just that a run succeeded.
- The same trap applies to "the latest" of anything shared: the newest branch, the newest tag, the top of a queue. Anchor by identity, never by position.

Related: [[verify-claims-against-artifacts]], [[act-on-fresh-state-anchor-by-identity]].
