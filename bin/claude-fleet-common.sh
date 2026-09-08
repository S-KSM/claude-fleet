# claude-fleet-common.sh: shared helpers, sourced by the other bin/claude-fleet-* scripts.
# Not meant to be executed directly.

SESSION_NAME="claude-fleet"
MAIN_BRANCH="${CLAUDE_FLEET_MAIN_BRANCH:-main}"

require_repo() {
  BASE_DIR="$(git rev-parse --show-toplevel 2>/dev/null)" || {
    echo "Error: Must be run inside a Git repository." >&2
    exit 1
  }
  WORKTREE_ROOT="$BASE_DIR/.worktrees"
}

require_no_session() {
  if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    echo "Error: tmux session '$SESSION_NAME' already exists. Attach with 'tmux attach -t $SESSION_NAME' or run claude-fleet-clean first." >&2
    exit 1
  fi
}

slugify() {
  echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '-' | tr -cd '[:alnum:]-_'
}

ensure_gitignore() {
  local gitignore_file="$BASE_DIR/.gitignore"
  [ -f "$gitignore_file" ] || touch "$gitignore_file"
  if ! grep -qxF ".worktrees/" "$gitignore_file"; then
    { echo ""; echo "# Claude Code fleet worktrees"; echo ".worktrees/"; } >> "$gitignore_file"
    echo "[fleet] Added .worktrees/ to .gitignore"
  fi
}

# ensure_worktree <tree_dir> <branch>
# Creates the worktree if missing, reusing the branch if it already exists
# (e.g. left behind by claude-fleet-clean). Refuses to touch a directory
# that exists but isn't a registered worktree, rather than silently
# launching Claude somewhere unmanaged.
ensure_worktree() {
  local tree_dir="$1" branch="$2"

  if git worktree list --porcelain | grep -qx "worktree $tree_dir"; then
    return 0
  fi

  if [ -e "$tree_dir" ]; then
    echo "Error: $tree_dir exists but is not a registered git worktree. Remove it manually or pick a different task name." >&2
    return 1
  fi

  if git rev-parse --verify --quiet "refs/heads/$branch" >/dev/null; then
    git worktree add "$tree_dir" "$branch"
  else
    git worktree add "$tree_dir" -b "$branch"
  fi
}

# install_cmd_for <dir>
# Prints a dependency-install shell command for the given worktree, or
# nothing if no recognized lockfile/manifest is present.
install_cmd_for() {
  local dir="$1"
  if [ -f "$dir/pnpm-lock.yaml" ]; then
    echo "pnpm install --frozen-lockfile || pnpm install"
  elif [ -f "$dir/package.json" ]; then
    echo "npm install"
  elif [ -f "$dir/poetry.lock" ]; then
    echo "poetry install --sync"
  elif [ -f "$dir/requirements.txt" ]; then
    echo "pip install -r requirements.txt"
  fi
}

# --- Optional team-brain integration -----------------------------------
# Everything below is inert unless a project opts in via .claude-fleet.conf
# (see examples/.claude-fleet.conf.example). Default fleet usage is unaffected.

# load_fleet_config: source ./.claude-fleet.conf (repo root) if present.
# Must be called after require_repo, since it relies on BASE_DIR.
load_fleet_config() {
  local conf_file="$BASE_DIR/.claude-fleet.conf"
  # shellcheck disable=SC1090
  [ -f "$conf_file" ] && source "$conf_file"
  TEAM_BRAIN_DIR="${CLAUDE_FLEET_TEAM_BRAIN_DIR:-$TEAM_BRAIN_DIR}"
}

# team_brain_enabled: true if TEAM_BRAIN_DIR is configured and looks like
# a team-brain checkout.
team_brain_enabled() {
  [ -n "$TEAM_BRAIN_DIR" ] && [ -d "$TEAM_BRAIN_DIR/plans" ]
}

# brain_map_file: path to the slug -> plan-file map written by
# claude-fleet-brain-tasks and read back by claude-fleet-ship.
brain_map_file() {
  echo "$WORKTREE_ROOT/.brain-map"
}

# sync_plan_pr <slug> <pr_url>
# Best-effort: flips a synced plan's status to pr-open and records
# related_pr. Matches ready-to-ship (never implemented) as well as
# implemented-pending-pr (the normal case — /implement already advanced
# the plan past ready-to-ship by the time claude-fleet-ship runs). Never
# fatal — a missing map entry or plan file is silently skipped so this
# can't break claude-fleet-ship.
sync_plan_pr() {
  local slug="$1" pr_url="$2"
  team_brain_enabled || return 0
  local map_file; map_file="$(brain_map_file)"
  [ -f "$map_file" ] || return 0

  local plan
  plan="$(awk -F'\t' -v s="$slug" '$1==s{print $2; exit}' "$map_file")"
  [ -n "$plan" ] && [ -f "$plan" ] || return 0

  local pr_number="${pr_url##*/}"
  local has_related=0
  grep -q '^related_pr:' "$plan" && has_related=1

  local tmp; tmp="$(mktemp)"
  awk -v pr="$pr_number" -v has_related="$has_related" '
    /^status:[ \t]*(ready to ship|implemented-pending-pr)[ \t]*$/ {
      print "status: pr-open"
      if (has_related == 0) print "related_pr: " pr
      next
    }
    /^related_pr:/ { print "related_pr: " pr; next }
    { print }
  ' "$plan" > "$tmp"
  mv "$tmp" "$plan"

  echo "==> team-brain: synced $plan (status: pr-open, related_pr: $pr_number)"
}
