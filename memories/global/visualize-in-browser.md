---
name: visualize-in-browser
description: "When you ask to \"visualize\" web/UI work, deliver it through your-review-tool (not a plain browser tab); scientific/research figures go to matplotlib instead"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 09853060-f5ae-40fc-830c-06cbcd526112
---

When you ask me to "visualize" something in website/UI development (a mockup, layout, product surface, design comparison), always deliver it through **your-review-tool**, your human-review surface — not a plain `open` browser tab and not only a screenshot. **Do NOT ask permission each time** — default to opening it with your-review-tool fork whenever visualization is wanted (incl. the brainstorming visual-companion step). The fork resolves at `~/Coding/your-review-tool-fork/dist/cli.mjs` via the `your-review-tool` command (see [[your-review-tool-fork]]).

**Why:** your-review-tool lets you visually review, annotate elements / selected text, queue prompts, and send feedback back; a plain browser tab or screenshot is one-way and you can't respond on it.

**How to apply:** Build the interactive HTML artifact (in `.your-review-tool/` under the cwd unless told otherwise; match the subject app's own design system — for your-project app that's its dark inline-style theme), then `your-review-tool <html-file>` to open the session and `your-review-tool poll <html-file>` (run in background, never kill) to wait for your feedback. Use `your-review-tool playbook <id>` (diagram/input/comparison/plan) for the right surface. Screenshotting for my own verification first is fine. Pairs with [[your-review-tool-artifact-prefs]] and [[mockup-critiques-into-spec]] (fold every annotation you make into the spec/plan).

**Explicitly do NOT start the `superpowers:brainstorming` visual-companion browser** — you corrected this directly; route every visualization (including inside the brainstorming flow) through your-review-tool instead. (Merged from `use-your-review-tool-for-visualization` + `visualize-means-your-review-tool`, originSessionId 699b70ec.)

**Scope (your correction):** your-review-tool is for website/UI work, not literally every visualization — the always-your-review-tool phrasing came from your-company product/mockup contexts. For research and scientific figures (PDE solution fields, error spectra, model-architecture diagrams) use the right tool, e.g. matplotlib, not your-review-tool HTML artifact. When unsure whether a "visualize" request is web-UI or a figure, ask in prose. (Folded from `your-review-tool-scope-websites`, originSessionId 75e8b5f8.)
