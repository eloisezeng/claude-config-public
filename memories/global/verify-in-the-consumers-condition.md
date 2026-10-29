---
name: verify-in-the-consumers-condition
description: A check run in an environment that differs from the consumer's proves nothing, in BOTH directions — a more forgiving one tests a fallback (`git apply --check` inside a repo resolves malformed headers a non-repo scratch refuses), and a more PERMISSIVE one cannot see a guard that fires only in the consumer's environment (a fixture quarantine keyed on `NODE_ENV === 'production'`); verify under the exact condition the consumer applies
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

**The inverse direction, measured 2026-10-26 (your-other-project, shelf hard-tail relink).** The forgiving-environment case above is only half the rule. An operator script shipped in a reviewed, CI-green PR could not boot on the box at all: it built its plugin registry with a bare `makeDomainyour-data-productPlugin()`, which falls through to a synthetic comps fixture whose constructor throws whenever `NODE_ENV === 'production'`. It died at MODULE SCOPE, before either of its modes, so the defect was not confined to the path that read the registry. Nothing in the repo could see it — every test of that arc constructed the plugin through a fixture harness, and vitest does not set `NODE_ENV=production`, so the only condition that fails was the one no check was ever run in. It surfaced when the script was finally run on the machine, with a deploy freeze about to be armed.

So the question is not only "is my check's environment more forgiving than the consumer's?" but also **"does the consumer's environment switch on a guard that mine does not?"** Grep the imported graph for `NODE_ENV`, `process.env`, and quarantine throws, and for any script destined for a server, spawn it in a CHILD PROCESS with the server's environment set. The fix is never to unset the environment variable: that puts the quarantined fixture inside a process which writes to live data, and silently moves every other production branch in the graph — repair the caller so it constructs what production constructs, importing the production wiring rather than restating it.
