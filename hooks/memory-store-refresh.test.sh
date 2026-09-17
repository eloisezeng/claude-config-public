#!/usr/bin/env bash
# Controls for hooks/memory-store-refresh.mjs, against REAL git repositories: a bare upstream, a
# partial sparse store clone reached through a fake config root's memory symlink, and a session
# checkout of the same upstream. Every accepting case has a refusing twin, because a refresher that
# never pulls and one that always pulls both pass half of these.
set -uo pipefail
HOOK="${MEMORY_STORE_REFRESH_HOOK:-$(cd "$(dirname "$0")" && pwd)/memory-store-refresh.mjs}"
pass=0; fail=0
ok() { pass=$((pass + 1)); printf 'ok   %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf 'FAIL %s\n' "$1"; }
check() { if eval "$2"; then ok "$1"; else bad "$1 -- [$2]"; fi }

T="$(mktemp -d)" || exit 1
[ -n "$T" ] || exit 1
trap 'rm -rf "$T"' EXIT
export GIT_CONFIG_GLOBAL="$T/gitconfig" GIT_CONFIG_NOSYSTEM=1
git config --file "$T/gitconfig" user.email t@t
git config --file "$T/gitconfig" user.name t
git config --file "$T/gitconfig" init.defaultBranch main
git config --file "$T/gitconfig" uploadpack.allowFilter true
export MEMORY_STORE_THROTTLE_MS=0 MEMORY_STORE_UNSYNCED_AGE_MS=0

# --- fixtures ------------------------------------------------------------------------------------
fresh() { # (re)build upstream, store, session and config root
  rm -rf "$T/up.git" "$T/author" "$T/store" "$T/session" "$T/roots"
  git init -q --bare "$T/up.git"
  git clone -q "file://$T/up.git" "$T/author" 2>/dev/null
  mkdir -p "$T/author/.claude/memory" "$T/author/src"
  printf 'a1\n' > "$T/author/.claude/memory/a.md"
  printf 'c1\n' > "$T/author/.claude/memory/c.md"
  printf 'code\n' > "$T/author/src/x.ts"
  (cd "$T/author" && git add -A && git commit -qm seed && git push -q origin main)
  git clone -q --filter=blob:none --sparse "file://$T/up.git" "$T/store" 2>/dev/null
  (cd "$T/store" && git sparse-checkout set .claude/memory && git config claude.memoryStore true)
  git clone -q "file://$T/up.git" "$T/session" 2>/dev/null
  mkdir -p "$T/roots/.claude/projects/p"
  ln -s "$T/store/.claude/memory" "$T/roots/.claude/projects/p/memory"
}
upstream_commit() { # message, then shell run inside the author clone
  (cd "$T/author" && eval "$2" && git add -A && git commit -qm "$1" && git push -q origin main)
}
run_hook() { # cwd -> stdout in $OUT, exit in $RC
  OUT="$(cd "$1" && MEMORY_STORE_CONFIG_ROOTS="$T/roots/.claude" node "$HOOK")"; RC=$?
}
head_of() { git -C "$1" rev-parse HEAD; }
up_head() { git -C "$T/up.git" rev-parse main; }

# 1. nothing to do -> silent
fresh
run_hook "$T/session"
check "up to date: exit 0" '[ "$RC" -eq 0 ]'
check "up to date: silent" '[ -z "$OUT" ]'

# 2. upstream adds b.md and the store already has the SAME bytes untracked -> adopted, fast-forwarded
fresh
printf 'b1\n' > "$T/store/.claude/memory/b.md"
upstream_commit add-b "printf 'b1\n' > .claude/memory/b.md"
run_hook "$T/session"
check "adopt untracked: HEAD reaches upstream" '[ "$(head_of "$T/store")" = "$(up_head)" ]'
check "adopt untracked: tree clean" '[ -z "$(git -C "$T/store" status --porcelain)" ]'
check "adopt untracked: silent" '[ -z "$OUT" ]'
check "adopt untracked: sparse cone kept src/ out" '[ ! -e "$T/store/src/x.ts" ]'

# 2b. twin: same path, DIFFERENT bytes -> refused, bytes untouched, reported
fresh
printf 'mine\n' > "$T/store/.claude/memory/b.md"
before="$(head_of "$T/store")"
upstream_commit add-b "printf 'b1\n' > .claude/memory/b.md"
run_hook "$T/session"
check "conflict untracked: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "conflict untracked: local bytes kept" '[ "$(cat "$T/store/.claude/memory/b.md")" = mine ]'
check "conflict untracked: reported by path" 'printf "%s" "$OUT" | grep -q "NOT updated.*\.claude/memory/b.md"'
check "conflict untracked: exit 0" '[ "$RC" -eq 0 ]'

# 3. upstream modifies a.md and the store has the same modification -> adopted
fresh
printf 'a2\n' > "$T/store/.claude/memory/a.md"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "adopt modified: HEAD reaches upstream" '[ "$(head_of "$T/store")" = "$(up_head)" ]'
check "adopt modified: tree clean" '[ -z "$(git -C "$T/store" status --porcelain)" ]'

# 3b. twin: modified differently -> refused
fresh
printf 'a-mine\n' > "$T/store/.claude/memory/a.md"
before="$(head_of "$T/store")"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "conflict modified: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "conflict modified: local bytes kept" '[ "$(cat "$T/store/.claude/memory/a.md")" = a-mine ]'

# 4. upstream deletes c.md and the store deleted it too -> adopted
fresh
rm "$T/store/.claude/memory/c.md"
upstream_commit del-c "git rm -q .claude/memory/c.md"
run_hook "$T/session"
check "adopt deletion: HEAD reaches upstream" '[ "$(head_of "$T/store")" = "$(up_head)" ]'
check "adopt deletion: tree clean" '[ -z "$(git -C "$T/store" status --porcelain)" ]'

# 4b. twin: upstream deletes c.md but the store EDITED it -> refused, edit kept
fresh
printf 'c-edit\n' > "$T/store/.claude/memory/c.md"
before="$(head_of "$T/store")"
upstream_commit del-c "git rm -q .claude/memory/c.md"
run_hook "$T/session"
check "conflict delete-vs-edit: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "conflict delete-vs-edit: edit kept" '[ "$(cat "$T/store/.claude/memory/c.md")" = c-edit ]'

# 5. an unrelated local note does not block the pull, and is reported as unsynced
fresh
printf 'e1\n' > "$T/store/.claude/memory/e.md"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "unsynced: HEAD reaches upstream" '[ "$(head_of "$T/store")" = "$(up_head)" ]'
check "unsynced: note kept untracked" '[ "$(git -C "$T/store" status --porcelain)" = "?? .claude/memory/e.md" ]'
check "unsynced: reported" 'printf "%s" "$OUT" | grep -q "1 memory note(s).*new here: \`.claude/memory/e.md\`"'

# 5b. the report goes only to sessions of the SAME repository
other="$T/other"; rm -rf "$other"; git init -q "$other"; git -C "$other" remote add origin "file://$T/elsewhere.git"
printf 'e1\n' > "$T/store/.claude/memory/e.md"
run_hook "$other"
check "unsynced: silent in another repository" '[ -z "$OUT" ]'
run_hook "$T"
check "unsynced: silent outside any repository" '[ -z "$OUT" ] && [ "$RC" -eq 0 ]'

# 6. a local commit in the store -> refused, reported
fresh
(cd "$T/store" && printf 'l\n' > .claude/memory/l.md && git add .claude/memory/l.md && git commit -qm local)
before="$(head_of "$T/store")"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "local commit: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "local commit: reported" 'printf "%s" "$OUT" | grep -q "has commits that are not on"'
check "local commit: names the committed note" 'printf "%s" "$OUT" | grep -q "touch \`.claude/memory/l.md\`"'
store_real="$(cd "$T/store" && pwd -P)"
check "local commit: names the safe reset, path quoted" 'printf "%s" "$OUT" | grep -qF "git -C '"'"'$store_real'"'"' reset --keep origin/main"'

# 7. a store WITHOUT the opt-in marker is never touched
fresh
git -C "$T/store" config --unset claude.memoryStore
before="$(head_of "$T/store")"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "not opted in: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "not opted in: no fetch happened" '[ "$(git -C "$T/store" rev-parse origin/main)" = "$before" ]'
check "not opted in: silent" '[ -z "$OUT" ]'
# positive control for 7: the same fixture WITH the marker does move
git -C "$T/store" config claude.memoryStore true
run_hook "$T/session"
check "control: opted in, the same store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'

# 7b. a GLOBAL (not local) marker does not opt a store in
fresh
git -C "$T/store" config --unset claude.memoryStore
git config --file "$T/gitconfig" claude.memoryStore true
before="$(head_of "$T/store")"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "global marker: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
git config --file "$T/gitconfig" --unset claude.memoryStore

# 7c. GIT_DIR inherited from the caller does not redirect the hook to another repository
fresh
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
OUT="$(cd "$T/session" && GIT_DIR="$T/session/.git" MEMORY_STORE_CONFIG_ROOTS="$T/roots/.claude" node "$HOOK")"
check "inherited GIT_DIR: store still moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'

# 7d. the hook runs when registered through a symlinked path
fresh
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
ln -sf "$HOOK" "$T/linked-hook.mjs"
OUT="$(cd "$T/session" && MEMORY_STORE_CONFIG_ROOTS="$T/roots/.claude" node "$T/linked-hook.mjs")"
check "symlinked entry: store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'

# 7e. a held index.lock is reported and leaves HEAD alone; once cleared, the store moves
fresh
printf 'b1\n' > "$T/store/.claude/memory/b.md"
upstream_commit add-b "printf 'b1\n' > .claude/memory/b.md"
before="$(head_of "$T/store")"
: > "$T/store/.git/index.lock"
run_hook "$T/session"
check "index.lock: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "index.lock: reported with git's reason" 'printf "%s" "$OUT" | grep -q "could not be updated; git said:.*index.lock"'
check "index.lock: exit 0" '[ "$RC" -eq 0 ]'
OUT="$(cd "$T/session" && MEMORY_STORE_THROTTLE_MS=3600000 MEMORY_STORE_CONFIG_ROOTS="$T/roots/.claude" node "$HOOK")"
check "index.lock: failure re-reported while throttled" 'printf "%s" "$OUT" | grep -q "could not be updated"'
rm -f "$T/store/.git/index.lock"
run_hook "$T/session"
check "index.lock control: cleared, store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ] && [ -z "$OUT" ]'

# 7f. a detached HEAD is refused and reported; back on the branch, the store moves
fresh
git -C "$T/store" checkout -q --detach
before="$(head_of "$T/store")"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "detached: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "detached: reported with the switch command" 'printf "%s" "$OUT" | grep -q "has a detached HEAD.*switch main"'
git -C "$T/store" checkout -q main
run_hook "$T/session"
check "detached control: on main, store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'

# 7g. a branch following a DIFFERENT upstream branch is refused
fresh
git -C "$T/store" branch -q --set-upstream-to=origin/main main
git -C "$T/store" checkout -q -b notes
git -C "$T/store" branch -q --set-upstream-to=origin/main notes
before="$(head_of "$T/store")"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "foreign upstream: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "foreign upstream: reported" 'printf "%s" "$OUT" | grep -q "branch \`notes\`, which follows \`origin/main\` instead.*switch main"'

# 7h. an adopted path with glob characters stages only itself
fresh
upstream_commit add-n1 "printf 'n1\n' > .claude/memory/n1.md"
run_hook "$T/session"
printf 'n1-local\n' > "$T/store/.claude/memory/n1.md"
printf 'nb\n' > "$T/store/.claude/memory/n[1].md"
upstream_commit add-nb "printf 'nb\n' > '.claude/memory/n[1].md'"
run_hook "$T/session"
check "literal pathspec: store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'
check "literal pathspec: n1.md left unstaged" '[ "$(git -C "$T/store" status --porcelain)" = " M .claude/memory/n1.md" ]'

# 7i. unsynced listing: backups hidden, a long list truncated, a fresh note held back
fresh
for i in 1 2 3 4 5 6 7 8 9 10; do printf 'u\n' > "$T/store/.claude/memory/u$i.md"; done
printf 'x\n' > "$T/store/.claude/memory/MEMORY.md.bak-x"
printf 'x\n' > "$T/store/.claude/memory/old.bak"
run_hook "$T/session"
check "unsynced: backups not counted" 'printf "%s" "$OUT" | grep -q "10 memory note(s)"'
check "unsynced: backups not named" '! printf "%s" "$OUT" | grep -q "bak"'
check "unsynced: list truncated" 'printf "%s" "$OUT" | grep -q "and 2 more"'
fresh
printf 'y\n' > "$T/store/.claude/memory/young.md"
printf 'o\n' > "$T/store/.claude/memory/old.md"
touch -t 202001010000 "$T/store/.claude/memory/old.md"
OUT="$(cd "$T/session" && MEMORY_STORE_UNSYNCED_AGE_MS=3600000 MEMORY_STORE_CONFIG_ROOTS="$T/roots/.claude" node "$HOOK")"
check "unsynced age: old note listed" 'printf "%s" "$OUT" | grep -q "1 memory note(s).*old.md"'
check "unsynced age: young note held back" '! printf "%s" "$OUT" | grep -q "young.md"'

# 7j. a branch with no upstream is refused with the set-upstream command; once set, the store moves
fresh
git -C "$T/store" branch -q --unset-upstream
before="$(head_of "$T/store")"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "no upstream: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "no upstream: reported with the repair" 'printf "%s" "$OUT" | grep -q "follows no upstream branch.*--set-upstream-to=origin/main"'
git -C "$T/store" branch -q --set-upstream-to=origin/main main
run_hook "$T/session"
check "no upstream control: set, store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'

# 7k. a deleted remote-tracking ref is recreated by the fetch instead of blocking every run
fresh
git -C "$T/store" update-ref -d refs/remotes/origin/main
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "missing tracking ref: store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ] && [ -z "$OUT" ]'
# ...even when the configured fetch refspec does not cover this branch, which is what makes the
# hook's explicit refspec necessary rather than decorative.
fresh
git -C "$T/store" config remote.origin.fetch '+refs/heads/other:refs/remotes/origin/other'
git -C "$T/store" update-ref -d refs/remotes/origin/main
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "foreign refspec: store still moves" '[ "$(head_of "$T/store")" = "$(up_head)" ] && [ -z "$OUT" ]'

# 7l. a tag named like the branch does not make the store look detached
fresh
git -C "$T/store" tag main
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "tag named main: store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ] && [ -z "$OUT" ]'

# 7m. an inherited GIT_CONFIG does not make every store look unmarked
fresh
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
OUT="$(cd "$T/session" && GIT_CONFIG="$T/gitconfig" MEMORY_STORE_CONFIG_ROOTS="$T/roots/.claude" node "$HOOK")"
check "inherited GIT_CONFIG: store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'

# 7n. edited and deleted notes are described as such, not as missing upstream
fresh
printf 'a-edit\n' > "$T/store/.claude/memory/a.md"
rm "$T/store/.claude/memory/c.md"
run_hook "$T/session"
check "unsynced kinds: edited and deleted named" 'printf "%s" "$OUT" | grep -q "2 memory note(s).*edited here: \`.claude/memory/a.md\`; deleted here: \`.claude/memory/c.md\`"'
check "unsynced kinds: nothing called new" '! printf "%s" "$OUT" | grep -q "new here"'

# 7o. a report reaches a session whose remote is spelled differently, or whose store remote has another name
fresh
printf 'mine\n' > "$T/store/.claude/memory/b.md"
upstream_commit add-b "printf 'b1\n' > .claude/memory/b.md"
git -C "$T/session" remote set-url origin "$T/up.git/"
run_hook "$T/session"
check "remote spelling: conflict reported" 'printf "%s" "$OUT" | grep -q "NOT updated"'
fresh
printf 'mine\n' > "$T/store/.claude/memory/b.md"
upstream_commit add-b "printf 'b1\n' > .claude/memory/b.md"
git -C "$T/store" remote rename origin upstream
run_hook "$T/session"
check "remote named upstream: conflict reported" 'printf "%s" "$OUT" | grep -q "NOT updated.*upstream/main"'

# 7p. a note name outside ASCII is shown as written
fresh
(cd "$T/store" && printf 'l\n' > .claude/memory/é.md && git add .claude/memory/é.md && git commit -qm local)
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
run_hook "$T/session"
check "non-ASCII committed note: named as written" 'printf "%s" "$OUT" | grep -q "touch \`.claude/memory/é.md\`"'

# 7q. sessions starting together: none reports a false failure, and the store moves
for trial in 1 2 3; do
  fresh
  upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
  for k in 1 2 3 4; do
    (cd "$T/session" && MEMORY_STORE_CONFIG_ROOTS="$T/roots/.claude" node "$HOOK" > "$T/par$k.out" 2>&1) &
  done
  wait
  check "burst $trial: store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'
  check "burst $trial: no false failure" '! cat "$T"/par*.out | grep -q "could not be updated"'
  check "burst $trial: lock released" '[ ! -e "$T/store/.git/claude-memory-refresh.lock" ]'
done

# 7r. a live lock skips the store quietly; a stale one is broken
fresh
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
before="$(head_of "$T/store")"
: > "$T/store/.git/claude-memory-refresh.lock"
run_hook "$T/session"
check "live lock: HEAD unchanged, silent" '[ "$(head_of "$T/store")" = "$before" ] && [ -z "$OUT" ]'
touch -t 202001010000 "$T/store/.git/claude-memory-refresh.lock"
run_hook "$T/session"
check "stale lock: broken, store moves" '[ "$(head_of "$T/store")" = "$(up_head)" ]'

# 8. throttle: inside the window no fetch happens, and a standing refusal is re-reported
fresh
printf 'mine\n' > "$T/store/.claude/memory/b.md"
upstream_commit add-b "printf 'b1\n' > .claude/memory/b.md"
MEMORY_STORE_THROTTLE_MS=0 run_hook "$T/session"
first_fetch="$(git -C "$T/store" rev-parse origin/main)"
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
OUT="$(cd "$T/session" && MEMORY_STORE_THROTTLE_MS=3600000 MEMORY_STORE_CONFIG_ROOTS="$T/roots/.claude" node "$HOOK")"
check "throttled: no second fetch" '[ "$(git -C "$T/store" rev-parse origin/main)" = "$first_fetch" ]'
check "throttled: refusal re-reported" 'printf "%s" "$OUT" | grep -q "NOT updated"'

# 9. a broken store fails open
fresh
rm -rf "$T/store/.git/objects"
run_hook "$T/session"
check "broken store: exit 0" '[ "$RC" -eq 0 ]'

# 9b. an unreachable remote is reported with git's reason, and HEAD stays put
fresh
upstream_commit mod-a "printf 'a2\n' > .claude/memory/a.md"
before="$(head_of "$T/store")"
mv "$T/up.git" "$T/up.git.off"
run_hook "$T/session"
mv "$T/up.git.off" "$T/up.git"
check "unreachable remote: HEAD unchanged" '[ "$(head_of "$T/store")" = "$before" ]'
check "unreachable remote: reported" 'printf "%s" "$OUT" | grep -q "could not be updated; git said:"'
check "unreachable remote: exit 0" '[ "$RC" -eq 0 ]'

# 10. the pure decision, both directions, driven through the exported function
node --input-type=module -e "
import { planRefresh, sshEnv, normalizeRemote } from '$HOOK';
const inc = new Map([['a', { status: 'M', blob: 'x' }], ['d', { status: 'D', blob: null }]]);
const cases = [
  [planRefresh(inc, [{ path: 'a', xy: ' M', blob: 'x' }], true).action, 'ff'],
  [planRefresh(inc, [{ path: 'a', xy: ' M', blob: 'y' }], true).action, 'refuse'],
  [planRefresh(inc, [{ path: 'a', xy: ' D', blob: null }], true).action, 'refuse'],
  [planRefresh(inc, [{ path: 'd', xy: ' D', blob: null }], true).action, 'ff'],
  [planRefresh(inc, [{ path: 'd', xy: ' M', blob: 'z' }], true).action, 'refuse'],
  [planRefresh(inc, [{ path: 'a', xy: 'UU', blob: 'x' }], true).action, 'refuse'],
  [planRefresh(inc, [{ path: 'a', xy: 'AA', blob: 'x' }], true).action, 'refuse'],
  [planRefresh(inc, [{ path: 'd', xy: 'DD', blob: null }], true).action, 'refuse'],
  [planRefresh(inc, [], false).reason, 'local-commits'],
  [planRefresh(new Map(), [{ path: 'q', xy: '??', blob: 'q' }], true).action, 'up-to-date'],
  [planRefresh(new Map(), [{ path: 'q', xy: '??', blob: 'q' }], true).unsynced.map((e) => e.path).join(), 'q'],
];
const ssh = (env, conf) => sshEnv(env, conf).GIT_SSH_COMMAND;
cases.push(
  [ssh({}, null), 'ssh -o BatchMode=yes -o ConnectTimeout=5'],
  [ssh({}, 'ssh -i k'), 'ssh -i k -o BatchMode=yes -o ConnectTimeout=5'],
  [ssh({ GIT_SSH_COMMAND: 'mine' }, 'ssh -i k'), 'mine'],
  [ssh({ GIT_SSH: '/bin/x' }, 'ssh -i k'), undefined],
  [normalizeRemote('git@GitHub.com:o/r.git'), 'github.com/o/r'],
  [normalizeRemote('https://github.com/o/r/'), 'github.com/o/r'],
  [normalizeRemote('ssh://git@github.com:22/o/r.git'), 'github.com/o/r'],
  [normalizeRemote('file:///p/Up.git'), '/p/Up'],
  [normalizeRemote('/p/Up.git/'), '/p/Up'],
  [normalizeRemote('https://github.com/o/r') === normalizeRemote('https://github.com/o/other'), false],
);
const bad = cases.filter(([got, want]) => got !== want);
if (bad.length) { console.error(JSON.stringify(bad)); process.exit(1) }
" && ok "pure functions: 21 cases" || bad "planRefresh: decision cases"

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
