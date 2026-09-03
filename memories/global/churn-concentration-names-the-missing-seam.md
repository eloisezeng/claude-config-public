---
name: churn-concentration-names-the-missing-seam
description: "When an arc's fixes keep landing in the same file, that file has fused responsibilities — census fixes-per-file at each round boundary and split the top one, instead of buying another round against it"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

A file that absorbs round after round of findings is not a hot spot, it is a **structural finding with a number attached**. Census it, say the number, and spend a round extracting the pure decision from the effects — otherwise every subsequent lens finds one more unhandled combination in the same fused module, forever, and each one converges.

**Why:** measured 2026-09-02 across the YOUR-MODULE `provider-data` arc's 28 fix commits — **15 touched `pipeline.ts` (2,893 lines) and 14 touched `cli.ts` (979 lines); the next file had 8.** That module holds the planning decision, the IO, the request accounting and the artifact write together, so a scenario is the only way to reach any of its rules. A pure decision function extracted from it can be property-tested exhaustively in one commit; the same logic embedded in the IO path can only be probed one scenario per round — which is exactly the shape the finding stream had.

**How to apply:**
- Run the census at each round boundary, beside the profile (`[[optimize-the-loop-unprompted]]`):
  `git log --since=<arc start> --grep='^fix(<arc>)' --pretty=%H | while read c; do git show --stat --format= --name-only $c; done | grep -v '\.test\.' | sort | uniq -c | sort -rn`
  Put the top three in the scorecard next to the severity tally.
- **A non-test file taking >40% of an arc's fixes is the finding.** The remedy is extracting the pure decision from the effects, and it belongs in the same round as that file's next fix — not in a "later refactor" nobody funds.
- Extracting pays twice: the decision becomes exhaustively testable (so the class closes instead of the instance), and the IO shrinks to something a lens can read whole.
- This is the code-shaped twin of the flat-finding-rate rule in [[codex-parallel-lenses-beat-serial-rounds]]: a flat rate asks what a subsystem is still FOR; concentrated churn names **which file to split**. It is also how [[document-rounds-end-when-findings-turn-code-shaped]] looks once the document is already code.
- Splitting is not free and is not always right — so argue it with the count. "15 of 28" is an argument; "this file feels big" is not, and a raw line-count threshold is worse than either.
