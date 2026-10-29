---
name: a-decorative-glyph-can-defeat-a-word-boundary
description: A runner's decorative line prefix may be Unicode-ALPHABETIC (node --test's ℹ U+2139 is), so a `\W`/`\b`-anchored parser reads every counter line as ABSENT and reports zero where the output is right there — control any output parser against a known-GREEN run before trusting a zero (measured: a green 9-test baseline refused as "the suite executed ZERO tests" while quoting that very output)
metadata:
  type: reference
  scope: global
---

When a tool parses another tool's output, a zero is two different claims — "the thing did not happen" and "I could not see it" — and a character-class assumption silently turns the second into the first.

**Measured 2026-10-07**, adapting the shared `codex-converge` mutation harness (`loop.py`, `mutate.py`) from vitest to `node --test`: every counter line is printed behind `ℹ` (U+2139 INFORMATION SOURCE). That glyph LOOKS like punctuation and is **Alphabetic** in Unicode, so a `\W`-anchored or `\b`-anchored counter pattern never matched. `tests_ran` came back 0, and the harness refused a genuinely green nine-test baseline with "the suite executed ZERO tests" — while quoting, in the same message, the output that contained the counters. The whole harness could not run in the repository at all. Fixed in the shared tool (`dotfiles/claude` `76c1620`) with controls both directions and 7 permanent self-test cases; the tool's own suites went 141→144 and 20→24, all green.

How to apply:

- **Control every output parser against a known-GREEN run before you trust a zero from it.** That is the one case that distinguishes "nothing ran" from "I cannot read this format", and it is cheap: one passing suite. A parser validated only against failures reads a green run as empty — `[[absence-needs-a-probe-that-could-see-presence]]`.
- **Never assume a glyph's Unicode category from how it looks.** `ℹ ✓ ✗ ● ▶ ⚠` are decorative prefixes that may be Alphabetic, Symbol or Mark; check with `unicodedata.category` / `\p{...}` rather than reasoning from appearance. Anchor on the literal glyph or on explicit whitespace, not on `\W`/`\b`.
- **A shared tool adapted to a new runner needs its self-tests extended in the same commit**, with a case per runner's real captured output — not a hand-written success line, which matches a substring of the running state or a clause the tool drops once nothing is pending — `[[control-a-settle-detector-on-captured-output]]`.
- **A refusal that quotes the evidence against itself is the tell.** When a gate's own message contains the data it says is missing, suspect the parser, not the subject.

Related: `[[a-red-suite-with-no-failing-test-lost-a-worker]]`, `[[verify-claims-against-artifacts]]`, `[[a-gate-may-not-read-its-verdict-from-the-gated-party]]`.
