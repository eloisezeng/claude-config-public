---
name: todo19-round
description: "TO-DO-19 — 11-item player/lyrics/sections/upload/settings round; branch todo19, PR #8 (open, not merged)"
metadata:
  type: project
---

TO-DO-19: 11 items shipped on branch `todo19` → **PR #8** (https://github.com/your-org/your-project/pull/8), open as of 2026-06-27, not yet merged. Branched from `main` at f908e40 (TO-DO-18). `main` was pushed to origin first (was 45 commits behind) so the PR diff is clean (~25 commits, 38 files).

Built via the full spec → Codex↔Claude convergence → plan → Codex↔Claude convergence → subagent-driven execution (TDD, per-task implementer+reviewer) → Claude(opus)+Codex whole-branch review pipeline. Codex's independent final review caught a real HIGH the Claude reviewers missed (see below). Verified: web 383 + analyzer 223 unit + 34 Playwright E2E green; tsc clean.

Key fixes worth remembering:
- **#3 no-lyrics** (RAYE "WHERE IS MY HUSBAND!", `rK5TyISxZ_M`): ASR `align_offset` rejected 123 correct LRCLIB lines on a chorus-heavy song because scattered ASR deltas gave only ~25% inliers. Fix: `inlier_frac` 0.30→0.20 in `lyric_align.py`, BUT that alone let a small clustered match falsely align edited songs, so also added an **inlier span-coverage gate** (inliers must span ≥35% of the LRC timeline). `min_inliers=6` stays the absolute floor. Live-verified.
- **#4 / #5 / count-in**: a native `pause` echo re-dispatching `togglePlay` is the recurring trap — guarded via `intentionalPauseRef` (set true before an intentional `handle.pause()`, one-shot-cleared in onPause/onEnded). NEVER fix loop/segment-end button state by adding a second `togglePlay` (double-toggle). The synthetic count-in branch in `runCountInPreroll` was the HIGH Codex caught — it paused a playing video without the guard. Shared `loopWrap(targetSec)` pre-rolls count-in on both single-segment and range loops; pass the seek target so the async YouTube gate can't misfire on a stale `getCurrentTime()`.
- **#9 section range edit**: stored as TIME ANCHORS (not segment indices — those renumber across rephase), keyed by the stable line-span `sectionKey`, mapped to nearest current boundaries on load.
- **#10 lyric anchors**: pure `adjustLines(lines, globalOffset, anchors)` in lyrics.ts; persisted in PlayerState; STATE_SCHEMA 2→3 — and the pre-existing beatDensity migration had to be re-pinned to `< 2` (was `< STATE_SCHEMA`) so the bump didn't re-run and corrupt v2 state. Recurring lesson: each migration must fence on its own hardcoded version, never the live STATE_SCHEMA.

Pairs with [[count-display-invariants]], [[codex-exec-hang-watchdog]], [[execution-verification-prefs]].
