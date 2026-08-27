---
name: detached-work-dies-with-its-allocation
description: "Where a scheduler scopes a job to a cgroup, everything started inside an interactive allocation dies with it on disconnect — setsid/nohup do not escape a cgroup; durable agents belong on a submit host outside any allocation, durable work in a batch job"
metadata:
  node_type: memory
  type: reference
  scope: global
---

Where a batch scheduler puts every process of a job into one cgroup, the scheduler's step daemon kills that whole cgroup when the allocation ends — including the moment the connection that requested it drops.
`setsid`, `nohup`, detached daemons and terminal multiplexers started *inside* the allocation do NOT escape this: they are members of the cgroup, so they die with it.
The failure looks like a crash rather than a kill, because the process is simply gone and nothing wrote an error anywhere.

Durable placements instead:

- **Long-lived interactive processes** (orchestrators, watchers, agents): a terminal multiplexer on the **submit host**, outside any allocation.
  Confirm the host's logout policy first — where logout reaps a user's processes, nothing there survives a disconnect either, and a reboot always wins.
- **Long-running work**: an independent batch submission, which the scheduler runs to completion regardless of your connection.

Quick check before starting anything long: if the scheduler's job-id variable is set in your environment, you are inside an allocation, and the session dies on disconnect no matter what you wrap it in.

**Why:** "detach it and it survives" is a habit from single-machine UNIX, where the parent is what dies. Under a cgroup-scoped scheduler the *membership* is what dies, and detaching does not change membership.

**How to apply:** decide WHERE a long-lived process lives before starting it, not after it disappears.
Probe the three durability tricks that a managed multi-user host commonly disables, because each fails in a different silent way: per-user crontab can be PAM-blocked, systemd user units may have no session bus on worker nodes, and host-to-host ssh can be gated on already holding a job on the destination.
