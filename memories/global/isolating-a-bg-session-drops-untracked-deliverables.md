---
name: isolating-a-bg-session-drops-untracked-deliverables
description: A background session's worktree guard rejects the first edit, but entering a worktree hands you an empty directory when the deliverable is untracked — check `git status` for the target path before isolating, and write through Bash when it is untracked
metadata:
  type: feedback
  scope: global
---

A background job is told to call `EnterWorktree` before its first edit, and the harness enforces it:
`Write`/`Edit` on the shared checkout are rejected until the session isolates.
Obeying that reflexively is sometimes the wrong move, because **a fresh worktree contains the tracked
tree and nothing else**.
If the files the task is about are untracked — a `??` entry in `git status`, a whole directory the
user has not committed yet — the worktree is an *empty* directory where the work should be, and the
first thing the session does there is recreate the deliverable from scratch beside the real one.

**So the guard's rejection is a question, not an instruction.** Before isolating, ask what the task
writes to and check it:

```sh
git status --porcelain -- <the path you will edit>   # '??' means it will NOT travel
git ls-files --error-unmatch <path> 2>/dev/null      # exit 0 means it is tracked
```

Tracked → isolate as told. Untracked → stay in place and write through **Bash** (`cat > file <<'EOF'`,
a `python` patch script, `sed`), which the guard does not block; say in the report that you did not
isolate and why. Measured 2026-10-15: the deliverable was an 18-slide deck generator in a directory
the user had never committed, and the handoff file recording progress lived in it too — entering a
worktree would have lost the figures, the handoff and the built `.pptx` in one call.

The same mechanism, from the dispatching side rather than the editing side, is
[[a-gitignored-doc-store-does-not-reach-a-fresh-worktree]]: git-invisible files do not reach a fresh
worktree, so anything that must be *read* there needs an absolute path or provisioning, and anything
that must be *written* there needs the worktree skipped.
A repo-wide `"worktree": {"bgIsolation": "none"}` in `.claude/settings.json` turns the guard off, but
that edits the user's settings for every future job to unblock one — prefer Bash.
