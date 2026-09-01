---
name: lavish-axi-fork
description: "lavish-axi must be the user's fork (the updated version), not upstream — already npm-linked to ~/code/lavish-axi-fork"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 39a21c8a-5481-47f7-b581-ded594350b2b
---

When using `lavish-axi` for human review, it MUST be the user's fork — her "updated version" with fixes/features upstream lacks.

- **Fork location:** `~/code/lavish-axi-fork`
- **Fork remote:** `eloise-idealab/lavish-axi` (forked from upstream `kunchenguid/lavish-axi`)
- **Invocation is unchanged:** the global `lavish-axi` command is `npm link`'d to the fork, so running `lavish-axi` already executes the fork's `dist/cli.mjs`. No separate command/binary name.

**Why:** the user maintains the fork as the current/updated lavish-axi; upstream is behind. She wants reviews to run through her version.

**How to apply:** just use `lavish-axi` as normal — it already resolves to the fork. If ever in doubt, confirm the global package links to `~/code/lavish-axi-fork` (`npm ls -g lavish-axi`). See [[lavish-artifact-prefs]] for how she wants the review surfaces built.
