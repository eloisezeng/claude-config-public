---
name: brainstorm-in-lavish
description: "Conduct brainstorming/design Q&A through lavish-axi, not terminal AskUserQuestion"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 09853060-f5ae-40fc-830c-06cbcd526112
---

When brainstorming or gathering design decisions with you, conduct it through **lavish-axi** — present the questions, options, mockups, and emerging design in an interactive lavish-axi artifact and collect your choices via `lavish-axi poll` — rather than terminal `AskUserQuestion` prompts.

**Why:** You want design discussion on the rich, annotatable Lavish surface where you can see mockups alongside the questions, pick options, annotate specific elements, and queue follow-ups — not answer plain terminal multiple-choice.

**How to apply:** ARM THE LISTENER IN THE SAME TURN YOU OPEN THE ARTIFACT — `lavish <file>` then immediately `lavish poll <file>` as a harness-tracked background job. A page with no poll attached still queues your answers correctly, but you press "Send to Agent" and see nothing happen, and report the tool broken (a real run lost three answered decisions to silence, and they were re-typed into chat). Queued feedback is never lost, so the repair is just to poll — but the silence costs your trust in the surface. Build the brainstorming artifact (use lavish `input` playbook for radio/select selections + a working submit/queue button per [[lavish-artifact-prefs]]; match the subject app's design system). Open with `lavish <file>`, poll in the background, fold every selection/annotation into the spec per [[mockup-critiques-into-spec]]. Extends [[visualize-in-browser]] (which already routes "visualize" requests to lavish) to the whole brainstorming flow.
