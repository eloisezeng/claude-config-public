---
name: probe-the-argv-the-process-runs
description: A liveness probe must match the argv the process RUNS, not the command line you typed — a launcher that re-execs makes a live child read as dead, and the next move is usually to pay for it twice
metadata:
  type: feedback
scope: global
---

`pgrep -f '<the command I typed>'` is a claim about YOUR string, not about the process. Launchers rewrite
their own argv: they drop wrapper flags, resolve relative paths, re-exec a vendored binary under a
different name. The probe then reports 0 while the work is running fine.

Measured: `pgrep -cf 'run-codex.sh --policy-version'` read **0** twice while the review was healthily
reading the tree — the launcher had re-exec'd as `codex exec -s read-only -C <snapshot> …`, which that
pattern cannot match. The reading said "dead", and the reflex it invites is to relaunch — paying twice for
one answer, and racing two writers at one output path.

So: derive the pattern from what `ps` actually shows for a known-live instance before trusting it, and
prefer matching on a stable ANCHOR the process cannot rewrite — the output path, the snapshot directory,
the lock file — over the launcher's name. Better still, gate on the ARTIFACT (`[ -s verdict.json ]`) and
use process liveness only to break the wait, so an unmatchable pattern ends the loop rather than
manufacturing a false death.

Related but distinct: a `nohup … &` launch from a background shell can kill the launcher outright with
`child setpgid: Operation not permitted`, and it leaves stale `.runlock` directories that refuse the next
attempt — clear them before relaunching, and start such a tool as a properly parented child.
See [[absence-needs-a-probe-that-could-see-presence]], [[an-armed-watcher-holds-its-boot-config]].
