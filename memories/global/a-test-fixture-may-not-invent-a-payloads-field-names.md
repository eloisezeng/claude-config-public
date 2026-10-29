---
name: a-test-fixture-may-not-invent-a-payloads-field-names
description: A fixture standing in for an external payload must be copied from a measured response, or the test and the code agree with each other and with nothing real
metadata:
  type: feedback
scope: global
---

When a fixture stands in for a payload something else produces — an endpoint's JSON, a CLI's output, a webhook, another team's file — copy it from a MEASURED response and say in a comment where and when it was measured.
A fixture whose field names you invented makes the test and the code agree with each other and with nothing real, and the test goes green on code that is wrong for every actual input.

**Why:** measured 2026-10-17. A report renderer read `commit`, `sha`, `builtAt` and `buildTime` from a build-information endpoint; the endpoint answers `git_commit`, `build_time`, `git_branch` and a ready-made `build_label`.
The renderer therefore printed "reported, but with no commit or time field" for every real run, and its whole-output unit test passed, because the fixture used the same invented names.
A typecheck cannot catch this: the payload's type was `Record<string, unknown>`, which is what an unparsed external payload honestly is.
Nothing found it until I read a real run file by hand.

**How to apply:** take the fixture from the artifact, not from the field names you would have chosen.
Where the real payload already composes the string you were about to assemble — here a ready-made label field, which the producer builds as "<commit> built <time>" — render THAT rather than reassembling a second wording of the same facts, and add only what it leaves out.
Related: [[use-the-products-own-label-never-an-invented-name]], [[verify-claims-against-artifacts]], [[a-new-detectors-first-run-measures-the-detector]].
