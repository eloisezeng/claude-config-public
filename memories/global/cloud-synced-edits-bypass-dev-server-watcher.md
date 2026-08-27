---
name: cloud-synced-edits-bypass-dev-server-watcher
description: "In a cloud-synced folder (OneDrive/Dropbox/iCloud), a dev server's file watcher misses edits that arrive via sync rather than a local write — the served bundle goes stale and reads as a code regression"
metadata:
  node_type: memory
  type: reference
  scope: global
---

When a project lives inside a cloud-synced folder on Windows or macOS, a dev server's file watcher does not reliably fire for changes that arrive **through the sync client** rather than through a local editor write.
The server keeps serving the previously compiled bundle, so a feature looks broken or reverted in the browser while the source on disk is completely correct.
Confirmed on Next.js 16 + Turbopack under OneDrive, where `app/globals.css` edits never reached the served CSS chunk.

The distinction that matters: a **live local write** (an editor/agent writing the file while the server runs) hot-reloads correctly — verified sub-second.
The failure is specific to changes that landed some other way: synced down from another machine, or made while the server was stopped.

**How to diagnose without a browser.**
Fetch the page, extract the asset URL from the HTML, fetch that asset, and grep the *served bytes* for the rule or symbol you expect.
Note that Turbopack serves global CSS from `/_next/static/chunks/[root-of-the-server]__*.css`, not `/_next/static/css/...`.
If the change is present in the source file but absent from the served asset, the bundle is stale — it is not a code bug.

**How to apply.**
Restart the dev server to force a recompile from current source; clearing the build cache is not required.
Then hard-refresh the browser.
After a *live* edit, don't restart reflexively — verify the served asset first and only restart if it really didn't update.
