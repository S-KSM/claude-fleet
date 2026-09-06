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
