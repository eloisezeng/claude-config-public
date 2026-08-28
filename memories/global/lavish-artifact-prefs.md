---
name: lavish-artifact-prefs
description: "How you want lavish-axi review artifacts built — interactive radios, working submit, notifications"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 4e85aedd-72b3-4e58-86b9-ac16d336fd49
---

When building lavish-axi review surfaces for you, default to these:

- **Interactive controls, not annotate-only.** Put real `<input type="radio">` / `<form>` choices in the artifact so you can pick options directly, rather than highlighting elements and annotating. (lavish "input" playbook.)
- **The submit/queue button MUST actually work.** Real bugs that have hit this: (1) a form control named `window` shadowed `window.lavish` inside inline `on*` handlers → `undefined`; (2) `new FormData(el)` was called on a `<div>` (FormData only accepts `<form>`); (3) **inline `onsubmit=`/`onclick=` attributes silently did nothing** — the button appeared dead with no error — even though the official lavish `input` playbook example itself uses inline `onsubmit`. Note: the fork's `src/html-transform.js` does NOT strip handlers (it only injects `sdk.js` before `</body>`), so the cause is the chrome's click/submit interception, not sanitization. The fix that worked: wire handlers in a real `<script>` block via `addEventListener`, and bind BOTH the form's `submit` AND the button's `click` (not submit alone). Read the checked radio via `form.querySelector('input[name=...]:checked')` or `new FormData(form).get(name)`, never name controls `window`/`top`/`self`/`document`, guard for `window.lavish` not yet present, and surface errors inline (try/catch) instead of failing silently. Offer an "Other" free-text option too. A worthwhile fork hardening (not yet done): surface artifact runtime JS errors / dead-control failures back through `poll` the way `layout_warnings` are, so silent button breakage becomes visible to the agent automatically.
- **The API is `window.lavish.queuePrompt(text, opts)` + `window.lavish.sendQueuedPrompts()` — there is NO `window.lavish.respond`.** A guard written as `typeof window.lavish.respond !== 'function'` therefore ALWAYS fires, and the button reports "Not connected yet" forever no matter how long you wait. This has now produced a dead button twice; the honest tell is that the failure message blames connection timing rather than the missing method. Confirm the method name against `lavish-axi playbook input` before shipping the artifact, and make the guard name the method it actually calls.
- **Notifications:** ping you when a response/needs-input is ready — see [[notify-on-response]].

**Why:** you'll reuse lavish and want the basics (radios, working queue, notifications) to just work.

**How to apply:** start from a known-good form pattern; test the queue path mentally before shipping the artifact; keep the `window.lavish` call in real function scope.
