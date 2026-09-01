---
name: latex-math-in-docs
description: The user wants math written as LaTeX in markdown docs ($...$) and as mathtext in figures — with GitHub's renderer quirks respected
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: aaa02d17-acf1-4a00-9c6d-49ac2791820d
---

Write all math as **LaTeX**, not unicode/ASCII:
- **Markdown docs** (`docs/*.md`, notes, READMEs): inline `$...$` / display `$$...$$` (GitHub renders
  via MathJax). E.g. `$\partial_t c = M\nabla^2(c^3 - c - \varepsilon^2 \nabla^2 c)$`,
  `$\varepsilon \in [0.012, 0.018]$`, `$\gamma$`, `$\rho$`, `$\nabla^2$`, `$c \approx \pm 1$`.
  Don't leave bare unicode (∂, ∇, ε, γ, ρ, ²) or ASCII (`eps`, `c^3`, `lap`).
- **Figures**: matplotlib **mathtext** `$...$`.

**GitHub renderer gotchas** (verified live via `gh api markdown`, 2026-08-04; each silently breaks rendering):
- Keep a `$$` display equation on ONE line between the `$$` delimiters — a bare `=` (or `-`) line inside the block becomes a setext heading and the `_{...}` subscripts turn into `<em>` italics.
- No backslash-punctuation inside `$...$`: markdown escapes eat it before math extraction (`\,` → `,`, same class: `\;` `\!` `\{`). Drop thin spaces or use `\cdot`.
- `$` does not OPEN after a dash/en-dash: `$1.01$–$1.14\times$` leaves the second half raw. Put the range in one span: `$1.01\text{–}1.14\times$`.
- Verify a math-heavy doc by POSTing it to `gh api markdown` and checking every `$` landed inside a `<math-renderer>` element.

**Why:** the math is the substance of research docs; LaTeX renders cleanly and is the form
The user expects — but only if the renderer actually fires. **How to apply:** use `$...$` from the start,
convert any unicode/ASCII math encountered, and run the `gh api markdown` check before shipping a doc with equations.
