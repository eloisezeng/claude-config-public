---
name: adjudicate-review-disputes-in-the-contract
description: "When a reviewer flags by-design behavior, amend the spec + pin a test — never rebut prompt-side; when a reviewer's proposed fix is harmful, reject the fix but extract and address the real hazard underneath"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: a6419b03-b3f5-4e10-b520-ec9083d72172
  modified: 2026-07-20T18:41:33.849Z
---

When a reviewer (especially a cross-AI convergence reviewer like Codex) flags behavior that is actually by-design, do NOT just rebut it in the next round's prompt.
Adjudicate it in the contract: amend the written spec to state the design explicitly, pin the adjudicated behavior with a test, and only then tell the reviewer the resolution with the spec citation.
A prompt-side rebuttal leaves the ambiguity alive for every future reviewer (and implementer); a spec line + pinning test kills it permanently.

Corollary: when a reviewer's proposed FIX is harmful, rejecting the fix is not enough — extract the real hazard the finding gestures at and address that instead.

**Why:** 2026-07-20 your-project ads convergence: Codex R1 HIGH ("GA4 must be library-scoped") and R2 HIGH ("remove the AdSense script tag on unmount") were both contract misreadings — the first seeded by my own loose review-prompt wording, the second proposing an actively harmful SPA anti-pattern (script-tag removal doesn't unload executed code; re-injecting adsbygoogle.js causes TagErrors).
Each was resolved by spec-amend + test-pin (app-wide-GA4 line + e2e pin; injection-surface-gated line + real-client unit pin) — and R2's underlying hazard (a persistent script auto-placing ads outside the allowed surface) became a real deploy rule (Auto ads OFF in the AdSense console).
R3 came back CLEAN. Convergence terminates when the contract is unambiguous, not when the rebuttal is persuasive.

**How to apply:** on any convergence finding you believe is by-design: (1) check whether the spec actually says so explicitly — if not, the finding is legitimate ambiguity, not reviewer error; (2) add the explicit spec line; (3) add the discriminating test that pins the adjudicated behavior; (4) cite both in the next round's prompt as a binding adjudication; (5) if the finding proposed a fix you rejected, name the underlying hazard and show where it is now addressed.
Related: [[mockup-critiques-into-spec]], [[feedback-spec-stated-rules-exactly]], [[execution-verification-prefs]].
