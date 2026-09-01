# Trimming a project's local memory index

Project memory indexes (`~/.claude/projects/<project>/memory/MEMORY.md`) load into every session of that project, and grow as sessions append entries.
The CLAUDE.md memory-hygiene rule keeps new writes distilled; this prompt cleans up an index that has already grown.
Paste it into a Claude Code session **in the project whose memory needs trimming** (reference run: your-other-project, 16.4 KB → 10.6 KB, 2026-07-31 — per-session lesson hooks deliberately kept).

```text
Trim this project's Claude memory index (~/.claude/projects/<this-project>/memory/MEMORY.md) without losing information.

1. Measure first: report the index's size and entry count. If it's under ~4 KB, report "no trim needed" and stop.
2. Preserve everything before editing: copy the current MEMORY.md verbatim to memory/index-archive-<today>.md with a header saying what it is. Never delete or edit body files.
3. Rewrite the index:
   - One line per entry; the hook is the single thing a future session must know, not a paragraph.
   - Pull standing ACTION ITEMS and live state (pending decisions, unmerged PRs, watch items, deadlines) into a section at the top — these must never be buried or dropped.
   - Consolidate environment/tool facts (paths, ports, CLI quirks, credentials locations) into a few grouped lines.
   - Sessions older than ~3 weeks whose work shipped: drop their index lines (the body files and the archive keep everything); where several same-day sessions exist, one digest line pointing at the archive is enough.
   - End with one Archive line pointing at the archive file.
4. Verify against artifacts: every kept link resolves to an existing file; re-read the new index for any live state or unresolved action you dropped; report before/after sizes.
```

Going forward the write-time rule in CLAUDE.md (## Memory: "Keep memories distilled") should prevent regrowth; re-run this only if an index creeps past ~8 KB again.
