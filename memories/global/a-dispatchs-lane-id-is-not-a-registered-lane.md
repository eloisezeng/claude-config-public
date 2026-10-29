---
name: a-dispatchs-lane-id-is-not-a-registered-lane
description: handoff.sh can print lane=HANDOFF-<8hex> into its dispatch record while registering the lane NOWHERE — not in ops/dispatches/ and not in ops/lanes/ — so the work has no ledger row, --close refuses as "never registered", and a seat reporting "lane closed" closed nothing
metadata:
  type: feedback
  scope: global
---

A dispatch's printed lane id is a NAME, not a registered lane.
`handoff.sh` ended one dispatch with `lane=HANDOFF-32731529` in `<handoff>.md.dispatch`, and that id existed nowhere else: grepping it across all of `~/.claude/ops/` returned exactly one hit, the dispatch record itself.
There are TWO places it should have appeared and neither had it.
Dispatched lanes register as directories under `~/.claude/ops/dispatches/`, and `--close` looks only there; ordinary lanes are files under `~/.claude/ops/lanes/` and close by editing the file.
The work was therefore invisible in the open-lane ledger, which is the artifact answering "is anybody doing this?", and `--close HANDOFF-32731529 completed` refused with "no open dispatched lane ... already closed, or never registered".
The shape of the id is the tell: every genuinely registered dispatch is `HANDOFF-<slug>-<8hex>`, so a bare `HANDOFF-<8hex>` with no slug is a registration that did not happen.
Check for the registration after dispatching rather than trusting the printed line, and write a lane file by hand when it is missing.

The second half is why that gap survives unnoticed.
`--close <lane> completed` refuses unless given `--lesson=<slug>` or `--lesson='none: <reason>'`, so a close is easy to attempt and fail.
A successor seat reported to me in writing that it had closed this lane "completed with its done-check passing"; the file read `status: open`.
It was right about the two lanes it actually owned, so the report was 2-of-3 correct, which is the hardest shape to catch — a wholly wrong report gets checked, a mostly right one gets believed.
Read the lane file's own `status:` line before believing any close, including your own, and grep with FILENAMES (`grep -H`) because a multi-file `grep '^status:'` prints bare values whose order you will misattribute — I misread exactly that and briefly claimed the statuses were inverted when they were not.

See [[ops-lane-ledger]] for the ledger's rules, [[verify-claims-against-artifacts]] for the general form, and [[a-seat-closing-its-slice-can-strand-the-whole-arc]] for the other direction of this failure, where a close that DOES happen closes too much.
