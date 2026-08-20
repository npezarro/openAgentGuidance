#!/usr/bin/env bash
# public-metadata-guard.sh — PreToolUse (Bash) gate for GitHub text that is
# published without ever passing through git.
#
# The commit path is now gated three ways (pre-commit on content, commit-msg on
# the message, pre-push on the diff). None of them sees a PR title, a PR body,
# an issue, a comment, or a release note: `gh pr create --body "..."` posts
# straight to a public API. The learning-agent opens PRs on a PUBLIC repo on
# every run, so this was the widest remaining ungated write path.
#
# Blocks only on PUBLIC repos, for the same reason git-commit-msg does:
# attribution and named specifics are exactly what private repos are for.
#
# Input: PreToolUse JSON on stdin. Deny protocol: message on stderr, exit 2.
#
# Register in ~/.claude/settings.json under PreToolUse, matcher "Bash".

set -uo pipefail

LIB=""
for cand in "$(dirname "$0")/lib/anonymity-check.sh" \
            "$HOME/repos/openAgentGuidance/hooks/lib/anonymity-check.sh"; do
  [ -r "$cand" ] && { LIB="$cand"; break; }
done
if [ -z "$LIB" ]; then
  # Never block on our own breakage, but never do it quietly either.
  echo "WARNING: anonymity-check.sh not found; gh publish gate DISABLED." >&2
  exit 0
fi
# shellcheck source=lib/anonymity-check.sh
source "$LIB"

INPUT=$(cat 2>/dev/null || true)
[ -n "$INPUT" ] || exit 0

CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
CWD=$(printf '%s' "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
[ -n "$CMD" ] || exit 0

# ── Does this command publish text to GitHub? ─────────────────────────
# Creating or editing a PR/issue/release, or commenting on one. `gh pr merge`,
# `gh pr list`, `gh pr view` publish nothing and are not matched.
echo "$CMD" | grep -qE '\bgh[[:space:]]+(pr|issue|release)[[:space:]]+(create|edit|comment)\b' || exit 0

# ── Which repo? ───────────────────────────────────────────────────────
# An explicit --repo wins; otherwise the command acts on the cwd's repo.
TARGET_DIR="${CWD:-.}"
if [[ "$CMD" =~ --repo[[:space:]]+([^[:space:]\"\']+) ]]; then
  SLUG="${BASH_REMATCH[1]}"
  VIS=$(gh repo view "$SLUG" --json visibility -q '.visibility' 2>/dev/null || echo "UNKNOWN")
else
  VIS=$(repo_visibility "$TARGET_DIR")
fi
[ "$VIS" = "PUBLIC" ] || exit 0

# ── Assemble the text this command would publish ──────────────────────
# The whole command string is scanned rather than parsed for --title/--body.
# Parsing shell quoting correctly here is a losing game (nested quotes, $(...),
# heredocs), and over-scanning is the safe direction: the extra text is flags
# and paths, which do not trip either check. Bodies passed by file are read,
# since --body-file is how long PR descriptions are actually written.
TEXT="$CMD"
while read -r f; do
  [ -n "$f" ] && [ -r "$f" ] && TEXT="$TEXT
$(cat "$f")"
done < <(printf '%s\n' "$CMD" | grep -oE '(--body-file|--notes-file|-F)[[:space:]]+[^[:space:]"'"'"']+' | awk '{print $2}')

deny() {  # $1 = headline, $2 = detail
  cat >&2 <<EOF

=========================================
  BLOCKED: publishing to a PUBLIC repo
=========================================

$1

$2

$(anon_split_advice)

This is \`gh\` posting straight to the GitHub API -- no commit, so no commit
gate ever sees it. Rewrite the title/body, or target the private repo.
EOF
  exit 2
}

# ── Check 1: sensitive identifiers ────────────────────────────────────
if scan_identifiers_available; then
  if ! OUT=$(printf '%s\n' "$TEXT" | scan_identifiers); then
    deny "Sensitive identifiers in the PR/issue text:" "$OUT
See the identifier list your SCAN_SCRIPT uses for replacement values."
  fi
fi

# ── Check 2: direct attribution ───────────────────────────────────────
if ! HITS=$(printf '%s\n' "$TEXT" | scan_attribution); then
  deny "Direct attribution in text bound for a PUBLIC repo:" "$HITS

Rewrite it to state the rule and the evidence, dropping who asked."
fi

exit 0
