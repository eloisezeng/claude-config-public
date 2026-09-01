#!/usr/bin/env bash
#
# Back up "global" (cross-project) Claude memories into this repo.
#
# A memory is backed up iff its frontmatter carries `scope: global`. Such files
# are MOVED into memories/<root>/<projectdir>/<file> and replaced in place with a
# symlink, so the repo becomes the single source of truth and ordinary edits to
# the memory write straight through to the tracked file.
#
# Per-project state memories (no `scope: global`) are left untouched and local.
#
# Safe to run anytime: idempotent, fast, no-ops when nothing is newly global.
#
# FAILURE VISIBILITY (2026-08-19): the Stop hook runs this under
# `>/dev/null 2>&1 || true`, so without the trap below any failure would be
# perfectly silent — the same failure class that let the config sync rot for
# three days. On non-Mac boxes a nonzero exit emails you@example.edu,
# rate-limited to one mail per 12h.

_sm_fail_alert() {
  local rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$(uname)" != "Darwin" ] && command -v mail >/dev/null 2>&1; then
    local stamp="${TMPDIR:-/tmp}/claude-config-syncmem-mail.stamp"
    local last=0 now; now="$(date +%s)"
    [ -e "$stamp" ] && last="$(stat -c %Y "$stamp" 2>/dev/null || echo 0)"
    if [ $(( now - last )) -gt 43200 ]; then
      printf 'sync-memories.sh FAILED (rc=%s) on %s — global memories are not being routed into claude-config until this is fixed.\n' \
        "$rc" "$(hostname)" \
        | mail -s "claude-config sync-memories FAILED on $(hostname)" \
            you@example.edu >/dev/null 2>&1 && touch "$stamp"
    fi
  fi
  return "$rc"
}
trap _sm_fail_alert EXIT
# Pushing is handled separately by the launchd watcher (memories/ is in its
# WatchPaths) — this script only does the move+symlink.
#
# Restore on a fresh machine is handled by install.sh (re-creates the symlinks).

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin"

REPO="$HOME/dotfiles/claude"
MEM_ROOT="$REPO/memories"
LOG="$HOME/Library/Logs/claude-config-autopush.log"

log() { { echo "[$(date '+%Y-%m-%d %H:%M:%S')] sync-memories: $*" >>"$LOG"; } 2>/dev/null; }

is_global() {
  # True only if the YAML FRONTMATTER (between the first two --- delimiters)
  # declares scope: global. Scoping to frontmatter avoids misclassifying a memory
  # whose body merely mentions a `scope: global` line (e.g. in a code block).
  # Decide ONLY in END: in awk a mid-stream `exit` still runs END, so any END
  # `exit` would override it. global iff there is an opening ---, a closing ---,
  # and a `scope: global` line strictly between them.
  awk '
    NR==1 { if ($0 !~ /^---[[:space:]]*$/) nofm=1; next }
    !closed && /^---[[:space:]]*$/ { closed=1; next }
    !closed && /^[[:space:]]*scope:[[:space:]]*global[[:space:]]*$/ { found=1 }
    END { exit (!nofm && closed && found ? 0 : 1) }
  ' "$1"
}

warn_unindexed() {
  # The injection hook reads ONLY the index, so a global body with no pointer
  # line would never load. Warn (stderr + log) rather than silently rewrite it.
  local file="$1" index="$2"
  if ! { [ -f "$index" ] && grep -qF "($file)" "$index"; }; then
    echo "sync-memories: UNINDEXED global/$file — add a pointer to memories/global/MEMORY.md" >&2
    log "UNINDEXED global/$file (no pointer in MEMORY.md)"
  fi
}

for root in claude claude1; do
  base="$HOME/.$root/projects"
  [ -d "$base" ] || continue

  # Iterate real (non-symlink) memory files, excluding the per-project index.
  while IFS= read -r f; do
    [ -L "$f" ] && continue          # already backed up (symlink into repo)
    is_global "$f" || continue       # not tagged global -> leave it local

    # .../projects/<projectdir>/memory/<file>  ->  flat global store
    file="$(basename "$f")"
    dest="$MEM_ROOT/global/$file"        # FLAT global namespace
    index="$MEM_ROOT/global/MEMORY.md"

    if [ -e "$dest" ]; then
      if cmp -s "$f" "$dest"; then
        rm -f "$f"                        # identical already in store: drop local, no symlink
        log "deduped (already global) global/$file"
        warn_unindexed "$file" "$index"   # body is in the store but may not be indexed yet
      else
        log "CONFLICT (skipped, repo differs): global/$file"
      fi
      continue
    fi

    mkdir -p "$(dirname "$dest")"
    mv "$f" "$dest"                        # move into store; NO symlink-back
    log "promoted global/$file"
    warn_unindexed "$file" "$index"
  done < <(find "$base" -type f -path '*/memory/*.md' ! -name 'MEMORY.md' 2>/dev/null)
done
