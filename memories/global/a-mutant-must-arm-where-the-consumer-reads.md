---
name: a-mutant-must-arm-where-the-consumer-reads
description: A mutant can fail to reach the code two ways — the consumer reads a GENERATED copy, or the anchor occurs several times and a positional edit hits the wrong one — and "did not change the answer" is byte-identical to "never reached the code"; prove the arming in the artifact the consumer loads, and derive the target from the subject
scope: global
metadata:
  type: feedback
---

A mutation run reports SURVIVED for two reasons that look identical in its output: the tests are weak, or **the mutant never reached the code under test**.
A harness's MISARMED state only covers the anchor not matching *inside the file it edited*; it cannot know that file is not the one the consumer loads.

So before believing any SURVIVED, name the artifact the consumer actually reads and confirm the mutation is in THAT one.
Where a build step sits between them, mutate the source and re-run the generator inside the copy — or mutate the generated artifact directly.
A mutant whose arming is unproved is not evidence about the test; it is no measurement at all.

**Why:** reviewing PR 76 in `your-university_scheduler` I stripped ME's `deptIn:["ACM"]` / `minNumber:100` from `public/requirements.json` in a scratch copy and ran the browser test against it with `SITE_ROOT`. Exit 0, 43 PASS, 2 s — a clean SURVIVED that would have been written down as a weak test. The page loads `public/data.js`, generated from `requirements.json` by `scripts/rebuild_data_js.py`; the mutant was in a file nothing read. Re-armed through the generator in the copy, the same mutant killed the test in 2 s: exit 1, seven named failures. The test was never weak.

This is `[[enumerate-the-transforms-between-authoring-and-use]]` pointed at a mutation harness — the artifact that ACTS is not the one you AUTHORED — and the reason it is worth its own entry is the direction of the error: that class usually makes a guard read GREEN when something is broken, and here it made a mutation run read SURVIVED when nothing was. Both are a fail-open, and this one arrives wearing the costume of a finding about your tests.

**A second route to the same fail-open: the anchor occurs more than once, and a positional edit hits the wrong one.**
Where the string you mutate appears several times in the file, `text.replace(anchor, '')` edits the FIRST occurrence, which is a coin flip about whether it belongs to the thing under test.
The file changes, so every cheap signal says the mutant armed; no fault appears, so the output is indistinguishable from a guard that does not work.
Derive the target from the SUBJECT instead — search backwards from the code under test, or forwards from its name — and raise a named MISARMED error rather than returning an unchanged file, because a mutant that silently no-ops is worse than one that throws.

**Why:** closing a gap in `your-other-project`'s workflow-wiring guard, I cut `GH_TOKEN` from an alarm step with a forward `replace`. `fly-deploy.yml` carries four such lines and the first two belong to pre-existing freeze-interlock steps, so the mutant edited a line the guard has no opinion about and reported SURVIVED. Only the PAIRED assertion caught it: the same mutant applied to the other workflow was killed, and one of two identical mutants surviving is a fact about the mutant, never about the test. Searching backwards from the first `ci-alarm.mjs` invocation fixed it, since a step's `env:` block precedes its `run:` block.

The same check pays for itself the other way round: confirm the generated artifact is in sync with its source first (regenerate and diff for byte-identity), because that is also the gate on whether what ships matches what the source says. Related: `[[a-surviving-mutant-may-mean-the-property-is-unobservable]]`, `[[verify-claims-against-artifacts]]`, `[[never-arm-a-fault-in-an-auto-syncing-tree]]`.
