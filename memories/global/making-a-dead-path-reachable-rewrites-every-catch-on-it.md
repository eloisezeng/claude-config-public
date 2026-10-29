---
name: making-a-dead-path-reachable-rewrites-every-catch-on-it
description: a fix that lets a previously-unreachable error finally arrive silently changes what every existing catch on that path MEANS, with no diff in those files and no red test — enumerate and drive the callers yourself before committing, because the per-item handling was written against an error that could not come
metadata:
  type: feedback
scope: global
---

Correcting an error's CLASSIFICATION is two changes, and only the first one shows up in your diff.
Making a dormant error finally reach its callers changes the meaning of every `catch` already on
that path — and those files do not appear in the diff, the compiler says nothing, and the suite
stays green, because no test ever drove them with the condition that was impossible until now.

The shape: a transport relabelled the run's own budget refusal as a provider failure, so the
scheduler's `instanceof RequestBudgetExceededError` branch was DEAD CODE and a board that merely
ran out of requests was recorded as a board that FAILED — which after `BOARD_GONE_DAYS` declares
the board gone and releases the user's rows for a board nothing ever asked. The diagnosis was
right and the fix was right in shape (a `RequestNotIssuedError` class, rethrown untouched, so a
refusal to issue is not a fact about the host). What it did NOT do is ask what the newly-reachable
error now means where it lands. Measured: that revived branch restores `Last checked` — correct for
a read that never issued a request, starvation for one that issued attempts and then ran out, so a
three-day probe asked for the SAME company every day where the identical probe at BASE reached the
next one on day two; and two batch callers outside the change (`fetchCommand`, a registry seeder)
now abort before publishing, losing an invocation's completed work where they used to record a
per-company failure. Full suite green at 1,854 tests with both regressions in it.

So: when a fix makes a path reachable, the callers of that path ARE the change. Enumerate every
one, say in writing what each now does with the error, and DRIVE each of them under the newly
reachable condition yourself before committing — a diff-scoped review cannot see a file it does
not contain, and a green suite is evidence about the tests that exist, not about the branch that
just came alive. Expect the revived handler to be written for the narrower case it was reachable
for (never-issued), so the fix is usually to split the outcome rather than to tune the handler:
tell an entirely UNISSUED attempt from an INTERRUPTED one and give each its own disposition.

Asking a review lens the blast-radius question is worth doing and is not a substitute: here the
lens found both regressions and I had written the question for it, which means I knew the risk and
paid a review round to answer what I could have measured in one probe before the commit.

Related: [[a-new-first-guard-retires-the-old-ones-coverage]] is the inverse — a new guard making an
old path unreachable. [[a-pure-decision-with-no-caller-passes-every-test]] is the same blindness
one step earlier, where nothing calls the decision at all.
[[fix-the-class-not-the-reported-instance]] · [[absence-needs-a-probe-that-could-see-presence]]
