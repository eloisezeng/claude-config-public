---
name: your-review-tool-fork
description: "your-review-tool must be your fork (the updated version), not upstream — already npm-linked to ~/Coding/your-review-tool-fork"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 39a21c8a-5481-47f7-b581-ded594350b2b
---

When using `your-review-tool` for human review, it MUST be your fork — your "updated version" with fixes/features upstream lacks.

- **Fork location:** `~/Coding/your-review-tool-fork`
- **Fork remote:** `your-org/your-review-tool` (forked from upstream `kunchenguid/your-review-tool`)
- **Invocation is unchanged:** the global `your-review-tool` command is `npm link`'d to the fork, so running `your-review-tool` already executes the fork's `dist/cli.mjs`. No separate command/binary name.

**Why:** you maintain the fork as the current/updated your-review-tool; upstream is behind. You want reviews to run through your version.

**How to apply:** just use `your-review-tool` as normal — it already resolves to the fork. If ever in doubt, confirm the global package links to `~/Coding/your-review-tool-fork` (`npm ls -g your-review-tool`). See [[your-review-tool-artifact-prefs]] for how you want the review surfaces built.
