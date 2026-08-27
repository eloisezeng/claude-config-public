---
name: session-reachability-is-status-not-state
description: Fleet liveness has FOUR states — dead, reachable-but-capped, limit-dead-but-revivable, live; the roster's `status` answers reachability, only transcript growth answers progress, `state` answers neither, and neither a limit death nor leaving the roster means dead
scope: global
metadata:
  type: feedback
---

In `claude agents --json` a row carries BOTH `state` and `status`, and they answer different
questions. `state` (`working`/`blocked`/`done`) is the job's recorded stage — the same STALE TEXT as
`state.json`'s `detail`, written at some past moment and never retracted. `status`
(`busy`/`idle`/`waiting`, or **null**) is the live roster's reachability. They disagree freely: a row
reading `status=busy state=done` is normal. Sorting a fleet census by `state` therefore invents live
sessions — measured 2026-08-21, two sessions classified ALIVE from `state` whose nudges both bounced
with "No agent named … is reachable".

**Reachability test:** roster `pid`, non-null `status`, and a socket at `/tmp/cc-socks/<pid>.sock` were
perfectly coextensive across a 41-row fleet (17 rows all three, 24 rows none, zero disagreements), so
any one of the three answers it. Look on the ROSTER row, not in `state.json`: zero of 143 `state.json`
files carried a `pid` key at all, so an `if pid:` guard there silently never runs and every row falls
through to the default branch.

**Reachable ≠ able to progress — there are THREE states, and the roster can only see two:**
- **dead** — no roster pid, no socket, `status` null. A send bounces; re-dispatch, never retry.
- **reachable-but-capped** — pid, socket and `status=busy` all present, but the transcript is FLAT and
  the last assistant turn carries `model=<synthetic>` (the harness's own error turn). The cap is
  per-request, so the socket answers while every turn dies.
- **live** — transcript bytes growing over a timed window.

Only transcript growth separates the second from the third. And a capped session does NOT retry on its
own, so it staying flat across a credit top-up or account switch is **not** evidence the fix failed —
it is waiting for a nudge. Never read that flatness as a verdict on the billing change.

**A terminal-looking state is not terminal — re-measure, never remember.** Two exits look like death
and are not, and conflating either with death puts a second author on a live branch:
- **A limit death is a FOURTH state, not a variant of capped.** A session whose last entry is a
  synthetic zero-token *"You've hit your session limit"* / *"You've reached your <tier> limit"* can
  resume later and run dozens of real turns — measured 2026-08-22: a seat died at 02:48:44Z on a
  session limit and was at 58 live turns by 03:15Z. So a cap is a ROLLING condition: a session, or a
  MODEL TIER, declared spent must be re-probed at act time rather than carried as a fact. The same
  night, three seats overrode `handoff.sh`'s Fable default for an hour on a genuine 01:55Z Fable
  limit-death, after the account switch at ~02:0xZ had already restored it — a probe that could see
  presence found 79 real `claude-fable-5` turns with non-zero output tokens. Correct such a claim as a
  SUPERSESSION, not a retraction: the evidence was real and the ordering (claim timestamp vs the
  world's change) is what settles it — [[re-read-cannot-tell-wrong-from-acted-on]].
- **Leaving the roster is not death — a clean handoff also leaves.** A session that dispatches a
  successor and ends with `stop_reason: end_turn` disappears from `claude agents --json` exactly like a
  crash. A watchdog whose death branch is "no longer listed" therefore fires on the healthiest possible
  exit; measured 2026-08-22, one did. Watch the CHAIN (newest handoff record's session id, re-resolved
  each cycle, plus commits on the branch), never one session id, and read the transcript's last
  assistant entry before calling anything dead.

**How to apply:** derive liveness at ACT TIME, not from a census taken minutes earlier — a nudge list
ages. Say "reachable" or "has a live record", never a bare "alive". Distinguish blocked-on-a-limit from
blocked-on-a-permission-prompt before reviving anything: both render as `blocked`, and only the handoff
doc tells them apart — conflating them nearly put two seats on a live sale.
Settle a CONTESTED seat only by an explicit two-sided exchange with the other claimant plus two timed
transcript samples — never through a third party who holds the record but not the authority, and never
on your own read of a roster row; whoever is wrong stands down in writing before anyone touches the
artifact. And before arming any watchdog, run its death branch against a control that must NOT fire
(a session you know is mid-handoff) — [[absence-needs-a-probe-that-could-see-presence]] applies to
your own instrument.
See [[act-on-fresh-state-anchor-by-identity]], [[verify-claims-against-artifacts]],
[[claude-agents-is-the-fleet-write-surface]], [[worker-liveness-must-reflect-progress]],
[[a-handoff-doc-must-not-assert-a-drop-it-has-not-made]], [[shared-runbooks-reclaim-ownership-at-fire-time]].
