---
name: dev-pipeline-plan-subagent-converge
description: Default pipeline for substantial features/changes — brainstorm/spec → writing-plans → subagent-driven impl → Codex↔Claude convergence + Playwright/E2E verify → push
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: eaf52ee2-48de-403f-9860-e1614d2d58e1
---

For any substantial feature or change, your default workflow (you ask for this repeatedly, so do it without being told):

1. **Brainstorm → spec** (superpowers:brainstorming) — present a design, get approval, write the spec doc.
2. **writing-plans** — turn the approved spec into an implementation plan.
3. **subagent-driven-development** — execute the plan via subagents, not all inline.
4. **Codex↔Claude convergence review** — adversarial cross-AI loop (Codex CLI + a blind Claude reviewer); verify each finding, fix real ones test-first, repeat until BOTH agree no BLOCKER/HIGH/MEDIUM remain. Mechanics + `codex exec` gotchas in [[codex-exec-hang-watchdog]].
5. **Verify** — run the real thing E2E (Playwright for browser/UI), as an end user would, before claiming done.
6. **Push** — only after convergence + verification pass.

**Why:** You value quality/robustness over dev cost; the cross-AI convergence loop has caught real bugs that both the first reviewer and a single self-review missed, and E2E verification catches "code-correct but product-wrong" gaps.

**How to apply:** Default to this pipeline for features/refactors/bug-fix-with-design; don't ask whether to do it. Skip only for trivial mechanical edits. The tracked `codex-converge` skill packages the entire pipeline — invoke it rather than assembling the stages by hand. Pairs with [[background-subagent-parallel-workflow]] (parallel dispatch) and [[notify-on-response]] (only ping at done/blocked during long loops).
