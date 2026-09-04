---
name: codex-model-tiers-and-effort-routing
description: Codex tier+effort are set separately and BOTH are per-machine; Sol defaults to `low` on the user's Mac, an unknown -p profile falls back SILENTLY instead of erroring, so read the run-log banner not the flag you passed
metadata:
  node_type: memory
  type: feedback
  scope: global
---

Codex exposes a set of tiers plus a per-model effort ladder. The tier sets capability, the effort sets how hard it thinks, and **they are set separately** — which is where the money goes wrong.

**Tier availability AND the installed profile set are PER-MACHINE. Never carry a routing flag from one machine's notes to another.** This config repo is shared with a fork on a different account, so a profile named in a shared skill may simply not exist where it runs. Measured:

| machine | tiers | profiles installed |
| --- | --- | --- |
| the user's Mac (CLI 0.153.2, re-measured 2026-09-04) | all three 5.6 tiers; **`gpt-5.6-sol` defaults to `low`** | **NONE.** `ls ~/.codex/*.config.toml` matches nothing. The four below were present 2026-08-17 and had vanished by 2026-09-04 — so a profile set is not a stable property of a machine either, and `~/.codex` is not this config repo's to keep. Was: `luna`(low) `terra`(high) `sol`(high) `solx`(xhigh) |
| deathstrxder's Windows (his ChatGPT account, CLI 0.147.0) | Sol 400s `not supported when using Codex with a ChatGPT account`; Terra is the ceiling | `luna` `terra` `terrax` `terramax` |
| your-university cluster (CLI 0.146.0) | base config is `gpt-5.6-sol`, and Sol runs fine | **none** — every `-p` falls back |

**The dangerous half: an unknown `-p` profile does not error.** It silently layers nothing and runs the base config in `~/.codex/config.toml`. Measured on the Mac 2026-08-17: `-p terrax` (absent there) ran `gpt-5.6-sol` at reasoning effort **`none`** while the caller believed it had asked for Terra/xhigh — the run succeeds, the verdict is well-formed, and nothing says the tier was wrong. The fallback can land you on a *higher or lower* tier depending on the machine, so it is not even reliably a downgrade.

**Guard, don't remember:** `run-codex.sh` refuses a `-p` with no matching `$CODEX_HOME/<name>.config.toml` (listing what is installed) and prints `tier actually used: model=… effort=…` read from codex's own banner. **Confirm the tier from that banner, never from the flag you passed**, and treat `effort=none` as a void review.

Routing, written as tiers rather than profile names because the profiles are currently absent here — spell the route as `-m gpt-5.6-sol -c model_reasoning_effort=high` and let the banner confirm it: Luna/low for textual traceability only; Terra/medium for breadth; Terra/high (`-p terra`) for spec and plan convergence and for Codex `--write` implementation of mechanical tasks; **Sol/high for adversarial diff review; Sol/xhigh for security, money, migrations and schema**; `-m gpt-5.6-sol -c model_reasoning_effort="max"` extends one reasoning chain (a race, an ordering bug — splitting it loses the thread); `ultra` spawns internal subagents (independent workstreams only) and its cost is unbounded in principle, so ask first.

There is **no `--effort` flag on the Codex CLI** (that belongs to the `codex:*` plugin's companion script). Use `-c model_reasoning_effort="high"`, which always works, in preference to a profile, which may not exist; an explicit `-m`/`-c` beats the profile on the same command line.

Gotchas verified live, not from docs:
- GPT-5.6 needs CLI **≥ 0.144.0**; an older CLI 400s rather than falling back. `codex --version` reports the PATH binary, which can lag the desktop app that refreshes the shared catalog — **trust a live probe, not the catalog**.
- An unsupported effort is a hard 400, not a downgrade, and the error's "supported values" list is **model-scoped**.
- **Context window is 272,000**, not the 1.5M secondary write-ups quote.
- Published API prices are **not what the user pays** — Codex authenticates with a ChatGPT subscription, so usage draws on plan allowance. Use them as relative weights only. When the allowance is exhausted the CLI offers a paid upgrade: **never take it** — see [[no-extra-cash-without-permission]]. A limit reset can be a month out, so record what could not be reviewed instead of quietly shipping as if it had been.

Pairs with [[codex-exec-hang-watchdog]], [[openai-structured-output-schema-limits]], [[execution-verification-prefs]], [[read-the-tool-error-before-routing-around]], [[global-config-repo]].
