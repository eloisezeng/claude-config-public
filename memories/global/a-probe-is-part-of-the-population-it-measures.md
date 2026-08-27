---
name: a-probe-is-part-of-the-population-it-measures
description: "A probe over a live process/file population includes the probing command itself; run controls with the measurement's exact predicate AND breadth, split the target literal, and treat a control reading NON-ZERO as invalidating exactly as a positive control reading zero"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

When you measure a **live population you are running inside** — processes via `ps`, open files, sockets, tmp paths, a log you are also writing — your own command is a member of that population. Controls, not just measurements, are exposed to this.

**Measured 2026-08-21**, supervising a watcher fleet. A gate reading printed:

```
TRUE_WATCHERS = [2]                     # correct
ZERO_CONTROL(watch-999.sh)  = [2]       # should be 0
POS_CONTROL(dirt-sampler)   = [3]       # exactly ONE sampler exists
```

Cause: the probe's own command line carried the literal string `watch-999.sh` inside a **`printf` label**, and `ps -eo args=` swept the probing shell plus its subshell. The `[w]atch-999` bracket trick guards only the *pattern* occurrence — it does nothing about a second literal occurrence anywhere else in the same command, and nothing announces the contamination.

Compounding it, the controls used a *different predicate* from the measurement: the measurement filtered `comm ~ /bash$/` then `grep -qF` on each candidate's args, while the controls were a raw `ps | grep -c` over everything. Same-name controls that sweep a wider population certify nothing about a narrower measurement.

**Why:** a control exists to prove the probe discriminates. A control that reads **non-zero** has failed exactly as hard as a positive control that reads **zero** — both say *the probe was not measuring what you thought*, and neither failure is visible in the measurement's own number, which looked perfectly plausible at `[2]`. Discipline that only checks one direction catches half the cases.

**How to apply:**
- Run every control through the **same predicate and the same breadth** as the measurement — literally the same function, called with a different target.
- **Split the target literal** so it never appears whole in the probe's own args: `TGT='watch-''570.sh'; ZC='watch-''999.sh'`.
- Read controls **before** the measurement's number, so a contaminated one stops you rather than decorating a conclusion you have already drawn.
- State both control readings when you report the measurement; a number quoted without its controls is not a measurement.
- Prefer excluding `$$` and its descendants outright when the population genuinely can contain you.

Mirror of [[absence-needs-a-probe-that-could-see-presence]] (zero from a probe with no discriminating power); same family as [[verify-claims-against-artifacts]].
