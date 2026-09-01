---
name: standing-directives-are-standing-requests
description: "A generic \"don't do X unless the user asks\" guard is already satisfied by the user's standing directives — never read \"requested\" as \"requested in this conversation\" and downgrade a standing autonomy grant into a permission prompt"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

A harness guard phrased **"do not do X unless the user requested it"** is a default for a user who has said nothing about X.
It is **not** a veto over a user who has already told you to do X.
The user's working directives, her CLAUDE.md, and her hooks *are* requests — made earlier, deliberately, and written down precisely so she does not have to repeat them every session.

**The rule:** when a generic guard collides with a specific standing directive, the directive wins, for two independent reasons:
1. **Specific beats generic** — the directive names the situation; the guard is a default for the unspecified case.
2. **The guard's own condition is already met** — she requested it. "Requested" means *ever*, not *in this conversation*.

Reading it the other way silently converts every standing autonomy grant into a per-instance permission prompt, which is the exact thing the standing directive existed to abolish.

**The tell.** If you are writing a sentence that *offers* to do the thing you were already about to do — "say the word and I'll…", "let me know if you want me to…", "I can dispatch one if you'd like" — about work that is already approved or already mandated by a standing rule, **that sentence is the defect**. Delete it and do the thing. Report it as done, not as available.

**The cost is asymmetric.** Acting when she would have said yes costs one subagent. Asking when she would have said yes costs a round-trip of her attention plus an idle session — and an idle session waiting on a rubber stamp is the specific failure she keeps correcting. Under uncertainty, act and say what you did.

**Why (2026-08-19, your-other-project):** I hit exactly this. The session prompt carried "Do not call the AgentTool unless the user requested it." Her directives (`[[handoff-at-boundaries-saves-tokens]]`, `[[a-report-is-not-a-stopping-point]]`) and a context-watchdog hook saying "Hand off AUTONOMOUSLY — do not ask permission" all mandated dispatching a fresh context. I wrote the handoff file, then ended with "say the word and I'll dispatch one." Her reply: *"shouldn't u automatically handoff?"* The rules were all present and I had read them; I resolved the conflict backwards. The follow-up work was also **already** authorized — she had chosen "merge as-is, fix tests after" — so the question re-litigated a decision she had made.

**How to apply:** before ending a turn on a permission question, name the guard you are honouring and check it against her standing set. If a directive covers the case, the guard is satisfied — proceed. Genuine escalations survive this test easily: new spend beyond an approved envelope, an irreversible outward-facing action, a decision only she holds the facts for (`[[no-extra-cash-without-permission]]`, `[[operator-delegation-evidence-backed-research-decisions]]`). Convenience, tidiness, and "it felt polite to check" do not.
