---
name: an-optional-value-flag-eats-the-next-positional
description: A CLI flag whose value is OPTIONAL consumes the next positional argument as its value — `vitest list --json <file>` overwrites that file with the JSON listing; always write `--flag=value` and put positionals first
metadata:
  node_type: memory
  type: reference
  scope: global
---

A flag declared with an **optional** value (`--json`, `--outputFile`, `--reporter`, `--coverage`, many `--report*` flags) cannot tell "no value given, here is a positional" from "here is my value".
The parser takes the next token.
When that flag's value is an OUTPUT PATH, the positional you meant as an input gets **overwritten**.

Measured: `npx vitest list --json components/__tests__/SegmentTimeline.adjust-window.test.tsx` printed nothing, exited 0, and silently replaced that 17,757-byte test file with a 623,899-byte JSON listing of every test in the repo.
It looked like "the file has no tests" — the next three probes all agreed, because they were reading the JSON.
`--json --filesOnly <file>` in the same session behaved correctly, which is what made the destructive form look safe.

**Why:** the failure is silent in both directions — no error, exit 0, empty stdout — and the symptom it produces ("that file collects zero tests") points at the file, not at the command that just ate it.
A tool run to *inspect* an artifact is not assumed to write, so the clobber is not looked for.

The mirror image of the same rule: a flag placed BEFORE the positional can reach a different parser entirely, and the tool's own error message will not say so.
Measured 2026-10-29: `handoff.sh <file>` refused a re-dispatch with "use --force to dispatch anyway"; `handoff.sh --force <file> -- "<objective>"` answered **"unknown option: --force"**, because the leading token hits the top-level mode dispatcher (`--*) die "unknown option"`) while `--force` is only declared in the per-mode option block that runs after the positional.
`<file> "<objective>" --force` dispatched.
So a suggested flag that "does not exist" may exist in exactly one position — grep the script for the flag before concluding the version lacks it, and never read that error as evidence about what the launcher did (see [[a-launchers-error-message-may-postdate-its-irreversible-half]]).

**How to apply:**
- Write `--flag=value` **always**, never `--flag value`, for any flag that can also appear bare.
- Put positionals before flags, or after `--` — this is the fix for BOTH directions: the eaten positional and the flag the top-level parser never sees.
- When a tool rejects a flag it just recommended, `grep -n '\-\-flag)' <script>` and find which parse block declares it, rather than assuming the flag was removed.
- Before running an unfamiliar inspect/list/report subcommand against a path you care about, ask which of its flags take an optional value.
- When a probe returns "empty" for one input and works for its neighbours, `wc -c` and `head` the input before believing the result — see [[verify-claims-against-artifacts]] and [[absence-needs-a-probe-that-could-see-presence]].
- Recovery: a working copy under a mutation/gate harness is often the only surviving post-edit copy of an uncommitted file; restore from it and `shasum -a 256` both sides. This is a reason to [[stage-immediately-verify-commits-from-the-object]] — an edit that was `git add`ed is recoverable, one that was not is not.
