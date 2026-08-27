# Cross-project memory generalization — design

Date: 2026-06-27
Status: Approved (pending spec review)
Scope: the global Claude config repo (`~/dotfiles/claude`, aka `claude-config`), not any single application repo.

## Problem

Learnings tagged `scope: global` are backed up across machines but not across projects.

Each global memory is physically stored at `~/dotfiles/claude/memories/<configDir>/<project>/<name>.md` and symlinked back into the originating project's `memory/` folder.
The Stop hook and the repo auto-sync make it cross-**machine**.
But the harness natively loads only the *current* project's `memory/MEMORY.md`, so a global memory authored under one project never surfaces when working in another project.

The cost of this is already visible.
There are 31 `scope: global` memories spread across both config dirs (`claude` and `claude1`) and four projects (`your-project`, `your-other-project`, `your-company-leads`, `your-company-services`), each silo invisible to the others.
Several are duplicates that were independently re-learned in separate silos because they could not see each other:

- `prefer-playwright-e2e-convergence` (your-other-project) ≈ `execution-verification-prefs` (your-project).
- `use-your-review-tool-for-visualization` + `visualize-means-your-review-tool` (your-other-project) ≈ `visualize-in-browser` (your-project).
- `notify-only-on-convergence-or-blocked` (your-other-project) ≈ `notify-on-response` (your-project).
- `extract-learnings-proactively` and `check-memory-before-asking-user` (your-other-project) are behavioral directives your-project silo has never seen.

## Goals

Make genuinely-universal learnings available in **every** project's context, including brand-new projects, with no per-project setup.
Keep project-specific facts local.
Keep the always-in-context cost small.
Tighten the discipline for deciding what is universal so the global tier does not fill with project-specific noise.

## Non-goals

No change to how per-project (untagged) memories work.
No attempt to auto-classify existing memories without human review.
No new always-on content beyond a short curated directives shortlist.

## Model: two tiers

Universal learnings split into two flavors that load differently.

**Tier 1 — behavioral directives (always-on).**
Always-relevant rules that shape every action (for example: run the verification convergence loop, fix what you flag, implement stated rules exactly).
These become a short curated section in `CLAUDE.md`, which is already a repo symlink loaded in every project, so this tier is cross-project and cross-machine for free.

**Tier 2 — universal facts (unfold on demand).**
Occasionally-relevant facts (identity, tooling paths, platform facts).
These load everywhere as a one-line pointer index and unfold to full text only when relevant.

## Architecture

### Storage

Add a project- and config-dir-independent store beside the existing per-config-dir folders:

```
~/dotfiles/claude/memories/
├── claude1/<project>/…   ← existing per-project memories (unchanged)
├── claude/<project>/…    ← existing per-project memories (unchanged)
└── global/               ← NEW: universal facts tier
    ├── MEMORY.md         ← the global index (pointer lines only)
    └── <name>.md         ← global memory bodies
```

It sits beside the config-dir folders because universal facts are tied to neither a config dir nor a project.
It rides the existing repo auto-sync (`sync.sh` plus the launchd/systemd watcher), so a file is cross-machine the moment it lands there.

### Loading (Tier 2)

Add a synchronous `SessionStart` hook, `inject-global-memory.sh`.
It reads `memories/global/MEMORY.md` and emits it as `additionalContext` in every session, regardless of project.
It resolves the repo root portably across all three supported platforms — macOS (`~/dotfiles/claude`), Linux (`~/claude-config`), and Windows (the `sync.ps1` checkout location) — matching `sync.sh` / `sync.ps1`.
A `.sh` hook plus a `.ps1` (or cross-platform `node`) variant are provided so the hook runs in each platform's shell.
The injected block is clearly headed, for example "Global memory (cross-project) — bodies at `~/dotfiles/claude/memories/global/<name>.md`, unfold with Read", so a relevant-looking pointer can be opened by absolute path in any project.
If the file is missing or empty, it emits nothing.
It must be synchronous (not `async` like `sync.sh`) so its stdout is captured as context.

Output format requirements (per the Claude Code hooks docs at https://code.claude.com/docs/en/hooks).
The hook emits **plain raw stdout** and exits `0`; for a context-only `SessionStart` hook, plain stdout is added to context directly, so no JSON envelope is used.
It must not emit JSON, because a JSON envelope requires stdout to contain *only* the JSON object (structured fields like `hookSpecificOutput.additionalContext`); mixing the Markdown header with JSON would either be parsed as raw text or fail JSON parsing.
Hook output is capped at 10,000 characters; beyond that the harness replaces it with a preview plus a file path.
The index is pointers-only, so it stays well under the cap, but the hook guards this explicitly: if the rendered index exceeds a safe budget (for example 8,000 characters) it truncates and appends a single line pointing at `memories/global/MEMORY.md` to read in full.

Precedence between tiers.
The injected global block is **default behavior**; a project-local memory (the native per-project `MEMORY.md` block) **overrides** global guidance whenever it speaks to a project-specific constraint.
The injected block states this precedence in its header so a project-local override is honored over a global default rather than read as a contradiction.

### Loading (Tier 1)

A curated "Working directives" subsection in `CLAUDE.md`.
Each line is one imperative plus a pointer to the global memory holding the why/how, for example:

- Run the Playwright-grounded Claude↔Codex convergence loop on every review until clean → `[[execution-verification-prefs]]`.
- Fix what you flag, even out of scope → `[[feedback-fix-dont-just-note]]`.
- On any API or tool error, route around it — never abandon → `[[feedback-never-give-up-on-api-errors]]`.
- Implement stated numeric, layout, and timing rules exactly; unit-test them; verify the cited example → `[[feedback-spec-stated-rules-exactly]]`.
- Fold every mockup or brainstorm critique into the spec and plan → `[[mockup-critiques-into-spec]]`.

The imperative one-liner lives in `CLAUDE.md` so it is always-on and cannot be missed.
The full why/how stays in the Tier 2 global memory body and unfolds on demand.
No detail is duplicated, so `CLAUDE.md` stays lean.
This section stays a deliberately short shortlist even as the facts tier grows.

### Data flow when a universal learning is captured

Write the body to `memories/global/<name>.md`.
Add one pointer line to `memories/global/MEMORY.md`.
If it is a behavioral directive, also add a one-line imperative to the `CLAUDE.md` directives section.
The watcher auto-commits and syncs.
The next session in any project injects the updated index, so the learning is cross-project and cross-machine with no per-project files touched.

### Interaction with the existing memory-sync Stop hook

This is the load-bearing integration the rest of the design depends on.
Today `sync-memories.sh` (a `Stop` hook) scans each project's `memory/` dir and, for any file tagged `scope: global`, **moves it to `memories/<configDir>/<project>/<file>` and symlinks it back into that one project**.
That is precisely the silo this design eliminates, so if the natural authoring path (write a memory, tag it `scope: global`) keeps flowing through the old hook, every new global memory is re-siloed and the `memories/global/` store is bypassed.

The hook must therefore be updated so that `scope: global` memories route to the **flat** `memories/global/<file>` store instead of the per-config-dir/per-project path, and are **not** symlinked back into the originating project — global memories surface via the injection hook, not through any single project's `memory/` dir, and symlinking one back would both re-localize it and double-load it against the injected block.
After the move, the local original is removed (no symlink left behind).
This applies to **both** branches of the current hook: the move branch (new destination) and the `cmp -s` identical-destination branch — the latter today relinks the local file, but under the new model it must simply remove the local file (no symlink), since the global body already lives in the store.

Index ownership stays manual, matching the per-project convention: the author writes the `memories/global/MEMORY.md` pointer line directly (per the data-flow above).
If the hook moves a straggler that was tagged in a project dir but has no global index entry yet, it logs that gap so it is visible rather than silently un-indexed; it does not silently rewrite the index.

Slug collisions: `memories/global/` is a single flat namespace, so two projects can no longer rely on path separation to disambiguate same-named memories.
The hook keeps its existing conflict guard — if a differently-contented file already occupies the destination slug, it logs `CONFLICT` and skips rather than overwriting.
Global slugs must therefore be globally-unique, descriptive names; the migration's dedup step resolves the current collisions up front.

The fresh-machine restore in `install.sh` must also be updated.
Its current loop restores every `memories/**/*.md` assuming the shape `memories/<configDir>/<project>/<file>`, so once `memories/global/` exists it would misread `global` as a config dir and create bogus links under `~/.global/projects/...`.
The restore loop must skip `memories/global/**` entirely — the global store is read by the injection hook directly from the repo checkout, so it is never symlinked or copied into a `~/.<configDir>` location — and continue restoring only the legacy silo paths (until those are retired).

## Discipline: the promotion test

Rewrite the `## Memory` rules in `CLAUDE.md` from a category list into a concrete test plus routing.

**Test.**
"Would this help me in an unrelated project next week, independent of any single repo?"
If yes, it is universal.
Project-technical facts stay local even when the underlying pattern is interesting — file the generalization, not the instance.
For example, your-project's exact count-grid rules stay local, while "treat stated numeric rules as exact invariants and test them" is the global lesson.

**Routing once universal.**
A behavioral directive is written to `memories/global/` and also gets a one-line imperative in the `CLAUDE.md` directives section.
A pure fact is written to `memories/global/` with an index line only.

**Storage-location update.**
Global memories now go to `memories/global/`, not `memories/<configDir>/<project>/`.

## Migration: guided consolidation

Migration is a guided consolidation, not a blind move, because of dedup judgment calls and because some `scope: global` tags are over-broad (for example `your-review-tool-fork-sse-hardening` is arguably tool-internal rather than universal).

1. Collect all `scope: global` bodies across both config dirs and all projects.
2. Re-apply the promotion test to each; downgrade mis-tagged ones back to local; keep genuine universals.
3. Dedup and merge near-duplicates into one canonical memory, keeping the richer body, unioning the why/how, and preserving each source `originSessionId` in a note.
4. Move survivors to `memories/global/` via `git mv`, build `global/MEMORY.md`, and distill the behavioral ones into the `CLAUDE.md` directives section.
5. Remove the per-project copies and symlinks plus their `MEMORY.md` pointer lines so nothing double-loads.

**Downgrade-to-local is a distinct, order-sensitive operation.**
An existing `scope: global` memory being downgraded to local is currently a symlink whose target is the tracked repo copy, so naively deleting the repo target would strand or destroy the memory.
The safe order is: replace the project-dir symlink with a real local file copy, strip the `scope: global` line from that local copy, re-add its pointer to the per-project `MEMORY.md`, and only then remove/untrack the repo-side silo (or `global/`) copy.

**Manifest before any deletion.**
Step 5 removes live symlinks and edits per-project `MEMORY.md` files, and those per-project `MEMORY.md` files live outside the repo (only the `scope: global` bodies are tracked in `memories/`), so deletion there is not `git`-reversible.
Before deleting anything, write a migration manifest with one row per memory: source path, destination path, the original `MEMORY.md` pointer line, the origin session IDs, a content checksum, and the decision (move / merge-into / downgrade-to-local).
The manifest is committed, so the pre-migration state is fully reconstructable even for the out-of-repo edits.

**Tombstones for renamed slugs.**
When a merge or move changes a memory's slug, leave a tombstone alias (a short stub memory, or an alias entry in `global/MEMORY.md`) mapping the old slug to the new one, so existing `[[old-slug]]` links in transcripts, specs, and other memories do not silently break.

**Safety.**
Ship the mechanism (store, hook, `CLAUDE.md` rules) first.
Then present the proposed merged and deduped global set for approval before deleting anything from the silos.
Every in-repo move is a `git mv`, and the manifest plus tombstones cover the out-of-repo edits, so the whole migration is reversible.

## Testing and verification

**Injection hook unit test.**
Given a temp `global/MEMORY.md`, assert the injected block.
Given a missing or empty file, assert no output.
Assert the repo root resolves on both macOS and Linux paths.

**Sync-hook routing unit test.**
Given a `scope: global` memory placed in a project `memory/` dir, assert `sync-memories.sh` moves it to `memories/global/<file>`, leaves no symlink in the project, and does not write it under `memories/<configDir>/<project>/`.
Given a destination slug already occupied by differing content, assert it logs `CONFLICT` and skips rather than overwriting.

**End-to-end (the real proof).**
Start a session in a different project (for example `your-company-leads`) and confirm the global index appears and a body unfolds.
Confirm a brand-new project with no `memory/` dir still gets the global index.
Run the check under **both** config dirs (`~/.claude` and `~/.claude1`), not just one, since they are independent settings entry points.
Exercise the `SessionStart` `source` variants — `startup`, `resume`, `clear`, and `compact` — because the hook fires for all of them and must inject consistently.
Add a fixture that breaks the settings symlink assumption (a real `settings.json` under one config dir that lacks the hook) and confirm the installer preflight detects the divergence and fails loudly rather than silently covering only one config dir.
On Windows (or a copy-mode fixture), confirm the **hook script and `settings.windows.json` entry** are present in the live `~/.claude` copy after the install/re-copy step, and that the copied hook resolves the repo checkout and injects `memories/global/MEMORY.md` from there — the store is read from the repo, not from a `~/.claude` copy.

**Migration check.**
Count universals before and after to confirm none are lost.
Confirm no double-listing.
Confirm each merge is captured.

## Edge cases and risks

Config-dir coverage must be proven, not assumed.
Today `~/.claude1/settings.json` symlinks to `~/.claude/settings.json`, which symlinks to the repo `settings.json`, so one edit covers both config dirs — but that is a symlink chain, not an invariant.
If either config dir's `settings.json` is ever a real file, or the Linux setup does not mirror the convention, one install silently covers only one config dir.
The installer therefore runs a preflight that resolves the active `settings.json` for each config dir it finds (`~/.claude`, `~/.claude1`), installs the hook into each distinct resolved target, and fails loudly if any active config lacks the hook; also add the hook to `settings.linux.json` and `settings.windows.json`.

Windows uses copies, not symlinks.
Per the repo README, on Windows the tracked config files are copied into `~/.claude` rather than symlinked, so edits do not flow back and a `git pull` does not update the live copies.
This caveat applies to the **hook script** (it must exist where `settings.windows.json` invokes it) and to the `settings.windows.json` entry — both must be re-copied into the live config after pulling (or Developer Mode + symlinks enabled).
The `memories/global/` store itself is **not** subject to the copy caveat: the hook resolves the repo checkout and reads `<repo>/memories/global/MEMORY.md` directly on every platform, so the store is always read from the synced repo, never from a `~/.claude` copy.
The migration is authored on macOS/Linux against the repo; Windows machines pick up the store immediately on `git pull`, and the hook/settings on their next re-copy/install.
The global index stays pointers-only and capped; after dedup it is roughly 20 lines.
Migration is sequenced so nothing appears twice once per-project copies are removed.
During the transition, before per-project copies are removed, a memory could appear in both the native per-project block and the injected global block; step 5 of migration resolves this.

## Rollout sequence

1. Create `memories/global/` with an empty `MEMORY.md`.
2. Update `sync-memories.sh` to route `scope: global` memories to the flat `memories/global/<file>` store without symlinking back (both the move and identical-`cmp` branches), keeping the existing conflict guard; and update the `install.sh` restore loop to skip `memories/global/**`. Unit-test both.
3. Add `inject-global-memory` (plain stdout, 10k-cap guard) as a `.sh` and a `.ps1`/`node` variant, and install it via the config-dir preflight into every active `settings.json` plus `settings.linux.json` and `settings.windows.json`; unit-test it.
4. Update the `CLAUDE.md` `## Memory` rules and add the "Working directives" subsection.
5. Run the guided consolidation migration: build and commit the manifest, get approval, write tombstones, then delete per-project copies.
6. End-to-end verify under both config dirs, across `SessionStart` source variants, in a second project and in a fresh project, including authoring a fresh `scope: global` memory and confirming it lands in `memories/global/` (not a silo) and injects everywhere.
