---
name: verify-in-the-consumers-condition
description: A check run in a more forgiving environment than the consumer's proves nothing — `git apply --check` INSIDE a repo resolves malformed patch headers via the index-line blob fallback that a non-repo scratch does not have; verify under the exact condition the consumer applies
scope: global
metadata:
  type: feedback
---

Measured 2026-08-28 (your-project, e2e-port-isolation, r9→r10): four mutant patches carried a doubled `--- a/a/e2e/...` prefix that `-p1` strips to a nonexistent path.
r9 "verified" all four with `git apply -p1 --check` run from inside `web/` — which is inside a git repo, where git falls back to the patch's `index <sha>..<sha>` line and resolves the blob anyway, so the check passed.
The consumer (`redgreen.sh`) applies patches in a NON-REPO scratch, where no such fallback exists; its preflight refused all four, and the successor session had to repair them (`201de45`) and re-verify.

**Why:** many tools carry silent environment-dependent fallbacks (git's index-line blob resolution, PATH lookups, config inheritance, network retries). A verification run where a fallback is available tests the fallback, not the artifact. The claim "X was verified" is then overstated in exactly the way `[[verification-claims-are-earned-per-item]]` warns about — and the check that existed to catch the defect is the thing that hid it.

**How to apply:**
- Before calling an artifact verified, name the CONSUMER's condition (its cwd, whether it runs in a repo, its env, its tool version) and run the check under that condition — for patches destined for a non-repo scratch, `git apply --check` from a non-repo directory.
- When a harness has its own preflight, the harness's preflight IS the verification; a hand-rolled approximation of it is only trustworthy if it reproduces the consumer's environment.
- When the divergence bites, enumerate the class (which artifacts share the malformed shape), fix all of them, and correct the overstated record in place — `[[fix-the-class-not-the-reported-instance]]`, `[[verify-claims-against-artifacts]]`.
