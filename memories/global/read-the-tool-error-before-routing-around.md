---
name: read-the-tool-error-before-routing-around
description: "A tool error that names a replacement is a redirect, not a disable — take the named path; a workaround that merely returns data can silently degrade quality"
metadata: 
  node_type: memory
  type: feedback
  scope: global
---

Before routing around a failing tool, **read the error text and classify it**.
An error that names a replacement tool or a required argument is a *redirect* — take the named path.
Only an error that reports no path forward justifies an improvised workaround.

**Why:** [[feedback-never-give-up-on-api-errors]] says route around obstacles, and that stands — but a workaround chosen without diagnosing the error can succeed loudly while failing quietly.
It returns plausible data, so nothing looks broken, and the misdiagnosis then propagates into logs and handoffs as settled fact.
Worked example: round-2 websearcher subagents hit a context-mode PreToolUse hook that intercepts `WebFetch` and directs the caller to `ctx_fetch_and_index`.
They recorded "WebFetch disabled in env" and fell back to `curl`/`urllib`.
Pages came back, so it read as a clean workaround — but the fallback bypassed the searchable index, pulled raw bytes into subagent context, and the false "disabled" claim survived two batches in the flow log before anyone reproduced it.

**How to apply:** reproduce the failure yourself before accepting a subagent's or a log's diagnosis of it — "X is disabled/broken" is a claim about the environment and needs the same evidence as any other ([[verify-claims-against-artifacts]]).
Check the obvious config surface (settings, permissions, frontmatter tool lists) before blaming the environment.
When a subagent's declared tool list is the real blocker, fix the *registry*, not the prompt.
Verify the replacement path actually works before rewriting callers to use it, and when you correct a misdiagnosis, correct the record where it was written, not only the code ([[unambiguous-status-and-logs]]).
Fix every caller with the same defect, not just the one that reported it ([[feedback-fix-dont-just-note]]).
