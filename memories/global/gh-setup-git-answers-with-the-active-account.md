---
name: gh-setup-git-answers-with-the-active-account
description: "`gh auth setup-git` installs ONE global helper that answers as the ACTIVE gh account, so on a multi-account machine it silently shadows every repo the active account cannot see — and GitHub reports that as `Repository not found`, byte-identical to a deleted repo"
metadata: 
  node_type: memory
  type: feedback
  scope: global
---

`gh auth setup-git` writes a single `credential.https://github.com.helper = !gh auth git-credential` into **global** config.
That helper answers with whichever account `gh` has ACTIVE — not with the account that owns the repo you are standing in.
On a machine with several logged-in accounts, every repo the active account cannot see then fails with `remote: Repository not found`, which is byte-identical to the repo being deleted or the URL being wrong.
This is the same failure that cost four days of unpushed config commits (`[[verify-in-the-consumers-condition]]`).

**The fix is per-repo, not global** — one global mapping cannot serve two accounts.
Pin the owner in the working copy, ordered ahead of `osxkeychain`, fetching the token at call time so nothing lands on disk:

    git -C <repo> config --local credential.https://github.com.username <owner>
    git -C <repo> config --local --add credential.helper ""
    git -C <repo> config --local --add credential.helper '!f(){ [ "$1" = get ] && printf "username=<owner>\npassword=%s\n" "$(gh auth token --user <owner>)"; }; f'
    git -C <repo> config --local --add credential.helper osxkeychain

A bare `credential.helper=""` resets only the bare list — the URL-scoped global helper still runs first, and returns the right token *because* the local `username` pin is in the request.

**Verify per distinct REMOTE, not per directory** (measured 2026-09-02: 106 working copies, 5 distinct remotes — one probe each).
`gh api repos/<owner>/<name> --jq .permissions.push` under each logged-in token tells you which account is the right pin before you touch git at all.

**`git ls-remote origin -h` is a broken probe**: it exits 0 with zero output whether or not authentication succeeded, so it cannot distinguish working from failing.
Drop the `-h` and count refs.
I misread that probe's exit 0 as "this repo authenticated fine before my change" and reverted a correct fix on the strength of it — `[[absence-needs-a-probe-that-could-see-presence]]`, `[[a-control-must-match-the-probes-shape]]`.
