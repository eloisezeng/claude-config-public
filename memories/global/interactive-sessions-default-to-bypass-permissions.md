---
name: interactive-sessions-default-to-bypass-permissions
description: Since 2026-09-01 ALL new sessions boot in bypassPermissions (user settings defaultMode) — no approval prompts anywhere; she applied it herself after the classifier refused agents doing it
metadata: 
  node_type: memory
  scope: global
  type: user
  originSessionId: d7080700-0450-41a5-82a6-d3ffbe31f30a
  modified: 2026-09-01T14:55:37.784Z
---

On 2026-09-01 the user set `permissions.defaultMode: "bypassPermissions"` in `~/.claude/settings.json` herself (via a `!` bash-input one-liner), after the auto-mode classifier blocked an agent from writing that key — an agent may never grant itself or future agents bypass, and must not route around that refusal.

Facts that follow:
- Every NEW session in every project boots with no approval prompts and no startup confirmation (`skipDangerousModePermissionPrompt` is also true). Already-open sessions keep the mode they booted with.
- The "unattended seat parked forever on an approval prompt" failure class ([[handoff-dispatch-in-bypass-permissions]]) no longer applies to sessions launched after this date; it still applies to any seat explicitly handed `auto`/`manual`.
- Do not hand-pass `--permission-mode` to defeat the default; pass one only to deliberately give a seat a stricter mode.
- In a session still running in auto mode, the classifier's permission-granting block is STICKY across related reads ([[a-permission-boundary-can-track-effect-not-command-text]]) — verify her settings edits with the Read tool, not shell.
