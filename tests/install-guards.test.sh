#!/usr/bin/env bash
# Tests for install.sh's REFUSALS and for the encoding of paths into the
# configuration files it GENERATES. Every case drives the real installer against
# a throwaway $HOME; nothing here touches the host's launchd, systemd or brew.
set -u
REPO="$(cd "$(dirname "$0")/.." && pwd -P)"
fail=0
assert_eq()       { [ "$1" = "$2" ] || { echo "FAIL[$3]: expected '$2' got '$1'"; fail=1; }; }
assert_contains() { case "$2" in *"$1"*) ;; *) echo "FAIL[$3]: expected to contain: $1"; fail=1;; esac; }
assert_missing()  { case "$2" in *"$1"*) echo "FAIL[$3]: expected NOT to contain: $1"; fail=1;; *) ;; esac; }
assert_absent()   { [ -e "$1" ] && { echo "FAIL[$2]: expected absent: $1"; fail=1; }; return 0; }

# PHYSICAL: install.sh resolves its own repo path with `pwd -P`, and on macOS
# mktemp hands back a path under the symlinked /var -> /private/var. Comparing
# spellings would fail on that resolution rather than on anything these cases are
# about — and a `contains` check would pass by accident, since /private/var/x
# contains /var/x as a substring.
# mktemp failing is not hypothetical -- a full disk, a read-only or hostile TMPDIR -- and in the
# `$(cd "$(mktemp -d)" && pwd -P)` shape the failure is SILENT and DESTRUCTIVE: bash treats
# `cd ""` as a successful no-op, so tmp becomes the CURRENT directory and the EXIT trap below
# deletes the checkout, uncommitted work included. Measured with mktemp stubbed to fail, not
# reasoned about. Check it BEFORE canonicalising, and before arming the trap.
tmp="$(mktemp -d)" || { printf '%s: cannot create a temp directory\n' "$0" >&2; exit 1; }
[ -n "$tmp" ] && [ -d "$tmp" ] \
  || { printf '%s: mktemp -d produced no directory\n' "$0" >&2; exit 1; }
tmp="$(cd "$tmp" && pwd -P)"
trap 'rm -rf "$tmp"' EXIT

# install.sh is unix-only by design (symlinks + launchd/systemd). Where `ln -s`
# silently copies, none of these assertions can hold — skip loudly.
: > "$tmp/.probe-target"; ln -s "$tmp/.probe-target" "$tmp/.probe-link" 2>/dev/null
[ -L "$tmp/.probe-link" ] || { echo "SKIP: install-guards (no real symlink support)"; exit 0; }
rm -f "$tmp/.probe-link" "$tmp/.probe-target"

# A copy, never the repo itself: these runs write into the tracked settings file,
# and a test must never mutate the thing it tests.
seed_repo() { mkdir -p "$1"; cp -R "$REPO/." "$1/" 2>/dev/null || true; rm -rf "$1/.git"; }

# PATH-scoped shims for every command that would otherwise reach the real
# machine: `uname` to drive either OS branch, and the three service managers so a
# generated plist/unit is written and inspected without ever being loaded.
shim_bin() { # $1 = dir, $2 = what argless `uname` prints
  mkdir -p "$1"
  cat > "$1/uname" <<SH
#!/usr/bin/env bash
[ "\$#" -eq 0 ] && { printf '%s\n' "$2"; exit 0; }
exec /usr/bin/uname "\$@"
SH
  for c in launchctl systemctl loginctl; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$1/$c"
  done
  chmod +x "$1"/uname "$1"/launchctl "$1"/systemctl "$1"/loginctl
}

# $1 = repo dir, $2 = HOME, $3 = shim dir (may be empty), rest = install.sh args.
# Captures stderr; the caller reads $rc and $out.
run_install() {
  local repo="$1" home="$2" pfx="$3"; shift 3
  out="$( HOME="$home" PATH="${pfx:+$pfx:}$PATH" SKIP_OPENSUPERWHISPER=1 \
          bash "$repo/install.sh" "$@" 2>&1 )"; rc=$?
  return 0
}

# ---- G1. a trailing newline must not install the SIBLING repo -------------
# `$(dirname …)` and `$(cd … && pwd -P)` both strip trailing newlines, so a repo
# whose directory name ends in one resolves to the sibling directory without it.
# That sibling is an ordinary directory which may hold its own installer, so
# "does the resolved path contain an install.sh" answers yes and the WRONG repo
# is what gets installed. The guard has to compare filesystem identity.
if mkdir "$tmp/g1/" 2>/dev/null && mkdir "$tmp/g1/nl-repo"$'\n' 2>/dev/null; then
  seed_repo "$tmp/g1/nl-repo"                       # the stripped SIBLING
  printf 'STRIPPED-SIBLING\n' > "$tmp/g1/nl-repo/CLAUDE.md"
  cp "$REPO/install.sh" "$tmp/g1/nl-repo"$'\n'"/install.sh"   # a copy: its own inode
  printf 'NEWLINE-REPO\n'     > "$tmp/g1/nl-repo"$'\n'"/CLAUDE.md"
  mkdir -p "$tmp/g1/home"
  run_install "$tmp/g1/nl-repo"$'\n' "$tmp/g1/home" "" "$tmp/g1/home/.claude"
  [ "$rc" != 0 ] || { echo "FAIL[G1]: installer exited 0 from a newline-named repo"; fail=1; }
  assert_contains "refusing" "$out" G1
  # The anchor: nothing was installed at all — in particular not the sibling's.
  assert_absent "$tmp/g1/home/.claude/CLAUDE.md" G1
else
  echo "SKIP[G1]: filesystem rejects a directory name ending in a newline"
fi

# ---- G2. a config dir that aliases another must not destroy it ------------
# `ln -sfn X X` replaces the file with a symlink to itself. Reproduced with the
# mirror as a symlink to the primary: the mirror pass overwrote every link the
# primary pass had just made. The first install here is real, so the case asserts
# SURVIVAL of a working installation rather than merely a non-zero exit.
mkdir -p "$tmp/g2/home"; seed_repo "$tmp/g2/home/dotfiles/claude"
shim_bin "$tmp/g2/bin" Darwin
run_install "$tmp/g2/home/dotfiles/claude" "$tmp/g2/home" "$tmp/g2/bin" "$tmp/g2/home/.claude"
assert_eq "$rc" 0 G2-baseline
assert_eq "$(readlink "$tmp/g2/home/.claude/CLAUDE.md")" "$tmp/g2/home/dotfiles/claude/CLAUDE.md" G2-baseline
ln -s "$tmp/g2/home/.claude" "$tmp/g2/home/.claude-alias"
run_install "$tmp/g2/home/dotfiles/claude" "$tmp/g2/home" "$tmp/g2/bin" \
            "$tmp/g2/home/.claude" "$tmp/g2/home/.claude-alias"
[ "$rc" != 0 ] || { echo "FAIL[G2]: installer accepted a mirror that aliases the primary"; fail=1; }
assert_contains "same directory" "$out" G2
# The anchor: the primary install is intact, not a symlink to itself.
assert_eq "$(readlink "$tmp/g2/home/.claude/CLAUDE.md")" "$tmp/g2/home/dotfiles/claude/CLAUDE.md" G2
# ...and the same for a primary that IS the repo.
run_install "$tmp/g2/home/dotfiles/claude" "$tmp/g2/home" "$tmp/g2/bin" "$tmp/g2/home/dotfiles/claude"
[ "$rc" != 0 ] || { echo "FAIL[G2-self]: installer accepted the repo as its own config dir"; fail=1; }
[ -f "$tmp/g2/home/dotfiles/claude/CLAUDE.md" ] && [ ! -L "$tmp/g2/home/dotfiles/claude/CLAUDE.md" ] \
  || { echo "FAIL[G2-self]: the repo's CLAUDE.md is no longer a regular file"; fail=1; }

# ---- G3. an out-of-home repo must not persist a host path -----------------
# The settings file the hook is written into is tracked and pushed to every
# machine, so an absolute path in it names a directory that exists on exactly one
# host. Refuse by default; the escape hatch is the anchor, since it proves the
# refusal is what stopped the write rather than the run failing for some other
# reason.
mkdir -p "$tmp/g3/home"; seed_repo "$tmp/g3/outside/claude"
shim_bin "$tmp/g3/bin" Darwin
before="$(cat "$tmp/g3/outside/claude/settings.json")"
run_install "$tmp/g3/outside/claude" "$tmp/g3/home" "$tmp/g3/bin" "$tmp/g3/home/.claude"
[ "$rc" != 0 ] || { echo "FAIL[G3]: installer accepted an out-of-home repo silently"; fail=1; }
assert_contains "outside your home directory" "$out" G3
assert_eq "$(cat "$tmp/g3/outside/claude/settings.json")" "$before" G3-unwritten
assert_absent "$tmp/g3/home/.claude/CLAUDE.md" G3-unwritten
out="$( HOME="$tmp/g3/home" PATH="$tmp/g3/bin:$PATH" SKIP_OPENSUPERWHISPER=1 \
        ALLOW_ABSOLUTE_HOOK_PATH=1 bash "$tmp/g3/outside/claude/install.sh" \
        "$tmp/g3/home/.claude" 2>&1 )"; rc=$?
assert_eq "$rc" 0 G3-optin
assert_contains "$tmp/g3/outside/claude/inject-global-memory.sh" \
  "$(jq -r '.hooks.SessionStart[]?.hooks[]?.command // ""' "$tmp/g3/outside/claude/settings.json")" G3-optin

# ---- G4. generated configuration is encoded for ITS grammar ---------------
# A path is a shell string here, XML there and a systemd command line somewhere
# else. Interpolated bare, `/re po/sync.sh` becomes the executable `/re` with an
# argument — and the .path unit still enables, so the only symptom is syncs that
# never run. `%` is a systemd specifier and `&` closes nothing in XML but makes
# the plist unparseable.
# Every reserved character of every grammar, in ONE fixture, because the old one
# was `re po%x&y` -- it contained neither `<` nor `"`, so deleting the XML `<`
# escaping and deleting the systemd double-quote escaping BOTH survived the
# suite. An encoder test whose fixture omits the character the encoder exists to
# encode is a control that cannot fail (round-5 tests #2).
#   %  systemd specifier (both units)   &  < >  XML
#   "  \  systemd command-line quoting
g4dir='re po%x&y<z>"q\w'
mkdir -p "$tmp/g4/home"; seed_repo "$tmp/g4/home/$g4dir/claude"
shim_bin "$tmp/g4/bin" Linux
run_install "$tmp/g4/home/$g4dir/claude" "$tmp/g4/home" "$tmp/g4/bin" "$tmp/g4/home/.claude"
assert_eq "$rc" 0 G4-linux
unit="$tmp/g4/home/.config/systemd/user/claude-config-sync.service"
pathunit="$tmp/g4/home/.config/systemd/user/claude-config-sync.path"
[ -f "$unit" ] || { echo "FAIL[G4-linux]: no .service unit was generated"; fail=1; }
# Written out by hand, single-quoted, NOT recomputed from the encoder: a fixture
# that applies the same function it is testing agrees with any bug.
#   \ -> \\   " -> \"   % -> %%   and the whole argument is quoted.
g4exec='re po%%x&y<z>\"q\\w'
assert_eq "$(grep '^ExecStart=' "$unit")" \
  "ExecStart=\"$tmp/g4/home/$g4exec/claude/sync.sh\"" G4-execstart
# PathModified is not a command line and is not unquoted: doubling `%` is the
# whole encoding, so the `"` and the `\` must arrive UNTOUCHED -- quoting them
# would make the quote characters part of the watched path.
g4path='re po%%x&y<z>"q\w'
g4root="$tmp/g4/home/$g4path/claude"
# The COMPLETE set, exactly, in emission order. `assert_contains` accepted a
# wrong filename (`CLAUDE.md.bak` contains `CLAUDE.md`), a missing line and an
# extra one -- and a watcher pointed at the backup file is invisible until syncs
# stop. Written out by hand rather than recomputed from install.sh's WATCH_ITEMS:
# a fixture that reads the array under test agrees with any edit to it.
g4items='CLAUDE.md AGENTS.md README.md LICENSE .gitignore
settings.json settings.linux.json settings.windows.json
install.sh sync.sh sync.ps1 watch.ps1 sync-memories.sh
inject-global-memory.sh inject-global-memory.mjs inject-ops-lanes.sh
bin docs hooks memories plugins skills tests'
g4want=""
for g4i in $g4items; do g4want="$g4want${g4want:+
}PathModified=$g4root/$g4i"; done
assert_eq "$(grep '^PathModified=' "$pathunit")" "$g4want" G4-pathmodified
# ...and the macOS watcher watches the SAME set. Two platforms, one array: the
# whole point of WATCH_ITEMS is that they cannot drift, so assert it rather than
# trusting that they were edited together.
# (deferred until $plist exists, below)

# G4b. The set is DERIVED, not curated: "every tracked top-level entry except
# .git". Asserted against the real repo in BOTH directions, because each
# direction catches a different failure and neither catches the other. A missing
# entry is a file whose edits fire no watcher and sit unbacked (measured
# 2026-09-01: 105 commits over four days, because the list covered 5 of 22).
# An extra entry is a watch on something that does not exist -- which is what a
# typo or a stale name looks like, and it is silent.
g4real="$(cd "$REPO" && git ls-files 2>/dev/null | sed 's|/.*||' | sort -u)"
if [ -n "$g4real" ]; then
  g4have="$(printf '%s\n' $g4items | sort -u)"
  assert_eq "$g4have" "$g4real" G4b-watchset-matches-repo
else
  echo "SKIP[G4b]: $REPO is not a git checkout, cannot derive the tracked top-level set"
fi
# ...and the macOS branch, whose grammar is XML.
shim_bin "$tmp/g4/bin-mac" Darwin
run_install "$tmp/g4/home/$g4dir/claude" "$tmp/g4/home" "$tmp/g4/bin-mac" "$tmp/g4/home/.claude"
assert_eq "$rc" 0 G4-darwin
plist="$tmp/g4/home/Library/LaunchAgents/com.your-org.claude-config-autopush.plist"
[ -f "$plist" ] || { echo "FAIL[G4-darwin]: no plist was generated"; fail=1; }
# One positive assertion carrying all three escapes, so deleting ANY of them
# fails it; `"` and `\` are not XML-reserved and must survive verbatim.
assert_contains 're po%x&amp;y&lt;z&gt;"q\w/claude/sync.sh' "$(cat "$plist")" G4-xml
# Two platforms, ONE array. Compare the plist's watched basenames against the
# same hand-written set the systemd half was checked against, so a change that
# widens one watcher and not the other is red.
# ProgramArguments' own `<string>.../claude/sync.sh</string>` matches this too;
# `sync.sh` is a legitimate member of the watch set, so `sort -u` collapses the
# duplicate rather than the line being filtered out. The log paths sit under
# $HOME/Library/Logs and contain no `/claude/`, so they do not match.
g4mac="$(sed -n 's|^ *<string>.*/claude/\([^/<]*\)</string>$|\1|p' "$plist" | sort -u)"
assert_eq "$g4mac" "$(printf '%s\n' $g4items | sort -u)" G4-mac-watchset
# The backstop, asserted as an artifact fact rather than trusted. A directory
# WatchPath does NOT fire on an in-place edit of a file already inside it, so
# events alone lose changes silently; StartInterval is the only thing bounding
# how long a local change can sit unbacked. Deleting it leaves every other
# assertion here green, which is exactly why it needs its own.
assert_contains '<key>StartInterval</key>' "$(cat "$plist")" G4-backstop
if command -v plutil >/dev/null 2>&1; then
  g4int="$(plutil -extract StartInterval raw -o - "$plist" 2>/dev/null)"
  assert_eq "$g4int" "900" G4-backstop-seconds
fi
# ...plus the raw forms, each spelled so it can only match its own escape being
# dropped: `y<z` appears if `<` was left bare even when `>` was escaped, and
# `z>"` appears if `>` was left bare even when `<` was escaped.
assert_missing 're po%x&y' "$(cat "$plist")" G4-xml
assert_missing 'y<z'       "$(cat "$plist")" G4-xml
assert_missing 'z>"'       "$(cat "$plist")" G4-xml
# The artifact check, where the platform can make it: launchd must be able to
# parse what we wrote. A string assertion alone would survive a half-escape.
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$plist" >/dev/null 2>&1 || { echo "FAIL[G4-xml]: plutil rejects the generated plist"; fail=1; }
fi

# ---- G5. a CARRIAGE RETURN in the invocation path is refused too ----------
# The newline half of this guard is what G1 drives. A bare CR is the other half
# and behaves differently: nothing strips it, so it survives into $REPO_DIR and
# into every generated plist, unit and settings command line, where it truncates
# or corrupts the line it lands in without ever looking wrong in a diff. Refuse
# the whole class at the entrance, not one member of it.
cr=$'\r'
if mkdir -p "$tmp/g5" 2>/dev/null && mkdir "$tmp/g5/cr-repo$cr" 2>/dev/null; then
  seed_repo "$tmp/g5/cr-repo$cr"
  mkdir -p "$tmp/g5/home"
  run_install "$tmp/g5/cr-repo$cr" "$tmp/g5/home" "" "$tmp/g5/home/.claude"
  [ "$rc" != 0 ] || { echo "FAIL[G5]: installer exited 0 from a repo path containing a carriage return"; fail=1; }
  assert_contains "refusing" "$out" G5
  # The anchor: nothing was installed, so the refusal is what stopped it.
  assert_absent "$tmp/g5/home/.claude/CLAUDE.md" G5
else
  echo "SKIP[G5]: filesystem rejects a directory name containing a carriage return"
fi

# ---- G6. two spellings of a dir that does not exist YET are still one dir --
# `same_dir` compared strings whenever `cd` failed, and at this point in the run
# neither config dir has been created — so an aliased mirror was undetectable in
# exactly the case the installer always meets: a first install. The primary pass
# would install into the directory and the mirror pass would then replace every
# link it had just made with a symlink to itself. canon_dir walks up to the
# nearest EXISTING ancestor and resolves that, so a path that does not exist is
# still an identity rather than a spelling.
mkdir -p "$tmp/g6/home"; seed_repo "$tmp/g6/home/dotfiles/claude"
shim_bin "$tmp/g6/bin" Darwin
ln -s "$tmp/g6/home" "$tmp/g6/alias"
[ -d "$tmp/g6/home/.claude" ] && { echo "FAIL[G6]: the primary already exists, so this case is not about a nonexistent path"; fail=1; }
run_install "$tmp/g6/home/dotfiles/claude" "$tmp/g6/home" "$tmp/g6/bin" \
            "$tmp/g6/home/.claude" "$tmp/g6/alias/.claude"
[ "$rc" != 0 ] || { echo "FAIL[G6]: installer accepted a mirror that aliases a not-yet-created primary"; fail=1; }
assert_contains "same directory" "$out" G6
# The anchor: it refused BEFORE installing, so nothing was left half-linked.
assert_absent "$tmp/g6/home/.claude/CLAUDE.md" G6

# ---- G7a. a MIDDLE symlink makes a per-item destination the source ---------
# The roots preflight compares three DIRECTORIES, and all three can be honestly
# distinct while a component BELOW one of them links back into the repository.
# `$PRIMARY/skills` -> the repo's `skills` is enough: the destination
# `$PRIMARY/skills/email-drafter` IS `$REPO/skills/email-drafter`, so the
# installer moves the repository's own skill aside and leaves a symlink pointing
# at where it used to be. Every root check passed before that first write, which
# is why the answer has to be taken per link, at act time.
mkdir -p "$tmp/g7a/home"; seed_repo "$tmp/g7a/home/dotfiles/claude"
shim_bin "$tmp/g7a/bin" Darwin
g7arepo="$tmp/g7a/home/dotfiles/claude"
mkdir -p "$tmp/g7a/home/.claude"
ln -s "$g7arepo/skills" "$tmp/g7a/home/.claude/skills"
run_install "$g7arepo" "$tmp/g7a/home" "$tmp/g7a/bin" "$tmp/g7a/home/.claude"
[ "$rc" != 0 ] || { echo "FAIL[G7a]: installer accepted a destination that resolves onto its own source through a middle symlink"; fail=1; }
assert_contains "same directory entry" "$out" G7a
# The anchor is the REPOSITORY, not the message: its skill must still be the real
# directory it was, with no backup copy taken and no link left in its place.
[ -d "$g7arepo/skills/email-drafter" ] && [ ! -L "$g7arepo/skills/email-drafter" ] \
  || { echo "FAIL[G7a]: the repository's own skill was replaced or moved aside"; fail=1; }
[ -e "$g7arepo/skills/email-drafter/SKILL.md" ] \
  || { echo "FAIL[G7a]: the repository's skill no longer has its contents"; fail=1; }
for b in "$g7arepo/skills/email-drafter".bak-*; do
  [ -e "$b" ] && { echo "FAIL[G7a]: the installer backed up a repository file: $b"; fail=1; }
done

# ---- G7b. ...and the same is true when the two NAMES differ ----------------
# Arm (a) above catches a destination that is literally its own source. A middle
# symlink can also land the destination somewhere ELSE inside the repository,
# where the names no longer match and only "is this inside the repo" answers it.
mkdir -p "$tmp/g7b/home"; seed_repo "$tmp/g7b/home/dotfiles/claude"
shim_bin "$tmp/g7b/bin" Darwin
g7brepo="$tmp/g7b/home/dotfiles/claude"
mkdir -p "$tmp/g7b/home/.claude"
ln -s "$g7brepo" "$tmp/g7b/home/.claude/skills"
run_install "$g7brepo" "$tmp/g7b/home" "$tmp/g7b/bin" "$tmp/g7b/home/.claude"
[ "$rc" != 0 ] || { echo "FAIL[G7b]: installer wrote a link into the repository itself"; fail=1; }
assert_contains "resolves inside the repository" "$out" G7b
assert_absent "$g7brepo/email-drafter" G7b

# ---- G8. a MIRROR that becomes an alias AFTER the preflight ---------------
# The preflight's answer is true when it is taken and stale by the time the
# mirror loop uses it. Reproduced deterministically rather than by racing: a
# PATH shim swaps the mirror for a symlink to the primary at the moment the
# installer takes the LAST primary link, i.e. after every root check has passed.
# Without the act-time check the mirror pass rewrites each freshly made link as a
# symlink to itself -- the exact damage the preflight exists to prevent.
mkdir -p "$tmp/g8/home"; seed_repo "$tmp/g8/home/dotfiles/claude"
shim_bin "$tmp/g8/bin" Darwin
g8repo="$tmp/g8/home/dotfiles/claude"
g8pri="$tmp/g8/home/.claude"; g8mir="$tmp/g8/home/.claude1"
cat > "$tmp/g8/bin/dirname" <<SH
#!/usr/bin/env bash
# Pass-through, except once: the final primary link is the seam between the
# preflight and the mirror loop, so the swap lands exactly there.
if [ "\${1:-}" = "$g8pri/settings.json" ]; then
  rm -rf "$g8mir"; ln -s "$g8pri" "$g8mir"
fi
exec /usr/bin/dirname "\$@"
SH
chmod +x "$tmp/g8/bin/dirname"
run_install "$g8repo" "$tmp/g8/home" "$tmp/g8/bin" "$g8pri" "$g8mir"
[ -L "$g8mir" ] || { echo "FAIL[G8]: the shim never swapped the mirror, so this case proved nothing"; fail=1; }
[ "$rc" != 0 ] || { echo "FAIL[G8]: installer mirrored onto an alias of the primary it had just installed"; fail=1; }
assert_contains "same directory entry" "$out" G8
# The anchor: the primary's links still point AT THE REPO, not at themselves.
g8got="$(readlink "$g8pri/CLAUDE.md" || true)"
assert_eq "$g8got" "$g8repo/CLAUDE.md" G8-primary-intact
[ -e "$g8pri/CLAUDE.md" ] || { echo "FAIL[G8]: the primary's CLAUDE.md link is broken -- it points at itself"; fail=1; }

# ---- G9. a dot component that does not exist yet still names one dir -------
# canon_dir re-appended the missing tail verbatim, so `$HOME/nope/../dotfiles`
# and `$HOME/dotfiles` compared different -- and the `..` resolves the moment
# `mkdir -p` runs, which is after the refusal would have been useful.
mkdir -p "$tmp/g9/home"; seed_repo "$tmp/g9/home/dotfiles/claude"
shim_bin "$tmp/g9/bin" Darwin
g9repo="$tmp/g9/home/dotfiles/claude"
[ -d "$tmp/g9/home/nope" ] && { echo "FAIL[G9]: the dot component exists, so this case is not about an unresolved path"; fail=1; }
run_install "$g9repo" "$tmp/g9/home" "$tmp/g9/bin" "$tmp/g9/home/nope/../dotfiles/claude"
[ "$rc" != 0 ] || { echo "FAIL[G9]: installer accepted a primary that spells the repo through a nonexistent directory"; fail=1; }
# The PREFLIGHT's own words, not a substring the act-time guard also satisfies:
# with canon_dir left comparing spellings, link() still refuses this pair -- so a
# loose "same directory" check passes while the roots check is broken, and the
# case would prove nothing. (It did: two mutations survived it.)
assert_contains "the primary config dir and the repo are the same directory" "$out" G9
# And the sharper anchor: refused before the FIRST write. The dot component only
# resolves once `mkdir -p` has created it, so its existence afterwards is proof
# the run got as far as linking.
assert_absent "$tmp/g9/home/nope" G9-refused-before-any-write
[ -f "$g9repo/CLAUDE.md" ] && [ ! -L "$g9repo/CLAUDE.md" ] \
  || { echo "FAIL[G9]: the repository's CLAUDE.md was replaced by a link to itself"; fail=1; }

# ---- G10. two roots differing only in CASE on a case-folding volume --------
# No concurrency and no symlink: on a case-insensitive filesystem `~/.ConfigX`
# and `~/.configx` are two spellings of one directory, and NO amount of string
# normalisation can know that -- only the filesystem can. Probed rather than
# assumed, because the answer differs per volume and a case-sensitive one would
# make this pass for the wrong reason.
mkdir -p "$tmp/g10/probe/CaseProbe"
if [ -d "$tmp/g10/probe/caseprobe" ]; then
  mkdir -p "$tmp/g10/home"; seed_repo "$tmp/g10/home/dotfiles/claude"
  shim_bin "$tmp/g10/bin" Darwin
  g10repo="$tmp/g10/home/dotfiles/claude"
  run_install "$g10repo" "$tmp/g10/home" "$tmp/g10/bin" \
              "$tmp/g10/home/.ConfigX" "$tmp/g10/home/.configx"
  [ "$rc" != 0 ] || { echo "FAIL[G10]: installer mirrored a case-alias of the primary onto itself"; fail=1; }
  assert_contains "same directory entry" "$out" G10
  g10got="$(readlink "$tmp/g10/home/.ConfigX/CLAUDE.md" || true)"
  assert_eq "$g10got" "$g10repo/CLAUDE.md" G10-primary-intact
  [ -e "$tmp/g10/home/.ConfigX/CLAUDE.md" ] || { echo "FAIL[G10]: the primary's CLAUDE.md points at itself"; fail=1; }
else
  echo "SKIP[G10]: this volume is case-sensitive, so two spellings are two directories here"
fi

# ---- G11. collapsing a `..` can EXPOSE a symlink, which must be resolved ----
# Lexical collapse is sound for components that do not exist, but its RESULT can
# name a path that does -- `$HOME/nope/../../alias/dotfiles/claude` collapses
# onto `$tmp/alias/dotfiles/claude`, and `alias` is a symlink to the home that
# holds the repo. A canon_dir that collapses and stops there answers with a
# spelling again, and the roots check is back where it started. So the collapse
# is followed by one more physical resolution, and this is the case that needs it.
mkdir -p "$tmp/g11/home"; seed_repo "$tmp/g11/home/dotfiles/claude"
shim_bin "$tmp/g11/bin" Darwin
g11repo="$tmp/g11/home/dotfiles/claude"
ln -s "$tmp/g11/home" "$tmp/g11/alias"
run_install "$g11repo" "$tmp/g11/home" "$tmp/g11/bin" \
            "$tmp/g11/home/nope/../../alias/dotfiles/claude"
[ "$rc" != 0 ] || { echo "FAIL[G11]: installer accepted a primary that reaches the repo through a collapsed dot and a symlink"; fail=1; }
assert_contains "the primary config dir and the repo are the same directory" "$out" G11
assert_absent "$tmp/g11/home/nope" G11-refused-before-any-write
[ -f "$g11repo/CLAUDE.md" ] && [ ! -L "$g11repo/CLAUDE.md" ] \
  || { echo "FAIL[G11]: the repository's CLAUDE.md was replaced by a link to itself"; fail=1; }

[ "$fail" = 0 ] && echo "PASS: install-guards" || exit 1
