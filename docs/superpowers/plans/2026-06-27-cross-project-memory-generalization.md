# Cross-Project Memory Generalization Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `scope: global` learnings load in every project (not just cross-machine) via a project-independent `memories/global/` store injected into every session, plus the discipline rules and migration to populate it.

**Architecture:** A two-tier model. Tier 1 (always-on behavioral directives) lives in `CLAUDE.md`, already loaded everywhere. Tier 2 (universal facts) lives in a new flat `memories/global/` store, surfaced in every session by a synchronous `SessionStart` node hook that prints the global index to stdout. The existing `sync-memories.sh` Stop hook and `install.sh` restore loop are updated so the natural authoring path routes global memories into the new store instead of the old per-project silos.

**Tech Stack:** Bash (existing hooks/installer), Node ≥ 20 (new cross-platform injection hook), `jq` (idempotent settings edits), plain-bash test scripts (no bats/shellcheck dependency).

## Global Constraints

- Repo root: `~/dotfiles/claude` (macOS), `~/claude-config` (Linux), `sync.ps1` checkout location (Windows). Spec scope is this repo only — no application repo is touched.
- The injection hook emits **plain raw stdout** and exits `0`. Never JSON. (SessionStart plain stdout is added to context; JSON would require stdout to be *only* the JSON object.)
- Hook output is capped at **10,000 characters** by the harness; the hook self-guards at a **8,000-character** budget, truncating with a pointer line to `memories/global/MEMORY.md`.
- The injection hook is **synchronous** (no `"async": true`) so its stdout is captured as context.
- `memories/global/` is a **single flat namespace**; slugs must be globally-unique, descriptive. On a same-slug collision with differing content, `sync-memories.sh` logs `CONFLICT` and skips — never overwrites.
- The `memories/global/` store is **read from the repo checkout** by the hook, never copied/symlinked into `~/.<configDir>`. Only the hook reference + per-OS `settings.*.json` entries are platform-installed.
- Per-OS settings carry per-OS absolute paths: edit `settings.json` (macOS), `settings.linux.json` (Linux), `settings.windows.json` (Windows).
- Scripts honor `$HOME` and documented env overrides so tests run in a sandbox HOME with no global side effects.
- Migration is approval-gated: present the merged/deduped set for approval before any deletion; manifest committed first.
- Source of truth: `docs/superpowers/specs/2026-06-27-cross-project-memory-generalization-design.md`.

---

### Task 1: Injection hook `inject-global-memory.mjs` + global store scaffold

**Files:**
- Create: `~/dotfiles/claude/inject-global-memory.mjs`
- Create: `~/dotfiles/claude/memories/global/MEMORY.md`
- Test: `~/dotfiles/claude/tests/inject-global-memory.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the executable `inject-global-memory.mjs`. Behavior contract: resolves the global-memory dir as `process.env.CLAUDE_GLOBAL_MEMORY_DIR || join(<scriptDir>, 'memories', 'global')`; reads `MEMORY.md` there; if missing or whitespace-only, prints nothing and exits `0`; otherwise prints a header line `# Global memory (cross-project) — bodies at <dir>/<name>.md, unfold with Read; project-local memory overrides these defaults` followed by a blank line and the file contents; if the rendered output exceeds 8000 chars, prints the header + first 8000 chars of the index truncated at a line boundary + a final line `… (truncated — read <dir>/MEMORY.md in full)`. Always exits `0`.

- [ ] **Step 1: Create the store scaffold**

Create `~/dotfiles/claude/memories/global/MEMORY.md` with exactly this content:

```markdown
<!-- Global (cross-project) memory index. Pointer lines only — one per memory.
     Bodies are sibling <name>.md files. Loaded into every session by
     inject-global-memory.mjs (SessionStart hook). Keep this pointers-only and
     under ~8000 chars. -->
```

- [ ] **Step 2: Write the failing test**

Create `~/dotfiles/claude/tests/inject-global-memory.test.sh`:

```bash
#!/usr/bin/env bash
# Tests for inject-global-memory.mjs — plain bash, no bats dependency.
set -u
HOOK="$(cd "$(dirname "$0")/.." && pwd)/inject-global-memory.mjs"
fail=0
assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL: expected to contain: $1"; fail=1;; esac; }
assert_empty()    { [ -z "$1" ] && return; echo "FAIL: expected empty output, got: $1"; fail=1; }
assert_eq()       { [ "$1" = "$2" ] && return; echo "FAIL: expected '$2' got '$1'"; fail=1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/global"

# Case A: non-empty index -> header + contents, exit 0
printf -- '- [Foo](foo.md) — a foo fact\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"; code=$?
assert_eq "$code" "0"
assert_contains "Global memory (cross-project)" "$out"
assert_contains "[Foo](foo.md)" "$out"

# Case B: missing file -> no output, exit 0
rm -f "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"; code=$?
assert_eq "$code" "0"; assert_empty "$out"

# Case C: whitespace-only -> no output
printf -- '   \n\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"
assert_empty "$out"

# Case E: comment-only (the scaffold state) -> treated as empty, no injected noise
printf -- '<!-- docs, no pointers yet -->\n' > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"
assert_empty "$out"

# Case D: oversize -> truncated + pointer line
yes '- [x](x.md) — padding line to exceed the byte budget for truncation test' | head -n 400 > "$tmp/global/MEMORY.md"
out="$(CLAUDE_GLOBAL_MEMORY_DIR="$tmp/global" node "$HOOK")"
assert_contains "truncated — read" "$out"
[ "${#out}" -le 8300 ] || { echo "FAIL: output not truncated (${#out} chars)"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: inject-global-memory" || exit 1
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash ~/dotfiles/claude/tests/inject-global-memory.test.sh`
Expected: FAIL (node cannot find module `inject-global-memory.mjs`).

- [ ] **Step 4: Write the hook**

Create `~/dotfiles/claude/inject-global-memory.mjs`:

```javascript
#!/usr/bin/env node
// SessionStart hook: print the global (cross-project) memory index to stdout
// so it loads in EVERY project. Plain stdout (no JSON), always exit 0.
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { dirname, join } from 'node:path';

const scriptDir = dirname(fileURLToPath(import.meta.url));
const dir = process.env.CLAUDE_GLOBAL_MEMORY_DIR || join(scriptDir, 'memories', 'global');
const BUDGET = 8000;

let raw = '';
try { raw = readFileSync(join(dir, 'MEMORY.md'), 'utf8'); } catch { process.exit(0); }
// Strip HTML doc comments so the scaffold/explanatory comment is never injected.
const body = raw.replace(/<!--[\s\S]*?-->/g, '').trim();
if (body === '') process.exit(0);

const header =
  `# Global memory (cross-project) — bodies at ${dir}/<name>.md, unfold with Read; ` +
  `project-local memory overrides these defaults\n\n`;

let out = header + body + '\n';
if (out.length > BUDGET) {
  const slice = out.slice(0, BUDGET);
  const atLineBoundary = slice.slice(0, slice.lastIndexOf('\n'));
  out = atLineBoundary + `\n… (truncated — read ${dir}/MEMORY.md in full)\n`;
}
process.stdout.write(out);
process.exit(0);
```

- [ ] **Step 5: Make it executable and run the test**

Run:
```bash
chmod +x ~/dotfiles/claude/inject-global-memory.mjs
bash ~/dotfiles/claude/tests/inject-global-memory.test.sh
```
Expected: `PASS: inject-global-memory`

- [ ] **Step 6: Commit**

```bash
git -C ~/dotfiles/claude add inject-global-memory.mjs memories/global/MEMORY.md tests/inject-global-memory.test.sh
git -C ~/dotfiles/claude commit -m "feat(memory): global-memory injection hook + store scaffold"
```

---

### Task 2: Wire the hook into settings + fail-loud preflight in install.sh

**Files:**
- Modify: `~/dotfiles/claude/settings.json` (macOS), `~/dotfiles/claude/settings.linux.json`, `~/dotfiles/claude/settings.windows.json`
- Modify: `~/dotfiles/claude/install.sh` (add `install_global_memory_hook` + preflight)
- Test: `~/dotfiles/claude/tests/install-global-hook.test.sh`

**Interfaces:**
- Consumes: `inject-global-memory.mjs` (Task 1).
- Produces: a bash function `install_global_memory_hook` in `install.sh` that, given a settings JSON path and the absolute hook command, idempotently ensures a synchronous `SessionStart` command-hook invoking the hook exists; and a `preflight_global_memory_hook` that resolves each present config dir's active `settings.json` (`~/.claude`, `~/.claude1`) and exits non-zero if any lacks the hook command.

- [ ] **Step 1: Write the failing test**

Create `~/dotfiles/claude/tests/install-global-hook.test.sh`:

```bash
#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
assert_eq() { [ "$1" = "$2" ] && return; echo "FAIL: expected '$2' got '$1'"; fail=1; }
# null-safe count of inject hooks; .command? // "" avoids errors on command-less entries
CNT='[.hooks.SessionStart[]?.hooks[]? | select((.command? // "") | test("inject-global-memory"))] | length'

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
echo '{"hooks":{}}' > "$tmp/settings.json"
HOOK="node $REPO/inject-global-memory.mjs"

# install.sh is bash (the user's interactive shell is zsh) -> always invoke via bash -c
run() { bash -c "source '$REPO/install.sh' --source-only; $1"; }

run "install_global_memory_hook '$tmp/settings.json' '$HOOK'"
assert_eq "$(jq "$CNT" "$tmp/settings.json")" "1"

# Idempotent: second install adds no duplicate
run "install_global_memory_hook '$tmp/settings.json' '$HOOK'"
assert_eq "$(jq "$CNT" "$tmp/settings.json")" "1"

# Not async (no async key on the inject entry)
asynccount="$(jq '[.hooks.SessionStart[]?.hooks[]? | select((.command? // "")|test("inject-global-memory")) | .async] | map(select(. != null)) | length' "$tmp/settings.json")"
assert_eq "$asynccount" "0"

[ "$fail" = 0 ] && echo "PASS: install-global-hook" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/dotfiles/claude/tests/install-global-hook.test.sh`
Expected: FAIL (`install.sh` is not source-safe / function undefined).

- [ ] **Step 3: Add the functions + a source-only early-return, before the procedural body**

`install.sh` runs `set -euo pipefail` and its installer body is **procedural** (starts at the `echo "Linking repo -> $PRIMARY"` line, ~line 51). The `link` and `backup_if_real` helpers are defined just above it (~lines 31-49). Insert the new functions **immediately after the `link()` definition (line 49) and before the `echo "Linking repo -> $PRIMARY"` line (line 51)**, followed by the early-return. Because the early-return precedes the procedural body, sourcing with `--source-only` loads the functions and stops before any linking/restore/watcher side effects (and before `PRIMARY` is ever used). `$1` being `--source-only` is harmless: `PRIMARY="${1:-$HOME/.claude}"` (line 16) is assigned but never reached for use.

```bash
# Idempotently ensure a synchronous SessionStart command-hook for $2 exists in
# the settings JSON at $1. (.command? // "" makes the match null-safe.)
install_global_memory_hook() {
  local settings="$1" cmd="$2" tmp
  [ -f "$settings" ] || echo '{}' > "$settings"
  tmp="$(mktemp)"
  jq --arg cmd "$cmd" '
    .hooks //= {} | .hooks.SessionStart //= []
    | if any(.hooks.SessionStart[]?.hooks[]?; (.command? // "") == $cmd) then .
      else .hooks.SessionStart += [ { "hooks": [ { "type": "command", "command": $cmd } ] } ] end
  ' "$settings" > "$tmp" && mv "$tmp" "$settings"
}

# Fail loudly if any present config dir's active settings.json lacks the hook.
preflight_global_memory_hook() {
  local cmd="$1" cfg active missing=0
  for cfg in "$HOME/.claude" "$HOME/.claude1"; do
    [ -d "$cfg" ] || continue
    active="$cfg/settings.json"
    [ -e "$active" ] || { echo "preflight: $active missing" >&2; missing=1; continue; }
    if ! jq -e --arg cmd "$cmd" 'any(.hooks.SessionStart[]?.hooks[]?; (.command? // "") == $cmd)' "$active" >/dev/null; then
      echo "preflight: $active lacks global-memory hook ($cmd)" >&2; missing=1
    fi
  done
  return $missing
}

# (Task 4 inserts restore_memories() here, above this early-return.)

# Allow `source install.sh --source-only` to load functions without installing.
[ "${1:-}" = "--source-only" ] && return 0
```

Then, in the procedural body, install the hook into **this OS's** settings file and preflight with **the same command**. `SETTINGS_SRC` is already computed by `uname` (line 26-29), and `REPO_DIR` is the real checkout path on this machine, so this is OS-correct without any guessed paths. Add right after the existing settings-link line (`link "$REPO_DIR/$SETTINGS_SRC" "$PRIMARY/settings.json"`, ~line 55):

```bash
# Global-memory injection hook: install into THIS OS's settings + verify.
HOOK_CMD="node $REPO_DIR/inject-global-memory.mjs"
install_global_memory_hook "$REPO_DIR/$SETTINGS_SRC" "$HOOK_CMD"
preflight_global_memory_hook "$HOOK_CMD" || { echo "global-memory hook preflight FAILED" >&2; exit 1; }
```

Do NOT try to write the other OSes' settings files from this run with guessed paths — each OS installs its own correct path when `install.sh` runs there. Pre-populating all three tracked files (so other machines get it on first pull) is done once, manually, in Step 5 using each OS's real checkout path.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/dotfiles/claude/tests/install-global-hook.test.sh`
Expected: `PASS: install-global-hook`

- [ ] **Step 5: Pre-populate all three tracked settings files (each with its real per-OS path)**

So every machine gets the hook on first `git pull` (not only after re-running `install.sh`), add the entry to all three tracked settings files using each OS's known checkout path. The Windows path is **read from the existing `settings.windows.json`** (currently `C:\Users\ilike\OneDrive\Desktop\claude-config`) — confirm it before running, do not fabricate. `install.sh` is bash, so invoke via `bash -c`:

```bash
cd ~/dotfiles/claude
run() { bash -c "source ~/dotfiles/claude/install.sh --source-only; $1"; }

# macOS checkout: ~/dotfiles/claude
run "install_global_memory_hook settings.json 'node \$HOME/dotfiles/claude/inject-global-memory.mjs'"
# Linux checkout: ~/claude-config
run "install_global_memory_hook settings.linux.json 'node \$HOME/claude-config/inject-global-memory.mjs'"
# Windows checkout: the base path already used by hooks in settings.windows.json. Verify first:
grep -o '[A-Za-z]:[^"]*claude-config' settings.windows.json | head -1
# Then (substituting that exact base; example uses the current value):
run "install_global_memory_hook settings.windows.json 'node C:\\\\Users\\\\ilike\\\\OneDrive\\\\Desktop\\\\claude-config\\\\inject-global-memory.mjs'"

# Verify each file has exactly one inject command with the right path:
for f in settings.json settings.linux.json settings.windows.json; do
  echo "== $f =="; jq -r '.hooks.SessionStart[]?.hooks[]? | select((.command? // "")|test("inject-global-memory")) | .command' "$f"
done
```
Expected: each file prints exactly one inject command with its correct per-OS path; no `"async"` key on any.

- [ ] **Step 6: Commit**

```bash
git -C ~/dotfiles/claude add install.sh settings.json settings.linux.json settings.windows.json tests/install-global-hook.test.sh
git -C ~/dotfiles/claude commit -m "feat(memory): install global-memory SessionStart hook into per-OS settings + preflight"
```

---

### Task 3: Route `scope: global` to the flat global store in sync-memories.sh

**Files:**
- Modify: `~/dotfiles/claude/sync-memories.sh`
- Test: `~/dotfiles/claude/tests/sync-memories.test.sh`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: updated `sync-memories.sh` whose behavior is: for a real (non-symlink) project memory file tagged `scope: global`, the destination is `$MEM_ROOT/global/<file>` (flat, no `<root>/<project>` segment); after placing it, the local project file is **removed** (no symlink-back) in BOTH the move branch and the identical-`cmp` branch; if the destination slug exists with differing content, log `CONFLICT` and skip. Honors `$HOME` for sandboxing.

- [ ] **Step 1: Write the failing test**

Create `~/dotfiles/claude/tests/sync-memories.test.sh`:

```bash
#!/usr/bin/env bash
set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)/sync-memories.sh"
fail=0
assert_true()  { eval "$1" && return; echo "FAIL: $2"; fail=1; }
assert_false() { eval "$1" && { echo "FAIL: $2"; fail=1; }; return 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mkdir -p "$tmp/dotfiles/claude/memories"
proj="$tmp/.claude1/projects/-Some-Proj/memory"
mkdir -p "$proj"
printf -- '---\nname: g\nmetadata:\n  scope: global\n---\nbody\n' > "$proj/g.md"
printf -- '---\nname: loc\n---\nlocal body\n' > "$proj/loc.md"

err="$(bash "$SRC" 2>&1 1>/dev/null)"

# global memory moved to FLAT global store, original removed, no silo path
assert_true  '[ -f "$tmp/dotfiles/claude/memories/global/g.md" ]' "g.md not in flat global store"
assert_false '[ -e "$proj/g.md" ]' "project g.md should be removed (no symlink-back)"
assert_false '[ -e "$tmp/dotfiles/claude/memories/claude1/-Some-Proj/g.md" ]' "must not use silo path"
# untagged memory untouched
assert_true  '[ -f "$proj/loc.md" ] && [ ! -L "$proj/loc.md" ]' "local memory must stay put"
# unindexed straggler warned (no pointer in a (missing) global MEMORY.md)
assert_true  'printf "%s" "$err" | grep -q "UNINDEXED global/g.md"' "should warn about unindexed straggler"

# conflict: differing content already at destination -> skip, keep nothing duplicated
mkdir -p "$tmp/.claude1/projects/-Other/memory"
printf -- '---\nname: g\nmetadata:\n  scope: global\n---\nDIFFERENT\n' > "$tmp/.claude1/projects/-Other/memory/g.md"
bash "$SRC"
assert_true '[ "$(cat "$tmp/dotfiles/claude/memories/global/g.md" | tail -1)" = "body" ]' "conflict must not overwrite"

[ "$fail" = 0 ] && echo "PASS: sync-memories" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/dotfiles/claude/tests/sync-memories.test.sh`
Expected: FAIL (current script writes to the `<root>/<project>` silo and symlinks back).

- [ ] **Step 3: Update the routing**

In `sync-memories.sh`, replace the destination computation and the two placement branches. The new inner loop body:

```bash
    file="$(basename "$f")"
    dest="$MEM_ROOT/global/$file"        # FLAT global namespace
    index="$MEM_ROOT/global/MEMORY.md"

    if [ -e "$dest" ]; then
      if cmp -s "$f" "$dest"; then
        rm -f "$f"                        # identical already in store: drop local, no symlink
        log "deduped (already global) global/$file"
      else
        log "CONFLICT (skipped, repo differs): global/$file"
      fi
      continue
    fi

    mkdir -p "$(dirname "$dest")"
    mv "$f" "$dest"                        # move into store; NO symlink-back
    log "promoted global/$file"
    # The injection hook reads ONLY the index, so a promoted body with no pointer
    # line would never load. Warn (stderr + log) rather than silently rewrite it.
    if ! { [ -f "$index" ] && grep -qF "($file)" "$index"; }; then
      echo "sync-memories: UNINDEXED global/$file — add a pointer to memories/global/MEMORY.md" >&2
      log "UNINDEXED global/$file (no pointer in MEMORY.md)"
    fi
```

Keep the outer `for root in claude claude1` scan and the `find ... ! -name 'MEMORY.md'` exactly as-is (we still scan both config dirs' project memory files; only the destination + no-symlink + straggler-warning behavior changes). Remove the old `$root/$projectdir` destination construction.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/dotfiles/claude/tests/sync-memories.test.sh`
Expected: `PASS: sync-memories`

- [ ] **Step 5: Commit**

```bash
git -C ~/dotfiles/claude add sync-memories.sh tests/sync-memories.test.sh
git -C ~/dotfiles/claude commit -m "feat(memory): route scope:global to flat memories/global store, no symlink-back"
```

---

### Task 4: Skip `memories/global/**` in the install.sh restore loop

**Files:**
- Modify: `~/dotfiles/claude/install.sh` (the memory-restore loop)
- Test: `~/dotfiles/claude/tests/install-restore.test.sh`

**Interfaces:**
- Consumes: nothing.
- Produces: the restore loop no longer treats `memories/global/` as a `<configDir>/<project>` triple, so it creates no `~/.global/...` links and leaves the global store untouched (it is read from the repo, never restored into `~/.<configDir>`).

- [ ] **Step 1: Write the failing test**

Create `~/dotfiles/claude/tests/install-restore.test.sh`:

```bash
#!/usr/bin/env bash
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd)"
fail=0
assert_true()  { eval "$1" && return; echo "FAIL: $2"; fail=1; }
assert_false() { eval "$1" && { echo "FAIL: $2"; fail=1; }; return 0; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
export HOME="$tmp"
mem="$tmp/dotfiles/claude/memories"
mkdir -p "$mem/global" "$mem/claude1/-Proj"
printf -- '- [x](x.md)\n' > "$mem/global/MEMORY.md"
printf -- 'gbody\n'       > "$mem/global/x.md"
printf -- 'legacy\n'      > "$mem/claude1/-Proj/foo.md"

# Run restore in a SUBSHELL: sourcing install.sh enables `set -euo pipefail`,
# which must not leak into the assertion shell.
bash -c "source '$REPO/install.sh' --source-only; restore_memories '$mem'"

# global store must NOT be restored into a ~/.global config dir
assert_false '[ -e "$tmp/.global" ]' "must not create ~/.global from memories/global"
# legacy silo memory MUST still restore as a symlink into the project memory dir
link="$tmp/.claude1/projects/-Proj/memory/foo.md"
assert_true '[ -L "$link" ]' "legacy memory must restore as a symlink"
assert_true '[ "$(readlink "$link")" = "$mem/claude1/-Proj/foo.md" ]' "legacy symlink must point at the repo file"

[ "$fail" = 0 ] && echo "PASS: install-restore" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/dotfiles/claude/tests/install-restore.test.sh`
Expected: FAIL (`restore_memories` undefined, or it creates `~/.global`).

- [ ] **Step 3: Extract the restore loop into `restore_memories()` with the global skip**

Add this function in the functions block from Task 2, **immediately above** the `[ "${1:-}" = "--source-only" ] && return 0` line (so it is defined for both real execution and `--source-only` sourcing; it relies on `link`, defined higher up). It reproduces the existing per-file logic (install.sh:71-78) and adds one skip:

```bash
restore_memories() {
  local mem_root="$1" src rel root rest projectdir file linkpath
  while IFS= read -r src; do
    rel="${src#"$mem_root"/}"            # <root>/<projectdir>/<file>  OR  global/<file>
    root="${rel%%/*}"
    [ "$root" = "global" ] && continue   # global store is read from the repo, never restored
    rest="${rel#*/}"; projectdir="${rest%%/*}"; file="${rest#*/}"
    linkpath="$HOME/.$root/projects/$projectdir/memory/$file"
    link "$src" "$linkpath"
  done < <(find "$mem_root" -type f -name '*.md' 2>/dev/null)
}
```

Then replace the existing inline restore loop body (install.sh:71-79, the `while IFS= read -r src … done < <(find …)` block) with a single call, keeping the surrounding `if [[ -d "$REPO_DIR/memories" ]]; then echo "Restoring global memories"; … fi`:

```bash
  restore_memories "$REPO_DIR/memories"
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash ~/dotfiles/claude/tests/install-restore.test.sh`
Expected: `PASS: install-restore`

- [ ] **Step 5: Commit**

```bash
git -C ~/dotfiles/claude add install.sh tests/install-restore.test.sh
git -C ~/dotfiles/claude commit -m "fix(memory): skip memories/global in install.sh restore loop (no bogus ~/.global links)"
```

---

### Task 5: Rewrite CLAUDE.md memory rules + add Working directives

**Files:**
- Modify: `~/dotfiles/claude/CLAUDE.md`
- Test: `~/dotfiles/claude/tests/claudemd.test.sh`

**Interfaces:**
- Consumes: nothing (the `[[links]]` resolve to global memories created in Task 6; soft links, fine if Task 6 follows).
- Produces: a `## Working directives` section and a rewritten `## Memory` section containing the promotion test, routing, and the `memories/global/` storage location.

- [ ] **Step 1: Write the failing test**

Create `~/dotfiles/claude/tests/claudemd.test.sh`:

```bash
#!/usr/bin/env bash
set -u
MD="$(cd "$(dirname "$0")/.." && pwd)/CLAUDE.md"
fail=0
need() { grep -qF "$1" "$MD" || { echo "FAIL: CLAUDE.md missing: $1"; fail=1; }; }

need "## Working directives"
need "memories/global/"
need "Would this help me in an unrelated project next week"
need "[[execution-verification-prefs]]"
need "[[feedback-spec-stated-rules-exactly]]"
# the new routing must point at the flat global store, not a per-project silo
grep -qF 'memories/claude1/' "$MD" && { echo "FAIL: stale per-project silo path still present"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: claudemd" || exit 1
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash ~/dotfiles/claude/tests/claudemd.test.sh`
Expected: FAIL (sections not yet present).

- [ ] **Step 3: Add the Working directives section**

Insert this section in `CLAUDE.md` immediately before the `## Memory` section:

```markdown
## Working directives

These are always-on. The one-line rule lives here; the why/how is in the linked global memory (unfold on demand).

- Run the Playwright-grounded Claude↔Codex convergence loop on every review until clean — `[[execution-verification-prefs]]`.
- Fix what you flag, even out of scope — `[[feedback-fix-dont-just-note]]`.
- On any API or tool error, route around it; never abandon the task — `[[feedback-never-give-up-on-api-errors]]`.
- Implement stated numeric/layout/timing rules exactly; unit-test them; verify the cited example — `[[feedback-spec-stated-rules-exactly]]`.
- Fold every mockup or brainstorm critique into the spec and plan — `[[mockup-critiques-into-spec]]`.
```

- [ ] **Step 4: Rewrite the Memory section**

Replace the body of the `## Memory` section with:

```markdown
## Memory

- A learning is **global** if it passes this test: "Would this help me in an unrelated project next week, independent of any single repo?" If yes, it is who the user is, a universal working preference, a tool/platform fact, or a generalizable lesson. Project-technical facts stay **local** even when the pattern is interesting — file the generalization, not the instance.
- **Routing.** A *behavioral directive* → write the body to `memories/global/` AND add a one-line imperative to the `## Working directives` section above. A *pure fact* → write the body to `memories/global/` with an index line only.
- Global memories live in `memories/global/` (flat namespace, globally-unique descriptive slugs). The `sync-memories.sh` Stop hook routes any `scope: global` memory there automatically; the `inject-global-memory.mjs` SessionStart hook loads the `memories/global/MEMORY.md` index into every project. Project-local memory overrides global defaults on project-specific constraints.
- Leave per-project state memories untagged so they stay local.
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash ~/dotfiles/claude/tests/claudemd.test.sh`
Expected: `PASS: claudemd`

- [ ] **Step 6: Commit**

```bash
git -C ~/dotfiles/claude add CLAUDE.md tests/claudemd.test.sh
git -C ~/dotfiles/claude commit -m "docs(memory): two-tier directives + promotion-test memory rules in CLAUDE.md"
```

---

### Task 6: Guided consolidation migration (approval-gated)

**Files:**
- Create: `~/dotfiles/claude/tests/migration-verify.sh` (post-migration invariant check)
- Create (transient, committed): `~/dotfiles/claude/memories/global/MIGRATION-MANIFEST.md`
- Modify: `~/dotfiles/claude/memories/global/MEMORY.md`, the migrated body files, per-project `MEMORY.md` files (out-of-repo), `CLAUDE.md` directive `[[links]]` (verify resolution)

**Interfaces:**
- Consumes: the store (Task 1), routing (Task 3), restore skip (Task 4), CLAUDE.md (Task 5).
- Produces: a populated `memories/global/` with deduped canonical memories, tombstones for renamed slugs, and a committed manifest. Invariant: zero universal memories lost; no memory appears in both a project `MEMORY.md` and the global index.

- [ ] **Step 1: Enumerate the migration set and build the manifest**

Run:
```bash
cd ~/dotfiles/claude/memories
grep -rl 'scope: global' claude claude1 | sort
```
For each file, add a row to `memories/global/MIGRATION-MANIFEST.md` with: source path, proposed destination slug, decision (`move` / `merge-into:<slug>` / `downgrade-to-local`), original `MEMORY.md` pointer line, origin session IDs, `shasum` of the body. Use the known dedup clusters from the spec:
- `prefer-playwright-e2e-convergence` + `execution-verification-prefs` → merge into `execution-verification-prefs`.
- `use-lavish-for-visualization` + `visualize-means-lavish` + `visualize-in-browser` → merge into `visualize-in-browser`.
- `notify-only-on-convergence-or-blocked` + `notify-on-response` → merge into `notify-on-response`.
- Tool-internal candidates (e.g. `lavish-fork-sse-hardening`, `lavish-axi-threading-and-collapsibles`) → evaluate with the promotion test; `downgrade-to-local` if not universal.

- [ ] **Step 2: CHECKPOINT — present the manifest for approval**

Show the proposed manifest (every move/merge/downgrade) to the user. **Do not delete or move anything yet.** Get explicit approval. Commit the manifest as-is:
```bash
git -C ~/dotfiles/claude add memories/global/MIGRATION-MANIFEST.md
git -C ~/dotfiles/claude commit -m "chore(memory): migration manifest (pre-approval snapshot)"
```

- [ ] **Step 3: Apply moves and merges**

For each `move`: write the canonical body to `memories/global/<slug>.md` and add its pointer line to `memories/global/MEMORY.md`. For each `merge-into`: write the unioned body (richer base + merged why/how, both `originSessionId`s noted) to the canonical `memories/global/<slug>.md`; for the non-canonical sources, add a **tombstone** — a one-line alias entry in `MEMORY.md`: `- [old-slug → <slug>](<slug>.md) — renamed`. Bodies that already live in the repo move via `git mv` where the slug is unchanged.

- [ ] **Step 4: Downgrade-to-local (order-sensitive)**

For each `downgrade-to-local` whose project file is currently a symlink into the repo: replace the symlink with a real local copy, strip the `scope: global` line, re-add its pointer to that project's `MEMORY.md`, and only then remove the repo-side copy **from disk** (not merely untrack it — an untracked leftover would be re-picked-up by the restore loop / future migrations):
```bash
# for each downgrade target <f> (project path), currently a symlink into the repo:
t="$(readlink "$f")"                        # repo-side target (absolute)
cp "$t" "$f.real" && mv -f "$f.real" "$f"   # replace symlink with a REAL local copy
# (now edit $f to remove the `scope: global` line, and re-add its pointer to the project's MEMORY.md)
[ -f "$f" ] && [ ! -L "$f" ] || { echo "ABORT: local copy missing for $f" >&2; exit 1; }
git -C ~/dotfiles/claude rm -f "${t#"$HOME/dotfiles/claude/"}"   # remove repo file from disk AND index
```

- [ ] **Step 5: Remove per-project copies + pointer lines for migrated globals**

For every migrated (non-downgraded) memory, remove its symlink/copy from the project `memory/` dir and delete its pointer line from that project's `MEMORY.md` so nothing double-loads (native per-project block + injected global block).

- [ ] **Step 6: Write the verification check and run it**

Create `~/dotfiles/claude/tests/migration-verify.sh`:

```bash
#!/usr/bin/env bash
set -u
REPO=~/dotfiles/claude
fail=0
# 1. Every global index pointer resolves to a body (or is a tombstone alias).
while IFS= read -r slug; do
  [ -f "$REPO/memories/global/$slug" ] || { echo "FAIL: dangling pointer $slug"; fail=1; }
done < <(grep -oE '\]\([a-z0-9-]+\.md\)' "$REPO/memories/global/MEMORY.md" | sed -E 's/\]\((.*)\)/\1/' | sort -u)

# 2. No slug appears in BOTH a project MEMORY.md and the global index.
for pm in "$HOME"/.claude*/projects/*/memory/MEMORY.md; do
  [ -f "$pm" ] || continue
  while IFS= read -r b; do
    grep -qF "$b" "$REPO/memories/global/MEMORY.md" && { echo "FAIL: double-listed $b"; fail=1; }
  done < <(grep -oE '\]\([a-z0-9-]+\.md\)' "$pm" | sed -E 's/\]\((.*)\)/\1/')
done
[ "$fail" = 0 ] && echo "PASS: migration-verify" || exit 1
```

Run: `bash ~/dotfiles/claude/tests/migration-verify.sh`
Expected: `PASS: migration-verify`

- [ ] **Step 7: Commit**

```bash
git -C ~/dotfiles/claude add -A memories CLAUDE.md tests/migration-verify.sh
git -C ~/dotfiles/claude commit -m "chore(memory): migrate global memories into flat store (deduped + tombstoned)"
```

---

### Task 7: End-to-end verification (real sessions)

**Files:**
- Create: `~/dotfiles/claude/tests/e2e-checklist.md` (documented manual E2E, committed)

**Interfaces:**
- Consumes: everything.
- Produces: recorded evidence the global index injects in a *different* project, a fresh project, both config dirs, and the authoring round-trip.

- [ ] **Step 1: Run the full unit suite**

Run:
```bash
for t in ~/dotfiles/claude/tests/*.test.sh; do bash "$t" || echo "SUITE FAIL: $t"; done
bash ~/dotfiles/claude/tests/migration-verify.sh
```
Expected: every line `PASS: …`.

- [ ] **Step 2: Cross-project injection**

Start a session in a *different* project (e.g. `~/code/your-company-leads`) and confirm the injected "Global memory (cross-project)" block appears and a body unfolds via Read. Record the observation in `tests/e2e-checklist.md`.

- [ ] **Step 3: Fresh-project + both-config-dir injection**

Confirm a brand-new project dir (no `memory/`) still receives the global block, and repeat the check under both `~/.claude` and `~/.claude1`. Record results.

- [ ] **Step 4: Authoring round-trip**

In a project session, write a throwaway memory tagged `scope: global`, end the session (fires `sync-memories.sh`), and confirm it landed in `memories/global/` (not a silo), with no symlink left in the project. Also confirm it is **either** indexed in the global index **or** the sync hook logged the `UNINDEXED` warning (so it can never silently fail to load):
```bash
slug=throwaway.md
grep -qF "($slug)" ~/dotfiles/claude/memories/global/MEMORY.md \
  || grep -q "UNINDEXED global/$slug" ~/Library/Logs/claude-config-autopush.log \
  && echo "OK: indexed or warned" || echo "FAIL: silently unindexed"
```
Then delete the throwaway. Record results.

- [ ] **Step 5: Commit**

```bash
git -C ~/dotfiles/claude add tests/e2e-checklist.md
git -C ~/dotfiles/claude commit -m "test(memory): E2E checklist evidence for cross-project injection"
```

---

## Self-Review

**Spec coverage:** storage (T1), injection hook + format/cap/precedence (T1, header in hook), Tier-1 directives + promotion test (T5), sync-hook routing incl. both branches + conflict (T3), install.sh restore skip (T4), config-dir preflight + per-OS settings (T2), migration manifest/dedup/tombstones/downgrade-order (T6), two-config + source-variant + Windows + authoring E2E (T7). Windows `.ps1` is intentionally avoided by using a single node hook (spec-permitted); `settings.windows.json` still gets an entry (T2) and is exercised in T7 conceptually.

**Placeholder scan:** no TBD/TODO; every code step shows real code with literal shell/jq.

**Type/name consistency:** `install_global_memory_hook`, `preflight_global_memory_hook`, `restore_memories`, `CLAUDE_GLOBAL_MEMORY_DIR`, and `memories/global/` are used identically across tasks.
