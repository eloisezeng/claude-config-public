# get-shit-done (gsd) removed — 2026-09-09

Removed at the user's instruction while auditing what in `~/.claude` was never
backed by this repo. It was **dormant**: nothing in `settings.json` invoked any
of it, and the install was pristine — 0 of its 282 files had been modified since
it was installed, so no work of hers lived inside it.

## What was deleted (~277 MB, 10 locations)

| Path | Size / count |
| --- | --- |
| `~/.claude/get-shit-done/` | 3.4 MB, 282 files, v1.42.3 |
| `~/.claude/skills-archive/` | 68 skills, 280 KB — verified 100% `gsd-*` |
| `~/.claude/agents-archive/` | 33 agents, 640 KB — verified 100% `gsd-*` |
| `~/.claude/hooks/gsd-*.{js,sh}` | 12 files |
| `~/.claude/gsd-file-manifest.json` | |
| `~/.claude/gsd-install-state.json` | |
| `~/.claude/gsd-migration-journal/` | 4 KB |
| `~/.claude/.gsd-profile` | one word: `full` |
| `~/.agents/skills/gsd-*/` | 67 skills, 280 KB — the Codex CLI's own skill dir |
| `~/.npm/_npx/9785a834b31d581d/` | 273 MB — the `get-shit-done-cc` installer package |

### The first pass missed two locations, and the miss had a measured cost

The table's first eight rows are all under `~/.claude`, because that is where the
audit looked. `~/.claude` is not the footprint: the Codex CLI auto-discovers
`~/.agents/skills`, and 67 `gsd-*` skills sat there untouched by the first pass.

That was not latent. Open ops lane `2026-09-02-gsd-code-review-skill-broken-path`
measured the cost on 2026-09-02: `gsd-code-review/SKILL.md:34` points at
`$HOME/.Codex/...` (capital C), a path that has never existed here, so the skill
matched every code-review prompt, failed to read its own workflow, and sent two
of three review lenses hunting. One ran a `find` across `$HOME` that took
**144,889 ms** -- 2.5 minutes of a single review round spent on a filesystem
sweep, on every round, since June.

Enumerating one root and treating it as the whole set is the reason the first
pass read complete. Both roots were verified 100% `gsd-*` before deletion, by
name and by count, and the deletion asserted its own blast radius: 77 dirs -> 10,
the ten surviving names byte-identical to the non-gsd set measured beforehand,
`.skill-lock.json` unchanged (it tracks 8 skills, all from `mattpocock/skills`,
and never knew about gsd), and 0 dangling symlinks before and after.

The npx package is the installer that put gsd there. Removing it is what stops a
stray `npx get-shit-done-cc` from restoring all of it; npx re-fetches on demand,
so nothing is lost that a network call cannot replace.

Both archive directories were checked for non-gsd entries before deletion, not
assumed: `ls | grep -cv '^gsd-'` returned 0 for each. Counting a set is not
classifying it, so the classification was measured.

## Reinstalling, if ever wanted

Version 1.42.3 came from a public source, so this is a reversible deletion:

    https://github.com/gsd-build/get-shit-done

It was not installed as a Claude Code plugin (it appears in neither
`plugins/installed_plugins.json` nor `known_marketplaces.json`), so it has to be
reinstalled by its own installer rather than with `claude plugin install`.
