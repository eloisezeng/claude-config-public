# usage: ci-green.sh <sha> [base-ref]   (run from inside the repo; REPO=owner/name, else inferred)
#
# Is CI GREEN on this exact commit? Fails CLOSED. Never reads `gh pr checks` -- that rollup LAGS and
# has reported "0 pending of 1" while the check-runs API showed 4 checks with 3 still running.  -> VERDICT: GREEN | NOT-GREEN <why>; exit 0 iff GREEN
set -u
export GH_TOKEN=$(gh auth token --user your-org)
FULL=$(git rev-parse "$1")
REPO="${REPO:-$(gh repo view --json nameWithOwner --jq .nameWithOwner)}"
BASE_REF="${2:-origin/main}"
D=/tmp/.cig.$$; mkdir -p $D
# A pull_request run executes the workflow from the MERGE ref, so a job only the BASE defines still
# runs -- deriving the required set from the head alone would never require it. Union both sides,
# parsing each file SEPARATELY (concatenating them makes the second file's `on:` keys look like jobs).
git show "$FULL:.github/workflows/ci.yml"     > $D/head.yml 2>/dev/null || true
git show "$BASE_REF:.github/workflows/ci.yml" > $D/base.yml 2>/dev/null || true
gh api "repos/$REPO/commits/$FULL/check-runs" --paginate \
  --jq '.check_runs[] | [.name,.status,.conclusion,(.id|tostring)] | @tsv' > $D/runs.tsv
python3 "$(dirname "$0")/ci-derive.py" "$FULL" "$D"
rc=$?; rm -rf $D; exit $rc
