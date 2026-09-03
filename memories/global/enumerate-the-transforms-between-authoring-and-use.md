---
name: enumerate-the-transforms-between-authoring-and-use
description: Prevention arrives one increment late because lessons are extracted from losses; audit the MECHANISM instead — enumerate every transform between an artifact's authoring and its use.
metadata:
  type: feedback
scope: global
---

Prevention is systematically one increment late because a lesson is distilled FROM a loss.
That ordering cannot be fixed by distilling harder. It is fixed by changing what you audit:
stop waiting for instances and enumerate the MECHANISM that produces them.

The mechanism that keeps producing them here has one shape — **the artifact that ACTS is not
the artifact you AUTHORED.** Something transforms it in between: a templater, a cap, a cache,
a boot snapshot, a copy, a default-include, a symlink that decayed.

Measured 2026-09-02: **8 of 120 standing directives are independent instances of this one
class**, each learned separately from its own loss — a watcher holding its boot config; an
edit landing in a file that stopped being a link; the public mirror default-including; a
capped SessionStart injection dropping 56% of the memory index; a successor booting with a
contradicting injected system prompt; a gitignored doc store not reaching a fresh worktree;
a fleet guard being a snapshot rather than a latch; a server string a client identity-matches.
The ninth was found *without* a loss, by asking the mechanism question directly: skill `args`
are word-split and expanded into SKILL.md as shell positionals BEFORE the model reads it, so a
bare `$5` in skill prose is rewritten with the caller's 5th argument word. It was silently
corrupting the codex-converge SPEND guardrail and eleven examples in the email-drafter voice
profile. Nothing had gone visibly wrong yet.

**How to get ahead of the increment.** For any artifact you rely on being read as written, list
every transform between authoring and use, and for each ask what it can silently rewrite, drop
or stale. Then check the artifact AT THE POINT OF USE, never at the point of authorship — hash
the file the process actually runs, diff what reaches context against what is on disk, render
the template and read the output. A guard that reads the authored copy cannot see this class at
all, which is why every one of the eight read green while failing.

**And guard the guard.** A guard for this class is itself an artifact that acts, so it inherits
the class. Mine shipped two fail-opens in one session: `sys.flags.interactive is False`
(`0 is False` → never ran, exited 0, approved a broken tree), and a `(?<!\\)` lookbehind that
treated ANY preceding backslash as safe when only exactly one escapes. Both were invisible to a
green suite. Every guard needs a positive control proving it can see the thing it hunts, must
fail CLOSED on an incomplete scan, and needs a mutant that its assertions demonstrably kill.

Related: [[measure-what-reaches-context-not-disk]] · [[an-armed-watcher-holds-its-boot-config]] ·
[[a-linked-config-file-can-become-a-copy]] · [[a-token-sanitizer-cannot-see-a-topic-leak]] ·
[[absence-needs-a-probe-that-could-see-presence]] · [[extract-learnings-proactively]]
