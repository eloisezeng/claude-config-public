---
name: scale-test-large-data-paths
description: "For code whose memory/time scales with input, add a resource-constrained scale test — a fixture proves logic, not that it won't OOM at production scale"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: session_01TePdzy5YAkEpRQ3sLF49Sq
---

When a code path's memory or runtime grows with input size — streaming, diffing, sorting, or aggregating large files/collections — a small-fixture unit test proves the **logic** but NOT the behavior at production scale. Add a **scale/stress test that exercises the real growth path under a constrained resource** (e.g. run the function in a child process with a tight `--max-old-space-size` and assert it completes with the right output) so an unbounded accumulation fails the test instead of production.

**Red flags that demand a scale test (treat as latent OOMs):** building an array/list/Map proportional to input (`const out = []; for (…) out.push(…)` then return), loading a whole file into memory, buffering all results before returning, or any "collect everything then process" shape on unbounded input.

**Two traps that hid this class of bug:**
- Don't conclude a large-data feature "works" from a path that **short-circuits the expensive work** (e.g. a content-hash "unchanged → skip diff" branch never walks the data), nor from a **smaller sibling that happens to fit** — the expensive path must be run at real scale at least once, on purpose.
- A green suite of tiny fixtures is not coverage of the memory dimension. If the function's cost is O(input), there must be a test where input is large.

**Why (2026-07-01, your-data-product `.com` zone-scout):** `diffNameFiles` buffered every delta in one array. Unit tests used ~handful-of-name fixtures; the `.org` lane (~14k deltas/day) ran the same code fine; and the only `.com` "comparison" ever exercised before prod was a hash-equal short-circuit. So the OOM (~millions of deltas → ~1 GB V8 heap) first appeared in production, silently killing the pipeline. A single resource-capped scale test on a generated large diff — reproduced after the fact in one run — would have caught it. Fix + guard: `[[verify-claims-against-artifacts]]`, `[[extract-learnings-proactively]]`.

**How to apply:** for each hot path, generate a large input in a test, run it in a child process with a low heap cap, assert exit 0 + correct output; keep the guard cheap enough to run in CI. Prefer a running-code regression test over a comment.
