#!/usr/bin/env bash
# bin/refresh-plugin-manifests.mjs must produce the SAME BYTES on every machine,
# and must refuse rather than emit an empty manifest.
#
# WHY THIS EXISTS. The repo used to carry a verbatim copy of Claude Code's live
# plugin cache record. Measured 2026-09-09, the committed copy held three entries
# under a SECOND machine's home directory next to this machine's own -- because
# `installPath` is absolute, so whichever box committed last overwrote the
# other's paths. Left alone with a sync daemon on both machines, that is an
# unbounded commit loop: every sync produces a diff, every diff a commit, and the
# two never converge. The normalizer exists to make the output independent of the
# machine that ran it, and machine-independence is the property this test pins --
# not the file's content, which is allowed to change whenever a plugin is added.
#
# Everything runs against a SCRATCH copy: the real repo auto-commits, so a
# deliberately broken input must never be written inside it.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
GEN="$REPO/bin/refresh-plugin-manifests.mjs"
fail=0
t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT

# A scratch "repo" holding only the generator and the directory it writes into.
mkdir -p "$t/repo/bin" "$t/repo/plugins"
cp "$GEN" "$t/repo/bin/"
GENC="$t/repo/bin/$(basename "$GEN")"

# Two live directories describing the SAME installation on two different
# machines: same marketplaces, same plugins, different homes, different cache
# shas, different timestamps, different key order.
mk_live() { # mk_live <dir> <home> <sha> <ts>
  mkdir -p "$1"
  cat > "$1/known_marketplaces.json" <<JSON
{"version":1,"marketplaces":{
  "zeta":{"source":{"source":"github","repo":"acme/zeta"},"installLocation":"$2/.claude/plugins/marketplaces/zeta","lastUpdated":"$4"},
  "alpha":{"source":{"source":"github","repo":"acme/alpha"},"installLocation":"$2/.claude/plugins/marketplaces/alpha","lastUpdated":"$4"}}}
JSON
  cat > "$1/installed_plugins.json" <<JSON
{"version":2,"plugins":{
  "two@zeta":[{"scope":"user","installPath":"$2/.claude/plugins/cache/zeta/two/$3","version":"$3","installedAt":"$4","lastUpdated":"$4","gitCommitSha":"$3"}],
  "one@alpha":[{"scope":"user","installPath":"$2/.claude/plugins/cache/alpha/one/$3","version":"$3","installedAt":"$4","lastUpdated":"$4"}]}}
JSON
}

run() { CLAUDE_CONFIG_DIR="$1" node "$GENC" >/dev/null 2>&1; }

mk_live "$t/macA/plugins"    /Users/someone   aaaaaaaaaaaa 2026-01-01T00:00:00.000Z
mk_live "$t/boxB/plugins"    /home/otheruser  bbbbbbbbbbbb 2026-09-09T23:59:59.000Z

# --- 1. machine independence: the two machines must write identical bytes -----
run "$t/macA"; cp "$t/repo/plugins/installed_plugins.json" "$t/A.json"; cp "$t/repo/plugins/known_marketplaces.json" "$t/A.mk"
run "$t/boxB"; cp "$t/repo/plugins/installed_plugins.json" "$t/B.json"; cp "$t/repo/plugins/known_marketplaces.json" "$t/B.mk"
if ! cmp -s "$t/A.json" "$t/B.json" || ! cmp -s "$t/A.mk" "$t/B.mk"; then
  echo "FAIL: two machines with the same plugins produced DIFFERENT manifests -- each sync would overwrite the other forever"
  diff "$t/A.json" "$t/B.json"; diff "$t/A.mk" "$t/B.mk"
  fail=1
fi

# --- 2. positive control: the comparison above can actually fail --------------
# Without this, a generator that wrote a fixed empty file would pass step 1.
# The control asserts the fixtures really do differ at the source.
if cmp -s "$t/macA/plugins/installed_plugins.json" "$t/boxB/plugins/installed_plugins.json"; then
  echo "FAIL[control]: the two fixtures are identical, so step 1 proves nothing"; fail=1
fi

# --- 3. no machine-local path may survive into the manifest -------------------
if grep -qE '/Users/|/home/|[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$t/A.json" "$t/A.mk"; then
  echo "FAIL: a home path or a timestamp survived normalization:"
  grep -nE '/Users/|/home/|[0-9]{4}-[0-9]{2}-[0-9]{2}T' "$t/A.json" "$t/A.mk"
  fail=1
fi

# --- 4. the set is preserved in both directions ------------------------------
got="$(python3 -c "import json;print(' '.join(sorted(json.load(open('$t/A.json'))['plugins'])))" 2>/dev/null)"
[ "$got" = "one@alpha two@zeta" ] || { echo "FAIL: plugin set became '$got', expected 'one@alpha two@zeta'"; fail=1; }

# --- 5. idempotence ----------------------------------------------------------
run "$t/macA"
cmp -s "$t/repo/plugins/installed_plugins.json" "$t/A.json" || { echo "FAIL: running the generator twice changed the output"; fail=1; }

# --- 6. fail CLOSED: never write an empty manifest ---------------------------
# An empty manifest reads exactly like "this setup uses no plugins" and would
# delete the record of every one of them.
for bad in '{"version":1,"marketplaces":{}}|empty marketplaces' '{"version":1' 'not json at all'; do
  body="${bad%%|*}"
  mkdir -p "$t/bad/plugins"
  cp "$t/macA/plugins/installed_plugins.json" "$t/bad/plugins/"
  printf '%s' "$body" > "$t/bad/plugins/known_marketplaces.json"
  if run "$t/bad"; then echo "FAIL: generator ACCEPTED a broken known_marketplaces.json (${bad##*|})"; fail=1; fi
  cmp -s "$t/repo/plugins/installed_plugins.json" "$t/A.json" \
    || { echo "FAIL: a refused run still modified the manifest (${bad##*|})"; fail=1; cp "$t/A.json" "$t/repo/plugins/installed_plugins.json"; }
done
rm -rf "$t/nothing"; mkdir -p "$t/nothing"
if run "$t/nothing"; then echo "FAIL: generator accepted a config dir with no plugins/ at all"; fail=1; fi

# --- 7. --check reports staleness without writing ----------------------------
run "$t/macA"
CLAUDE_CONFIG_DIR="$t/macA" node "$GENC" --check >/dev/null 2>&1 || { echo "FAIL: --check called a fresh manifest stale"; fail=1; }
printf '{"version":1,"plugins":{}}' > "$t/repo/plugins/installed_plugins.json"
if CLAUDE_CONFIG_DIR="$t/macA" node "$GENC" --check >/dev/null 2>&1; then
  echo "FAIL: --check passed over a manifest that does not match the machine"; fail=1
fi
grep -q '"one@alpha"' "$t/repo/plugins/installed_plugins.json" && { echo "FAIL: --check WROTE to the manifest"; fail=1; }

# --- 8. two machines with DIFFERENT plugin sets must CONVERGE, not alternate ---
# The steps above compare machines that have the SAME plugins installed, so they
# only ever pinned the output's FORMAT. The live failure was a difference in the
# SET: measured 2026-09-09, this Mac had `mattpocock-skills@mattpocock` and
# `claude-mem@thedotmack` and the box sharing this repo did not, so the two sides
# alternately added and removed the same ten lines -- 13 commits in 86 minutes,
# never converging. A generator that REPLACES the manifest with its own machine's
# set cannot pass this section; one that UNIONS can.
r2="$t/repo2"
mkdir -p "$r2/bin" "$r2/plugins"
cp "$GEN" "$r2/bin/"
GEN2="$r2/bin/$(basename "$GEN")"
run2() { CLAUDE_CONFIG_DIR="$1" node "$GEN2" >/dev/null 2>&1; }
ip2() { python3 -c "import json;print(' '.join(sorted(json.load(open('$r2/plugins/installed_plugins.json'))['plugins'])))" 2>/dev/null; }
mk2() { # mk2 <dir> <home> — full set
  mkdir -p "$1"
  cat > "$1/known_marketplaces.json" <<JSON
{"version":1,"marketplaces":{
  "zeta":{"source":{"source":"github","repo":"acme/zeta"},"installLocation":"$2/z","lastUpdated":"2026-01-01T00:00:00.000Z"},
  "alpha":{"source":{"source":"github","repo":"acme/alpha"},"installLocation":"$2/a","lastUpdated":"2026-01-01T00:00:00.000Z"}}}
JSON
  cat > "$1/installed_plugins.json" <<JSON
{"version":2,"plugins":{
  "two@zeta":[{"scope":"user","installPath":"$2/t","version":"x"}],
  "one@alpha":[{"scope":"user","installPath":"$2/o","version":"x"}]}}
JSON
}
mk2partial() { # mk2partial <dir> <home> — a machine that never installed two@zeta
  mkdir -p "$1"
  cat > "$1/known_marketplaces.json" <<JSON
{"version":1,"marketplaces":{
  "alpha":{"source":{"source":"github","repo":"acme/alpha"},"installLocation":"$2/a","lastUpdated":"2026-09-09T23:59:59.000Z"}}}
JSON
  cat > "$1/installed_plugins.json" <<JSON
{"version":2,"plugins":{
  "one@alpha":[{"scope":"user","installPath":"$2/o","version":"y"}]}}
JSON
}
mk2        "$t/full/plugins" /Users/someone
mk2partial "$t/part/plugins" /home/otheruser

# control: the two fixtures really do differ in SET, so this section can fail.
if [ "$(python3 -c "import json;print(sorted(json.load(open('$t/full/plugins/installed_plugins.json'))['plugins']))")" \
   = "$(python3 -c "import json;print(sorted(json.load(open('$t/part/plugins/installed_plugins.json'))['plugins']))")" ]; then
  echo "FAIL[control]: the full and partial fixtures have the same plugin set, so section 8 proves nothing"; fail=1
fi

run2 "$t/full"; after_full="$(ip2)"
[ "$after_full" = "one@alpha two@zeta" ] || { echo "FAIL: the full machine wrote '$after_full', expected 'one@alpha two@zeta'"; fail=1; }
cp "$r2/plugins/installed_plugins.json" "$t/converged.json"

run2 "$t/part"; after_part="$(ip2)"
[ "$after_part" = "one@alpha two@zeta" ] \
  || { echo "FAIL: a machine without two@zeta DELETED it -- set became '$after_part'; the other machine will add it back and the two will alternate forever"; fail=1; }

# the marketplace it never installed must survive too
grep -q '"zeta"' "$r2/plugins/known_marketplaces.json" \
  || { echo "FAIL: the partial machine dropped the 'zeta' marketplace it never installed"; fail=1; }

# CONVERGENCE is the property: a second pass by either machine changes nothing.
run2 "$t/part"
cmp -s "$r2/plugins/installed_plugins.json" "$t/converged.json" || { echo "FAIL: the partial machine's second run still differed -- not converged"; fail=1; }
run2 "$t/full"
cmp -s "$r2/plugins/installed_plugins.json" "$t/converged.json" || { echo "FAIL: the full machine's run after the partial one produced a diff -- the sync loop is still live"; fail=1; }

# --- 9. --prune is the DELIBERATE way to remove, and a sync must never do it ---
run2 "$t/part"   # a plain run still keeps everything
[ "$(ip2)" = "one@alpha two@zeta" ] || { echo "FAIL: a plain run pruned"; fail=1; }
CLAUDE_CONFIG_DIR="$t/part" node "$GEN2" --prune >/dev/null 2>&1
pruned="$(ip2)"
[ "$pruned" = "one@alpha" ] || { echo "FAIL: --prune left '$pruned', expected only 'one@alpha'"; fail=1; }
grep -q '"zeta"' "$r2/plugins/known_marketplaces.json" && { echo "FAIL: --prune kept the 'zeta' marketplace"; fail=1; }
grep -q 'refresh-plugin-manifests.mjs --prune\|--prune' "$REPO/sync.sh" && { echo "FAIL: sync.sh passes --prune -- an unattended sync must never subtract"; fail=1; }

[ "$fail" -eq 0 ] && echo "PASS: plugin-manifest"
exit "$fail"
