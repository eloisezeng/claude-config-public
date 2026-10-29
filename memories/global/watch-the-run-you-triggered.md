---
name: watch-the-run-you-triggered
description: "the latest run" is whoever pushed last, and a SCHEDULED run's headSha is the DEFAULT branch's — pin a deploy by the SHA actions/checkout resolved, and distinguish ABSENT-object from NOT-an-ancestor or the probe reports a confident wrong FAIL
metadata:
  type: feedback
scope: global
---

`gh run list --workflow X --limit 1` returns the **newest** run, not **your** run.
On any repo with concurrent merges, that is routinely somebody else's push.

Worse, for a run that checks out a **non-default ref**, the run's own `headSha` is the **default branch's** tip and not the ref's, so anchoring by `headSha` — the obvious fix — silently anchors to the wrong thing and every run looks identical.

**Why:** 2026-07-31, your-other-project. Merged a PR, took the latest deploy run, watched it go green, then verified the live site and found the change absent.
The run belonged to a PR another session had merged ~2 minutes earlier; my deploy was still `in_progress`.
The green tick was real — it just wasn't mine.

2026-10-11, job_hunt, which is where the `headSha` half was measured.
A scheduled workflow lives on `main` and checks out `simplify-only-preview`.
All eight most recent runs reported the identical `headSha=0963e289` — `main`'s tip — while actually building three different trees (`3827574`, then `a4e24e1`, then `d1cba0b`).
A probe anchored on `headSha` could not have told any deploy from any other.

**Where the real SHA is.** `actions/checkout` runs `git log -1 --format=%H` and prints the 40-hex SHA on the **NEXT line** of the log.
The checkout group's own lines (`Checking out the ref`, `git checkout --progress --force -B <ref> refs/remotes/origin/<ref>`) carry **no SHA at all**, so a probe grepping those comes back empty and reads as "cannot tell" rather than as a failure.

**How to apply:**
- Anchor by identity, never by position: assert `merge-base --is-ancestor <your-sha> <resolved-sha>` so a later push by someone else still passes while a wrong tree fails.
- Read the resolved SHA out of the run's **log**, with `grep -A1 'git log -1 --format=%H'`. The PR/run-level rollup is not evidence for a non-default ref.
- Fail **CLOSED** when no SHA is found: say the probe is blind. An unreadable log must never read as a pass, and the two failure directions (blind probe vs wrong tree) must not look alike.
- **Control the probe before the run you care about exists**, against a run whose answer you already know — a pre-merge run must be REFUSED. Then prove the PASS branch is reachable too (a SHA that does contain the merge), or you have only shown it can fail. **Skipping the PASS half is what actually goes wrong**: 2026-10-28, job_hunt, a probe controlled only on the FAIL direction then reported `b57c4a5 is NOT contained in 6079c27e…` about a run that HAD deployed it — `6079c27` was a newer merge the local clone had never fetched, and `git merge-base --is-ancestor` exits non-zero for a **missing object** exactly as it does for a true negative. The wrong answer arrives as a confident finding about the deploy, pointed at production, with nothing in the output hinting the probe is the broken part.
- A containment check has **THREE** outcomes, not two: contained, not contained, and *I do not have that object*. Collapsing the third into the second is a FALSE NEGATIVE, which is worse than a blind probe because it reads as evidence. Test the object exists (`git cat-file -e "$SHA^{commit}"`), fetch once if it does not, and only then answer — still failing BLIND, never NEGATIVE, if it is still absent. The "fail CLOSED when no SHA is found" rule above covers an unreadable LOG and does not reach this case.
- Expect the resolved SHA to be **ahead of** your merge rather than equal to it, because a sibling merges inside your window as a matter of course (here the user merged her own PR #6 three minutes after mine, and the deploy carried both). That is why the assertion is ancestry and never equality — and it is also why the clone's objects go stale mid-probe.
- Confirm the deployed artifact **carries** the change, and prefer a signal the change alone could produce: a symbol absent at the previous tip, or output only the new feature emits. A line that both the old and new tree would print cannot separate them.

Related: [[verify-claims-against-artifacts]], [[act-on-fresh-state-anchor-by-identity]], [[absence-needs-a-probe-that-could-see-presence]], [[a-guard-must-be-satisfiable-not-just-failable]], [[control-a-settle-detector-on-captured-output]].
