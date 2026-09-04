#!/usr/bin/env bash
# profile-loop.sh — where did this arc's wall-clock go, and which lever is worth pulling?
#
#   profile-loop.sh <round-dir>... [--json OUT] [--round TRACK:N] [--arc DIR]
#
# Now a thin front for `loop.py profile`.  Given a dir with a `jobs.jsonl` ledger (written by
# `loop.py run` / `run-codex.sh --arc …`) it reports exact, attributed timings per track and
# round; for a flat artifact dir with no ledger it falls back to the birth→mtime heuristics
# this script used to carry, and reports every such artifact as UNATTRIBUTED (lever L7).
# Cheap by construction: it reads file stats and the head/tail of each log, never the tree.
set -eu
exec python3 "$(cd "$(dirname "$0")" && pwd)/loop.py" profile "$@"
