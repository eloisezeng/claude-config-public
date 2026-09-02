---
name: builtin-local-notifications-are-terminal-escapes-only
description: Claude Code's built-in LOCAL notification channel emits only a terminal escape sequence, never an OS banner, and resolves to nothing outside Apple Terminal / iTerm2 / kitty / ghostty — so an osascript notification hook is a different surface, not a duplicate
metadata:
  node_type: memory
  type: reference
  scope: global
---

Measured by reading the 2.1.258 binary on 2026-09-01, after being asked whether the custom notification hooks in `claude-config` duplicated the product's own and could be deleted.
They do not.
Re-measure against the then-current binary before acting on this, but do not assume the built-in covers a desktop banner — as of 2.1.258 it never has.

**`preferredNotifChannel` is the only built-in LOCAL channel, and every one of its values emits a TERMINAL ESCAPE SEQUENCE.**
`iterm2` → OSC 9, `terminal_bell` → `\a`, `kitty` → OSC 99, `ghostty` → OSC 777, `iterm2_with_bell` → both, `notifications_disabled` → nothing.
Whether any of those becomes a visible toast is the *terminal's* decision, not Claude Code's.

**Its default `auto` resolves by terminal and falls through to silence.**
Apple_Terminal → `terminal_bell`, and only after shelling out to `defaults export com.apple.Terminal` to confirm the current profile's `Bell` is enabled; iTerm.app → `iterm2`; kitty → `kitty`; ghostty → `ghostty`; **everything else → `no_method_available`, which delivers nothing at all.**
VS Code's integrated terminal is in that last bucket, and VS Code raises no OS toast from a bell either — so on a VS Code setup the built-in local surface is empty.

**The binary contains no `display notification` for these events.** Its single osascript banner is the re-authentication prompt.

**`inputNeededNotifEnabled` / `agentPushNotifEnabled` are MOBILE push over Remote Control** — a different device, not the local machine. Reading them as "the built-in version of my local chime" is the mistake that makes the hook look redundant.

**Consequence.** A `Notification`-hook script that rings `osascript display notification` is a *different surface* from the built-in channel, not a second implementation of it. The two double up only on a terminal that raises its own OS toast from the escape sequence (iTerm2, kitty, ghostty); there, pick one surface rather than deleting the hook. Anywhere else, deleting the hook removes local notification entirely — along with anything the hook does that the product has no equivalent for, such as muting the ~60 s `idle_prompt` chime while background agents are still running.

Related: [[notify-on-response]] (when a notification is justified at all), [[a-mention-is-not-a-property]] (a setting that *names* notifications is not a notification that fires).
