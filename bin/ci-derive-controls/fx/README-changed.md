`changed.txt` is the caller-measured changed-file set `ci-green.sh` writes beside the workflows
(`git diff --name-only <merge-base> <head>`), and `ci-derive.py` reads it to answer every file-level
`paths:` filter. It is part of the capture, not a hand-written mock: these are the seven files
681fc6d4 changed against its parent, read back with `git show --stat --oneline 681fc6d4` on
your-org/your-other-project.

It was MISSING from this fixture until 2026-09-09, because the path-filter rule landed in
`ci-derive.py` after the capture was taken. An absent set is not an empty one -- it means "not
determined" -- so `head.your-module.yml.yml` was refused by name on every case, and controls 0 and D had
been reading ASSERT-FAIL, unnoticed, ever since. That refusal is correct behaviour and is now pinned
by control G, which deletes this file and requires the refusal to name the workflow.
