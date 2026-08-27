---
name: dry-run-bounds-writes-not-resources
description: "A '--dry-run' promises it will not WRITE; it promises nothing about memory, CPU or locks — read the query before running any enumeration against a live box, and bound it in the engine"
metadata:
  node_type: memory
  type: feedback
  scope: global
---

`--dry-run`, `--plan`, `--check` and "it only prints what it would do" are claims about **mutation**. They say nothing about **resource cost**, and a read-only step can take production down as hard as a bad write: an unbounded `SELECT` materialised into a list, a full-table scan holding a lock, a fan-out of API calls.

**Before running ANY enumeration or sweep against a live system — including one a runbook (even your own) says is a safe dry run:**
1. **Read the query/loop it actually runs.** Not the flag, not the doc — the code.
2. **Ask what it materialises**, and bound it by the engine, never in the language: the filter belongs in the `WHERE`/index/`LIMIT`, not in a `.filter()` after `.all()`. "Load everything, keep the few" is an OOM with a delay fuse.
3. **Count first, in a separate cheap query** (`SELECT count(*) … WHERE <the real filter>`). If the count is not the order of magnitude you expected, stop — your filter is wrong or your mental model is.
4. **Prefer running it somewhere the blast radius is yours** (a local copy, a replica) when the box also serves users.

Where a shared machine hosts more than one service, name the collateral before you run: on a single-box deploy the "internal tool" and every public page share one process and one heap.

**Why (2026-08-18, your_other_project):** a runbook I had written myself documented `da-affiliate-enroll --all-eligible` (no `--apply`) as a safe dry run that "prints the exact list". Its selector had **no status filter in SQL at all** — it `.all()`'d every unenrolled row and filtered in JS. On the live 2 GB box that materialised **5,573,849 rows to select 42**, OOM'd the machine, and took down the dashboard *and* all five published customer-facing sites for ~15 minutes. The flag was honest about writes and silent about the thing that mattered.

**How to apply:** treat "is this dry run resource-safe?" as a separate question from "is this dry run write-safe", and answer it out loud before executing. When you write a runbook, state each step's resource cost next to its safety claim — an unqualified "dry run: safe" in a runbook is the bug that gets executed later by someone with less context, including you. Pin the fix with `[[scale-test-large-data-paths]]`; the selector's bound is code, so it gets a resource-constrained test, not a comment.
