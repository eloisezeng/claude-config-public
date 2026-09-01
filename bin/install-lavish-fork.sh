#!/usr/bin/env bash
# Install the lavish-axi fork as the global `lavish-axi` command.
#
# CLAUDE.md requires `lavish-axi` to resolve to the personal fork, not the
# upstream npm package. The fork is not published to npm, so it cannot be
# installed with `npm i -g`: it has to be cloned, built, and linked. This
# script does that, and is safe to re-run.
set -euo pipefail

FORK_REMOTE="${LAVISH_FORK_REMOTE:-https://github.com/eloise-idealab/lavish-axi.git}"
FORK_DIR="${LAVISH_FORK_DIR:-$HOME/Coding/lavish-axi-fork}"
FORK_BRANCH="${LAVISH_FORK_BRANCH:-feat/realtime-sse-threading}"
UPSTREAM_REMOTE="${LAVISH_UPSTREAM_REMOTE:-https://github.com/kunchenguid/lavish-axi.git}"

say() { printf '\033[1m==>\033[0m %s\n' "$*"; }
die() { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

command -v git  >/dev/null || die "git is required"
command -v npm  >/dev/null || die "npm is required"
node_major="$(node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0)"
[ "$node_major" -ge 20 ] || die "Node >= 20 required (found $(node -v 2>/dev/null || echo none))"

# A running server keeps the OLD build loaded; changing the tree under it does
# nothing until it restarts, and that silence reads as "the fix didn't work".
if pgrep -f 'lavish-axi.*server' >/dev/null 2>&1; then
  say "NOTE: a lavish-axi server is running. Restart it after this finishes, or it keeps serving the old build."
fi

if [ -d "$FORK_DIR/.git" ]; then
  say "Fork already at $FORK_DIR — fetching"
  git -C "$FORK_DIR" remote get-url origin >/dev/null 2>&1 || die "$FORK_DIR has no origin remote"
  git -C "$FORK_DIR" fetch --all --prune --quiet
else
  say "Cloning fork into $FORK_DIR"
  mkdir -p "$(dirname "$FORK_DIR")"
  git clone --quiet "$FORK_REMOTE" "$FORK_DIR"
  git -C "$FORK_DIR" remote add upstream "$UPSTREAM_REMOTE" 2>/dev/null || true
fi

# Resolve the branch against whatever remote actually carries it. The feature
# branch disappears once its PR lands, so fall back rather than fail.
target=""
for r in $(git -C "$FORK_DIR" remote); do
  if git -C "$FORK_DIR" rev-parse --verify --quiet "refs/remotes/$r/$FORK_BRANCH" >/dev/null; then
    target="$r/$FORK_BRANCH"; break
  fi
done
if [ -z "$target" ]; then
  say "Branch '$FORK_BRANCH' not found on any remote (merged and deleted?) — falling back to origin/HEAD"
  target="$(git -C "$FORK_DIR" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || echo origin/main)"
fi

if ! git -C "$FORK_DIR" diff --quiet || ! git -C "$FORK_DIR" diff --cached --quiet; then
  die "$FORK_DIR has uncommitted changes — commit or stash them, then re-run"
fi

say "Checking out $target"
git -C "$FORK_DIR" checkout --quiet -B "${FORK_BRANCH##*/}" --track "$target" 2>/dev/null \
  || git -C "$FORK_DIR" checkout --quiet "$target"

say "Installing dependencies"
( cd "$FORK_DIR" && npm install --silent )
if npm --prefix "$FORK_DIR" run 2>/dev/null | grep -qE '^\s+build'; then
  say "Building"
  ( cd "$FORK_DIR" && npm run build --silent )
fi

say "Linking as the global lavish-axi"
( cd "$FORK_DIR" && npm link >/dev/null )

# Verify against the artifact, not the exit status: a link that silently kept
# pointing at the upstream package is the failure this whole script exists to
# prevent.
resolved="$(npm ls -g --depth=0 --parseable 2>/dev/null | grep -i 'lavish-axi$' | head -1 || true)"
want="$(cd "$FORK_DIR" && pwd -P)"
if [ -n "$resolved" ] && [ "$(cd "$resolved" 2>/dev/null && pwd -P || echo none)" = "$want" ]; then
  say "OK — global lavish-axi resolves to $want"
  say "    $(command -v lavish-axi || echo 'lavish-axi not on PATH — check your npm global bin dir')"
  say "    $(git -C "$FORK_DIR" log -1 --format='%h %s')"
else
  die "global lavish-axi does NOT resolve to $want (got: ${resolved:-nothing}). Run 'npm ls -g lavish-axi' to inspect."
fi
