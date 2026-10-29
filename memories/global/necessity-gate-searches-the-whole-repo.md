---
name: necessity-gate-searches-the-whole-repo
description: Before claiming "nothing exists" in a necessity gate, search from the repo ROOT over every prior round/stream/worktree AND every OPEN PULL REQUEST HEAD with the command and hit list pasted — an unmerged branch is invisible to git grep, so a gate run in a worktree is a claim about the MERGE TARGET, not the repository (measured: a per-band decomposition built a THIRD time; a Guest allowance UI already shipped on an open PR the gate could not see)
metadata:
  type: feedback
  scope: global
---

Before planning any new component, run the existence search from the repository ROOT over EVERY prior round, stream, worktree and vendored tree — **and over every OPEN PULL REQUEST HEAD** — `git grep -il '<concept synonyms>' -- '*.py'` and, where the project has one, its generated tool inventory (`mffp_autoresearch/tools/make_tools_index.py --find <concept>`) — and paste the exact command with its hit list into the necessity gate. Classify every hit as reuse / extend / superseded with the reason. "Nothing exists" without the command shown is not a finding.

**Why:** On 2026-09-05 (round 5 of MFFP) I declared "no spectral or band tool exists anywhere in rounds 1–4" after grepping `round3/tools` and a wrong round-4 path with a narrow regex, and built a per-band error decomposition for the third time: round 1 held `field_error_decomposition.py`, `band_phase_anatomy.py` and `band_weight_counterfactual.py` (which also carried the lesson that per-band ratios are unbounded in near-empty bands), and round 4's `run_p0c_diagnostics.py::band_profile` had already profiled the eight bar-tier dumps. The user caught it by asking "was this not done for round 4?". The cost was the pure module and a wrong claim in a converged spec; the class is the general one from [[absence-needs-a-probe-that-could-see-presence]] — an absence claim whose probe could not have seen the thing.

**The second blind spot, measured 2026-10-07: an UNMERGED branch is invisible to `git grep`.** A gate run inside a worktree based on `origin/main` answers a question about the MERGE TARGET, not about the repository. Mine declared three components "genuinely new"; an open pull request already shipped the Guest allowance UI, a browser-side limit stub, a visitor-mode provider and a meter, and the stub's own header named my change as the limit service it was waiting for. The two changes were complementary rather than duplicates, so nothing was wasted that round — but the gate had no way to know that, and the ONLY reason I found it was a reviewer asking a different question. Run this and paste it with the gate:

```
git fetch origin "+refs/pull/*/head:refs/remotes/origin/pr/*"
for n in <every open number>; do
    printf "pr/%s " "$n"
    git diff --name-only origin/main...origin/pr/$n | grep -icE '<concept synonyms>'
done
```

Then **check ancestry among the hits before believing any one of them**, because the pull request somebody told you about may be contained in a newer one that supersedes it: `git merge-base --is-ancestor origin/pr/35 origin/pr/37` proved PR #37 held both #34 and #35, so #37 was the branch to reconcile with and the two I had been handed were its parts. A hit list without the ancestry check names the wrong integration target.

**How to apply:** Treat the necessity gate as a MEASUREMENT with a stated rule: root-wide command, synonyms for the concept (band/spectral/fft/dct/radial/nyquist for this one), hit list pasted, each hit dispositioned. In a repo with rounds or streams, maintain a generated inventory with a freshness test (the MFFP one is `mffp_autoresearch/TOOLS_INDEX.md`, generated, `--check` pinned by `round5/tests/test_tools_index.py`) and search THAT, because a generated index cannot omit a tool that exists. When a prior tool is found, extend or cite it; when the new tool differs, write the difference into the spec next to the hit list so the next round's gate starts from it. Related: [[encode-the-invariant-in-the-shape-not-another-guard]], [[verify-claims-against-artifacts]], [[merge-clean-is-not-merge-correct]].
