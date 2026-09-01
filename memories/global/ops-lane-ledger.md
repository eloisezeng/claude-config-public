---
name: ops-lane-ledger
description: Open work lives as LANES in ~/.claude/ops/ — a dispatch registers one automatically, a seat dying never closes one, and only an explicit disposition (--close completed/cancelled/superseded) removes it
scope: global
metadata:
  type: feedback
---

**Origin (2026-08-31, FIX-HANDOFF run):** the RCA defect this cures had two write surfaces — the lane-scoped handoff doc (enforced by handoff.sh) and MEMORY.md (discretionary). Work discovered mid-session that was neither the current lane nor deliberately saved died with the window, silently. Decision record: `your-other-project/docs/notes/LIFECYCLE-DECISION-context-vs-handoff-2026-08-31.md`.

**The ledger** (`~/.claude/ops/`, resolution `$CLAUDE_OPS_DIR` → `$CLAUDE_CONFIG_DIR/ops` → `~/.claude/ops`; read its `README.md` once per session):
- `dispatches/<lane-key>` — one symlink per OPEN dispatched lane, pointing at the dispatch record (the record stays the sole source of truth; the ledger only makes it discoverable). `handoff.sh` registers it automatically on every dispatch, fail-closed: no ledger write, no launch.
- `lanes/<slug>.md` — frontmatter files (`lane:`, `status:`, `objective:`) for open work that is NOT a dispatch: blocked-on-user items, awaiting-integration results, discovered-but-unowned problems. Anything unresolved you discover and are not handing forward goes here BEFORE your window ends.
- Lane key = sanitized handoff basename + 8-hex md5 of the resolved path, so a re-dispatch of the same file lands on the same lane.

**Invariants:**
- **A seat dying, stalling, or being killed never closes its lane.** Worker termination ≠ completion; a lane leaves the open set only via explicit disposition.
- **Close = `handoff.sh --close <lane> <completed|cancelled|superseded> ["note"]`** — writes the disposition into the record first (audit line), removes the symlink second; every refusal errs OPEN. Handing off onward with handoff.sh supersedes the dispatcher's own lane automatically (coupled to retirement; a `--no-retire` side dispatch does not touch it).
- **Worker locality:** a dispatched seat carries `CLAUDE_HANDOFF_LANE` and its session-start view shows only its own lane plus a count of others — leave other lanes to their owners.
- **Coordinator reconstruction:** any fresh session's boot (SessionStart hook `inject-ops-lanes.sh`) lists the open set, so a coordinator death is recoverable without transcripts.

**How to apply:** trust the boot listing; when finishing a dispatched objective, close the lane in the same breath as the final report; when discovering new unresolved work, write a `lanes/` file immediately, not at session end; never delete a dangling `dispatches/` link without reading what happened to its record.

Related: [[handoff-at-boundaries-saves-tokens]], [[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]], [[fleet-burn-budget]].
