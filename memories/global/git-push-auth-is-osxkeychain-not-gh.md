---
name: git-push-auth-is-osxkeychain-not-gh
description: On macOS `git push` authenticates via osxkeychain, NOT via gh — so `gh auth switch` cannot fix a push, and the fix for a multi-account machine is to name the user in the push URL
metadata:
  type: reference
  scope: global
---

`git push` failing with `remote: Repository not found` on a private repo the user owns is an
IDENTITY problem, and on macOS the identity does not come from `gh`. Apple's Command Line Tools ship
a system gitconfig at `/Library/Developer/CommandLineTools/usr/share/git-core/gitconfig` setting
`credential.helper = osxkeychain`, so git reads one keychain entry per host and never consults which
account `gh` has active.

Two consequences that cost a round of wrong advice (measured 2026-08-30):

- **`gh auth switch` cannot fix a push.** It changes only what `gh`/PR tooling uses. Suggesting it
  is worse than useless when the user has other work depending on the active account.
- **"the agent can't push but you can" is usually false.** The user's own terminal reads the SAME
  keychain entry, so it fails identically. Do not hand off a push as though the human has different
  credentials until you have checked.

**Diagnose before advising:** `git config --show-origin --get-all credential.helper` names the
helper and the file it came from. Only then decide whose problem it is.

**The fix on a multi-account machine** — put the username in the URL, which makes osxkeychain look
that account up specifically and create a SEPARATE entry rather than disturbing the existing one:

```
git push https://<user>@github.com/<owner>/<repo>.git <branch> …
```

The password prompt wants a `repo`-scoped PAT, not a password. Verify with `git ls-remote` on the
same URL form. Note this needs a TTY: from a non-interactive agent session the same URL dies with
`could not read Password … Device not configured`, so a human's success here does NOT grant the
agent access — [[cannot-push-your-project-repo]] is the worked instance.
