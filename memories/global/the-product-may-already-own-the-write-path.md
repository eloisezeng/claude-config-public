---
name: the-product-may-already-own-the-write-path
description: "Before building an operator script to patch a setting, ask whether the product already exposes a write path for that key — the product's path usually carries validation, audit and provenance the raw patch silently skips, so the script is the WORSE route, not merely the longer one"
metadata: 
  node_type: memory
  scope: global
  type: feedback
  originSessionId: 996823db-a0e4-486e-bcd9-fa2b5848d1ca
  modified: 2026-08-30T18:07:45.996Z
---

Before writing an operator/box-side script to change a setting, find out **who else writes that key**.
Grep the key name across the whole tree — UI components, API route handlers, allowlist constants — not just the module that reads it.
If the product already owns a write path, that path is the answer, and the script should never exist.

**This is not about saving effort. The hand-rolled patch is usually the WORSE artifact.**
A product write path typically carries three things a raw `UPDATE`/`json_set` silently drops:

1. **Validation** — the key is checked against an allowlist, so a typo cannot invent a config key.
2. **Atomic read-modify-write** of just that key, rather than a blob rewrite that can lose siblings.
3. **Provenance and audit** — a change row naming who changed what.

Point 3 is usually decisive: a setting changed with no audit row is exactly the drift that "check the live instance, not the code" exists to catch, and it is invisible afterwards.

**Measured 2026-08-30, your-other-project, decision (4) "turn inbox notification emails on".**
The decision record called it "a live-DB config patch" and named a blocker for it **twice** — first a missing Fly token, then the permission classifier — across two sessions.
Both were answers to the wrong question.
`emailInboxNotifications` was in `TOGGLEABLE_FLAGS`, was the key behind `MUTABLE_ALERT_KINDS.inbox_new_items`, and had a **button on the live dashboard** (`InboxEmailControl.tsx`, mounted on the company page).
Verified on the live page: the row rendered "Not emailing you about these" with an `Off` pill and a **Turn back on** control.
One click, no token, no SSH, no script, no deploy.

The script that had been written for it was deleted on its merits, not as redundant: the product's `op:'configFlag'` path validates against the allowlist and writes through `patchConfigHuman`, which calls `recordConfigChanges(..., 'human')`.
The `json_set` script would have set the flag with **no audit row and no provenance**, in a system whose `config_changed` alert cannot even be silenced.

**The tell that you are in this failure mode:** you are enumerating *blockers* (a token, a permission, an access path) for an action, and you have never asked whether the action needs that access at all.
A blocker analysis that gets refined twice without ever being questioned is the signal — go looking for the door that is already open.

Related: [[verify-claims-against-artifacts]] · [[a-permission-boundary-can-track-effect-not-command-text]] · [[absence-needs-a-probe-that-could-see-presence]]
