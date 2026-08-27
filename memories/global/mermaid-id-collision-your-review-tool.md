---
name: mermaid-id-collision-your-review-tool
description: Mermaid v11 startOnLoad breaks multi-diagram your-review-tool artifacts (same-ms SVG id collision); render manually with unique ids
metadata: 
  node_type: memory
  type: reference
  scope: global
  originSessionId: 74881e6a-52ce-4b2b-a369-6b8c3c8483b4
---

Mermaid v11 (`startOnLoad: true`) derives SVG element ids from a millisecond timestamp.
When several diagrams on one page render within the same millisecond they get identical ids, their scoped styles/defs collide, and all node content visually piles into the first diagram's panel while later panels appear empty.
Every diagram parses and renders fine in isolation, so parse-checking finds nothing — inspect the DOM for duplicate `id="mermaid-<timestamp>"` to confirm.

**How to apply:** in your-review-tool/HTML artifacts with multiple `<pre class="mermaid">` blocks, set `startOnLoad: false` and render each block explicitly with a unique id:
`const {svg} = await mermaid.render("mmdiag" + i++, src)` then `pre.replaceWith(holderDiv.firstElementChild)`.
Read the source via `pre.innerHTML` with `&gt;/&lt;/&amp;` decoded (not `textContent`, which strips `<b>/<br/>` label HTML).
Related: [[your-review-tool-artifact-prefs]].
