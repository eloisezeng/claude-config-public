---
name: a-guard-reading-a-generated-tree-is-fail-open-until-it-is-generated
description: a type-checker or linter whose INPUT includes a generated tree reads green over a broken branch until the generator has run, so fix it with an ORDER in the gate script, never another check
metadata:
  type: feedback
  scope: global
---

When a guard's input set includes a **generated** directory, the guard is fail-open on any tree
where the generator has not run — and it reports success, not "I could not check that".
Ask of every gate: *what writes the files this gate reads, and has that thing run?*
This is the `[[enumerate-the-transforms-between-authoring-and-use]]` question asked about a
guard's INPUT rather than about an artifact's content, and it is the half people skip because the
guard's own command line looks complete.

**Why:** `tsconfig.json` includes `.next/types/**`, the tree `next build` generates, and that
tree is the only place Next's conformance constraint on a route export lives — nothing under
`src/` carries it (`grep -rl OmitWithTag src/` returns 0 files, which is the mechanism shown
rather than claimed). Measured 2026-10-07 on a private frontend repo: with two route defects armed
and `.next/types` removed, `npm run typecheck` exited **0 with zero `error TS` lines** while
`npm run build` exited **1**. A clean `tsc`, 841 unit tests and 21 rendering tests all agreed a
branch that did not build was fine, across four sessions and twenty implementation tasks, in a
repo where merging deploys.

**How to apply:** fix it as an **ORDER**, not as another check — the generator runs before the
guard, in the project's own gate script (`"gate": "npm run build && npm run typecheck && npm
test"`), so the guard's input exists by the time it reads it. Then pin the three things that make
the order load-bearing, because any one of them silently removed restores the fail-open: the
sequence itself, that the steps are `&&`-joined (a `;`-joined gate reports the LAST step's status,
so a failing generator hides behind a passing suite — `[[a-control-must-match-the-probes-shape]]`),
and the config `include` that carries the generator's output into the guard. Add one assertion
that **expires honestly**: that no source file carries the constraint, so the day the tool ships it
as an importable type, the ordering stops being load-bearing and that test is where it surfaces.
Do not instead make the guard refuse on a missing generated tree — that reddens a fresh clone and
gets switched off. Where the generated tree also constrains what a module may EXPORT, a derived
census over the real file list (failing closed on a low count) catches the cheap half on every
suite run, controlled against a deliberate stray export — `[[a-guard-must-be-satisfiable-not-just-failable]]`.
