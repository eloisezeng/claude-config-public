---
name: brainstorm-in-your-review-tool
description: "Conduct brainstorming/design Q&A through your-review-tool, not terminal AskUserQuestion"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 09853060-f5ae-40fc-830c-06cbcd526112
---

When brainstorming or gathering design decisions with you, conduct it through **your-review-tool** — present the questions, options, mockups, and emerging design in an interactive your-review-tool artifact and collect your choices via `your-review-tool poll` — rather than terminal `AskUserQuestion` prompts.

**Why:** You want design discussion on the rich, annotatable your-review-tool surface where you can see mockups alongside the questions, pick options, annotate specific elements, and queue follow-ups — not answer plain terminal multiple-choice.

**How to apply:** ARM THE LISTENER IN THE SAME TURN YOU OPEN THE ARTIFACT — `your-review-tool <file>` then immediately `your-review-tool poll <file>` as a harness-tracked background job. A page with no poll attached still queues your answers correctly, but you press "Send to Agent" and see nothing happen, and report the tool broken (a real run lost three answered decisions to silence, and they were re-typed into chat). Queued feedback is never lost, so the repair is just to poll — but the silence costs your trust in the surface. Build the brainstorming artifact (use your-review-tool `input` playbook for radio/select selections + a working submit/queue button per [[your-review-tool-artifact-prefs]]; match the subject app's design system). Open with `your-review-tool <file>`, poll in the background, fold every selection/annotation into the spec per [[mockup-critiques-into-spec]]. Extends [[visualize-in-browser]] (which already routes "visualize" requests to your-review-tool) to the whole brainstorming flow.
