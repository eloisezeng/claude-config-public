---
name: brainstorm-in-lavish
description: "Conduct brainstorming/design Q&A through lavish-axi, not terminal AskUserQuestion"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 09853060-f5ae-40fc-830c-06cbcd526112
---

When brainstorming or gathering design decisions with the user, conduct it through **lavish-axi** — present the questions, options, mockups, and emerging design in an interactive Lavish artifact and collect her choices via `lavish-axi poll` — rather than terminal `AskUserQuestion` prompts.

**Why:** She wants design discussion on the rich, annotatable Lavish surface where she can see mockups alongside the questions, pick options, annotate specific elements, and queue follow-ups — not answer plain terminal multiple-choice.

**How to apply:** ARM THE LISTENER IN THE SAME TURN YOU OPEN THE ARTIFACT — `lavish-axi <file>` then immediately `lavish-axi poll <file>` as a harness-tracked background job. A page with no poll attached still queues her answers correctly, but she presses "Send to Agent" and sees nothing happen, and reports the tool broken (2026-08-20: she answered three decisions, got silence, and re-typed them into chat). Queued feedback is never lost, so the repair is just to poll — but the silence costs her trust in the surface. Build the brainstorming artifact (use the lavish `input` playbook for radio/选择 selections + a working submit/queue button per [[lavish-artifact-prefs]]; match the subject app's design system). Open with `lavish-axi <file>`, poll in the background, fold every selection/annotation into the spec per [[mockup-critiques-into-spec]]. Extends [[visualize-in-browser]] (which already routes "visualize" requests to lavish) to the whole brainstorming flow.
