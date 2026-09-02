<!-- Moved out of memories/global/ on 2026-09-01: this is a historical migration RECORD, not a
     memory. It has no memory frontmatter, so neither load path (the MEMORY.md index, a CLAUDE.md
     [[link]]) could ever reach it, and sync-memories.sh's warn_unindexed had been logging it as
     UNINDEXED ever since. -->

# Global memory migration manifest (pre-approval snapshot)

Date: 2026-06-27. 31 `scope: global` memories across both config dirs / 4 projects → flat `memories/global/`.
Decisions: **move** (keep as canonical), **merge→x** (fold into canonical x, leave a tombstone alias), **downgrade** (not universal → make local, strip `scope: global`).
Result: **25 canonical** global memories, **4 tombstoned** merges, **1 downgraded**, **1 deleted**.

APPROVED 2026-06-27. Amendment: `feedback-prefers-prose-clarification` → **delete** (the user confirmed she prefers multiple-choice; the memory was stale/wrong; `present-options-abc-not-star` covers option formatting). No replacement written, per her instruction.

| slug | from (configDir/project) | decision | sha10 | originSessionId |
|------|--------------------------|----------|-------|-----------------|
| background-subagent-parallel-workflow | claude/your-other-project | move | 68b2afe2b3 | 8ea80339 |
| check-memory-before-asking-user | claude/your-other-project | move | 36ba364a76 | 0e4cf0a3 |
| dev-pipeline-plan-subagent-converge | claude/your-other-project | move | c288049e7d | eaf52ee2 |
| explain-plainly-non-expert-domain | claude/your-other-project | move | 869ea47192 | 32bbc7d4 |
| extract-learnings-proactively | claude/your-other-project | move | 3e94ffb644 | 7a88ef9c |
| lavish-axi-threading-and-collapsibles | claude/your-other-project | move | f416176ba5 | 2bdfe366 |
| lavish-no-redisplay-answered-questions | claude/your-other-project | move | deb33fb400 | 55767a6f |
| mark-fixture-data | claude/your-other-project | move | f1ad52e644 | bc8819fd |
| parse-xlsx-with-claude-for-excel | claude/your-other-project | move | 0a4edad802 | 32bbc7d4 |
| present-options-abc-not-star | claude/your-other-project | move | ab0d29189d | 32bbc7d4 |
| claude1-second-profile | claude/your-project | move | 9ca5bf6f82 | a20cde08 |
| feedback-prefers-prose-clarification | claude/your-company-leads | move | c5ed10e2f5 | 172f8138 |
| feedback-privacy-business-material | claude/your-company-leads | move | e941a850f4 | 172f8138 |
| grill-defer-domain-judgment | claude/your-company-services | move | c2887bb206 | 35ccf7b1 |
| brainstorm-in-lavish | claude1/your-project | move | 79796af03c | 09853060 |
| execution-verification-prefs | claude1/your-project | move (canonical) | 64535ce910 | 8db8ef80 |
| feedback-fix-dont-just-note | claude1/your-project | move | 1247be2083 | f8b962fe |
| feedback-never-give-up-on-api-errors | claude1/your-project | move | 0d0dead169 | f8b962fe |
| feedback-spec-stated-rules-exactly | claude1/your-project | move | 91b1135dec | 147d8326 |
| global-config-repo | claude1/your-project | move | 0091f5484c | 6a537bfa |
| lavish-artifact-prefs | claude1/your-project | move | c8eab06799 | 4e85aedd |
| lavish-axi-fork | claude1/your-project | move | a9b64f74a0 | 39a21c8a |
| mockup-critiques-into-spec | claude1/your-project | move | fb49df2381 | 4e85aedd |
| notify-on-response | claude1/your-project | move (canonical) | d3d23ff22d | 4e85aedd |
| visualize-in-browser | claude1/your-project | move (canonical) | fdc42df95a | 09853060 |
| prefer-playwright-e2e-convergence | claude/your-other-project | merge→execution-verification-prefs | 33a414def5 | 76615deb |
| use-lavish-for-visualization | claude/your-other-project | merge→visualize-in-browser | 8e7ec3c891 | 699b70ec |
| visualize-means-lavish | claude/your-other-project | merge→visualize-in-browser | 8ea902d44e | 699b70ec |
| notify-only-on-convergence-or-blocked | claude/your-other-project | merge→notify-on-response | 431d212830 | 55767a6f |
| lavish-fork-sse-hardening | claude/your-other-project | downgrade (local to lavish-axi-fork work) | 344b5890d2 | 64260f39 |

## Rationale for the 5 non-trivial calls

- **merge→execution-verification-prefs:** `prefer-playwright-e2e-convergence` is the same Claude↔Codex E2E-convergence preference, re-learned in the your-other-project silo.
- **merge→visualize-in-browser:** `use-lavish-for-visualization` + `visualize-means-lavish` both say "visualize = build a lavish-axi artifact" — the same rule, twice.
- **merge→notify-on-response:** `notify-only-on-convergence-or-blocked` is a refinement of the notify preference (the long-autonomous-loop case); folded in as a nuance, not a separate memory.
- **downgrade lavish-fork-sse-hardening:** this is implementation work on a specific lavish-fork feature branch (SSE hardening, Slack thread panel) — project-specific to the lavish-axi-fork repo, not a universal preference. Stays local.
- Everything else is a straightforward universal (identity, working preference, tooling fact, or generalizable lesson) → move as-is.

Amendment 2026-07-31: demoted 2 post-migration globals to your-other-project project memory (single-project platform gotchas): fly-deploy-depot-builder-fallback, node22-worker-tsx-execargv-silent-fail. Removed the 4 tombstone aliases (all [[old-slug]] refs rewritten to canonical). De-duplicated the index: behavioral directives are indexed in CLAUDE.md ## Working directives only.
