---
name: handoff-dispatch-in-bypass-permissions
description: Handoff successors boot in bypassPermissions — handoff.sh defaults PMODE to it (2026-08-28, pinned by AB5/AB6), so never hand-pass a mode that defeats it; a direct `claude --bg` still needs the flag by hand, because the prompting class parks an unattended seat unrescuably
metadata:
  type: feedback
  scope: global
---

The user, 2026-08-28: "whenever handing off to new sessions, use auto mode, ideally bypass permissions" — then, asked whether to make it mechanical: "flip handoff.sh's default".

**`handoff.sh` now supplies it:** `PMODE="bypassPermissions"` is the default in `hooks/handoff.sh`'s option-parse block, forwarded to `claude --bg` where the argv is assembled.
Cited by symbol rather than line number: measured 2026-09-01, the line numbers this memory used to carry (2656 / 2904) had drifted to 2860 / 2991 and pointed at unrelated code.
Pinned by `tests/handoff.test.sh` AB5 (no flag → the dispatch carries `--permission-mode bypassPermissions`) and AB6 (an explicit flag still wins, with an `assert_missing` control that fails if the default is APPENDED alongside the explicit one rather than overwritten — argv would accept that silently and `claude` would resolve whichever it read last).

**Why the old `PMODE=""` was not a neutral default.**
It omitted the flag entirely, so the successor booted in the PROMPTING class — the one mode that parks an unattended seat forever on a tool-approval prompt, and **a queued `SendMessage` cannot drain past it** because the seat never reaches a tool round to read the message.
That seat is unrescuable by messaging; see [[bg-session-liveness-and-approval-parking]].

**Still pass it by hand wherever no launcher does it for you** — a direct `claude --bg`, or any dispatch that does not go through `handoff.sh`.
`claude --permission-mode` accepts `acceptEdits`, `auto`, `bypassPermissions`, `manual`, `dontAsk`, `plan`.
Give a seat that should still gate something `auto`, and one that should prompt like a human session `manual`.
`handoff.sh` does not validate the value — a typo passes straight through and `claude --bg` rejects it at launch, which reads as a turn-1 death rather than as a bad flag ([[handoff-successor-model-safeguard-failure]]).

**The default is a CONSTANT, deliberately not an env var.**
A bg seat exports `CLAUDE_HANDOFF_MODEL` into every seat it dispatches, which is exactly how the Fable model default became dead code inside the fleet ([[continued-sessions-default-to-fable]]).
A constant cannot be defeated that way — so do not "helpfully" re-add an env override.

**Why bypass is safe to hand an unattended seat on this machine** (measured 2026-08-28):
no `/Library/Application Support/ClaudeCode/managed-settings.json`, no `permissions.defaultMode`, no `permissions.disableBypassPermissionsMode` — and `skipDangerousModePermissionPrompt: true` is already set in `~/.claude/settings.json`, so a bypass seat does not park on the dangerous-mode confirmation itself.
Re-check those four before assuming it holds on another box.

Peer messaging survives the resulting mode split only because `crossSessionInbound: "accept"` is set in USER settings and wins ahead of the parity check.
Without it a bypass-class successor and a prompting-class parent hold each other's messages for 5 minutes and then drop them — see [[cross-session-inbound-hold-is-mode-parity]].

**Unmeasured:** whether `bypassPermissions` clears the specific `EnterWorktree` park.
That remedy (create the worktree with `git worktree add`, forbid `EnterWorktree` in the handoff, order writes through Bash) was measured under the prompting default — keep it until someone measures the bypass case.
