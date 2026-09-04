# Replicating this Claude Code setup

Give a collaborator access to this repo (or have them fork it), then have them paste the prompt below into a fresh Claude Code session on their machine.
It reproduces the harness setup (symlinked config, memory architecture, hooks, auto-sync, plugins, CLI tools) while stripping personal content.
This prompt is for collaborators only: step 2 deletes the repo's memories, which a collaborator doesn't want but you do.
To set up another machine of your own — keeping and merging that machine's existing memories — use `second-machine-setup-prompt.md` instead.

```text
Set up my Claude Code environment to match your-org/claude-config. Work step by step; verify each step against its artifact before moving on, and ask me whenever a choice is mine to make.

1. FORK FIRST — never point at the upstream repo. This config auto-commits and auto-pushes every local change via a file watcher, so it must target MY fork: `gh repo fork your-org/claude-config --clone ~/dotfiles/claude` (ask me for access or a URL if that fails), and confirm `git remote -v` shows my fork.

2. PERSONALIZE MY FORK BEFORE INSTALLING (the repo carries the user's personal config; commit these changes to my fork):
   - memories/: these are the user's memories, not mine. Unless I say otherwise: delete any memories/<configdir>/ per-project trees (backups install.sh would otherwise symlink onto my machine). As of 2026-09-02 there are none and there should never be another: per-project memory now lives in each project's own repo at .claude/memory/, tracked, with the harness path as a symlink into that clone. memories/ should contain only global/, delete all bodies in memories/global/, and reduce memories/global/MEMORY.md to its header comment. Also remove docs/2026-06-27-global-memory-migration-manifest.md (it lived in memories/global/ until 2026-09-01).
   - CLAUDE.md: keep the General Guidelines section; walk me through the Working directives one by one and delete the ones I don't adopt (each `[[slug]]` needs a matching body in memories/global/, so write bodies for the ones I keep, or strip the links). Update the Tools section — the user uses a personal fork of lavish-axi; I'll use the upstream npm package unless I say otherwise. Update tests/claudemd.test.sh so its pinned strings match my edited CLAUDE.md.
   - skills/email-drafter is the user's personal email voice: delete it and remove it from ITEMS in install.sh, unless I want to write my own voice profile in its place.
   - settings.json (macOS) or settings.linux.json: hook paths are `$HOME`-based, so there is nothing to rewrite as long as the clone sits where the hooks point — ~/dotfiles/claude on macOS; on Linux settings.linux.json points at ~/claude-config, so either clone there or update those paths. The macOS notification hooks fire only when their gate files exist under ~/.claude/, and install.sh now creates them for you (deriving the names by scanning every script under hooks/, so this doc cannot go stale again — it previously listed two of the three gates, omitting `.enable-fleet-notif`, and nothing created any of them, so the hooks logged their events and rang nothing). Pass SKIP_NOTIF_FLAGS=1 if my terminal already raises its own OS toast (iTerm2, kitty, ghostty), where the hook and the terminal would double-ring.

3. Run ./install.sh from ~/dotfiles/claude (macOS/Linux; Windows uses the PowerShell path in the README). Verify: ~/.claude/CLAUDE.md, AGENTS.md, settings.json and the tracked skills are symlinks into the repo, and the SessionStart global-memory hook is present in the active settings.json.

4. Install plugins (marketplace details are in plugins/known_marketplaces.json):
   - claude-plugins-official: superpowers, skill-creator, frontend-design
   - context-mode marketplace: context-mode (then run its ctx-upgrade/doctor to confirm the version is current)
   - Do NOT install claude-mem (listed in the manifest but disabled in settings — its background observer sessions burn tokens) and do NOT install anything gsd-* (retired from this setup).

5. Install the CLI tools CLAUDE.md references, with Node >= 20: `npm i -g gh-axi chrome-devtools-axi`, then run `bin/install-lavish-fork.sh` for the forked `lavish-axi`, which is not published to npm (plus `no-mistakes` if I keep that skill; skip any I told you to drop in step 2).

6. VERIFY end to end: `bash tests/*.test.sh` in the repo all PASS; `git -C ~/dotfiles/claude status` is clean and a test commit auto-pushes to my fork within ~1 minute; a brand-new Claude Code session starts with no hook errors and injects my (possibly empty) global memory index.

7. When done, tell me about docs/trim-local-memories-prompt.md in this repo: once my projects accumulate local memories, pasting it into a project session distills an overgrown memory index (the CLAUDE.md memory-hygiene rule keeps new writes lean; that prompt cleans up growth after the fact).
```
