---
name: an-ansi-fix-must-reach-the-lookup-not-only-the-parser
description: Fixing ANSI blindness in a parser leaves every caller that LOCATES the line still blind, and a sibling tool sharing the format is a second instance the first sweep never visited.
scope: global
metadata:
  type: feedback
---

When you fix an ANSI-stripping defect, sweep every site that **matches** a line, not only the sites that **parse** one — and sweep sibling TOOLS that consume the same output format, not only sibling lines in the file you were handed.

**Why.** A parser that strips its own argument looks correct in isolation and makes its caller's blindness invisible: `selected_tests()` stripped ANSI and had six passing cases, while the caller that produced its argument did `ln.strip().startswith('Tests ')` on raw bytes that begin `\x1b[2m      Tests `. The summary therefore read as ABSENT, the parser returned `None` for "could not tell", and the guard fell back to its refusal path. Measured 2026-10-03: a five-mutant battery with a green baseline and five genuinely correct mutants reported **0 of 5**, every one MULTI-SELECT. The same class had been found and fixed weeks earlier in a sibling tool (`loop.py`'s `Test Files` counter, three parse sites) — the sweep stayed inside that one file, and `mutate.py` beside it was never looked at.

**How to apply.**
- Grep for the **predicate**, not the symbol: `startswith(`, `== '`, `match(` against any line of tool output, across every tool that reads that tool's output.
- Extract the lookup into a named function so it can be tested at all. An inline `next(ln for ln in out.splitlines() if ...)` has no seam, which is why it was never covered.
- Build the regression cases from **real captured bytes**. Every pre-existing case was a hand-typed uncoloured string — that is precisely why the class survived, and a new hand-typed case would have preserved it.
- Control it by arming the OLD code on a copy and showing the new tests fail: 3 of 7 failed there, which is what makes "fixed" a measurement. Never arm it in the tracked tree — `~/dotfiles/claude` auto-commits.
- Add the negative control too: a `Test Files` line also contains `Test`, so a looser match reports the FILE count as the test count — a `1` that happens to look right.

Related: [[fix-the-class-not-the-reported-instance]] · [[absence-needs-a-probe-that-could-see-presence]] · [[handoff-session-id-ansi-poisoning]] · [[a-control-must-match-the-probes-shape]]
