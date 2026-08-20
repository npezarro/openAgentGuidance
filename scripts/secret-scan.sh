#!/usr/bin/env bash
# secret-scan.sh — deterministic gate for secrets and private identifiers.
#
# The git hooks in hooks/ call this. It ships with working defaults so the gate
# is live the moment you install it: a hook whose scanner is missing prints a
# warning and passes everything, which looks identical to a clean repo.
#
# Two pattern sources:
#   1. The built-in SECRET patterns below: credential SHAPES (key formats, private
#      key headers, connection strings). These are universal.
#   2. Your own identifiers, one regex per line, in a file this script never
#      publishes: usernames, hostnames, internal domains, private repo names.
#      Default location: $HOME/.config/open-agent-guidance/identifiers.txt
#      Override with IDENTIFIERS_FILE. Create it with --init.
#
# Usage:
#   cat file | secret-scan.sh              # scan stdin
#   secret-scan.sh --file path             # scan a file
#   secret-scan.sh --diff [range]          # scan added lines of a git diff
#   secret-scan.sh --repo-scan [dir]       # scan all tracked files
#   secret-scan.sh --patterns              # print the active pattern list
#   secret-scan.sh --init                  # create the identifiers file
#   secret-scan.sh --selftest              # prove the gate can actually fail
#
# Exit: 0 clean, 1 violations found, 2 usage error.

set -uo pipefail

IDENTIFIERS_FILE="${IDENTIFIERS_FILE:-$HOME/.config/open-agent-guidance/identifiers.txt}"

# Credential shapes. Deliberately narrow: a pattern that fires on ordinary prose
# gets disabled by whoever it annoys, and then nothing is checked at all.
read -r -d '' SECRET_PATTERNS <<'EOF' || true
-----BEGIN [A-Z ]*PRIVATE KEY-----
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
gh[pousr]_[A-Za-z0-9]{30,}
github_pat_[A-Za-z0-9_]{50,}
xox[baprs]-[A-Za-z0-9-]{10,}
sk-[A-Za-z0-9]{32,}
sk-ant-[A-Za-z0-9_-]{20,}
AIza[0-9A-Za-z_-]{35}
ya29\.[0-9A-Za-z_-]+
eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}\.
https://hooks\.slack\.com/services/[A-Za-z0-9/]+
https://discord(app)?\.com/api/webhooks/[0-9]+/[A-Za-z0-9_-]+
(postgres|postgresql|mysql|mongodb(\+srv)?|redis|amqp)://[^[:space:]/@]+:[^[:space:]/@]+@
(?i)(api[_-]?key|secret|passwd|password|token|bearer)[[:space:]]*[:=][[:space:]]*['"][^'"[:space:]]{12,}['"]
EOF

build_patterns() {
  printf '%s\n' "$SECRET_PATTERNS" | grep -v '^[[:space:]]*$'
  if [ -f "$IDENTIFIERS_FILE" ]; then
    grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$IDENTIFIERS_FILE" || true
  fi
}

# A repo may legitimately contain something shaped like a secret: a docs example
# using placeholder credentials, a vendor's published example key, this script's
# own selftest fixture. Without an exemption path those fire on every run, and a
# warning nobody can act on trains people to ignore the gate entirely.
#
# Put one regex per line in .secret-scan-allow at the repo root. A matching LINE
# is exempt. Keep entries narrow: exempt the example, not the pattern.
ALLOW_FILE="${ALLOW_FILE:-.secret-scan-allow}"

scan_stream() {
  local pat_file hits
  pat_file="$(mktemp)"; trap 'rm -f "$pat_file"' RETURN
  build_patterns > "$pat_file"
  # A gate that cannot match anything reports every input as clean. Refuse.
  if [ ! -s "$pat_file" ]; then
    echo "secret-scan: no patterns loaded; refusing to report a result" >&2
    return 2
  fi
  hits="$(grep -n -E -f "$pat_file" - 2>/dev/null || true)"
  if [ -n "$hits" ] && [ -f "$ALLOW_FILE" ]; then
    local allow
    allow="$(grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$ALLOW_FILE" || true)"
    if [ -n "$allow" ]; then
      hits="$(printf '%s\n' "$hits" | grep -v -E -f <(printf '%s\n' "$allow") || true)"
    fi
  fi
  if [ -n "$hits" ]; then
    echo "BLOCKED: possible secret or private identifier:"
    # Show the line number and a truncated match, never the whole secret.
    printf '%s\n' "$hits" | cut -c1-120 | head -20
    return 1
  fi
  return 0
}

case "${1:-}" in
  --patterns) build_patterns; exit 0 ;;
  --init)
    mkdir -p "$(dirname "$IDENTIFIERS_FILE")"
    if [ -f "$IDENTIFIERS_FILE" ]; then echo "exists: $IDENTIFIERS_FILE"; exit 0; fi
    cat > "$IDENTIFIERS_FILE" <<'TPL'
# One regex per line. Anything matching these is blocked from a commit.
# These are not secrets, they are identifiers that reveal your setup.
# Lines starting with # are ignored. This file should never be committed.
#
# Examples, uncomment and edit:
# my-internal-hostname\.example\.com
# ^|[^a-z]myusername([^a-z]|$)
# 10\.0\.[0-9]{1,3}\.[0-9]{1,3}
# name-of-a-private-repo
TPL
    echo "created: $IDENTIFIERS_FILE"; exit 0 ;;
  --selftest)
    # Prove the gate fails on a known-bad input before trusting it to pass.
    #
    # Run against the RAW pattern set, with the allowlist disabled. A repo that
    # exempts this fixture (this repo does: it appears in .secret-scan-allow so
    # the file you are reading does not trip its own gate) would otherwise make
    # the selftest report that the scanner passes known-bad input, which is the
    # exact failure the selftest exists to detect.
    ALLOW_FILE="/nonexistent"
    if printf 'AKIAIOSFODNN7EXAMPLE\n' | scan_stream >/dev/null 2>&1; then
      echo "SELFTEST FAILED: scanner passed a known-bad input"; exit 1
    fi
    if ! printf 'an ordinary sentence about refactoring\n' | scan_stream >/dev/null 2>&1; then
      echo "SELFTEST FAILED: scanner blocked ordinary text"; exit 1
    fi
    echo "selftest ok: blocks a known secret, passes ordinary text"
    echo "patterns loaded: $(build_patterns | wc -l)"
    exit 0 ;;
  --file)
    [ -n "${2:-}" ] || { echo "usage: --file <path>" >&2; exit 2; }
    scan_stream < "$2"; exit $? ;;
  --diff)
    git diff --cached ${2:+"$2"} | grep '^+' | grep -v '^+++' | scan_stream; exit $? ;;
  --repo-scan)
    dir="${2:-.}"; rc=0
    while IFS= read -r f; do
      [ -f "$dir/$f" ] || continue
      out="$(scan_stream < "$dir/$f")" || { echo "$f:"; printf '%s\n' "$out"; rc=1; }
    done < <(git -C "$dir" ls-files 2>/dev/null)
    exit $rc ;;
  "") scan_stream; exit $? ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac
