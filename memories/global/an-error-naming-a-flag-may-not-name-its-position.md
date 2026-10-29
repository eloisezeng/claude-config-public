---
name: an-error-naming-a-flag-may-not-name-its-position
description: A refusal that recommends a flag states the flag, never where it is accepted — the same flag reads as "unknown option" in a different argument position, so read the usage line, not the recommendation
metadata:
  type: feedback
  scope: global
---

A tool's refusal that recommends a flag tells you the flag EXISTS, never where it parses.
Take the position from the usage line or the option-parse block, never from the recommendation — and never conclude the flag is absent from the build because one position rejected it.

Measured 2026-10-28 on `handoff.sh`, three calls to dispatch one successor:

1. `handoff.sh <file> -- "<objective>"` refused with *"a live successor is already on record — use `--force` to dispatch anyway"*.
2. `handoff.sh --force <file> -- "<objective>"` answered **`unknown option: --force`**, which reads exactly like a flag the recommendation invented.
3. `grep -n '^\s*--[a-z-]*)' handoff.sh` found `--force` alive at line 3389 — in the option loop that runs AFTER two positionals. The accepted form is `handoff.sh <file> "<objective>" --force`, and the usage line says so: `<handoff-file> <objective> [options]`. The `--` form puts the objective where the parser is still reading options, so the flag lands in the wrong block.

**Why:** the refusal and the parser are written in different places, so the refusal knows the flag's NAME and not its grammar.
Reading `unknown option` as "this flag does not exist" is the expensive misread, because the next move is to route around a guard that was working: here it would have meant leaving a converged spec stage undispatched and the lane owned by a seat about to retire.
This is the same family as `[[a-launchers-error-message-may-postdate-its-irreversible-half]]` — a launcher's message is not a measurement of the launcher — and the same family as `[[an-optional-value-flag-eats-the-next-positional]]`, where argument POSITION silently changes meaning.

**How to apply:** on any "unknown option" for a flag a tool's own error just recommended, grep the script's option-parse block for the flag before believing it, and put positionals FIRST in the order the usage line gives, with options after them.
Read the record rather than the message afterwards, per `[[a-launchers-error-message-may-postdate-its-irreversible-half]]`.
