---
name: answer-five-written-questions-before-implementing
description: Every spec and plan answers five written questions before its review — who fills each deciding value and what share of live items carry it, restart/retry/half-deploy behaviour, largest real input, every other reader of the value, and the live values of the settings it depends on
scope: global
metadata:
  type: feedback
---

Before any spec or plan is reviewed, it answers these five questions **in writing**, each with a measured number and the query that produced it:

1. For each value the change uses to DECIDE something: which step fills it, and what share of live items have it filled today.
2. What happens if the machine restarts, a run retries, or a deploy lands halfway through.
3. How large the largest real input is.
4. Which other pages, emails, reports or steps read the same value and must change with it.
5. Which live settings the change depends on, and what their live values are.

**A check that fires is a problem to FIX, then merge — never a warning to carry or a stop to argue past** (the user, 2026-09-11: "if a check finds a problem, shouldn't it fix the problem then merge").
The only legitimate route past a firing check is repairing the check itself, in the same change, with the reason written down; "stop, unless you write an excuse" degenerates into the excuse.

**Why:** a defect census over 178 merges to one repo (2026-08-12..09-11) found 72 that repaired something already shipped. Of the 40 most recent, classified: the earliest point at which each was catchable was **live measurement for 14 and design review for 13** — while **code review was the point that caught 0 of the 40**. The five questions are one per measured class: value-production-rarely-writes 6, lifecycle/timing 8, production-scale 6, change-not-carried-to-every-reader 3, settings-default-vs-live 1. Reviewing the artifact harder cannot reach any of them, because every one is a fact about the running system that the diff does not contain.

**How to apply:**
- Question 1 is the load-bearing one, and it subsumes a separate pre-merge counting gate: the count belongs inside the design review, not as a second checklist at merge time (the user judged the separate gate overkill, 2026-09-11).
- A share of 0% is a finding, not a note — the check refuses everything. A share far below what the design assumed is the same finding at lower volume.
- Answer from the live system, read-only, and name the source in the same sentence as the number. A code default, a config file, or a remembered figure is not an answer to any of the five.
- Question 4 is the one people skip because it has no diff: the readers that must change are precisely the ones the change does not touch.

Related: [[a-gate-may-not-read-its-verdict-from-the-gated-party]], [[measure-a-lanes-inlet-not-its-enable-flag]], [[a-setting-is-not-a-rate]], [[verify-claims-against-artifacts]], [[codex-parallel-lenses-beat-serial-rounds]], [[use-the-products-own-label-never-an-invented-name]].
