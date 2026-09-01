---
name: chrome-devtools-axi-mcp-version-skew
description: "chrome-devtools-axi breaks with \"Required at pageId\" on every page-scoped command when its pinned MCP contract lags the npx-fetched chrome-devtools-mcp@latest; fix is `npm install -g chrome-devtools-axi@latest`, not abandoning the tool"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 8c87fc12-e6a0-4f81-8aaf-6bedd893bb63
  modified: 2026-08-30T20:45:34.040Z
---

`chrome-devtools-axi` fails **every page-scoped command** — `snapshot`, `screenshot`, `eval` — with an identical error:

```
MCP error -32602: Input validation error: Invalid arguments for tool take_snapshot: Required at pageId
```

`open`/`newpage`/`pages`/`resize` still work, so the browser looks healthy and only the commands that read the page are dead.
`screenshot` is the nastiest: it **prints the destination path and exits 0 while writing no file**, so a caller that trusts stdout reports a screenshot it does not have — always `ls` the file.

**Cause is version skew, not a broken tool.** When `chrome-devtools-mcp` is not installed globally the bridge spawns `npx -y chrome-devtools-mcp@latest`, so the MCP side floats to the newest release while the installed axi stays pinned to whatever contract it shipped against. `chrome-devtools-mcp` 1.x added multi-page support and made `pageId` **required** on page-scoped tools; an older axi never sends it. Measured 2026-08-30: axi 0.1.24 against chrome-devtools-mcp 1.8.0 — every page-scoped call failed.

**Fix:**

```bash
npm install -g chrome-devtools-axi@latest   # 0.1.24 -> 0.1.33 restored snapshot + screenshot
```

Diagnose it by comparing `chrome-devtools-axi -v` against `npm view chrome-devtools-axi version` **before** concluding the tool is unusable — a floating `@latest` dependency means this recurs whenever `chrome-devtools-mcp` makes a breaking change, so re-check the version pair rather than re-deriving the diagnosis.

Route-around while blocked: any repo with Playwright installed can screenshot directly (`chromium.launch()`), but the script must live **inside** the package dir that owns `node_modules` or ESM resolution fails — see [[read-the-tool-error-before-routing-around]] (the error names the missing argument, which is what identifies this as skew rather than a dead tool) and [[verify-claims-against-artifacts]] (the `screenshot` path-without-file is exactly the status-line-vs-artifact trap).
