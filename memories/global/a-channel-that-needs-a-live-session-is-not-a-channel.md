---
name: a-channel-that-needs-a-live-session-is-not-a-channel
description: When auditing whether a failure reaches anyone, enumerate each claimed channel and ask what must ALREADY be running for it to fire — a channel whose precondition is "somebody started a session" delivers nothing in exactly the case that matters, and the alarm must SELF-CLEAR or it teaches the reader to ignore the next one
scope: global
metadata:
  type: feedback
---

Before wiring an alert, and before believing a system already has one, enumerate every claimed channel and ask one question of each: **what must already be alive for this to fire?**
A hook, a watcher, a local script, a terminal session, a person's attention.
A channel whose precondition is "somebody started a session" delivers nothing in precisely the case the alarm exists for, which is that nobody is looking.
Prefer a channel that lives **inside the artifact** — a repository issue, a tracked file, a row somebody will read anyway — because it needs nobody to be present and it travels with a fresh clone.

Two properties the channel needs beyond existing:

- **It must SELF-CLEAR.** An open alert that is no longer true teaches the reader that an open alert means nothing, which is the same outcome as having no alarm, reached more slowly. Raise on red, close on green, in the same change.
- **It must carry what failed, and the REPORTER comes first.** An alarm on a signal that has been wrong twice recently gets switched off within a week, so fix the reporting half and any known false positives in the same change as the alarm, never after it.

**Why:** `your-other-project`'s nightly full suite was the only full-suite run anywhere, and its own comment named three channels a red would reach.
Measured 2026-10-26: two were scripts under `~/dotfiles/claude` that need somebody to start a session first, and the third was GitHub's default notification email — so a fresh clone of the repository gets none of them, and the job body had no `if: failure()` step at all.
Over the 46 runs since 2026-09-11 there were 4 reds lasting 45.4, 22.9, 24.0 and 24.0 hours, and the three near 24 cleared because the next night happened to pass rather than because anyone acted.
The comment was the place the wrong belief survived longest, because it read as documentation rather than as an assumption.

Two traps found while wiring the replacement, both worth checking by hand:

- **A permission is not a credential.** `permissions: issues: write` grants the token the right to open an issue; it does not hand that token to the CLI, which reads `GH_TOKEN` from the environment and finds nothing without an `env:` block. On a failure-gated step the two failure modes are not symmetric: the step sits inside an already-failing job, so an unauthenticated call adds one more red step to a job that is red anyway and the alarm never fires. The thing built to make a red visible is itself invisible. Guard both, and remember that checking only the declaration tests the half that was never going to be the problem.
- **A report built from a log tail is fail-open.** Any process that prints multi-line noise on the way out evicts the one line naming the cause. Read the runner's structured report instead, state the no-marker case explicitly with its exit code, and name the victim of a lost worker — `[[a-tail-window-is-not-a-failure-report]]`, `[[a-red-suite-with-no-failing-test-lost-a-worker]]`.

Related: `[[notify-on-response]]` for when to interrupt a person at all, `[[watch-the-run-you-triggered]]` for the other half of this — a green tick is not a deployment, so pin the run by the commit you pushed and confirm the artifact carries the change.
