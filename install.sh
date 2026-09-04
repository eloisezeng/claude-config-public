#!/usr/bin/env bash
#
# Symlinks this repo's Claude config into a Claude config directory.
#
# Usage:
#   ./install.sh                      # link repo -> ~/.claude
#   ./install.sh ~/.claude            # explicit primary dir
#   ./install.sh ~/.claude ~/.claude1 # also mirror a second dir onto the primary
#
# Re-running is safe: existing real files are backed up to <file>.bak-<n>,
# existing symlinks are replaced in place.

set -euo pipefail

# A LITERAL newline, used by every newline guard below. It has to be written this
# way: `$(printf '\n')` is the empty string, because command substitution strips
# trailing newlines — so a guard built on it matched every path and refused
# everything.
hook_nl='
'
# Its carriage-return twin. A path containing a CR is just as unencodable in a
# single-line hook command, and a CR-LF pair reaching a systemd unit ends the
# line early exactly as a bare LF does.
hook_cr=$'\r'

# pwd -P (physical): if install.sh is invoked through a symlinked path, the
# logical pwd would bake that alias into the launchd plist, the memory links,
# and the settings hook (appending a duplicate beside the canonical entry).
# The RAW spelling is checked first, before any command substitution touches it.
# `$(dirname "$x")` strips trailing newlines from its own result, so a script
# path whose directory component ends in one is already the wrong path by the
# time REPO_DIR is computed -- and no later check on REPO_DIR can recover what
# was thrown away. This one guard is deterministic and link-independent, which
# the `-ef` check below is not.
case "${BASH_SOURCE[0]}" in
  *"$hook_nl"*|*"$hook_cr"*)
    printf 'install: the path this script was invoked by spans lines (it contains a newline or carriage return) — refusing.\n' >&2
    exit 1 ;;
esac
# `x` is a SENTINEL, not decoration: `$(... pwd -P)` strips every trailing
# newline, so a repo directory whose name legitimately ends in one resolved to a
# DIFFERENT, existing sibling and the run installed that sibling's config
# (reproduced: `nl-repo` beside `nl-repo\n`, exit 0, the sibling's CLAUDE.md
# linked in). Printing a sentinel after the path makes the substitution's
# stripping a no-op; removing the sentinel and exactly one newline -- the one
# `pwd` itself emitted -- leaves the path byte-exact, newline and all, for the
# interior-newline refusal below to catch.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P && printf 'x')"
REPO_DIR="${REPO_DIR%x}"
REPO_DIR="${REPO_DIR%"$hook_nl"}"
# A newline in a path is not one problem but two, and both end here.
#
# TRAILING: a command substitution strips trailing newlines, so a repo directory
# whose name ends in one resolves to a path that is not this repo. Physical
# resolution cannot fix that — only a `cd` in this shell could, and that would
# move a cwd the rest of the script relies on. Checking that the resolved path
# merely CONTAINS an install.sh does not catch it either: the stripped sibling is
# an ordinary directory that may hold its own installer, and then the wrong
# repo's settings, hooks and watcher paths are what get installed (reproduced
# with `newline-repo` beside `newline-repo\n` — the run exited 0 and installed
# the sibling's CLAUDE.md). The question is not "is there an install.sh there"
# but "is it THIS install.sh", and `-ef` — same device and inode — is what
# answers it. It is a BELT, not the guard: `-ef` follows symlinks, so a link at
# the stripped sibling's install.sh pointing back at this one satisfies it while
# every other path in the run still comes from the wrong directory (reproduced;
# the run exited 0 and installed the sibling's CLAUDE.md). The two checks above
# — the raw-spelling refusal and the sentinel-preserved resolution — are what
# actually close the class; this one stays because it is cheap and catches a
# resolution that went wrong for some reason nobody has thought of yet.
if [[ ! -f "$REPO_DIR/install.sh" || ! "$REPO_DIR/install.sh" -ef "${BASH_SOURCE[0]}" ]]; then
  printf 'install: resolved the repo directory to %q, whose install.sh is not this script — refusing (a path component ending in a newline resolves to a different, existing sibling).\n' "$REPO_DIR" >&2
  exit 1
fi
# INTERIOR: a newline inside the path cannot be represented in a systemd unit
# (the line simply ends, and the remainder parses as another directive) and
# cannot be escaped into the single-line settings hook command at all. It was
# already refused, but only by portable_hook_cmd — i.e. after every link had been
# rewritten. Refuse it here, before anything is mutated.
case "$REPO_DIR" in
  *"$hook_nl"*)
    printf 'install: the repo path contains a newline — refusing (it cannot be encoded into a systemd unit or a hook command).\n' >&2
    exit 1 ;;
esac
PRIMARY="${1:-$HOME/.claude}"
MIRROR="${2:-}"

# Files/dirs to link from the repo into the primary config dir.
ITEMS=(CLAUDE.md AGENTS.md bin skills/email-drafter skills/codex-converge skills/codex-opinion skills/no-mistakes skills/scientific-figures)
# `bin` holds the fleet tooling (`fleet` and the helpers it execs). It is linked rather
# than copied because `~/.local/bin/fleet` is itself a symlink into it, so an edit made
# through either path lands in the repo and is version-controlled like everything else.

# settings.json is per-OS: hooks reference OS-specific tools (osascript on
# macOS, notify.sh on Linux), so a single shared file can't serve both. Each OS
# links its own source file to the same destination ($PRIMARY/settings.json).
# Add more branches here for future platforms.
# NOTE: this installer is unix-only (symlinks + launchd/systemd). Windows uses
# the PowerShell path (sync.ps1 / watch.ps1, copy-not-symlink per README); the
# settings.windows.json global-memory hook entry is maintained there, not here.
case "$(uname)" in
  Linux) SETTINGS_SRC="settings.linux.json" ;;
  *)     SETTINGS_SRC="settings.json" ;;   # macOS (Darwin) and fallback
esac

backup_if_real() {
  # If $1 is a real file/dir (not a symlink), move it aside.
  local path="$1"
  if [[ -e "$path" && ! -L "$path" ]]; then
    local n=1
    while [[ -e "$path.bak-$n" ]]; do n=$((n + 1)); done
    echo "  backing up existing $path -> $path.bak-$n"
    mv "$path" "$path.bak-$n"
  fi
}

# Every destructive step this installer takes is one `ln -sfn`, and all of them
# come through link(), so this is the ONE place a concrete (target, destination)
# pair can be judged against the filesystem AS IT IS AT ACT TIME. The roots
# preflight further down validates three DIRECTORIES before the first write; it
# cannot see either of the two ways that is not enough:
#
#   * a per-item destination that resolves somewhere else because a MIDDLE
#     component is a symlink -- a distinct PRIMARY whose `skills` is a link to
#     the repository's `skills`, so `$PRIMARY/skills/email-drafter` backs up the
#     repository's real skill and leaves a self-referential link in its place,
#     with every root check having passed (round-5 correctness #7);
#   * a MIRROR that was distinct when the preflight ran and is an alias of
#     PRIMARY by the time the mirror loop reaches it (round-5 lifecycle #15) --
#     and, with no concurrency at all, two roots that differ only in case on a
#     case-folding volume, which become one directory the moment `mkdir -p` runs
#     (the other half of round-5 correctness #6).
#
# Identity is asked of the FILESYSTEM (`-ef` is same-device-and-inode), never of
# the two spellings: that answers symlinked ancestors, unresolved `..`, hard
# links and case-folding volumes with one test, and the last of those no amount
# of string normalisation can decide.
link_refuses() { # <target> <linkpath> -> 0 (printing why) if this link must not be made
  local target="$1" linkpath="$2" tpar tname dpar dname dcanon
  tpar="${target%/*}";   tname="${target##*/}";   [[ "$tpar" == "$target" ]] && tpar="."
  dpar="${linkpath%/*}"; dname="${linkpath##*/}"; [[ "$dpar" == "$linkpath" ]] && dpar="."

  # (a) The same directory ENTRY: one parent directory, one name. `ln -sfn X X`
  # writes a symlink pointing at itself, over whatever X was.
  if [[ -d "$tpar" && -d "$dpar" && "$tpar" -ef "$dpar" && "$tname" == "$dname" ]]; then
    printf 'install: refusing to link %s -> %s: those are the same directory entry (%s and %s are one directory), so the link would point at itself and destroy the file. Nothing further was changed.\n' \
      "$linkpath" "$target" "$dpar" "$tpar" >&2
    return 0
  fi

  # (b) A destination that lands INSIDE the repository. Nothing in the repo is
  # ever a link destination, so a destination that resolves there means some
  # ancestor of it links back into the repo -- and installing would replace
  # tracked content with a link to itself even when the two names differ.
  if canon_dir "$dpar"; then
    dcanon="$CANON_DIR"
    if [[ "$dcanon" == "$REPO_DIR" || "$dcanon" == "$REPO_DIR"/* ]]; then
      printf 'install: refusing to link %s -> %s: the destination resolves inside the repository (%s), so an ancestor of it is a link back into the repo and installing would overwrite tracked content with a link to itself. Nothing further was changed.\n' \
        "$linkpath" "$target" "$dcanon" >&2
      return 0
    fi
  else
    printf 'install: cannot resolve %q while validating the link %s -> %s — refusing rather than writing into a directory whose identity is unknown.\n' \
      "$dpar" "$linkpath" "$target" >&2
    return 0
  fi
  return 1
}

link() {
  # link <target-absolute> <link-path>
  local target="$1" linkpath="$2"
  mkdir -p "$(dirname "$linkpath")"
  # Judged per pair, here, with fresh state -- see link_refuses. Stopping
  # part-way leaves a partial installation, which a re-run repairs; proceeding
  # destroys a file, which it does not.
  if link_refuses "$target" "$linkpath"; then
    exit 1
  fi
  backup_if_real "$linkpath"
  ln -sfn "$target" "$linkpath"
  echo "  $linkpath -> $target"
}

# Hook command for the tracked settings, written with a literal $HOME (hooks run
# through a shell, so it expands at runtime): the tracked settings files are
# shared across machines whose usernames differ, so no absolute home path may
# appear. Falls back to the absolute path only for a repo genuinely outside $HOME.
#
# BOTH paths are resolved physically BEFORE any prefix decision is taken. Two
# spellings break a naive comparison in opposite directions:
#   * the repo reached through a symlinked ANCESTOR (/var -> /private/var on
#     macOS, an automounted /home on clusters) is inside $HOME but does not look
#     it, so a literal comparison bakes a machine-specific absolute path into a
#     file shared across machines;
#   * a path that merely LOOKS like it is under $HOME ($HOME/shortcut -> an
#     out-of-home directory) is not, so emitting "$HOME/shortcut/..." produces a
#     settings file that works only on the host that happens to have that
#     shortcut. This is why the physical resolution cannot be a fallback after
#     the literal cases: a literal case that returns early is never corrected.
# The $HOME-relative form is emitted only when the PHYSICAL repo is a descendant
# of the PHYSICAL home; otherwise the physical absolute path is emitted, which is
# the spelling that survives being read on another mount.
#
# bash (not node) because Claude Code runs hooks with a minimal PATH where nvm's
# `node` does not resolve but `bash` (in /bin) always does.
# The path is interpolated into a DOUBLE-QUOTED shell command, so any character
# that would close that string or start an expansion has to be escaped, or the
# generated hook is unparsable and every SessionStart silently fails. The literal
# $HOME prefix is written by us and stays unescaped so it still expands.
shq_in_dq() { printf '%s' "$1" | sed -e 's/[\\"`$]/\\&/g'; }

# --- Encoding a path into a GENERATED configuration file ----------------------
# Three generated files carry this repo's path and each has its own grammar, so
# "it is already escaped over there" is never an answer. Enumerated with counts,
# because whether every site got encoded is not a question you can answer by
# looking at any one of them:
#   * launchd plist (XML)  — 27 interpolations: 1 Label, 1 ProgramArguments
#     script path, 23 WatchPaths, 2 log paths.  Encoder: xml_text.  The 23 is
#     ${#WATCH_ITEMS[@]} and both watchers loop over that ONE array, so this
#     count moves when the array does — see the WATCH_ITEMS comment below.
#   * systemd .service     — 1 interpolation: ExecStart.  Encoder: systemd_arg.
#     Left bare, a repo at `/repo space/` generates `ExecStart=/repo space/sync.sh`
#     whose executable token is `/repo`; the unit enables successfully and every
#     sync then fails, which is the worst shape a bug can have.
#   * systemd .path        — 23 interpolations: PathModified (same WATCH_ITEMS
#     array as the plist above).  Encoder: systemd_path.
#     These take a bare path and are NOT unquoted, so quoting them would make the
#     quote characters part of the watched path; only `%` needs doubling.
#   * settings.json hook   — 1 interpolation, encoded at its own choke point
#     (shq_in_dq inside jq): a shell word inside a JSON string is a fourth
#     grammar with a fourth encoder, which is why it is not in this list.
# A newline is refused up front (see $hook_nl) rather than encoded, because
# PathModified has no escape for one.
xml_text()     { printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }
systemd_path() { printf '%s' "$1" | sed -e 's/%/%%/g'; }
systemd_arg() {
  local a="$1"
  a="${a//\\/\\\\}"   # backslashes first, or they would escape the escapes
  a="${a//\"/\\\"}"
  a="${a//%/%%}"      # specifiers are expanded inside quotes too
  printf '"%s"' "$a"
}

portable_hook_cmd() {
  local repo="$1" home_p repo_p
  home_p="$(cd "$HOME" 2>/dev/null && pwd -P)" || home_p="$HOME"
  repo_p="$(cd "$repo" 2>/dev/null && pwd -P)" || repo_p="$repo"
  # A newline cannot be escaped into a single-line shell command at all, and one
  # here would split the hook into two commands. The installer already refuses
  # such a repo path up front (see $hook_nl); this stays because the function is
  # called directly by the tests and must not emit a broken command for anyone.
  case "$repo_p" in
    *"$hook_nl"*) echo "repo path contains a newline; refusing to generate a hook command: $repo_p" >&2; return 1 ;;
  esac
  case "$repo_p" in
    "$home_p"/*) printf 'bash "$HOME%s/inject-global-memory.sh"' "$(shq_in_dq "${repo_p#"$home_p"}")"; return ;;
  esac
  printf 'bash "%s/inject-global-memory.sh"' "$(shq_in_dq "$repo_p")"
}

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

# Report — never silently remove — an inject hook in the settings file that is
# not the one we just installed and whose script does not exist on this machine.
#
# The reviewer's recommendation was to RECONCILE such entries away. Refused, with
# a reason: this file is shared across machines, so an entry that is broken here
# may be the only working one somewhere else. Appending leaves a stale entry that
# prints an error on every SessionStart; removing it silently disables global
# memory on the machine that needed it, and two machines installing in turn would
# then delete each other's hook forever. Noise is the better failure, so the
# operator is told exactly what to delete and decides.
warn_stale_inject_hooks() { # $1 = settings file, $2 = the command we installed
  local settings="$1" cmd="$2" other path
  while IFS= read -r other; do
    [ -n "$other" ] || continue
    path="${other#*\"}"; path="${path%\"*}"        # the quoted script path
    case "$path" in '$HOME'*) path="$HOME${path#\$HOME}" ;; esac
    if [ -e "$path" ]; then continue; fi
    printf 'install: NOTE — %s also runs a global-memory hook whose script does not exist here:\n' "$settings" >&2
    printf 'install:   %s\n' "$other" >&2
    printf 'install:   left in place (another machine may need it). Delete it by hand if this repo moved.\n' >&2
  done < <(jq -r --arg cmd "$cmd" '
    .hooks.SessionStart[]?.hooks[]?
    | select((.command? // "") | test("inject-global-memory"))
    | select((.command? // "") != $cmd) | .command' "$settings" 2>/dev/null)
}

# Compare two directory paths by identity, not spelling: a config dir reached
# through a symlinked ancestor (/var -> /private/var) is the same dir.
# A path that does not exist YET still has an identity: the physical path of its
# deepest existing ancestor, plus the components below it. `|| a="$1"` used to
# fall back to the raw SPELLING instead, so two names for one not-yet-created
# directory (`$HOME/link/new` and `$HOME/real/new`, where `link` -> `real`)
# compared UNEQUAL and the mirror pass treated the primary as a distinct dir --
# `ln -sfn X X`, a self-referential broken symlink at CLAUDE.md, which is the
# exact damage the refusal above exists to prevent (reproduced).
#
# Written with parameter expansion rather than basename/dirname because those go
# through command substitution, which strips trailing newlines -- the same defect
# this file already carries one sentinel to avoid.

# Collapse `.` and `..` in a path TEXTUALLY. That is sound HERE and only here:
# canon_dir applies it to a physical prefix (`pwd -P`, so no symlink survives in
# it) followed by components that do not exist -- and `..` can only mean its
# lexical parent when there is no symlink for it to mean anything else.
#
# Without it, canon_dir re-appended the missing tail verbatim, so
# `$HOME/missing/../repo` and `$HOME/repo` compared DIFFERENT while naming the
# same directory the instant `mkdir -p` ran: the roots check passed and the
# install went on to replace the repository's own files with links to themselves
# (round-5 correctness #6).
LEXNORM=""
lexnorm() { # $1=path -> LEXNORM
  local _rest="${1#/}" _out="" _c
  while [[ -n "$_rest" ]]; do
    _c="${_rest%%/*}"
    if [[ "$_rest" == */* ]]; then _rest="${_rest#*/}"; else _rest=""; fi
    case "$_c" in
      ''|.) ;;
      ..)   _out="${_out%/*}" ;;
      *)    _out="$_out/$_c" ;;
    esac
  done
  LEXNORM="${_out:-/}"
}

CANON_DIR=""
canon_dir() { # $1=path -> CANON_DIR; 1 = undecidable
  local _p="$1" _rest="" _out _hop=0
  while [[ "$_p" == */ && "$_p" != "/" ]]; do _p="${_p%/}"; done
  [[ -n "$_p" ]] || _p="."
  while :; do
    if _out="$(cd "$_p" 2>/dev/null && pwd -P && printf 'x')"; then
      _out="${_out%x}"; _out="${_out%"$hook_nl"}"
      lexnorm "$_out$_rest"
      # A collapse can expose a path that DOES exist -- `$HOME/nope/../alias/x`
      # collapses onto `$HOME/alias/x`, and `alias` may be a symlink -- and on an
      # existing path only `pwd -P` may have the last word. So resolve again, and
      # only then answer. It terminates because lexnorm is idempotent: the second
      # pass cannot differ, so this branch is taken at most once per resolution.
      if [[ "$LEXNORM" != "$_out$_rest" ]]; then
        # The hop budget is shared with the walk-up deliberately: a path that
        # exhausts it has not been resolved, and answering with a half-normalised
        # spelling would be a decision. Undecidable is the answer every caller
        # already reads as "refuse".
        [[ "$_hop" -lt 256 ]] || { CANON_DIR=""; return 1; }
        _hop=$(( _hop + 1 )); _p="$LEXNORM"; _rest=""; continue
      fi
      # Past that branch $LEXNORM and "$_out$_rest" are the same string by
      # construction; this names which of them is the authority.
      CANON_DIR="$LEXNORM"
      return 0
    fi
    # Bounded: the only way `cd .` fails is a deleted cwd, and a walk that
    # cannot reach an existing ancestor must stop rather than spin.
    _hop=$(( _hop + 1 ))
    [[ "$_hop" -le 256 ]] || { CANON_DIR=""; return 1; }
    case "$_p" in
      /) CANON_DIR=""; return 1 ;;
      */*) _rest="/${_p##*/}$_rest"; _p="${_p%/*}"; [[ -n "$_p" ]] || _p="/" ;;
      *)   _rest="/$_p$_rest"; _p="." ;;
    esac
  done
}

# Compare two directory paths by identity, not spelling: a config dir reached
# through a symlinked ancestor (/var -> /private/var) is the same dir. An
# UNDECIDABLE comparison answers "same", because every caller reads true as
# "refuse" or "this dir is managed" -- both the conservative side.
same_dir() {
  local a b
  canon_dir "$1" || { printf 'install: cannot resolve %q (is the working directory gone?) — treating it as the same directory, which refuses rather than risks a self-overwriting link.\n' "$1" >&2; return 0; }
  a="$CANON_DIR"
  canon_dir "$2" || { printf 'install: cannot resolve %q (is the working directory gone?) — treating it as the same directory, which refuses rather than risks a self-overwriting link.\n' "$2" >&2; return 0; }
  b="$CANON_DIR"
  [ "$a" = "$b" ]
}

# Fail loudly if a config dir's active settings.json lacks the hook.
#   preflight_global_memory_hook <cmd> <dir-we-installed-into>...
# Scans the known profile dirs so a SECOND profile that has drifted is caught
# even when this run did not target it, with one distinction that matters:
#   * a dir this run installed into MUST have a settings.json — we just linked
#     one, so its absence is a real failure;
#   * a dir this run did NOT install into may exist purely as a side effect of
#     restoring memories ($HOME/.<root>/projects/... creates the parent and
#     nothing else). That is not a configured profile, so there is no hook to
#     check and no failure to report. Without this distinction the FIRST install
#     creates ~/.claude1/projects/... and every LATER install then aborts on
#     "preflight: ~/.claude1/settings.json missing" — after relinking
#     everything — which is how a re-run of an idempotent installer came to exit 1.
preflight_global_memory_hook() {
  local cmd="$1"; shift
  local cfg active m missing=0 managed
  for cfg in "$HOME/.claude" "$HOME/.claude1"; do
    [ -d "$cfg" ] || continue
    active="$cfg/settings.json"
    if [ ! -e "$active" ]; then
      managed=0
      for m in "$@"; do same_dir "$cfg" "$m" && { managed=1; break; }; done
      [ "$managed" = 1 ] && { echo "preflight: $active missing" >&2; missing=1; }
      continue
    fi
    if ! jq -e --arg cmd "$cmd" 'any(.hooks.SessionStart[]?.hooks[]?; (.command? // "") == $cmd)' "$active" >/dev/null; then
      echo "preflight: $active lacks global-memory hook ($cmd)" >&2; missing=1
    fi
  done
  return $missing
}

# Restore backed-up per-project memories as symlinks. Skips the flat global
# store, which the injection hook reads straight from the repo (never restored).
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

# Allow `source install.sh --source-only` to load functions without installing.
# NOTE: sourcing has already applied `set -euo pipefail` (line 13); callers should
# source in a subshell (`bash -c 'source install.sh --source-only; ...'`, as the
# tests do) so those stricter options don't leak into an interactive shell.
[ "${1:-}" = "--source-only" ] && return 0

# --- Validate the WHOLE target set before the first link ----------------------
# Everything below this point mutates: ITEMS are linked into PRIMARY, PRIMARY's
# links are linked into MIRROR, and the hook command is written into a TRACKED
# settings file that syncs to every machine. A check that fires part-way through
# has already destroyed part of the installation, so both of the things that can
# go wrong are decided here, while nothing has been touched.

# (1) Two config dirs that are really the SAME directory turn `ln -sfn X X` into
# a symlink to itself and destroy the file being installed. Reproduced with
# MIRROR as a symlink to PRIMARY: the mirror pass replaced PRIMARY/CLAUDE.md and
# PRIMARY/settings.json with self-referential links, and the preflight that would
# have noticed runs afterwards — i.e. after the damage. Compared by identity
# (same_dir resolves physically), because in every real instance of this the two
# spellings differ; literal equality is only the easiest case to hit.
if same_dir "$PRIMARY" "$REPO_DIR"; then
  printf 'install: the primary config dir and the repo are the same directory (%s) — refusing; every link would overwrite its own target.\n' "$PRIMARY" >&2
  exit 1
fi
if [[ -n "$MIRROR" ]]; then
  if same_dir "$MIRROR" "$PRIMARY"; then
    printf 'install: the mirror dir and the primary config dir are the same directory (%s) — refusing; the mirror pass would replace each freshly installed link with a symlink to itself.\n' "$MIRROR" >&2
    exit 1
  fi
  if same_dir "$MIRROR" "$REPO_DIR"; then
    printf 'install: the mirror dir and the repo are the same directory (%s) — refusing.\n' "$MIRROR" >&2
    exit 1
  fi
fi

# (2) The settings file the hook is written into is TRACKED and shared across
# machines whose usernames and mount points differ, so nothing host-specific may
# be persisted in it. For a repo outside the physical $HOME, portable_hook_cmd
# has no $HOME-relative spelling to emit and falls back to an absolute path —
# which then gets committed and pushed to every machine, where it names a
# directory that does not exist.
#
# Asserted against the ARTIFACT (the exact string about to be persisted), not by
# re-deriving the in-home test: the invariant is "nothing machine-specific is
# written", and the command is the thing that gets written.
HOOK_CMD="$(portable_hook_cmd "$REPO_DIR")"
case "$HOOK_CMD" in
  'bash "$HOME'*) ;;   # $HOME-relative: expands correctly on every machine
  *)
    if [ "${ALLOW_ABSOLUTE_HOOK_PATH:-0}" != "1" ]; then
      printf 'install: this repo is outside your home directory, so the global-memory hook would be written into the TRACKED settings file as an absolute path (%s) and pushed to every machine.\n' "$HOOK_CMD" >&2
      printf 'install: move the repo under $HOME, or re-run with ALLOW_ABSOLUTE_HOOK_PATH=1 to accept a settings file that only works on this host.\n' >&2
      exit 1
    fi
    printf 'install: WARNING — persisting an absolute hook path (%s); this settings file will not work on another machine.\n' "$HOOK_CMD" >&2 ;;
esac

echo "Linking repo -> $PRIMARY"
for item in "${ITEMS[@]}"; do
  link "$REPO_DIR/$item" "$PRIMARY/$item"
done
link "$REPO_DIR/$SETTINGS_SRC" "$PRIMARY/settings.json"

# Mirror BEFORE the hook preflight: preflight checks every present config dir's
# active settings.json, so a fresh mirror dir must get its settings link first.
if [[ -n "$MIRROR" ]]; then
  echo "Mirroring $MIRROR -> $PRIMARY"
  for item in "${ITEMS[@]}"; do
    link "$PRIMARY/$item" "$MIRROR/$item"
  done
  link "$PRIMARY/settings.json" "$MIRROR/settings.json"
fi

# Global-memory injection hook: install into THIS OS's settings + verify.
# (HOOK_CMD was computed and checked before the first link — see the validation
# block above; it must not be recomputed here, or the check would be advisory.)
install_global_memory_hook "$REPO_DIR/$SETTINGS_SRC" "$HOOK_CMD"
warn_stale_inject_hooks "$REPO_DIR/$SETTINGS_SRC" "$HOOK_CMD"
preflight_global_memory_hook "$HOOK_CMD" "$PRIMARY" ${MIRROR:+"$MIRROR"} || { echo "global-memory hook preflight FAILED" >&2; exit 1; }

# --- Restore backed-up "global" memories as symlinks ---
# memories/<root>/<projectdir>/<file> maps to ~/.<root>/projects/<projectdir>/memory/<file>.
# Re-creates each symlink so cross-project memories survive a fresh checkout.
# (New global memories are migrated live by sync-memories.sh, run from the Stop hook.)
if [[ -d "$REPO_DIR/memories" ]]; then
  echo "Restoring global memories"
  restore_memories "$REPO_DIR/memories"
fi

# --- macOS: local desktop-notification gates ----------------------------------
# hooks/notification-event.sh raises an osascript banner ONLY when its gate file
# exists, and on macOS nothing else delivers a local alert: Claude Code's own
# `preferredNotifChannel` emits a terminal ESCAPE SEQUENCE, not an OS banner, and
# in VS Code's integrated terminal it resolves to `no_method_available`. So an
# install that skips this step is completely silent, and silence is
# indistinguishable from "no events happened" -- measured 2026-09-04 on this
# machine: 36 Notification events (21 idle_prompt, 8 agent_completed,
# 4 agent_needs_input, 2 permission_prompt, 1 push_notification) fired into a
# hook whose two gates had never been created by anything.
#
# The names are DERIVED from the hook, never retyped. A hand-copied list is
# exactly how docs/replicate-setup-prompt.md came to instruct the reader to
# create `.enable-response-ready-notif`, a gate the hook had stopped reading.
# Deriving means renaming a gate in the hook cannot leave the installer behind.
#
# Set SKIP_NOTIF_FLAGS=1 on a terminal that already raises its own OS toast from
# the escape sequence (iTerm2, kitty, ghostty), where the two would double-ring.
if [[ "$(uname)" == "Darwin" && "${SKIP_NOTIF_FLAGS:-0}" != "1" ]]; then
  # Scan EVERY hook, not just notification-event.sh: the turn-end chime lives in
  # stop-event.sh behind its own gate, and a derivation that reads one hook would
  # silently leave that one uncreated -- the same class of gap this block exists
  # to close. The set is derived from the directory, so a new gated hook is
  # picked up without editing this list.
  if [[ ! -d "$REPO_DIR/hooks" ]]; then
    echo "WARNING: $REPO_DIR/hooks missing - desktop notifications will be silent" >&2
  else
    NOTIF_FLAGS=()
    while IFS= read -r f; do [[ -n "$f" ]] && NOTIF_FLAGS+=("$f"); done < <(
      grep -rho '\.claude/\.enable-[a-z0-9-]*-notif' "$REPO_DIR/hooks" | sed 's|.*/||' | sort -u
    )
    # Fail CLOSED on an empty derived set: the hook is present but names no gate,
    # which means this derivation broke, not that notifications are unwanted.
    if (( ${#NOTIF_FLAGS[@]} == 0 )); then
      echo "ERROR: no .enable-*-notif gates found in $REPO_DIR/hooks - derivation is stale" >&2
      exit 1
    fi
    mkdir -p "$HOME/.claude"
    for f in "${NOTIF_FLAGS[@]}"; do
      if [[ -e "$HOME/.claude/$f" ]]; then
        echo "Notification gate already on: $f"
      else
        : > "$HOME/.claude/$f"
        echo "Enabled notification gate: $f"
      fi
    done
  fi
fi

# --- What the auto-sync watchers watch ----------------------------------------
# ONE array, two encoders (launchd XML below, systemd further down), so the two
# platforms cannot drift apart. The rule is "every top-level entry except .git",
# NOT a hand-picked shortlist. The old shortlist was CLAUDE.md, settings.json,
# settings.linux.json, skills and memories — 5 of this repo's 23 entries — so an
# edit to sync.sh, hooks/, bin/, docs/ or plugins/ fired nothing at all and sat
# unbacked until something happened to touch one of the five. Measured 2026-09-01:
# 105 commits, four days, never pushed.
# The repo ROOT is still deliberately not watched: it contains .git, and the
# watcher's own commit writes would re-trigger it in a loop.
# Adding a top-level file? Add it here. tests/install-guards.test.sh G4 asserts
# this set against the real repo listing in both directions, so a forgotten entry
# is a red test, not a silent gap.
WATCH_ITEMS=(
  CLAUDE.md AGENTS.md README.md LICENSE .gitignore
  settings.json settings.linux.json settings.windows.json
  install.sh sync.sh sync.ps1 watch.ps1 sync-memories.sh
  inject-global-memory.sh inject-global-memory.mjs inject-ops-lanes.sh
  bin docs hooks memories plugins skills tests
)

# --- macOS: auto-sync agent (launchd) ---
# Runs sync.sh (commit + pull-if-remote-advanced + push) the instant a tracked
# file changes (WatchPaths) - so your own edits push immediately and also pull
# anything new, PLUS a 15-minute StartInterval backstop. The backstop is not
# belt-and-braces: macOS WatchPaths on a DIRECTORY fires when an entry is added
# or removed and NOT when an existing file is edited in place, which is what
# most edits are. Without the interval, an in-place edit to a watched directory
# is invisible until something else fires the agent. The interval bounds how
# long any local change can sit unbacked at 15 minutes.
# Skipped on non-macOS. Disable with: SKIP_WATCHER=1 ./install.sh
if [[ "$(uname)" == "Darwin" && "${SKIP_WATCHER:-0}" != "1" ]]; then
  LABEL="com.your-org.claude-config-autopush"
  PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
  mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
  # XML character data, not shell: an unescaped & or < in a path (both legal on
  # macOS) produces a plist launchd refuses to load, and the watcher then never
  # runs while the install reports success. $PLIST itself is a filesystem path
  # and stays unencoded.
  L_XML="$(xml_text "$LABEL")"; R_XML="$(xml_text "$REPO_DIR")"; H_XML="$(xml_text "$HOME")"
  WATCH_XML=""
  for _w in "${WATCH_ITEMS[@]}"; do
    WATCH_XML+="        <string>$R_XML/$(xml_text "$_w")</string>"$'\n'
  done
  WATCH_XML="${WATCH_XML%$'\n'}"
  cat > "$PLIST" <<PLISTEOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$L_XML</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$R_XML/sync.sh</string>
    </array>
    <!-- Every top-level entry except .git (see WATCH_ITEMS above). NOT the
         repo root itself: it contains .git, and recursive fsevents would make
         git's own commit writes re-trigger the watcher in a loop. -->
    <key>WatchPaths</key>
    <array>
$WATCH_XML
    </array>
    <key>ThrottleInterval</key>
    <integer>5</integer>
    <!-- The backstop. A directory WatchPath does not fire on an in-place edit
         of a file already inside it, so events alone lose changes silently;
         this bounds unbacked local work at 15 minutes. sync.sh is a no-op when
         the tree is clean and the remote has not moved. -->
    <key>StartInterval</key>
    <integer>900</integer>
    <key>StandardOutPath</key>
    <string>$H_XML/Library/Logs/claude-config-autopush.log</string>
    <key>StandardErrorPath</key>
    <string>$H_XML/Library/Logs/claude-config-autopush.log</string>
</dict>
</plist>
PLISTEOF
  launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PLIST"
  echo "  auto-sync agent loaded ($LABEL): ${#WATCH_ITEMS[@]} paths watched, plus a 15-min backstop"
fi

# --- Linux: auto-sync watcher (systemd user .path unit + backstop timer) ---
# An event watch (inotify, via a systemd .path unit - no inotify-tools needed)
# so sync.sh fires the instant a tracked file changes, PLUS a 15-minute timer.
# The timer is back deliberately: an earlier install removed it as "polling",
# and the macOS side then lost 105 commits over four days because an event
# watch only sees what it can see. Directory watches aren't recursive, so a
# deeply-nested edit fires nothing; the timer is what bounds that at 15 minutes
# instead of "until something else happens". Both units are cheap — sync.sh
# exits immediately on a clean tree with an unmoved remote.
# Disable with: SKIP_WATCHER=1 ./install.sh
if [[ "$(uname)" == "Linux" && "${SKIP_WATCHER:-0}" != "1" ]]; then
  UNIT_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
  mkdir -p "$UNIT_DIR"
  # systemd unit syntax, not shell: ExecStart is SPLIT on whitespace, so a repo
  # at `/repo space/` yields an executable token of `/repo` — and the .path unit
  # still enables, so the breakage only shows up as syncs that silently never
  # run. PathModified is not a command line and is not unquoted, so it gets the
  # specifier-doubling only.
  EXEC_ARG="$(systemd_arg "$REPO_DIR/sync.sh")"
  R_UNIT="$(systemd_path "$REPO_DIR")"
  PATH_MOD=""
  for _w in "${WATCH_ITEMS[@]}"; do
    PATH_MOD+="PathModified=$R_UNIT/$(systemd_path "$_w")"$'\n'
  done
  PATH_MOD="${PATH_MOD%$'\n'}"
  cat > "$UNIT_DIR/claude-config-sync.service" <<UNITEOF
[Unit]
Description=Sync Claude config repo (commit, pull if remote advanced, push)

[Service]
Type=oneshot
ExecStart=$EXEC_ARG
UNITEOF
  cat > "$UNIT_DIR/claude-config-sync.path" <<UNITEOF
[Unit]
Description=Watch Claude config files and sync on change

[Path]
$PATH_MOD

[Install]
WantedBy=default.target
UNITEOF
  cat > "$UNIT_DIR/claude-config-sync.timer" <<UNITEOF
[Unit]
Description=Backstop for the Claude config sync (an event watch only sees what it can see)

[Timer]
OnBootSec=5min
OnUnitActiveSec=15min
Persistent=true
Unit=claude-config-sync.service

[Install]
WantedBy=timers.target
UNITEOF
  if command -v systemctl >/dev/null 2>&1; then
    systemctl --user daemon-reload 2>/dev/null || true
    if systemctl --user enable --now claude-config-sync.path 2>/dev/null; then
      echo "  systemd watch loaded (claude-config-sync.path): ${#WATCH_ITEMS[@]} paths watched"
    else
      echo "  (could not enable systemd user .path unit - is the user bus up?)"
    fi
    # Persistent=true so a machine that was asleep or logged out at the due
    # time runs the sync once on the next boot rather than skipping it.
    if systemctl --user enable --now claude-config-sync.timer 2>/dev/null; then
      echo "  systemd backstop timer loaded (claude-config-sync.timer): every 15 min"
    else
      echo "  (could not enable systemd user .timer unit - is the user bus up?)"
    fi
    # Keep the watch running across logout / when WSL has no active login.
    if command -v loginctl >/dev/null 2>&1; then
      loginctl enable-linger "$USER" 2>/dev/null \
        && echo "  linger enabled for $USER" \
        || echo "  (could not enable linger - run: sudo loginctl enable-linger $USER)"
    fi
  else
    echo "  systemctl not found - skipping Linux auto-sync watch"
  fi
fi

# --- macOS: OpenSuperWhisper dictation app (optional) ---
# Local Whisper dictation: https://github.com/starmel/OpenSuperWhisper
# Requires macOS 14+ on Apple Silicon. Disable with: SKIP_OPENSUPERWHISPER=1
if [[ "$(uname)" == "Darwin" && "${SKIP_OPENSUPERWHISPER:-0}" != "1" ]]; then
  if command -v brew >/dev/null 2>&1; then
    if brew list --cask opensuperwhisper >/dev/null 2>&1; then
      echo "  OpenSuperWhisper already installed"
    else
      echo "  installing OpenSuperWhisper (brew cask)..."
      brew install --cask opensuperwhisper || echo "  (OpenSuperWhisper install skipped/failed)"
    fi
  else
    echo "  Homebrew not found - skipping OpenSuperWhisper (then: brew install --cask opensuperwhisper)"
  fi
fi

echo
echo "Done. Plugins are NOT symlinked - reinstall them separately:"
echo "  - see plugins/installed_plugins.json + plugins/known_marketplaces.json;"
echo "    add each marketplace, then install each plugin (claude-plugins-official,"
echo "    context-mode, thedotmack)."
