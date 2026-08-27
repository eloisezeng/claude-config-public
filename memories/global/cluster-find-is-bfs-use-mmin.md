---
name: cluster-find-is-bfs-use-mmin
description: "`find` is not always GNU find — where it is `bfs`, relative `-newermt` strings ('-25 minutes', '25 minutes ago') fail with an error on stderr and an EMPTY result, so every liveness probe built on one reads as 'no recent writes'; use `-mmin -N` / `-mtime` instead"
metadata:
  type: reference
  scope: global
---

`find` on a shared multi-user host is not necessarily GNU find.
Where it resolves to `bfs`, `-newermt` accepts only ISO-8601-like timestamps.
A relative string fails with `Invalid timestamp` on stderr and returns nothing — and under `2>/dev/null` the probe looks like a clean "no matches".

**Why:** four successive versions of a watcher reported false "STALLED" on jobs and agents that were plainly alive, because `find … -newermt "-20 minutes"` always returned empty.
It was diagnosed only when a running task's rolling checkpoint was visibly fresh on disk while the watcher still called it stale.
The shape of the bug is general: an error the caller redirected away is indistinguishable from a legitimately empty result.

**How to apply:**

- Use `find … -mmin -N` (or `-mtime`) for recency, never a relative `-newermt` string.
- Before `2>/dev/null`-ing any probe used as a liveness signal, run it once WITHOUT the redirect against a file you KNOW is fresh — see [[absence-needs-a-probe-that-could-see-presence]].
- Treat an empty result from a redirected probe as "unknown", not as "no".
