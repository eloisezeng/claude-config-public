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
# Do NOT hard-code an account. Measured 2026-09-01: a pinned `--user your-org` token 404s on
# your-companyAI/your-other-project, which the active account reads fine -- and a private repo answers 404
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
# A pull_request run executes the workflow from the MERGE ref, so a job only the BASE defines still
# runs -- deriving the required set from the head alone would never require it. Union both sides,
# parsing each file SEPARATELY (concatenating them makes the second file's `on:` keys look like jobs).
git show "$FULL:.github/workflows/ci.yml"     > $D/head.yml 2>/dev/null || true
git show "$BASE_REF:.github/workflows/ci.yml" > $D/base.yml 2>/dev/null || true
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
rc=$?; rm -rf $D; exit $rc
