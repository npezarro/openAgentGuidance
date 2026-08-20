#!/usr/bin/env bash
# Install pre-commit and pre-push security hooks to repos.
#
# Usage:
#   bash install-hooks.sh                    # Install to current repo
#   bash install-hooks.sh --all-public       # Install to all local public repos
#   bash install-hooks.sh --all-local        # Install to ALL local repos (private too)
#   bash install-hooks.sh /path/to/repo      # Install to specific repo
#
# Hooks call security-scan.sh from your private context repo to detect sensitive
# identifiers before they reach a public remote.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRE_COMMIT="$SCRIPT_DIR/git-pre-commit"
PRE_PUSH="$SCRIPT_DIR/git-pre-push"
COMMIT_MSG="$SCRIPT_DIR/git-commit-msg"

install_hooks() {
  local repo_path="$1"
  local hooks_dir

  # --git-common-dir so a worktree checkout installs to the shared hooks dir
  # instead of failing on "$repo_path/.git", which is a FILE inside a worktree.
  hooks_dir=$(git -C "$repo_path" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  if [ -z "$hooks_dir" ]; then
    echo "  SKIP: $repo_path (not a git repo)"
    return
  fi
  hooks_dir="$hooks_dir/hooks"

  mkdir -p "$hooks_dir"

  # Install pre-commit (scans staged file content)
  if [ -f "$PRE_COMMIT" ]; then
    cp "$PRE_COMMIT" "$hooks_dir/pre-commit"
    chmod +x "$hooks_dir/pre-commit"
  fi

  # Install commit-msg (scans the message: published as widely as the diff)
  if [ -f "$COMMIT_MSG" ]; then
    cp "$COMMIT_MSG" "$hooks_dir/commit-msg"
    chmod +x "$hooks_dir/commit-msg"
  fi

  # Install pre-push
  if [ -f "$PRE_PUSH" ]; then
    cp "$PRE_PUSH" "$hooks_dir/pre-push"
    chmod +x "$hooks_dir/pre-push"
  fi

  echo "  OK: $repo_path"
}

install_global_template() {
  local template_dir="$HOME/.git-templates/hooks"
  mkdir -p "$template_dir"

  if [ -f "$PRE_COMMIT" ]; then
    cp "$PRE_COMMIT" "$template_dir/pre-commit"
    chmod +x "$template_dir/pre-commit"
  fi

  if [ -f "$COMMIT_MSG" ]; then
    cp "$COMMIT_MSG" "$template_dir/commit-msg"
    chmod +x "$template_dir/commit-msg"
  fi

  if [ -f "$PRE_PUSH" ]; then
    cp "$PRE_PUSH" "$template_dir/pre-push"
    chmod +x "$template_dir/pre-push"
  fi

  # Set global git template directory
  git config --global init.templateDir "$HOME/.git-templates"
  echo "  OK: Global template installed at $template_dir"
  echo "  New clones will auto-install hooks."
}

if [ "${1:-}" = "--all-local" ]; then
  # Every local repo, private ones included.
  #
  # --all-public is not enough to ship a FIX to these hooks. The hooks are copies:
  # editing them here changes nothing until each .git/hooks copy is replaced, and
  # they are installed far beyond the public repos, because init.templateDir puts
  # them in every new clone. When the visibility-wording bug was fixed
  # (2026-08-17), all 89 local repos plus the global template were still running
  # the pre-fix copy and --all-public would have left every private one behind --
  # including the repo whose wrong message started the investigation.
  echo "Installing hooks to all local repos (private included)..."
  echo ""
  COUNT=0
  for repo_path in "$HOME"/repos/*/; do
    repo_path="${repo_path%/}"
    git -C "$repo_path" rev-parse --git-dir >/dev/null 2>&1 || continue
    install_hooks "$repo_path"
    COUNT=$((COUNT + 1))
  done

  echo ""
  echo "Installing global git template..."
  install_global_template

  echo ""
  echo "Done. $COUNT local repos updated."

elif [ "${1:-}" = "--all-public" ]; then
  echo "Installing hooks to all local public repos..."
  echo ""

  # Get list of public repos
  # NOTE: --limit is required; gh defaults to 30 and silently caps the list, which
  # left public repos beyond the first 30 (e.g. claude-auto-merger) unprotected.
  PUBLIC_REPOS=$(gh repo list "${GH_OWNER:-$(gh api user --jq .login 2>/dev/null)}" --public --limit 1000 --json name -q '.[].name' 2>/dev/null || echo "")

  if [ -z "$PUBLIC_REPOS" ]; then
    echo "ERROR: Could not fetch public repo list (gh CLI issue?)"
    exit 1
  fi

  while IFS= read -r repo_name; do
    repo_path="$HOME/repos/$repo_name"
    if [ -d "$repo_path" ]; then
      install_hooks "$repo_path"
    else
      echo "  SKIP: $repo_name (not cloned locally)"
    fi
  done <<< "$PUBLIC_REPOS"

  echo ""
  echo "Installing global git template..."
  install_global_template

  echo ""
  echo "Done. All public repos protected."

elif [ -n "${1:-}" ]; then
  echo "Installing hooks to $1..."
  install_hooks "$1"

else
  # Default: install to repo containing this script (this repo)
  REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
  echo "Installing hooks to $REPO_ROOT..."
  install_hooks "$REPO_ROOT"
fi
