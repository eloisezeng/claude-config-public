---
name: recoverable-is-not-unused
description: "Before deleting a mirrored/regenerable artifact, enumerate its DEPENDENTS — recoverability makes the bytes restorable, not the local copy unused"
metadata:
  scope: global
  type: feedback
---

Proving an artifact is byte-identical on a remote proves it is **recoverable**. It does not prove it is **unused**. Those are different questions, and only the second one licenses deletion.

Before removing any local artifact, name what resolves through it and check each one still resolves afterwards. Symlink farms, generated-path config, cached mounts, and build outputs all create consumers that a content check never looks at.

**Why:** on your-research-project box I deleted a hub-mirrored dataset release after verifying all 415 files sha256-identical on the Hub — a clean, complete verification of the wrong proposition. `factory_your-research-project/data/` was a symlink farm whose 43 of 44 dataset mounts pointed into that release, so the deletion silently severed the data layer for every round including the active one. The failure surfaced only because a later pass happened to walk the tree and hit a dangling link; nothing about the deletion itself reported an error, because deleting a symlink target never does.

**How to apply:** make the dependent probe part of the deletion gate, not a follow-up.

```bash
find <root> -xtype l | wc -l          # dangling links: record BEFORE, assert unchanged AFTER
grep -rl '<path>' --include='*.{py,json,yaml,cfg}' <root>   # path referenced in config?
```

Assert the after-count equals the before-count in the same script that deletes. A deletion that raises the dangling-link count has broken something, whatever the content check said. Related: [[verify-claims-against-artifacts]], [[absence-needs-a-probe-that-could-see-presence]].
