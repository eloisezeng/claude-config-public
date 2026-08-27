---
name: zsh-agent-shell-quoting-gotchas
description: "The agent shell here is zsh with BSD userland — no word-splitting of unquoted expansions, no backslash-pipe grep alternation, flags glob-expanded, and vitest/ANSI output that defeats naive greps"
metadata:
  type: reference
scope: global
---

Four measured behaviours that make a command look like it worked when it did nothing. Each cost real time before it was recognised.

- **zsh does NOT word-split unquoted parameter expansions** (bash does). A multi-line `$FILES` becomes **one** argument. `for f in $FILES` iterates once with a giant filename ("File name too long", so no backups were taken) and `vitest run $FILES` passes one path that matches nothing — **it exits 0 having run zero tests**. Use an array (`files=(a b c); cmd "${files[@]}"`) or `${=FILES}` to opt into splitting. Green output from a command that ran nothing is the dangerous half.
- **Unquoted flags containing glob characters are expanded by zsh before the command sees them.** `grep -rl X --include=*.ts .` dies with `no matches found: --include=*.ts`. Quote the flag (`--include='*.ts'`) or name the directories instead.
- **BSD `grep` has no `\|` alternation** — that is a GNU extension. `grep 'a\|b'` silently matches nothing on macOS. Use `grep -E 'a|b'`. **An empty BSD-grep result is not evidence of absence** — `[[absence-needs-a-probe-that-could-see-presence]]`.
- **`grep` without `-a` returns NOTHING on a file containing NUL bytes**, because it is classified as binary. Any repo that deliberately uses a NUL delimiter in a source or test file will read as "the string is not there".
- **Strip ANSI before grepping tool output**, not after: `sed -e 's/\x1b\[[0-9;]*m//g'` first. Vitest/CI lines start with an escape sequence, so an anchored pattern like `grep -E '^ *(Tests|×)'` matches zero lines against the raw log and looks like a clean run.

**How to apply:** when a sweep, backup loop, or test invocation returns suspiciously fast or suspiciously clean, verify against the **artifact it should have produced** (files created, tests counted, rows changed) before believing the exit code — `[[verify-claims-against-artifacts]]`. Restore any file a measurement loop mutated with an explicit path list and confirm with `git status`, never with the same unquoted variable that failed to split.
