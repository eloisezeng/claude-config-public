#!/usr/bin/env bash
# usage: ci-green.sh <sha> [base-ref]   (run from inside the repo; REPO=owner/name, else inferred)
#
# Is CI GREEN on this exact commit? Fails CLOSED. Never reads `gh pr checks` -- that rollup LAGS and
# has reported "0 pending of 1" while the check-runs API showed 4 checks with 3 still running.  -> VERDICT: GREEN | NOT-GREEN <why>; exit 0 iff GREEN
set -u
# Say so, rather than letting `set -u` kill only the command substitution below (it dies in the
# SUBSHELL, so FULL just becomes empty) and then spending two API calls on an empty sha to reach
# the same refusal by a longer route. This must sit ABOVE the token block: `gh auth token` is
# itself a call, so validating after it means the guard fires after the first spend.
if [ "$#" -lt 1 ]; then
  echo "usage: ci-green.sh <sha> [base-ref]" >&2; exit 2
fi
# Find `gh` even where nothing sourced a login shell. A background job, a GUI-launched app and a
# LaunchAgent all run on launchd's bare PATH, which has no /opt/homebrew/bin -- so `gh` is present
# and installed while `command -v gh` says nothing, and every call here dies "gh: command not
# found". That reads as ABORT, which is the correct fail-closed answer to the wrong question: the
# gate is not blind to CI, it is blind to its own tool. Measured 2026-09-09 in a background session:
# gh 2.100.0 at /opt/homebrew/bin/gh, absent from PATH, and the gate aborted on a green commit.
if ! command -v gh >/dev/null 2>&1; then
  PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"; export PATH
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "VERDICT: ABORT -- gh not found on PATH or in the usual install locations" >&2; exit 2
fi
# Do NOT hard-code an account. Measured 2026-09-01: a pinned `--user your-org` token 404s on
# your-org/your-other-project, which the active account reads fine -- and a private repo answers 404
# for "you may not read this" byte-identically to "it is not there", so the wrong account turns a
# permission failure into a CI verdict. Honour an ambient GH_TOKEN, else CI_GREEN_GH_USER, else the
# account `gh` is actually active as.
if [ -z "${GH_TOKEN:-}" ]; then
  if [ -n "${CI_GREEN_GH_USER:-}" ]; then GH_TOKEN=$(gh auth token --user "$CI_GREEN_GH_USER")
  else GH_TOKEN=$(gh auth token); fi
  export GH_TOKEN
fi
FULL=$(git rev-parse "$1")
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
BASE_REF="${2:-origin/main}"
D=/tmp/.cig.$$; mkdir -p $D
# The branch the pull request targets, for a job `if:` reading `github.base_ref`. Only an EXPLICIT
# argument is written: the origin/main default above serves the diff, and letting a DEFAULT answer
# `github.base_ref == 'main'` would decide whether a job is required from a guess. The file ABSENT
# means "not given", and ci-derive.py then refuses any condition that needs it, by name. Line 2 is
# git's full name for the argument, and it is only trusted when git SUCCEEDS: measured 2026-09-10,
# `git rev-parse --symbolic-full-name` prints nothing for a sha, and for a name that does not resolve
# it echoes the name back on stdout while exiting 128.
if [ "$#" -ge 2 ]; then
  BASE_FULL=$(git rev-parse --symbolic-full-name "$2" 2>/dev/null) || BASE_FULL=""
  printf '%s\n%s\n' "$2" "${BASE_FULL%%$'\n'*}" > $D/base_ref.txt
  git remote > $D/remotes.txt 2>/dev/null || true
fi
# The changed-file set, for the file-level `paths:` filters ci-derive.py reads. A workflow a filter
# excludes does not run at all and registers no check-run, so requiring its jobs reports NOT-GREEN
# forever -- see the long note in ci-derive.py. This file being ABSENT is not the same as being
# EMPTY: absent means "could not determine", and the deriver then refuses every path-filtered
# workflow BY NAME rather than guessing in either direction.
MB=$(git merge-base "$BASE_REF" "$FULL" 2>/dev/null || true)
if [ -n "$MB" ] && [ "$MB" != "$FULL" ]; then
  # pull_request semantics: GitHub filters on the files the PR changes, i.e. merge-base..head.
  git diff --name-only "$MB" "$FULL" > $D/changed.txt 2>/dev/null || rm -f $D/changed.txt
elif [ -n "$MB" ]; then
  # The sha is already on the base branch. A merge-base diff would be EMPTY here and would read as
  # "no path-filtered workflow ran", so use the commit's own diff, which is what a push filters on.
  git diff --name-only "$FULL^" "$FULL" > $D/changed.txt 2>/dev/null || rm -f $D/changed.txt
fi
# A pull_request run executes the workflow from the MERGE ref, so a job only the BASE defines still
# runs -- deriving the required set from the head alone would never require it. Union both sides,
# parsing each file SEPARATELY (concatenating them makes the second file's `on:` keys look like jobs).
# EVERY workflow file, not a hard-coded `ci.yml`: that name is one repo's convention, and a repo
# that calls it `checks.yml` (or has no such file) derived an EMPTY required set and so could never
# read GREEN -- fail-closed, but permanently, which is a gate nobody can use. ci-derive.py decides
# which of these files can register a check on this sha, from each file's own `on:` block.
for side in head:$FULL base:$BASE_REF; do
  tag=${side%%:*}; ref=${side#*:}
  # --full-tree, so this works from ANY directory in the repo, not just the root. Without it
  # `git ls-tree` resolves the path argument against the CURRENT directory and prints results
  # relative to it, so running from a subdir (`web/` in a monorepo) silently matched nothing and
  # derived an EMPTY required set -- the exact permanent fail-closed the comment above says must
  # not happen, arriving by a different route. Measured 2026-09-07: from a repo SUBDIRECTORY this printed
  # `expected_jobs=[]` and NOT-GREEN while all five checks on the sha were green; one `cd ..` and
  # the same sha read GREEN. --full-tree also implies --full-name, which is what keeps the
  # `$ref:$wf` read below addressing the right blob.
  git ls-tree --full-tree --name-only "$ref" .github/workflows/ 2>/dev/null | while read -r wf; do
    case "$wf" in *.yml|*.yaml) ;; *) continue ;; esac
    git show "$ref:$wf" > "$D/$tag.$(basename "$wf" | tr / _).yml" 2>/dev/null || true
  done
done
# An ERRORED read is not evidence about CI. Without this check a 404/500/rate-limit yields an empty
# runs.tsv, which the deriver faithfully reports as "jobs never registered" -- a CI verdict rendered
# from an API failure. Abort on a distinct exit code (2) instead: an empty file is only meaningful
# when the call SUCCEEDED, which then still means NOT-GREEN via the deriver.
if ! gh api "repos/$REPO/commits/$FULL/check-runs" --paginate \
     --jq '.check_runs[] | [.name,.status,.conclusion,(.id|tostring)] | @tsv' > $D/runs.tsv 2>$D/err; then
  echo "VERDICT: ABORT -- check-runs API read FAILED for $REPO@${FULL:0:7} (this is not a CI result):"
  sed 's/^/  /' $D/err >&2; sed 's/^/  /' $D/err
  rm -rf $D; exit 2
fi
python3 "$(dirname "$0")/ci-derive.py" "$FULL" "$D"
rc=$?; rm -rf $D

# ---------------------------------------------------------------------------------------------
# ADVISORY ONLY: the health of the default branch's SCHEDULED backstop.
#
# This deliberately does NOT touch $rc. The verdict above is a question about ONE COMMIT, and
# ci-derive.py is right to drop schedule-triggered workflows from the expected set: a scheduled
# run never registers a check against a sha, so requiring one would report NOT-GREEN forever.
#
# But "correctly excluded from the verdict" turned into "never mentioned at all", and that silence
# cost 44 hours. Measured 2026-09-14/15 on your-org/your-other-project: the nightly full suite --
# the only full-suite run anywhere, and the backstop that makes the per-pull-request affected-test
# selection defensible -- was red on `main` two nights running. Running this script on any PR sha
# in that window printed VERDICT: GREEN and said nothing. The pull request that eventually fixed
# the failure stated in its own commit message that "nothing caught it", because nobody could see
# what had.
#
# So: same verdict, one more sentence. Fail open and stay quiet on any error -- an advisory that
# breaks the tool it advises is worse than the silence it replaces.
# ---------------------------------------------------------------------------------------------
{
  default_branch=$(gh repo view "$REPO" --json defaultBranchRef --jq .defaultBranchRef.name 2>/dev/null)
  if [ -n "$default_branch" ] && [ -d .github/workflows ]; then
    for wf in .github/workflows/*.yml .github/workflows/*.yaml; do
      [ -e "$wf" ] || continue
      grep -qE '^[[:space:]]*schedule:' "$wf" || continue
      base=$(basename "$wf")
      read -r st cc < <(gh api \
        "repos/$REPO/actions/workflows/$base/runs?branch=$default_branch&per_page=1" \
        --jq '.workflow_runs[0] | "\(.status) \(.conclusion)"' 2>/dev/null)
      [ "$st" = "completed" ] || continue
      case "$cc" in
        failure|timed_out)
          echo "ADVISORY: the scheduled backstop '$base' is $cc on $default_branch of $REPO."
          echo "ADVISORY:   The verdict above is about $FULL alone and is unaffected. A red backstop"
          echo "ADVISORY:   means a failure the per-PR test selection let through is already merged."
          echo "ADVISORY:   https://github.com/$REPO/actions/workflows/$base"
          ;;
      esac
    done
  fi
} 2>/dev/null || true

exit $rc
