---
name: playwright-pins-page-visibility
description: "Playwright pins document.visibilityState to 'visible' for every page it drives — genuine hidden-tab/backgrounding behavior is untestable in-harness; emulate the hidden-tab regime deterministically instead"
metadata:
  node_type: memory
  type: reference
  scope: global
---

Playwright (verified with real `channel: "chrome"`, headful, 2026-07-13) pins `document.visibilityState` to `"visible"` for every page it drives.
No in-harness backgrounding mechanism changes it — probed exhaustively: a trusted-gesture `window.open` tab (same `windowId` confirmed via CDP), CDP `Target.activateTarget`, CDP `Browser.setWindowBounds` minimize, and stripping all backgrounding-related default launch args (`--disable-backgrounding-occluded-windows`, `--disable-renderer-backgrounding`, `--disable-background-timer-throttling`) — in every case two same-window tabs BOTH report "visible" simultaneously, which real Chrome never does.
`visibilitychange` never fires either.

**Why it matters:** any e2e that claims to test hidden-tab behavior (timer throttling, frozen rAF, visibilitychange handlers) under Playwright silently tests the visible path instead — a false-confidence trap.

**How to apply:** don't fight it. Pin the hidden-tab regime deterministically in unit/component tests instead: fake timers advancing in 1 s steps (throttled-interval emulation), rAF never fired (frozen), lifecycle events (like YT onStateChange ENDED) delivered directly — plus a foregrounded real-pipeline e2e for the rest. State the harness limitation in the spec file so the next reader doesn't re-attempt it. Example: your-project repo `web/e2e/capture-real.spec.ts` + the "hidden-tab regime" tests in `CalibrateLesson.test.tsx` (PR #19).
