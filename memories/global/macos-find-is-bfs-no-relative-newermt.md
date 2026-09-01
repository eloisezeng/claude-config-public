---
name: macos-find-is-bfs-no-relative-newermt
description: On the user's Mac, `find` is bfs, which rejects `-newermt '-20 minutes'` (relative dates) — a freshness probe with swallowed stderr then matches NOTHING, ever
scope: global
metadata:
  type: reference
---

On the user's Mac, `find` resolves to **bfs**, not BSD/GNU find.
bfs accepts `-newermt` only with ISO-8601-like absolute timestamps (`2026-08-17T18:45:35Z`); a relative spec like `-newermt '-20 minutes'` is an "Invalid timestamp" **error**, not an empty match.

**Why it matters:** with `2>/dev/null` on the find (routine in monitor loops), the error is invisible and the probe returns empty on every check — so a liveness/stall watchdog built on it degenerates to whatever its other condition is (e.g. a pgrep snapshot) and false-fires forever. Two watchdog generations shipped with this bug before it was caught (2026-08-17); each firing looked exactly like a real stall.

**How to apply:** use duration predicates instead — `-mtime -20m` (bfs/BSD unit suffixes) or `-mmin -20` — and before arming any absence-detecting monitor, run its probe once against a state known to be PRESENT and confirm it matches ([[absence-needs-a-probe-that-could-see-presence]]). Never `2>/dev/null` a probe you haven't seen succeed.
