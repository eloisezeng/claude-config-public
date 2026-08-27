---
name: check-memory-before-asking-user
description: "Before asking you to re-supply context (feedback, decisions, scope), search existing memory first"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 0e4cf0a3-70b9-4572-a87f-b45c0c3c3063
---

On 2026-06-17, while scoping a dashboard polish spec, I asked you to re-dump your per-page UI feedback — when it was already stored in [[dashboard-ui-queue]] under "AUDITED PER-PAGE SCOPE" (Mission Control home, Pipeline+Funnel, PnL, company chrome/tabs, Skills flowchart). You caught it: "did you not store my previous feedback anywhere?"

**Why:** Re-asking for context I already saved wastes your time and signals I'm not using my own memory — the opposite of why the memory exists.

**How to apply:** Before asking the user to provide context they plausibly gave before (feedback, prior decisions, scope, requirements), FIRST grep the memory dirs (global + project). Surface what I found and ask only for what's genuinely missing. Treat "the user mentions there was earlier feedback" as a hard trigger to go read memory, not to ask them to repeat it.
