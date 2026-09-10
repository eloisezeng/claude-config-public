---
name: a-task-notification-reports-the-last-commands-exit
description: "A background-task completion notification reports the exit status of the LAST command in the chain, not the suite's — measured three times, twice over a genuinely red suite"
metadata:
  node_type: memory
  type: reference
  scope: global
---

`run_in_background` reports `(exit code N)` for the **backgrounded shell line as a whole**, which is
its LAST component's status. Any line that ends in an `echo`, a `tail`, or an append of a captured
code therefore reports **0** no matter what the suite did — the same defect as reading `$?` off a
`;`-joined line ([[a-control-must-match-the-probes-shape]]), one level up, and harder to see because
the notification arrives as authoritative-looking prose ("completed (exit code 0)") rather than as a
shell status you knew you were reading.

Measured three times in one arc on your-other-project (2026-09-07/08), **twice over a genuinely red
vitest suite that the notification called exit 0.**

The fix is to make the suite's own status an artifact inside the log, and read only that:

```bash
npm test > /abs/path/run.log 2>&1
ec=$?                                  # its own line — zsh has no $PIPESTATUS
echo "NPM_TEST_EXIT=$ec" >> /abs/path/run.log
```

then `grep -E 'NPM_TEST_EXIT=' /abs/path/run.log`. Never the notification, and never the summary
line — a run can print a passing `Tests` line and still exit non-zero on a worker crash, and a
stack trace in the log can equally be a **passing** test's asserted stderr, so the appended code is
the only thing that answers the question actually asked.

This generalizes: whenever a wrapper reports a status you did not compute, ask which process it
actually observed ([[verify-claims-against-artifacts]]).
