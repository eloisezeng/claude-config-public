---
name: ops-lane-ledger
description: Open work lives as LANES in ~/.claude/ops/ — a dispatch registers one automatically, a seat dying never closes one, only an explicit disposition removes it, and a lane CLOSING never means its seat stopped, so the symlink is not a done/quiet predicate
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
- **And the converse, which is the one that bites a WAITER: a lane closing never means its seat stopped.** The symlink's
  disappearance is a bookkeeping event, so it is not a done/quiet predicate for any other session. Measured 2026-10-27: a
  hold armed to wait for a peer stream to go quiet fired the moment its `dispatches/` symlink vanished, and at that instant
  the seat was still `working` with its own `state.json` detail reading `deploy dispatched; watching run, checking
  rowRelevance next`; the seat actually finished 84 seconds later. Acting on that signal would have merged into a live
  deploy stream. When you need "has that seat STOPPED", read the daemon's own `state` in `~/.claude/jobs/<id>/state.json`
  (`working` → anything else) and confirm it twice; the lane answers "is this work still owned", a different question.
  Age a seat from its last ASSISTANT TURN and never from silence alone — a seat inside one long shell command produced no
  turn for 16 minutes while fully alive, so a silence threshold reads a busy seat as finished.
- **Close = `handoff.sh --close <lane> <completed|cancelled|superseded> ["note"]`** — writes the disposition into the record first (audit line), removes the symlink second; every refusal errs OPEN. Handing off onward with handoff.sh supersedes the dispatcher's own lane automatically (coupled to retirement; a `--no-retire` side dispatch does not touch it).
- **Worker locality:** a dispatched seat carries `CLAUDE_HANDOFF_LANE` and its session-start view shows only its own lane plus a count of others — leave other lanes to their owners.
- **Coordinator reconstruction:** any fresh session's boot (SessionStart hook `inject-ops-lanes.sh`) lists the open set, so a coordinator death is recoverable without transcripts.

**A second config root gives you a second, EMPTY ledger — and every read of it fails open.**
The resolution chain above ends at `$CLAUDE_CONFIG_DIR/ops`, so a session booted under `.claude1`
resolved to `~/.claude1/ops`, which existed, contained `lanes/` and `dispatches/`, and was empty —
while the real ledger under `~/.claude/ops` held 203 lanes (measured 2026-09-07). Nothing errors:
`handoff.sh --close` reports "no open lane named …", the boot listing shows an empty open set, and
the pre-irreversible-act check in [[grep-the-ledger-for-the-artifact-not-your-lane]] greps zero
files and passes vacuously. That is the worst shape a safety gate can take — satisfied by absence,
see [[a-guard-must-be-satisfiable-not-just-failable]]. The fix is one symlink per extra root
(`ln -s ~/.claude/ops ~/.claude1/ops`), the same rule as project memory in
[[project-memory-lives-in-the-project-repo]]: link EVERY config root the machine uses, because a
record under an unused root is not merely hard to find, it is invisible AND it reads as "clear".
Before trusting an empty open set, count the lanes and confirm the path you read is the one with
the history in it.

A lane file is only in the ledger if its frontmatter carries the **`lane:` key**, matching the
slug. A file written with `state:` and `pointer:` but no `lane:` sits in `lanes/` looking filed and
is read by nothing — measured: two lanes written that way were both absent from the census
`handoff.sh --close` prints of lanes with nobody on them, which is the only reason I caught it. So
read a new lane back through the ledger's own reader (the close census, or the boot listing),
never by confirming the file exists. Copy the frontmatter from a lane the listing already shows.

**How to apply:** trust the boot listing; when finishing a dispatched objective, close the lane in the same breath as the final report; when discovering new unresolved work, write a `lanes/` file immediately, not at session end; never delete a dangling `dispatches/` link without reading what happened to its record.

Related: [[handoff-at-boundaries-saves-tokens]], [[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]], [[fleet-burn-budget]].
