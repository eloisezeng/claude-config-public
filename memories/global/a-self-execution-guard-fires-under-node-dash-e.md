---
name: a-self-execution-guard-fires-under-node-dash-e
description: A module's "am I the entry point?" guard is a comparison against `process.argv[1]`, and under `node -e` the FIRST USER ARGUMENT is argv[1] — so passing the module's own path as an argument to an inline script makes the imported module EXECUTE ITSELF, running whatever its CLI half does; pass paths by environment variable, and read a probe that hangs as a self-execution before blaming the thing being probed
metadata:
  type: feedback
  scope: global
---

The idiom is everywhere: a file exports pure functions and runs its command-line half only when it IS the entry point.
In Node that test is `` import.meta.url === `file://${process.argv[1]}` `` (the ESM spelling of Python's `if __name__ == '__main__'`), and it is a comparison against argv rather than anything the runtime knows.
**Under `node --input-type=module -e '<script>' a b`, there is no script path, so `process.argv[1]` is `a`.**
So the natural way to exercise one module's exports from a one-liner — `node -e '...' /path/to/mod.mjs` — satisfies that module's own guard, and `await import(scriptPath)` runs its CLI half instead of just loading it.

Two failures, both measured 2026-10-28 while writing a done-check over `scripts/deploy-smoke.mjs` in `your-other-project`:

- `const [, , scriptPath] = process.argv` skipped two and read the SECOND argument as the module, dying with `ERR_UNKNOWN_FILE_EXTENSION` on a `.yml`. A negative control that fails for a reason unrelated to what it checks is not a control.
- `const [, scriptPath] = process.argv` read the right path, the guard then matched, and the import ran the real deploy smoke check: `flyctl image show`, an `fly ssh` heartbeat poll with a 150-second deadline, and HTTPS probes of `https://undefined/`. It hung past a two-minute timeout before being killed.

Pass the paths by ENVIRONMENT VARIABLE (`SMOKE_SCRIPT=... node -e '... process.env.SMOKE_SCRIPT ...'`), so nothing a module compares against argv can match.
A wrapper script with its own path in argv[1] is safe for the same reason it is dangerous here: the guard compares against a path that is not the module's.
When a probe over an importable module hangs or makes network calls you did not write, suspect this before suspecting the subject — the symptom looks exactly like the module being slow, and the evidence is that the calls belong to its CLI half and not to your script.
See also [[verify-in-the-consumers-condition]] and [[absence-needs-a-probe-that-could-see-presence]].
