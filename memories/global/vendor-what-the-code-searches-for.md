---
name: vendor-what-the-code-searches-for
description: "Vendoring code without vendoring the files it SEARCHES for leaves it silently reading a neighbouring tree's copy — and the fall-through is invisible whenever that foreign file merely exists"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When you copy code into a new tree (vendoring, forking a harness, standing up a new experiment round), the copy is not self-contained until every input it *resolves by search path* is copied too. Any `parents[N]`, `_main_repo_root()`, "first root that contains X" or multi-root lookup will happily fall through to a neighbouring tree and read someone else's file.

**Why it bites:** the failure is silent exactly when it is most dangerous. A copied harness once resolved its reference file to the parent repo's older, sparser version and refused 57 of 79 cells — loud, found in an hour. The *same* file resolved a second input whose absence was "tolerated" (`if p is not None`), so it never raised at all: it quietly read a foreign file and stamped that path and hash into the results as provenance. Nobody noticed for the entire build, because nothing failed. A silently-satisfied dependency is worse than a loudly-broken one.

**How to apply:**
- Enumerate the search-path inputs when you vendor, not when they break: grep the vendored code for every multi-root resolution and ask, for each, *which tree wins today and which should win*. Classify each site (pinned / agrees-but-unpinned / mismatched) and report the count — an inventory, not a hunt.
- Vendor each resolved input alongside the code, pin it by hash in the dependency manifest, and verify your copy wins the search order ahead of any outer tree.
- **Make unresolvable inputs FAIL, never degrade.** Delete "tolerated absence" branches: a declared input that cannot be found inside your own identity set must raise. Pin that fail-closed behaviour with a test that removes the vendored file and asserts the raise.
- Producer/consumer inventories miss these by construction: they enumerate pairings *within* the tree, while these reach *outward*. Add search-path-resolved inputs as their own category.
- Tests that inject the dependency are blind to all of it — the resolution must be exercised through the real search path.

Related: [[verify-claims-against-artifacts]], [[absence-needs-a-probe-that-could-see-presence]], [[unambiguous-status-and-logs]], [[enumerate-recurring-defect-classes]].
