---
name: feedback-never-give-up-on-api-errors
description: "On any API/tool error, find a way around it (retry later, alternate path) — never give up"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: f8b962fe-83ad-4983-9f77-3533219c8f0e
---

When you hit an API error, rate limit, timeout, or transient tool failure, **never give up or stop the task**. Find a way to bypass it: retry, wait and retry later, back off, or use an alternate path/tool to accomplish the same thing.

**Why:** you want tasks driven to completion; a transient error is not a stopping condition.

**How to apply:** treat errors (Codex hangs, network blips, 429/503, model overload, command timeouts) as obstacles to route around, not reasons to abandon. Surface the error only if every workaround is exhausted, and say what you tried. Pairs with [[feedback-fix-dont-just-note]] and [[execution-verification-prefs]].
