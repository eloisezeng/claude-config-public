# Setting up this config on another machine of your own

This is the self-replication path: your own additional computer, which may already have a Claude account with stored memories.
Unlike `replicate-setup-prompt.md` (the collaborator path, which strips the repo's memories), this path keeps the repo's memories AND the target machine's existing memories, and merges the two.
Paste the prompt below into a fresh Claude Code session on the other machine.

```text
Set up my Claude Code environment from my existing config repo your-org/claude-config. This machine already has a Claude account with stored memories; nothing may be lost — this machine's memories and the repo's memories must be MERGED. Work step by step; verify each step against its artifact before moving on.

1. INVENTORY BEFORE TOUCHING ANYTHING. List every memory already on this machine: `find ~/.claude ~/.claude1 -path '*/memory/*.md' 2>/dev/null`, plus ~/.claude/CLAUDE.md if it exists. Save that list to a scratch file — it is both the merge worklist and the final proof that nothing was lost.

2. Clone MY repo (no fork — this is my own repo and it auto-pushes): `gh repo clone your-org/claude-config ~/dotfiles/claude`, and confirm `git remote -v` points at your-org/claude-config. The ~/dotfiles/claude location is load-bearing on macOS: TCC-protected folders (~/Documents, ~/Desktop, ~/Downloads) are unreadable to the launchd auto-sync watcher that install.sh sets up, so a clone there dies with "Operation not permitted" and nothing auto-pushes. Do NOT delete or edit anything under memories/ — those are my memories from my other machine and must survive.

3. Sanity-check hook portability: the tracked hook commands are written against `$HOME` (no usernames), so they work here as long as the repo sits at ~/dotfiles/claude. `grep -nE '/(Users|home)/[A-Za-z]' settings.json` must return nothing — if it finds an absolute home path, STOP and tell me before editing anything tracked (a dead path silently kills that hook: no pull at SessionStart, no global-memory injection, no memory sync on Stop).

4. Run ./install.sh from ~/dotfiles/claude — as `./install.sh ~/.claude ~/.claude1` if this machine has a second profile dir at ~/.claude1, so the mirror gets the settings link too. It backs up any real file it replaces to <file>.bak-<n> — it never deletes. Afterwards list every .bak-* it created, especially under ~/.claude/projects/*/memory/: each one is a pre-existing local file now shadowed by a repo copy. Diff each backup against the file that shadows it, fold any local-only content into the live file, then remove the .bak.

5. MERGE this machine's remaining local memories into the repo. For each memory from the step 1 inventory that still lives outside the repo:
   - Apply the global test from CLAUDE.md ("would this help in an unrelated project next week?"). If it passes: move the body to memories/global/<slug>.md (flat namespace, globally-unique descriptive slug) and add a one-line pointer to memories/global/MEMORY.md. If a same-named file already exists with different content, fold both into ONE distilled rule in place — never keep two variants and never overwrite the repo copy blindly.
   - If it fails the test (project-specific state): leave it exactly where it is, untagged, so it stays local to this machine.
   - If this machine had its own ~/.claude/CLAUDE.md (now a .bak from step 4), walk me through anything in it worth keeping and merge that into the repo CLAUDE.md or a global memory body.
   Keep everything distilled per the repo's memory-hygiene rule: fold corrections into the rule, never append logs; index lines stay one line each.

6. VERIFY end to end: every path in the step 1 inventory is accounted for (folded, promoted, or deliberately left local — nothing silently gone); every test passes via `for t in tests/*.test.sh; do bash "$t"; done` (a bare `bash tests/*.test.sh` runs only the FIRST script — the rest become its arguments); the merge commits auto-push to the repo within ~1 minute; a brand-new Claude Code session here starts with no hook errors and injects the MERGED global memory index. Then remind me to start a session on my other machine so it pulls the merged memories.
```
