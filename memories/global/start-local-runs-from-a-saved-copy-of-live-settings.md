---
name: start-local-runs-from-a-saved-copy-of-live-settings
description: Keep a saved copy of the live settings in the repo and start local runs and UI tests from it, reporting drift rather than silently filling it — code defaults stay the defaults for a NEW deployment only
scope: global
metadata:
  type: feedback
---

A local run, a UI test, and the running system must decide under the SAME settings.
Keep a read-only snapshot of the live settings committed in the repo, boot local runs and browser tests from it, and report drift between it and the live system as a finding.
The values written in the code stay what they are for: the defaults a **new** deployment starts from, never a description of what the running one does.

**How to apply:**
- A missing setting is REPORTED, never silently filled. Where a start-up step already back-fills missing top-level settings, leave its scope alone rather than extending it downward: an auto-fill that reaches deeper changes the running system as a side effect of a deploy, which is the defect, not the cure (the user, 2026-09-11, Q5 answer (a)).
- Exclude anything personal or secret from the snapshot (postal addresses, alert email lists, tokens) — the snapshot is a settings record, not a data export.
- Leave the local copy in whatever mode makes local safe (a practice/dry-run mode), and record that as a deliberate difference so the drift report does not flag it every run.
- Drift is a list with a count, not a boolean. Compare VALUES, not key names: a guard that compares only the key set reads green over every wrong number.

**Why:** measured 2026-09-11 on one live system against its own code: 169 shared settings, **131 equal and 38 different**.
The differences were not cosmetic, and they ran in the dangerous direction.
Two separate spending limits were each far larger live than the figure written in the code — one by a factor of 26 and the other by a factor of 150 — nine feature switches were off in the code and on live, and the run mode itself was the safe practice mode locally against the real one on the box.
Fourteen settings existed only on the live system (seven of them read by nothing at all), and two existed only in the code.
Nothing anywhere pulled the live settings locally or reported the drift, and the repo's own settings guard compared key NAMES against a golden file, so every one of those 38 differences read green.
A separate live-vs-code settings difference had already caused one shipped defect in the preceding month's 40.

Related: [[answer-five-written-questions-before-implementing]], [[a-setting-is-not-a-rate]], [[an-armed-watcher-holds-its-boot-config]], [[verify-claims-against-artifacts]], [[a-guard-must-be-satisfiable-not-just-failable]].
