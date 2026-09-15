---
name: a-refusal-guard-can-abort-an-installers-tail
description: A guard that correctly refuses ONE destructive pair aborts the whole run, so every step after it silently stops happening — check the installer's EXIT CODE, and treat a tool's own OLDER output as an input its current version must fold, not refuse
scope: global
metadata:
  type: feedback
---

Measured 2026-09-14: `~/dotfiles/claude/install.sh ~/.claude ~/.claude1` had been exiting **1** on every run for weeks.

`~/.claude1/hooks` was a whole-directory symlink to `~/.claude/hooks` — the shape an OLDER installer left, back when it linked directories where the current one links individual leaves.
So `$MIRROR/hooks/notify.sh` and `$PRIMARY/hooks/notify.sh` named **one directory entry**, and `link_refuses` stopped the run. That refusal was right: the link would have pointed at itself and destroyed the file.

**Why it stayed invisible.**
The refusal is the LAST thing printed, and it reads like a considered safety message rather than a failed install.
Everything after the mirror loop — the global-memory hook preflight, the memory restore, the notification gates, the auto-sync agent load — simply never ran, for weeks, with no artifact saying so.
What eventually surfaced was one tiny downstream symptom: `outputStyle: "tolerable"` set in the shared `settings.json` but `~/.claude1/output-styles/` did not exist, so the style silently failed to resolve in the second profile.
The visible symptom is always smaller than the aborted phase, and it never points at it.

**How to apply:**
- **Read an installer's exit code, never whether the thing you were looking at appeared.** `output-styles/tolerable.md` got created and the run still failed two items later. Checking the file you came for confirms your own step and is blind to the tail — `[[verify-claims-against-artifacts]]`.
- **A tool's own older output is an input its current version must handle.** When a program's shape changes (whole-dir link → per-leaf link), the previous shape is still on every machine that ran the old version, so the new one meets it by construction. Fold it — de-alias, migrate, absorb — so the run self-repairs; refusing means a permanent failure that a human has to reconcile by hand — `[[a-tracked-store-resolves-only-on-its-branch]]`.
- **Keep the `rm` narrow and prove the narrowness.** De-alias ONLY a subdirectory that is `-ef`-identical to the primary's own counterpart; never the mirror root, never a link pointing somewhere you cannot account for. A control asserting the elsewhere-pointing link is left alone is what separates the fix from "unlink every mirror subdirectory" — without it the positive test passes for both — `[[a-control-must-match-the-probes-shape]]`.
- **Assert RESOLUTION, not shape.** The property worth pinning is that each leaf still reaches the same real file (`-ef` through the links), because the shape changing is the fix and the resolution changing would be the regression.
- **Fix it through the product's own write path.** The instinct is to hand-make the one missing symlink; that leaves the installer still broken and the next run still exiting 1 — `[[the-product-may-already-own-the-write-path]]` · `[[fix-the-class-not-the-reported-instance]]`.
- On this machine the installer takes both roots: `install.sh ~/.claude ~/.claude1`. A primary-only run leaves the second profile behind silently — `[[a-two-root-machine-needs-the-root-named]]`.
