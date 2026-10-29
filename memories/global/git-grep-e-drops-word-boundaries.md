---
name: git-grep-e-drops-word-boundaries
description: "`git grep -E` matches NOTHING for `\\b` or `\\<`/`\\>` while the platform `grep -E` matches the same pattern on the same bytes — so a word-boundary absence probe validated in a pipe reads a confident zero once moved to git grep; use `-w`, `-P`, or explicit character classes, and control every absence probe against a known-present file"
metadata:
  node_type: memory
  scope: global
  type: reference
---

`git grep -E` and the system `grep -E` do not share a regex dialect, and the difference is silent in the dangerous direction.

**Measured 2026-10-17** (git 2.50.1, Apple Git-155, macOS) against one file known to contain the word `ventures` twice, on `origin/main`:

| probe | result |
|---|---|
| `git grep -c -F 'ventures'` | **2** (control: present) |
| `git grep -cE '\bventures\b'` | **no match, exit 1** |
| `git grep -cE '\<ventures\>'` | **no match, exit 1** |
| `git grep -cw 'ventures'` | **2** |
| `git grep -cP '\bventures\b'` | **2** |
| `git show <rev>:<file> \| grep -cE '\bventures\b'` | **2** |

The last two rows are the trap. The identical pattern works in the platform `grep` and under `git grep -P`, so a pattern drafted and sanity-checked in a pipe reads as verified, then returns a clean zero the moment it is moved to `git grep -E` to sweep a tree or a revision. Nothing warns: `\b` is not an error in POSIX ERE, it just is not a boundary, so the match fails and exit 1 is indistinguishable from a true absence.

This cost a false conclusion in a live task: a sweep for user-facing wording left in a codebase reported **0 remaining occurrences** across every source and content file, while output printed minutes earlier in the same session already showed two of them. Re-running with explicit character classes (`(^|[^A-Za-z])[Vv]entures?([^A-Za-z]|$)`) returned 1210 hits repo-wide and 119 in app source, which changed the answer the task was about.

How to apply:

- **Use `-w` for a whole-word search, or `-P` when the pattern needs real boundaries.** `git grep -w <word>` is the cheapest correct form. `git grep -P` works here but is not guaranteed in every git build, so a script that depends on it should fail loudly when PCRE is absent rather than degrade to zero matches. Explicit character classes are the portable fallback.
- **Never carry a regex between `grep` and `git grep` without re-controlling it.** They are two instruments; validating in one does not validate the other — `[[absence-needs-a-probe-that-could-see-presence]]`.
- **Control every absence probe against a file you already know contains the thing**, in the same invocation form you are about to trust, and read a zero as a claim about the instrument until that control passes. A sweep's "nothing left" is a measurement, not an observation — `[[necessity-gate-searches-the-whole-repo]]`, `[[verify-claims-against-artifacts]]`.
- **Suspect this first when a tree-wide sweep returns zero and anything in the session already showed a hit.** The contradiction inside your own output is the tell, exactly as in `[[a-decorative-glyph-can-defeat-a-word-boundary]]`.

Related: `[[absence-needs-a-probe-that-could-see-presence]]`, `[[a-decorative-glyph-can-defeat-a-word-boundary]]`, `[[zsh-agent-shell-quoting-gotchas]]`, `[[counting-a-set-is-not-classifying-it]]`.
