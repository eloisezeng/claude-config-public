---
name: cluster-find-is-bfs-use-mmin
description: "On the your-university cluster `find` is `bfs`, which REJECTS relative `-newermt` strings ('-25 minutes', '25 minutes ago') with an error on stderr and an EMPTY result — every liveness probe built on it reads as 'no recent writes'; use `-mmin -N` / `-mtime` instead"
metadata:
  type: reference
  scope: global
---

`find` on the your-university login nodes (hpc-92-*, hpc-33-*) resolves to `bfs`, which accepts only ISO-8601-like timestamps for `-newermt`.
A relative string fails with `Invalid timestamp` on stderr and returns nothing — with `2>/dev/null` the probe looks like a clean "no matches".

**Why:** on 2026-08-20/21 four successive watcher versions flagged false "STALLED" on live scheduler jobs and build agents, because `find … -newermt "-20 minutes"` always returned empty; diagnosed only after a running task's rolling checkpoint was visibly fresh.

**How to apply:** use `find … -mmin -N` (or `-mtime`) for recency; before `2>/dev/null`-ing a probe used as a liveness signal, run it once without the redirect against a file you KNOW is fresh ([[absence-needs-a-probe-that-could-see-presence]]).
