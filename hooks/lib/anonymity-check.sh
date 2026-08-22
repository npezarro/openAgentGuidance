#!/usr/bin/env bash
# anonymity-check.sh: shared checks for anything a PUBLIC repo publishes.
#
# A repo publishes more than its diff: commit messages, PR titles and bodies,
# issue text, release notes. Each of those is a separate write path, and each
# one previously had its own (usually absent) gate. This library is the single
# definition of "what may not go out", so a fix in one place covers all of them.
#
# Sourced by hooks/git-commit-msg and hooks/public-metadata-guard.sh. Those are
# COPIED into .git/hooks (and into ~/.git-templates), so source this by absolute
# path -- a relative path resolves against the copy's location, where lib/ does
# not exist:
#
#   source "$HOME/repos/openAgentGuidance/hooks/lib/anonymity-check.sh"
#
# Every function is side-effect free and prints to stdout; callers decide how to
# report and whether to block.

ANON_SCAN_SCRIPT="${ANON_SCAN_SCRIPT:-$HOME/repos/openAgentGuidance/scripts/secret-scan.sh}"

# ── repo_visibility [dir] ─────────────────────────────────────────────
# Echoes PUBLIC / PRIVATE / UNKNOWN. Caches in the repo's git dir, because a
# network call per commit is too slow.
#
# The cache EXPIRES (ANON_VIS_TTL_DAYS, default 7). It used to be permanent, on
# the reasoning that visibility "changes about once in a repo's lifetime". That
# is true and still the wrong call, because the two directions are not
# symmetric. git-commit-msg and public-metadata-guard.sh block only when
# visibility is PUBLIC, so a repo flipped private -> public keeps its stale
# PRIVATE entry forever and those gates silently stop protecting it. A gate that
# quietly turns itself off is worse than one that occasionally costs a `gh` call.
# (Audited 2026-08-17: 84 cached repos, all entries 15 days old and never
# revalidated. Two had drifted -- both in the harmless over-gating direction,
# so nothing was under-protected yet. The mechanism permitted the other
# direction; nothing detected it.)
#
# A failed lookup falls back to the stale value rather than UNKNOWN, so an
# offline push keeps the last known answer instead of downgrading to the
# treat-as-public wording. UNKNOWN is never written to the cache.
repo_visibility() {
  local dir="${1:-.}" cache vis remote slug stale="" ttl="${ANON_VIS_TTL_DAYS:-7}"
  cache=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || { echo "UNKNOWN"; return; }
  cache="$cache/.repo-visibility"

  if [ -f "$cache" ]; then
    stale=$(cat "$cache" 2>/dev/null)
    # find prints the path only when the file is OLDER than the TTL, so empty
    # output means the entry is still fresh.
    if [ -z "$(find "$cache" -maxdepth 0 -mtime "+$ttl" 2>/dev/null)" ]; then
      echo "$stale"
      return
    fi
  fi

  remote=$(git -C "$dir" remote get-url origin 2>/dev/null) || { echo "${stale:-UNKNOWN}"; return; }
  if command -v gh >/dev/null 2>&1 && [[ "$remote" =~ github\.com[:/]([^/]+/[^/.]+) ]]; then
    slug="${BASH_REMATCH[1]%.git}"
    vis=$(gh repo view "$slug" --json visibility -q '.visibility' 2>/dev/null || echo "UNKNOWN")
    if [ "$vis" != "UNKNOWN" ]; then
      echo "$vis" > "$cache"
      echo "$vis"
      return
    fi
    # Lookup failed (offline, auth expired, rate limit). Keep the old answer and
    # leave the cache mtime alone so the next run retries instead of trusting it.
    echo "${stale:-UNKNOWN}"
    return
  fi
  echo "${stale:-UNKNOWN}"
}

# ── visibility_notice <visibility> [slug] ─────────────────────────────
# Prints the one accurate sentence about why this repo is being gated, so the
# gates cannot contradict each other.
#
# git-pre-push printed "This is a PUBLIC repo ($slug)." UNCONDITIONALLY, seven
# lines below the "Private repo, scanned anyway" branch it had just taken: a
# private repo was told both at once (observed 2026-08-17 on a PRIVATE repo
# whose cached visibility was correctly PRIVATE). git-pre-commit had the milder
# form of the same bug, asserting PUBLIC in an else-branch that also catches
# UNKNOWN. Detection was never wrong in either case; both hooks just hardcoded
# the conclusion, because each carried its own copy of this wording.
visibility_notice() {
  local vis="${1:-UNKNOWN}" slug="${2:-this repo}"
  case "$vis" in
    PRIVATE)
      echo "Private repo ($slug), scanned anyway: repos can go public, and vendored"
      echo "files carry identifiers into other repos."
      ;;
    PUBLIC)
      echo "This is a PUBLIC repo ($slug)."
      ;;
    *)
      echo "Could not determine visibility for $slug, so it is treated as public."
      ;;
  esac
}

# ── scan_identifiers <<< text ─────────────────────────────────────────
# Reads text on stdin. Prints security-scan.sh's report and returns 1 if the
# text trips the sensitive-identifier list. Returns 0 (and prints nothing) when
# clean, or when the scanner is unavailable -- an absent scanner must not be an
# implicit block, but the caller is told via scan_identifiers_available.
scan_identifiers() {
  local out
  [ -x "$ANON_SCAN_SCRIPT" ] || return 0
  out=$("$ANON_SCAN_SCRIPT" 2>&1 || true)
  if printf '%s' "$out" | grep -q "BLOCKED"; then
    printf '%s\n' "$out"
    return 1
  fi
  return 0
}

scan_identifiers_available() { [ -x "$ANON_SCAN_SCRIPT" ]; }

# ── scan_attribution <<< text ─────────────────────────────────────────
# Reads text on stdin. Prints the offending lines and returns 1 if the text
# publishes a directive attributed to a named person.
#
# Deliberately narrow. NAMING the operator is fine ("the operator dictates via
# speech-to-text"); publishing them ISSUING an instruction is not. Each pattern
# needs the name AND a quoted or dated directive on the SAME line. grep is
# line-based, so a directive that wraps still trips on its first line.
#
# Set OPERATOR_NAME to the name that should not appear issuing directives in a
# public commit message. Unset, the name-specific patterns are skipped and only
# the generic pronoun patterns run.
#
# Calibrated over ~850 commits of real history: one match, a real leak. A looser
# variant taking a bare `<name> <date>` also flagged "(per <name> 2026-07-01)",
# which is attribution without exposure and not the target, so the date pattern
# requires a following colon.
scan_attribution() {
  local hits args=()
  if [ -n "${OPERATOR_NAME:-}" ]; then
    args+=(-e "\\b${OPERATOR_NAME}\\b[^|]*[:,][[:space:]]*\"")
    args+=(-e "\\b${OPERATOR_NAME}\\b[,[:space:]]+[0-9]{4}-[0-9]{2}-[0-9]{2}[^|]*:")
    args+=(-e "\\b(${OPERATOR_NAME}|the user|he|she|they) (said|says|asked for|told me|wants|requested|corrected)\\b")
  else
    args+=(-e '\b(the user|the operator) (said|says|asked for|told me|wants|requested|corrected)\b')
  fi
  hits=$(grep -nE "${args[@]}" || true)
  if [ -n "$hits" ]; then
    printf '%s\n' "$hits"
    return 1
  fi
  return 0
}

# ── anon_split_advice ─────────────────────────────────────────────────
# The remediation text every caller shows, so the guidance stays identical
# whichever gate fired.
anon_split_advice() {
  cat <<'EOF'
Public repos carry the RULE. The private repo carries who asked for it,
what they said, and which people/companies/rooms were involved.
See guidance/secrets-hygiene.md, 'Public repo commits are anonymous'.
EOF
}
