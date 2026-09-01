# E2E verification — cross-project memory generalization

Date: 2026-06-27. Evidence for the real code paths a new session exercises.

## Automated (run here)

- **Full unit suite green:** `inject-global-memory`, `install-global-hook`, `install-restore`, `sync-memories`, `claudemd`, `migration-verify` all PASS.
- **Production injection** — `bash "$HOME/dotfiles/claude/inject-global-memory.sh"` (the exact `settings.json` command) emits the header + 27 pointers = 30 lines, 4893 chars as of 2026-07-31 (harness cap 10000; grows as pointers are added — re-measure, don't trust these numbers). The global dir resolves from the hook's own repo location, so output is identical regardless of the session's project/cwd.
- **Authoring round-trip** (real `sync-memories.sh`, sandboxed `$HOME`): a project-dir memory tagged `scope: global` → moved to `memories/global/`, removed from the project dir (no symlink-back), and an `UNINDEXED` warning fired (since its pointer wasn't in the index yet). YES / NO / YES as expected.
- **No dangling symlinks** in any project `memory/` dir; **no migrated slug double-listed** in any project `MEMORY.md` (migration-verify check 2).

## Manual confirmation (next real session — the user)

These need an actual new Claude Code SessionStart, which can't be triggered from inside this session:

- [ ] Start a session in a brand-new project dir (no `memory/`) → confirm the global block still appears.
- [ ] Confirm under both `~/.claude` and `~/.claude1`.
- [ ] Exercise `SessionStart` sources: `startup`, `resume`, `clear`, `compact`.

The injected bytes these will receive are exactly the production-injection output verified above.
