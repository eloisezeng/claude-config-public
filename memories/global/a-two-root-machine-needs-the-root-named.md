---
name: a-two-root-machine-needs-the-root-named
description: This machine has two Claude config roots, each with its own agents page and job store — any destructive sweep must name WHICH root before it runs
metadata:
  type: feedback
---

`claude` runs on `~/.claude` and `claude1` on `~/.claude1` ([[claude1-second-profile]]). Each root has its OWN agents page, its own `jobs/` store and its own `projects/` transcripts, so "the completed sessions" names two different sets and the phrase never says which. The user asked for a sweep meaning `~/.claude1`; a delete list built by iterating both roots took 14 extra sessions out of `~/.claude`, and only luck made that harmless.

**Why:** a scope question is invisible when one of the two answers is the one you are standing in — the session's own root feels like "the" root, so the ambiguity never surfaces as a question. `claude rm` reinforces the illusion: it resolves ids against the CURRENT root only, answering `No job matching` for the other root's jobs, which reads like "already gone" rather than "wrong root".

**How to apply:** for any destructive or bulk operation on jobs, sessions, transcripts or worktrees, first MEASURE how many roots exist (`ls -d ~/.claude*/jobs`) — dotfiles travel between machines and a machine without `~/.claude1` has one agents page, so the question is moot there (measured 2026-09-10 on a Mac sharing these dotfiles: no `~/.claude1` directory and no `claude1` function in `~/.zshrc`); where two exist, ask WHICH ROOT in the first round of questions, never infer it from cwd; scope the enumeration to that root alone; and when a per-item command reports `No job matching`, treat it as a ROOT mismatch to confirm rather than a no-op to skip. Cross-root work needs `CLAUDE_CONFIG_DIR` set explicitly per call. Related: [[verify-claims-against-artifacts]], [[act-on-fresh-state-anchor-by-identity]].
