---
name: echo-fabricates-structure-in-zsh
description: The Bash tool runs zsh on this machine, whose builtin echo interprets backslash escapes — echo "$data" invents newlines/tabs that were never in the data; use printf '%s\n'
scope: global
metadata:
  type: reference
---

**The tool named "Bash" runs `zsh` here** (`BASH_VERSION` UNSET, `ZSH_VERSION=5.9`; verified 2026-08-21).
zsh's builtin `echo` **interprets backslash escapes by default** — no `-e` needed, unlike bash.
So `echo "$var"` on data containing a literal `\n` emits a REAL newline that was never there.

Proven with controls:

| probe | value |
|---|---|
| `t='a\nb'` — 4 bytes, real newlines | `[0]` |
| `echo "$t" \| wc -l` | `[2]` ← fabricated |
| `printf '%s\n' "$t" \| wc -l` | `[1]` ← correct |
| zeroing control `echo "ab" \| wc -l` | `[1]` |

**Rule: never pass DATA through `echo`; use `printf '%s\n' "$x"`.**
Quoting does NOT save you — `echo "$line"` is fully quoted and still fabricates. This is why the usual
"quote your expansions" advice under-covers it.

**Why it is dangerous:** it does not error. It emits confident garbage shaped exactly like measurement.
Real instance: `ps -eo pid=,ppid=,comm=,args= | ... | while IFS= read -r line; do pid=$(echo "$line" | awk '{print $1}')`
— correct in every usual respect (`IFS= read -r`, quoted `"$line"`, and `read` cannot even contain a newline) —
shattered one process into ~7 rows because the argv held literal `\n`. A count piped to `wc -l` there would
have read ~13 watchers instead of 2, wrong in the *safe-looking* direction.

Sits in the defect class **"a shell construct silently invents structure that was never in the data"**, with
three distinct mechanisms: word-splitting (`G="git …"; $G log` expands as ONE word → all-zero output),
escape interpretation (this), and re-parsing a row set. Diagnose which one before writing the rule — two
sessions here proposed two different wrong causes before measurement settled it. See
[[absence-needs-a-probe-that-could-see-presence]] and [[verify-claims-against-artifacts]].

**Corollary for process censuses:** anchor per-PID, or `awk` on `comm` (which cannot contain whitespace),
and derive every count as its own one-liner rather than from a re-parsed row set.
