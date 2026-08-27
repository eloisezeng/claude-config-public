---
name: github-personal-repo-collaborators-are-always-write
description: "On a user-owned GitHub repo every collaborator has write; the permission API returns 204 and silently ignores the role. Read-only needs an org."
metadata:
  node_type: memory
  scope: global
  type: reference
---

**A repository owned by a personal account has exactly one collaborator role: write.**
`PUT /repos/{owner}/{repo}/collaborators/{username}` documents `permission` as "**Only valid on organization-owned repositories**", default `push`.
On a user repo it returns **204 No Content** and changes nothing — a confident false positive, the same failure shape as [[hf-personal-repos-have-no-collaborators]].
Always re-read the permission afterwards; the status code is not the artifact.

To give someone read-only on your own repo you must **transfer it to an organization** (GitHub Free orgs support the full Read/Triage/Write/Maintain/Admin role set on private repos).
There is no other mechanism, because the two obvious alternatives both fail:

- **Branch protection / rulesets are 403 on a private repo on the Free plan** ("Upgrade to GitHub Pro"), so you cannot fence off `main` instead.
- **Removing the person entirely deletes their forks**: "If you remove a person's access to a private repository, any of their forks of that private repository are deleted." Local clones survive; the fork does not. So revoking access to stop their pushes also destroys the fork they were meant to work in, and on a private repo they can no longer read it to open a PR at all.

**How to apply:** before designing any "they contribute by PR, not by push" topology on GitHub, check whether the canonical repo is user-owned or org-owned — that single fact decides whether the topology is enforceable or merely a convention.
Pairs with [[global-config-repo]] and [[verify-claims-against-artifacts]].
