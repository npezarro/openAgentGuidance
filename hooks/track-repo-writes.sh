#!/usr/bin/env bash
# PostToolUse hook for Bash|Edit|Write: records which repo files this session wrote.
#
# TWO ledgers, deliberately separate:
#
#   /tmp/claude-repos-touched-{session_id}   Edit/Write only. PROOF of authorship.
#       Consumed by check-unpushed.sh (Stop gate) and worktree-guard.sh.
#       A false entry here blocks a session's exit, so only real tool-level writes
#       are allowed in.
#
#   /tmp/claude-repos-claimed-{session_id}   Bash-inferred probable writes (heredocs,
#       redirects, sed -i, python rewrites). ADVISORY only, consumed by claim-guard.sh.
#       Inference is heuristic, so it never reaches the push gate. This exists because
#       a file that nearly got clobbered (a progress.md rewritten via a python heredoc)
#       was invisible to the Edit/Write tracker while a second live session was
#       committing the same path.
#
# Both use TAB-separated:  <repo_root>\t<file_path>\t<epoch_seconds>
# The epoch is field 3 so `cut -f1` and two-field readers keep working.
set -euo pipefail

INPUT=$(cat)
SESSION_ID=$(echo "$INPUT" | jq -r '.session_id // empty' 2>/dev/null)
[ -z "$SESSION_ID" ] && exit 0

# Per-session liveness marker. claim-guard and worktree-guard only treat another
# session's ledger as a live competing writer while this file is fresh, so without
# it neither guard ever fires. Install this hook without a matcher so every tool
# call refreshes it, not only writes.
touch "/tmp/claude-session-alive-${SESSION_ID}" 2>/dev/null || true

LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/write-target-inference.sh"
[ -f "$LIB" ] || exit 0
# shellcheck source=lib/write-target-inference.sh
. "$LIB"

TOOL=$(echo "$INPUT" | jq -r '.tool_name // empty' 2>/dev/null)
NOW=$(date +%s)

# log_path <file_path> <ledger_file>
log_path() {
  local repo_root
  repo_root=$(wti_repo_root "$1")
  [ -z "$repo_root" ] && return 0
  printf '%s\t%s\t%s\n' "$repo_root" "$1" "$NOW" >> "$2"
}

# Commit ledger: /tmp/claude-commits-{session_id}, <repo_root>\t<sha>\t<epoch>.
# The Edit/Write ledger cannot see work written through Bash (heredocs, sed -i), which
# permissive-mode sessions do constantly, so a session could commit Bash-written files
# and stop with the push gate silent (measured: roughly one scored session in six).
# A commit is a far stronger authorship signal than a write inference: the session ran
# `git commit` and the repo's HEAD reflog shows a commit entry from the last few
# minutes. Consumed by check-unpushed.sh.
record_commits() {
  local cmd="$1" cwd="$2" d root line sha when subj
  printf '%s\n' "$cmd" \
    | grep -qE '(^|[;&|(]|&&|\|\|)[[:space:]]*git([[:space:]]+-[cC][[:space:]]+[^[:space:];&|]+)*[[:space:]]+commit([[:space:]]|$)' \
    || return 0
  {
    printf '%s\n' "$cwd"
    printf '%s\n' "$cmd" | grep -oE 'git[[:space:]]+-C[[:space:]]+[^[:space:];&|]+' \
      | sed -E 's/^git[[:space:]]+-C[[:space:]]+//' | tr -d "'\"" || true
  } | while IFS= read -r d; do
    [ -z "$d" ] && continue
    d=$(wti_expand "$d" "$cmd")
    case "$d" in /*) ;; *) d="${cwd}/${d}" ;; esac
    [ -d "$d" ] || continue
    root=$(git -C "$d" rev-parse --show-toplevel 2>/dev/null) || continue
    line=$(git -C "$root" log -g -1 --date=unix --format='%H%x09%gd%x09%gs' HEAD 2>/dev/null) || continue
    sha=$(printf '%s' "$line" | cut -f1)
    when=$(printf '%s' "$line" | cut -f2 | grep -oE '[0-9]{9,}' || true)
    subj=$(printf '%s' "$line" | cut -f3)
    case "$subj" in commit*) ;; *) continue ;; esac
    [ -n "$sha" ] && [ -n "$when" ] && [ $((NOW - when)) -le 300 ] || continue
    grep -qF "$sha" "$COMMIT_LEDGER" 2>/dev/null && continue
    printf '%s\t%s\t%s\n' "$root" "$sha" "$NOW" >> "$COMMIT_LEDGER"
  done
}
COMMIT_LEDGER="/tmp/claude-commits-${SESSION_ID}"

if [ "$TOOL" = "Bash" ]; then
  CMD=$(echo "$INPUT" | jq -r '.tool_input.command // empty' 2>/dev/null)
  [ -z "$CMD" ] && exit 0
  PAYLOAD_CWD=$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)
  case "$CMD" in
    *commit*) record_commits "$CMD" "$(wti_effective_cwd "$CMD" "$PAYLOAD_CWD")" || true ;;
  esac
  wti_is_write_cmd "$CMD" || exit 0

  EFF_CWD=$(wti_effective_cwd "$CMD" "$PAYLOAD_CWD")
  [ -n "$EFF_CWD" ] && [ -d "$EFF_CWD" ] || exit 0

  LEDGER="/tmp/claude-repos-claimed-${SESSION_ID}"
  while IFS= read -r cand; do
    [ -n "$cand" ] && log_path "$cand" "$LEDGER"
  done < <(wti_candidate_paths "$CMD" "$EFF_CWD")
  exit 0
fi

FILE_PATH=$(echo "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
[ -z "$FILE_PATH" ] && exit 0
log_path "$FILE_PATH" "/tmp/claude-repos-touched-${SESSION_ID}"
exit 0
