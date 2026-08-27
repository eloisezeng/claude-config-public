---
name: cross-session-inbound-hold-is-mode-parity
description: "\"Cross-session message held for approval\" is Claude Code's own inbound peer-message gate (mode parity: sender's permission-mode CLASS must match the receiver's); fix is `crossSessionInbound: accept` in USER settings — set 2026-08-20"
metadata: 
  node_type: memory
  type: reference
  scope: global
  originSessionId: fcc2e92f-6d21-4d04-8323-7da77cc46992
  modified: 2026-08-20T15:29:37.272Z
---

**The notice is emitted by the Claude Code binary, not by any repo hook or script.**
Verified 2026-08-20 on Claude Code 2.1.237 (`~/.local/share/claude/versions/2.1.237`, Bun-compiled; feature codename "harbor kite"):
the sender sees `Cross-session message held for approval. The recipient's session has different permission-mode settings, so their user must approve it before Claude sees it.`;
the receiver sees `Held peer message — from <session> … The sending session's permission mode class doesn't match this session's.`

**The check (receiver-side gate `u2f`), in order:**
1. If `crossSessionInbound` is set explicitly → that value wins (`accept` / `hold` / `refuse`).
2. Messages from sessions this session itself spawned (`selfSent`) → accept.
3. Otherwise *mode parity*: this session's class is `bypass` if `permissionMode === "bypassPermissions"` (or `plan` with bypass available), else `prompting`.
   If the sender attested a class: accept iff equal, else hold (`mode-mismatch`).
   If the sender attested none: hold only when this session is `bypass` (`no-mode-asserted`), else accept.
4. A held message waits `dialogExpiry` (default 5m; `CLAUDE_CODE_USER_DIALOG_TIMEOUT_MS` overrides) and is then dropped with an "expired" receipt — in headless sessions it just expires.

So a `--dangerously-skip-permissions` session talking to a normal prompting session (or vice versa) is always held by default — that is exactly the mixed fleet of background/foreground sessions this machine runs.

**Fix applied 2026-08-20:** `"crossSessionInbound": "accept"` in `~/.claude/settings.json`.
Precedence is policySettings → flagSettings → userSettings (first defined wins); `.claude/settings.json` / `settings.local.json` may only TIGHTEN (accept < hold < refuse), so the key must live in USER scope — a repo-level `accept` is ignored.
Takes effect in already-running sessions: the gate re-reads settings and has a `policy-accepts` release path ("crossSessionInbound now accepts") that delivers anything currently held.

**Caveats:** this build has NO per-sender trust list — `accept` admits every local peer session (same OS user; messages still arrive labelled as from another Claude session, never as from the user, and size/rate caps still apply).
Cross-machine sends (cloud / Remote Control) are gated separately on the SENDER by `isolatePeerMachines`.
Kill switch: env `CLAUDE_CODE_HARBOR_KITE` / flag `tengu_harbor_kite`; off → every inbound is refused regardless of this setting.
