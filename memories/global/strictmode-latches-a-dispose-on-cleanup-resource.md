---
name: strictmode-latches-a-dispose-on-cleanup-resource
description: A one-shot/latching resource bound to a bare React effect cleanup is dead at mount under StrictMode; bind it through a hook whose SETUP restores what its cleanup tore down, and mount the test under StrictMode
scope: global
metadata:
  type: feedback
---

`useEffect(() => () => resource.dispose(), [resource])` is WRONG for any resource whose teardown is
irreversible — a latch, a one-shot close, an `AbortController`, a disposed pool. React StrictMode
(dev; **on by default in the App Router**) runs every mount effect **setup → cleanup → setup**, and
`useState`/`useRef` hand back the SAME value all three times. So the cleanup kills the one instance
the component will ever have, before its first interaction.

**How to apply:**
- Bind through a hook whose setup RESTORES what its cleanup tore down (`reopen()` / re-create), and
  make that hook the only legal binding — pin it with an import census so no site can hand-roll the
  two lines again. A real unmount is a cleanup with no setup after it, so the teardown guarantee
  survives intact.
- Every unit test that mounts WITHOUT `<StrictMode>` is blind to this class. Mount the pinning test
  under `<StrictMode>`, and keep the hand-rolled version as an executable positive control asserting
  the broken outcome — if that control stops failing, the test has stopped testing.
- Symptom shape to recognise: **dev/e2e-only**, production fine (no double-invoke), and the feature
  half-works — the write/persist path completes, only the part gated on the dead resource vanishes.
  That reads as a missing button, not a broken feature, so it gets misfiled as a UI or timing bug.

**Why:** a scoped blob-URL owner whose `dispose()` latched was bound this way at two sites. Every
recording still recorded, saved and got its chip — but `create()` returned null, so the review
overlay never rendered: 22 e2e failures across 12 spec files, invisible to 3051 unit tests because
not one of them mounted under StrictMode. See [[spec-cites-code-by-line-number]].
