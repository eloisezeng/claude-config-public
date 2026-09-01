# Running your own Claude config off a fork

This repo is the user's personal Claude configuration.
It is not a shared team config: `CLAUDE.md`, `memories/`, and `skills/` encode one person's working preferences, one machine's Codex profiles, and one account's model availability.

Autosync makes that dangerous to share directly.
Every tracked-file edit is committed and pushed with no review step, so a machine-specific fact written on one computer lands in the other person's live agent config within seconds.

**So each person autosyncs to their own fork.** Improvements travel between forks as deliberate pull requests, never automatically.

## Why this matters — a real case

On 2026-08-13 a Windows machine autosynced its own Codex routing into this repo: `-p terrax` and `-p terramax`, the profiles installed *there*.

Neither profile exists on the user's Mac.
Codex does not error on an unknown `-p` — it silently falls through to the base config.
Measured on the Mac: `-p terrax` ran `gpt-5.6-sol` at reasoning effort **`none`**, while `codex-converge` believed it had requested Terra/xhigh.

Every adversarial diff review, security, money, migration and schema review on that machine ran at the weakest possible setting for four days, and each verdict looked completely normal.

Nobody did anything careless. The architecture simply had no place for "true on my machine only".

## One-time setup

### 1. Fork on GitHub

Open <https://github.com/your-org/claude-config> and press **Fork**.
Read access is enough to fork; you do not need write access to the user's repo.

### 2. Repoint your checkout

From your config repo (`~/dotfiles/claude`, or `~/claude-config` on Linux/WSL):

```bash
# Your fork becomes origin — this is where autosync pushes.
git remote set-url origin https://github.com/<your-username>/claude-config.git

# The user's repo becomes upstream — read-only, for pulling improvements.
git remote add upstream https://github.com/your-org/claude-config.git

# Never push to upstream by accident.
git remote set-url --push upstream DISABLED

git remote -v   # confirm before continuing
```

Expected:

```
origin    https://github.com/<you>/claude-config.git (fetch)
origin    https://github.com/<you>/claude-config.git (push)
upstream  https://github.com/your-org/claude-config.git (fetch)
upstream  DISABLED (push)
```

### 3. Point your branch at your fork

```bash
git push -u origin main
```

Autosync now pushes to your fork. Nothing you write reaches the user's repo unless you open a PR.

## Day to day

**Your own changes** — nothing to do. `sync.ps1` / `sync.sh` commits and pushes to your fork exactly as before.

**Pulling the user's improvements** — whenever you want them:

```bash
git fetch upstream
git rebase upstream/main      # or: git merge upstream/main
```

Review what arrives. Her `CLAUDE.md` and memories describe *her* machines and *her* preferences; take the parts that apply to you.

**Sending an improvement back** — only for genuinely portable work (a bug fix in `install.sh`, a Windows path fix, a new test):

```bash
git push origin HEAD:refs/heads/fix-something
gh pr create --repo your-org/claude-config --base main --head <your-username>:fix-something
```

## What belongs in a PR, and what never does

| Portable — PR it | Machine- or person-specific — keep in your fork |
| --- | --- |
| `install.sh`, `sync.sh`, `sync.ps1`, `watch.ps1` fixes | Codex profile names and tier routing |
| New tests | Model availability for your account |
| Windows plumbing (`settings.windows.json`) | Your own memories and preferences |
| README and docs corrections | Anything phrased "on this machine" / "on this account" |

The test in the last column is simple: **would this still be true on a computer you have never seen?** If not, it stays in your fork.

When a fact really is machine-specific but worth recording centrally, write it as a *comparison* rather than a replacement — see the per-machine table in `skills/codex-converge/SKILL.md`, which names each machine alongside what was measured there instead of overwriting one with the other.

## Guard rails now in place

- `run-codex.sh` **refuses** a `-p` naming a profile that has no matching `$CODEX_HOME/<name>.config.toml`, listing the profiles actually installed. A shared skill can no longer silently run at a tier that machine does not have.
- It also prints `tier actually used: model=… effort=…`, read from codex's own banner. Trust that line, never the flag you passed.
- `sync.sh` / `sync.ps1` no longer swallow git errors. A conflict now exits non-zero, logs, raises a desktop notification, and leaves the repo mid-rebase so you can see what collided.
