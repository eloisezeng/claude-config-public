---
name: an-armed-watcher-holds-its-boot-config
description: editing a watcher's config file does NOT change the running watcher — it holds what it loaded at boot; hash the file the PROCESS runs (from ps argv), and never let an assertion NAME a subject that can move
metadata:
  type: feedback
scope: global
---

A long-running watcher (Monitor, daemon, poller, `python3 -u script.py`) loads its config **once, at boot**. Editing that file on disk changes nothing in force. **Only a re-arm does.** So a fix is not live when the file is right — it is live when the *running process* is right.

Verify by hashing the file the PROCESS is actually executing, resolved from its `ps` argv — not the file you edited, and not the canonical/promoted mirror. A promoted mirror proves nothing about what is loaded.

**Corollary — a stale watcher is worse than none, but only once a correct one exists.** Two watchers on different configs emit *contradicting* alerts on the same subjects. Do not stop the stale one until the replacement's coverage is verified at artifacts; then stop it immediately, because "it dies with my session" is not a schedule.

**Corollary — never let a control, carve-out, or allowlist NAME a subject that can move.** Derive the subjects from the set they belong to and gate on a live predicate at run time. A named subject is correct only until the lane re-seats, then it silently asserts against a corpse while still reading green.

**Why:** 2026-08-23, your_other_project fleet supervision. A watchdog carve-out was keyed to a relay seat's job dir; the lane re-seated three times in one afternoon and needed a hand-repoint each time. Worse, `watcher_alive()` matched any process whose argv contained the job-dir path, so a hold left running under a *retired* seat's name reported it healthy forever. I caught my own fix re-introducing that bug ninety seconds after removing it — I added the current owner to the carve-out just as the lane moved off it. Separately my own Monitor kept a superseded roster for ~37 minutes even though its file on disk had been corrected: the process had already booted. Three hand-repoints in one afternoon was the signal that the *pattern* was the defect; deriving subjects from the set closed the class.

**How to apply:** after editing a watcher's config, re-arm and then hash the running file from `ps` argv to confirm. When two watchers overlap, verify the new one at artifacts, then stop the old one in the same turn. When writing any assertion about "the current owner", derive the owner — never type its id. See [[fix-the-class-not-the-reported-instance]], [[act-on-fresh-state-anchor-by-identity]], [[verify-claims-against-artifacts]], [[a-poll-loop-inherits-its-predicate]].
