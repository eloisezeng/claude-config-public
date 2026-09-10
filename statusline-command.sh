#!/bin/bash
# The user's Claude Code status line.
# Order: cwd (worktree-aware) -> git branch -> model name -> context remaining %.
# Muted/dim styling so it reads as terminal chrome, not competing with the conversation.
# Managed by the statusline-setup agent — use it again for further changes.

input=$(cat)

cwd=$(printf '%s' "$input" | jq -r '.workspace.current_dir // .cwd // empty')
model_name=$(printf '%s' "$input" | jq -r '.model.display_name // empty')
remaining=$(printf '%s' "$input" | jq -r '.context_window.remaining_percentage // empty')
repo_name_json=$(printf '%s' "$input" | jq -r '.workspace.repo.name // empty')
worktree_name=$(printf '%s' "$input" | jq -r '.workspace.git_worktree // empty')

[ -z "$cwd" ] && cwd="$PWD"
cd "$cwd" 2>/dev/null

# ---- colors: dim, muted "chrome" palette ----
TEXT=$'\033[2;38;5;250m'
SEP_COLOR=$'\033[2;38;5;238m'
RESET=$'\033[0m'
SEP="${SEP_COLOR} · ${TEXT}"

abbrev_home() {
  case "$1" in
    "$HOME"/*) printf '~/%s' "${1#$HOME/}" ;;
    "$HOME") printf '~' ;;
    *) printf '%s' "$1" ;;
  esac
}

# ---- directory field, readable for git worktrees ----
# Prefer the JSON-provided worktree name; fall back to the .claude/worktrees/<name>
# convention this repo uses, so a long nested path never gets printed raw.
if [ -z "$worktree_name" ]; then
  case "$cwd" in
    */.claude/worktrees/*)
      worktree_name="${cwd#*/.claude/worktrees/}"
      worktree_name="${worktree_name%%/*}"
      ;;
  esac
fi

if [ -n "$worktree_name" ]; then
  case "$cwd" in
    */.claude/worktrees/*)
      repo_root="${cwd%%/.claude/worktrees/*}"
      tail_path="${cwd#*/.claude/worktrees/"$worktree_name"}"
      tail_path="${tail_path#/}"
      ;;
    *)
      repo_root=""
      tail_path=""
      ;;
  esac
  if [ -n "$repo_name_json" ]; then
    repo_label="$repo_name_json"
  elif [ -n "$repo_root" ]; then
    repo_label=$(basename "$repo_root")
  else
    repo_label=$(basename "$cwd")
  fi
  dir_display="${repo_label}/${worktree_name}"
  [ -n "$tail_path" ] && dir_display="${dir_display}/${tail_path}"
else
  dir_display=$(abbrev_home "$cwd")
fi

# ---- git branch field, silently omitted outside a repo ----
branch=""
if git --no-optional-locks rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  branch=$(git --no-optional-locks symbolic-ref --quiet --short HEAD 2>/dev/null)
  if [ -z "$branch" ]; then
    short_sha=$(git --no-optional-locks rev-parse --short HEAD 2>/dev/null)
    [ -n "$short_sha" ] && branch="detached:${short_sha}"
  fi
fi

# ---- context-window remaining field ----
ctx_display=""
if [ -n "$remaining" ] && [ "$remaining" != "null" ]; then
  ctx_display="$(printf '%.0f' "$remaining")%"
fi

[ -z "$model_name" ] && model_name="Claude"

# ---- assemble, in order: dir, branch, model, context% ----
parts=()
[ -n "$dir_display" ] && parts+=("$dir_display")
[ -n "$branch" ] && parts+=("$branch")
[ -n "$model_name" ] && parts+=("$model_name")
[ -n "$ctx_display" ] && parts+=("$ctx_display")

line=""
for p in "${parts[@]}"; do
  if [ -z "$line" ]; then
    line="$p"
  else
    line="${line}${SEP}${p}"
  fi
done

printf '%s%s%s\n' "$TEXT" "$line" "$RESET"
