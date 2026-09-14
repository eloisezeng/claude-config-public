---
name: feedback-never-give-up-on-api-errors
description: "On any API/tool error, retry until it succeeds (back off between tries; route around only what retrying cannot fix) — never give up"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: f8b962fe-83ad-4983-9f77-3533219c8f0e
---

When you hit an API error, rate limit, timeout, or transient tool failure, **retry until it succeeds** — never give up or stop the task. Back off between attempts (wait longer each time) rather than hammering; if the error is not transient (a bad argument, a missing permission, a removed endpoint), fix the call or use an alternate path/tool that accomplishes the same thing, then keep going.

**Why:** the user wants tasks driven to completion; she said "whenever u get api error, retry until success" (2026-09-11). A transient error is not a stopping condition.

**How to apply:** treat errors (Codex hangs, network blips, 429/503, model overload, command timeouts) as a cue to retry, not a reason to abandon. Read the error first ([[read-the-tool-error-before-routing-around]]) — a redirect or a hard 4xx needs a changed call, not the same call again. Surface the error only if no retry or workaround can ever succeed, and say what you tried. Retrying never overrides the spend rule ([[no-extra-cash-without-permission]]). Pairs with [[feedback-fix-dont-just-note]] and [[execution-verification-prefs]].
