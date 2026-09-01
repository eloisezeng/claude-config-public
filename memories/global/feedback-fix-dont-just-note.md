---
name: feedback-fix-dont-just-note
description: "When you notice something worth fixing, fix it (even out of scope); run Claude/Codex convergence on every review"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: f8b962fe-83ad-4983-9f77-3533219c8f0e
---

Two standing work preferences from the user:

1. **Fix what you flag.** Whenever you note something worth fixing — even if it's out of scope of the original request — just fix it. Don't leave it as a "minor note for later."
2. **Always run the Claude/Codex convergence loop when reviewing code.** Every time you review a diff, cross-review it with Codex (`codex exec --skip-git-repo-check --cd <repo> "<prompt>" < /dev/null`) and iterate until both converge (no remaining real issues), not just once.

**Why:** noting-without-fixing leaves rot; she'd rather pay the extra edit now. Convergence (two independent reviewers iterating to agreement) catches more than a single pass. Matches [[execution-verification-prefs]].

**How to apply:** after finishing a task, act on every issue you surfaced in the same session. On any code review, loop Claude self-review + Codex review → fix → re-review until clean.
