---
name: lavish-axi-threading-and-collapsibles
description: "lavish-axi gotchas — thread replies via `stream --reply-to` not `poll --agent-reply`; avoid <details> collapsibles; RESTART the server to pick up fork build changes (server half only reloads on process restart, client half per request)"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 2bdfe366-d93f-422d-924d-f07135821569
---

Three operational gotchas when serving review artifacts through the user's `lavish-axi` fork (`feat/realtime-sse-threading`, npm-linked global → `$HOME/Coding/lavish-axi-fork`):

**1. Threaded replies require `stream`, not `poll`.**
`lavish-axi poll <file> --agent-reply "..."` posts a NEW TOP-LEVEL message (no `reply_to`) — it cannot thread.
To reply *inside* the thread of the message you're answering, use:
`lavish-axi stream <file> --agent-reply "..." --reply-to <message-id> --once`
The user message's `id` comes from the poll/stream feedback payload (`prompts[].id`). `--once` posts the reply, waits for the next single message, then exits (fits the background-task pattern). Default: thread every reply under the message you're answering.

**Why:** the user built the SSE + thread-panel feature herself and notices when replies land detached from their thread. See [[lavish-fork-sse-hardening]].

**2. Don't use `<details>`/`<summary>` collapsibles in lavish artifacts.**
The annotation/selection overlay in the lavish iframe swallows the click, so the native toggle never fires — the user sees a panel that won't expand. Render the content always-visible inline instead.

**3. After editing/building the fork, RESTART the server — a browser reload is not enough.**
The lavish client half (`dist/chrome-client.js`) is served fresh per request, so a tab reload picks up client changes. But the server half (`dist/cli.mjs` — session store, SSE `chat-sync`, queue-drain) is loaded into the running node process at start and only updates on **process restart**. A long-running server is therefore a STALE process: symptom seen 2026-06-25 was "my sent messages disappear from the chat" — that bug was already fixed in the build (persistent `session.chat` + `chat-sync`), but the live process predated the build. Fix = `lavish-axi stop` (or end the session) then relaunch; no rebuild/relink needed if `dist/` is current. Caveat: restarting kills any live review session, so do it between sessions.

**How to apply:** Markdown in `--agent-reply` text DOES render in the fork's chat panel — use `**bold**`, bullet lists, `code`. Keep replies formatted. See [[visualize-in-browser]].
