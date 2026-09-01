---
name: parse-xlsx-with-claude-for-excel
description: "Use the Claude for Excel add-in to parse .xlsx files (e.g. Jordan's your-data-product schedule), not stdlib XML parsing"
metadata: 
  node_type: memory
  type: feedback
  scope: global
  originSessionId: 32bbc7d4-ba8d-4d7b-aaa4-f9a73c50c636
---

When parsing the user's `.xlsx` files — e.g. `resources/jordan/2_your-data-product_agent_schedule.xlsx` — use the **Claude for Excel add-in** rather than a stdlib `zipfile`/XML fallback parser.

**Why:** `openpyxl` and `xlsx2csv` aren't installed in this environment, so the fallback this session was raw `zipfile` + `xml.etree` parsing. That loses multi-sheet structure, merged cells, and formula-derived/formatted values. Jordan's schedule alone has 8+ sheets (Control Panel, Universal Modules, Build Schedule, Daily Runbook, Evaluation Model, Decision Trees, Outreach Deal Desk, Reference Sources).

**How to apply:** reach for the Claude for Excel add-in first for any spreadsheet analysis. See [[phase3-polish-execution-ready]] for the broader Alex/Jordan-feedback context this came up in.
