---
name: gh-setup-git-answers-with-the-active-account
description: "`gh auth setup-git` installs ONE global helper that answers as the ACTIVE gh account, so on a multi-account machine it silently shadows every repo that account cannot see — surfacing either as `Repository not found` (byte-identical to a deleted repo) or, on a write it lacks, as a HANG at a terminal password prompt after a 401; clear it with a URL-scoped LOCAL reset, not a bare one"
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
To take the `gh` helper OUT of the chain entirely, the reset must be written at the **same URL-scoped key**, locally (local config is read after global, and an empty value resets the whole accumulated list):

    git config --local 'credential.https://github.com.helper' ""
    git config --local --add 'credential.https://github.com.helper' osxkeychain

**The symptom is a HANG, not `Repository not found`** (measured 2026-09-02, the public-mirror push).
`~/.gitconfig` held exactly this pair — an empty URL-scoped helper (which discarded the system `osxkeychain`) followed by `!gh auth git-credential` — so only `gh` was ever consulted; it answered as the wrong account, GitHub returned `HTTP/2 401 · Invalid username or token`, and git then fell through to a **terminal password prompt** and sat there. Three 60–120 s timeouts with no output.
I diagnosed that as a macOS keychain GUI prompt and told the user to run the push herself; hers timed out identically, which disproved it. `git credential-osxkeychain get` returns the password INSTANTLY — there was never a prompt to approve.
`GIT_TRACE=1 GIT_CURL_VERBOSE=1 GIT_TERMINAL_PROMPT=0` names the real cause in one run: trace prints which helper is invoked, and killing the prompt turns the hang into the 401 that was there all along. Run that BEFORE naming a cause — `[[read-the-tool-error-before-routing-around]]`.

**Verify per distinct REMOTE, not per directory** (measured 2026-09-02: 106 working copies, 5 distinct remotes — one probe each).
`gh api repos/<owner>/<name> --jq .permissions.push` under each logged-in token tells you which account is the right pin before you touch git at all.

**`git ls-remote origin -h` is a broken probe**: it exits 0 with zero output whether or not authentication succeeded, so it cannot distinguish working from failing.
Drop the `-h` and count refs.
I misread that probe's exit 0 as "this repo authenticated fine before my change" and reverted a correct fix on the strength of it — `[[absence-needs-a-probe-that-could-see-presence]]`, `[[a-control-must-match-the-probes-shape]]`.
