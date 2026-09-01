---
name: notify-on-response
description: Notify the user ONLY when she has an action to take — never for progress, wait-states, or completed work that needs nothing from her
metadata:
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 4e85aedd-72b3-4e58-86b9-ac16d336fd49
---

**The rule (her canonical phrasing):** "only notify me when there's some action i can take."
A ping is justified only by: a decision she must make, a deliverable she must act on to proceed (approve, review, test, enter a credential), or a blocker only she can clear.
Progress notes, wait-states, and COMPLETED work needing nothing from her are silence — "done, no action needed" means the consolidated summary goes in the transcript only, zero push.

**Timeliness (correction 2026-08-10, MFFP: "if the pieces were on file earlier, alert me sooner via email notification"):** an actionable item fires its alert the moment it becomes DECIDABLE — when the evidence/options are on file — not when the orchestrator next writes a summary or when a related decision surfaces it. Two open decisions touching the same object are presented together, in dependency order, as soon as the second lands.
**Why:** the panel-composition option sat on a card at batch-2 close but reached her only days later, buried inside a different decision's explainer — she had been deciding the narrower question without the piece that could moot it.
**How to apply:** at every batch/round close, sweep the new artifacts for operator-decision material and alert on what's decidable. In autonomous/headless operation (cluster sessions, remote loops) the alert channel is EMAIL — `mail -s "<short subject>" you@example.com` (transport verified on the your-university cluster) with a few plain-language lines: the decision, the options, where the full document lives, what is blocked on her answer. PushNotification stays the channel for interactive local sessions.

**Parallel work is an action-item class (correction 2026-08-17, "next time notify me if there are things i can do in parallel"):** whenever a long run starts, and in any consolidated summary that is not the end of the whole request, sweep for what the user could progress SIMULTANEOUSLY and surface it unprompted. Two buckets: the only-she-can-do items (credentials, vendor sign-ups/manual account steps, spend approvals, top-ups, sending a prepared file, approving a queued card) and the independent specs/branches a fresh session could start now. Her having to ask "anything I can do in parallel?" IS the miss.
**Why:** her time is the scarce resource across a run, and an item only she can clear — an exhausted credit balance, a vendor site-list step — blocks the agent's own next stage while sitting invisible in a backlog.
**How to apply:** a short "parallel now" block, one line per item, only-you items first (each with why it is hers and what it unblocks), then the startable specs, then any merge/deploy-freeze constraint governing whether those sessions may merge and which worktree to use. Ordinary silence rule still holds — no ping when the list is empty, and this block rides an existing message rather than generating its own.

**Mechanics (distilled from ten corrections, 2026-07-12 → 07-15):**

- The harness surfaces turn-ends AND interim prose. Mid-loop the bar is zero assistant text: tool calls only, from the moment work starts until the single terminal summary. Narration is itself a notification.
- "Finalized" = the terminal deliverable of the WHOLE request (deployed + live-verified, or PR ready if that's the ship target) — never an intermediate milestone (spec converged, round done, PR opened, merge done).
- Never background-and-yield to wait. Foreground-block long steps and CHAIN them in one turn: blocking `codex exec` / `gh run watch` / full test suites, and `until <condition>; do sleep 5; done` under the per-call timeout cap, repeated as needed. Ten sequential 10-minute foreground calls are ONE turn. `run_in_background` is only for genuine overlap, and a resumed turn continues silently — no status text.
- A user message arriving mid-loop: answer it briefly, then continue the loop foreground-chained in the SAME turn.
- When a response IS actionable: call the PushNotification tool with one short line (local toast fires regardless; mobile push needs Remote Control). If the notification text could truthfully end with "no action needed", do not send it.

**Channel state (corrected 2026-07-31 after the user's report: "the bell rings when background agents finish, not when the overall turn has ended"):**

- The background-finish bell was the Notification-event hook: it had NO matcher, so it rang for EVERY notification type — including `agent_completed` when a background agent finishes while the session sits idle — with the misleading "Claude needs your input" text. Fixed 2026-07-31 (suppress completion/noise types: `agent_completed`, `task_completed`, `auth_success`, `elicitation_complete/response`) and refined 2026-08-05 after "u chime even when background agents are still running": the remaining false bell was `idle_prompt`, which fires ~60s after EVERY turn end — including yields with background tasks still running (349 of 437 stops). Now `~/dotfiles/claude/hooks/stop-event.sh` records each session's running background-task count (shell + subagent) to `~/.claude/session-state/<sid>.bg` — only Stop payloads carry `background_tasks` — and `hooks/notification-event.sh` mutes `idle_prompt` while that count is > 0, logging a `NotificationSuppressed` line. Everything fails OPEN — unknown types, permission prompts, and missing/corrupt state still ring, so a wrong guess can't silently kill real alerts.
- Every Notification event is appended to `~/.claude/hook-events.log` (timestamp + raw payload). If a spurious bell recurs, read the log and tighten the filter against the OBSERVED payload — never against guessed strings.
- Mid-turn background completions emit NO user-facing event (probe-verified 2026-07-31; the harness injects transcript text for the model instead). The bell scenario is idle-session completions only.
- Stop-hook "Response ready" bell, per machine (revised 2026-08-14, "notify me in vscode when there are no background agents running and u need me to prompt u"): on the **Mac** it stays gated on `~/.claude/.enable-response-ready-notif` (absent → OFF; don't create the flag). On the **your-university HPC** (`~/.claude/hooks/notify.sh`) the turn-end bell is ON but rings ONLY when the Stop payload shows zero running `background_tasks` — bell = "your turn to prompt"; same fail-open state file (`~/.claude/session-state/<sid>.bg`) mutes the later idle_prompt while agents run, and the Mac's noise-type filter is ported. Decisions are logged as `bell event=… ring=…` lines in `~/.claude/state/notify.log`.
- Getting the HPC bell to the user's LOCAL machine: VS Code Remote-SSH forwards BEL but swallows OSC 9/777 (verified), so audibility requires her LOCAL VS Code user settings (she connects from a local **Windows** machine; the keys are identical on any OS): `"terminal.integrated.enableVisualBell": true` and `"accessibility.signals.terminalBell": {"sound": "on"}`. VS Code never raises an OS toast from a bell — walk-away coverage is the dormant email channel (`export CLAUDE_NOTIFY_EMAIL=…`).
- `agentPushNotifEnabled: false` disables only the harness's AUTOMATIC pushes; the model-invoked PushNotification tool still delivers (local toast always, mobile via Remote Control).
- These toggles are the user's. Never flip one to paper over a wait-state turn-end — cure that by foreground-chaining (see above), the sin every one of the ten corrections traced back to.
