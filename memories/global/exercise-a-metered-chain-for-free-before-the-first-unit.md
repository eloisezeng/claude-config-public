---
name: exercise-a-metered-chain-for-free-before-the-first-unit
description: "Before spending unit 1 of a countable pre-approved envelope, run the WHOLE chain against a throwaway store with an injected stub — have the stub mode REFUSE the real store by path, exhaust the throwaway envelope so the N+1 refusal is seen firing, and positive-control every safety check so its silence later means something — then spend unit ONE ALONE and parallelise only the rest; and check whether the wrapper you launch through DISCARDS the measurement your objective asks you to report (a launcher's tier banner went to a stderr the runner dropped, recoverable only from the inner tool's own log)"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

A countable envelope — N approved launches, N API calls, N credits, N sends — is spent by
ATTEMPTING, not by succeeding. A gate that counts attempts is the honest kind, and it
means a broken chain burns the envelope while producing nothing to show for it.

So the order is: build the whole chain, exercise it for FREE, then spend.

Four things the free pass must do, and the third and fourth are the ones usually skipped:

1. Point the chain at a THROWAWAY store and inject a stub for the metered effect. The
   stub should write a log shaped like the real one, so the parse that reads the
   measurement is exercised too.
2. Make the stub mode REFUSE the real store by path. Otherwise a stub run's reservation
   lands in the real ledger and consumes a slot for a run that did nothing —
   `[[a-gate-may-not-read-its-verdict-from-the-gated-party]]`.
3. EXHAUST the throwaway envelope and watch the N+1 attempt be refused. A gate asserted
   only in the direction that passes is a gate nobody has seen fire —
   `[[a-guard-must-be-satisfiable-not-just-failable]]`.
4. Positive-control every safety check, so its silence on the real run carries
   information. Mine checked that a workspace held no answer artefact; a clean workspace
   returned `[]` and the same workspace with the answer file added returned the finding
   naming it — `[[absence-needs-a-probe-that-could-see-presence]]`.

Then spend **unit one alone**. Not in parallel. A chain fault costs one unit instead of
all of them, and the first real unit is also the first honest measurement of what a unit
costs. Parallelise units two onward once the chain is proven — that buys the wall-clock
back without buying it with the envelope.

Measured 2026-10-26, a three-launch envelope: five free controls, then launch one alone
at 222 s and 48,186 tokens, then two concurrently, then the fourth attempt refused on the
REAL store with its row counts unchanged at 3 and 3. The whole run cost 67% of its own
projection, and nothing was learned the expensive way.

**The sting in the tail: the wrapper may throw away the number you were told to report.**
My objective said to read the tier back off the launcher's banner. The runner captured the
inner tool's log file and DISCARDED the launcher's own stdout and stderr whenever that file
existed — and the banner was on that stderr. Verification was intact (a mismatch still
quarantines the output and exits non-zero), so this was a reporting loss, not a
verification loss, and the value was recoverable from the inner tool's own banner inside
the kept log. Ask of any measurement an objective demands: which process PRINTS it, and
does the thing I am running through keep that stream? Then report the second source by
name and record the loss — `[[verify-claims-against-artifacts]]`.
