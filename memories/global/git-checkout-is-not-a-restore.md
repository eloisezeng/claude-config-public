---
name: git-checkout-is-not-a-restore
description: A mutation-control harness that restores with `git checkout -- <file>` reverts to the INDEX, silently destroying uncommitted work; restore from a byte copy held outside the repo and verify by hash
metadata:
  type: feedback
scope: global
---

`git checkout -- <file>` restores the file **from the index**, not from "how it was a moment ago".
In a dirty tree that means it reverts to the last commit and **silently discards every uncommitted edit** — so using it as the restore step of a mutation-control loop destroys exactly the work the controls were written to validate.

**Why:** measured — a four-control mutation sweep restored with `git checkout --` and wiped two files' worth of unstaged review fixes. All four controls fired correctly; the harness was what was broken, and the only reason it was caught is that the script hashed each file before mutating and compared after. Without that hash the loop would have reported four clean controls over a tree that had quietly lost the fixes.

**How to apply:** before mutating, copy each target to a path **outside the repo** and record its SHA-256. Restore with `cp` from that copy, then re-hash and assert equality — print a loud failure when it differs. Assert the tracked file is unchanged in the same script (`git status --porcelain` empty, compared against a baseline captured before the sweep). Commit first where you can: once the tree is clean, `git checkout --` becomes a correct restore, but the byte copy is still the mechanism that does not depend on that being true.

Two probe defects travel with this class and cost the same way:
- A control's pass/fail probe must **print a count either way**. `grep -E "Tests +[0-9]+ failed"` never matches vitest output, because ANSI codes sit between `Tests` and the number — so the baseline and every control printed nothing, and a silent control is indistinguishable from a passing one. Strip ANSI and emit unconditionally — [[absence-needs-a-probe-that-could-see-presence]].
- A wrapper's exit code is not the watched thing's outcome. A backgrounded `gh run watch` reported "exit code 0" while its own captured RC was 1 (it had died on a GitHub secondary rate limit, tripped by running a watch and two status pollers against one run at once). Read the conclusion from the API — [[verify-claims-against-artifacts]].

Related: [[never-arm-a-fault-in-an-auto-syncing-tree]] · [[a-mention-is-not-a-property]] · [[stage-immediately-verify-commits-from-the-object]]
