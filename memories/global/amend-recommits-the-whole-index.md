---
name: amend-recommits-the-whole-index
description: git commit --amend takes no pathspec, so it re-commits the ENTIRE index — fixing a message right after a path-restricted commit silently folds every other staged group into it, and the symptom frames the innocent flag
scope: global
metadata:
  type: feedback
---

`git commit -o <paths>` (`--only`) restricts correctly: it commits exactly the named paths and
leaves everything else staged.
`git commit --amend` with no pathspec does **not** — it re-commits the whole index, so a message
fix immediately after a restricted commit absorbs every other staged group into that commit and
leaves the tree clean.

Amend with `--only <the same paths>` when the index is deliberately split, or write the message
correctly the first time by reading the diff BEFORE composing it — the amend was only needed
because I described a schema change I had not looked at.

**Why:** the symptom frames the wrong suspect. What you observe is "N files in the commit, nothing
left staged", one command after typing `-o`, so the natural reading is that `-o` was ignored — and
that generalization is far more dangerous than the bug, because `-o` is the tool that makes atomic
commits possible while sibling sessions share one index
(`[[isolate-agents-that-mutate-the-tree]]`). The last command before the symptom is not always the
cause of it.

**How to apply:** verify every commit's FILE LIST from the object, not just its content —
`git show --name-only --format="" HEAD` — and do it after an amend, not only after the commit
(`[[stage-immediately-verify-commits-from-the-object]]`). Before blaming a flag, reproduce the
whole SHAPE including the follow-up command, in a throwaway repo: testing `-o` alone is a second
measurement that happens to be green, never a control
(`[[a-control-must-match-the-probes-shape]]`). And never file the generalization until the control
has run — a peer disputing it was right, and the retraction is cheaper than the rule.
