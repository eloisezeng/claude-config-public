---
name: read-the-ledger-before-routing-a-tool-call
description: an open lane often already holds the working parameter for the tool you are about to fail three times on
metadata:
  type: feedback
  scope: global
---

Before concluding a tool is unavailable, grep the open lane ledger for the TOOL's name — a lane
opened by a past failure usually records the exact working parameter, and the generic
"X is broken" write-up is the expensive way to rediscover it.

**Why:** a tool's own advertised capability list is not the account's. `~/.codex/models_cache.json`
named seven models; the account could run two, and the lane
`codex-refused-for-chatgpt-account` had already measured which two on 2026-10-04. Measured
2026-10-15: three launches × three watchdog attempts on two refused models, plus a written
"Codex cannot run here at all" that was wrong, all of it avoidable by one grep.

**How to apply:** the moment a tool errors in a way that looks structural (auth, model, tier,
quota, endpoint), `grep -ril '<tool>' ~/.claude/ops/lanes/` BEFORE the second attempt. If a lane
exists, read it and use its recorded parameter. If one does not, the write-up you were about to
make is worth making — but measure the working case too, not only the failing one, or the next
session repeats this. Pairs with [[read-the-tool-error-before-routing-around]], which says to
classify the error; this says to check whether someone already classified it.
