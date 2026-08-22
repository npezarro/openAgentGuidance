#!/usr/bin/env bash
# install.sh: wire this guidance repo into Claude Code.
#
# Idempotent. Prints what it will change, backs up anything it touches, and can
# be re-run after a `git pull` without duplicating hooks.
#
# Usage:
#   bash scripts/install.sh              # show what would change, then do it
#   bash scripts/install.sh --dry-run    # show only
#   bash scripts/install.sh --uninstall  # remove the hooks this added

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLAUDE_DIR="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"
AGENTS_DIR="$CLAUDE_DIR/agents"
MARKER="open-agent-guidance"

DRY=false; UNINSTALL=false
case "${1:-}" in
  --dry-run) DRY=true ;;
  --uninstall) UNINSTALL=true ;;
  "") ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

command -v python3 >/dev/null || { echo "python3 is required" >&2; exit 1; }
mkdir -p "$CLAUDE_DIR" "$AGENTS_DIR"
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"

python3 - "$REPO" "$SETTINGS" "$MARKER" "$DRY" "$UNINSTALL" <<'PY'
import json, os, shutil, sys, time

repo, settings_path, marker, dry, uninstall = sys.argv[1:6]
dry = dry == "true"; uninstall = uninstall == "true"

with open(settings_path) as f:
    try:
        cfg = json.load(f)
    except json.JSONDecodeError:
        print(f"ERROR: {settings_path} is not valid JSON. Fix or move it first.")
        raise SystemExit(1)

hooks = cfg.setdefault("hooks", {})

def cmd(body):
    # Read from disk, never over HTTP: a fetch that 404s with a trailing exit 0
    # disables the hook with no error and no symptom. Warn loudly if missing.
    return (f'bash -c \'AG="{repo}"; {body}\'')

def entry(command, timeout=15000):
    return {"hooks": [{"type": "command", "command": command, "timeout": timeout,
                       "_source": marker}]}

wanted = {
    "SessionStart": [
        cmd('F="$AG/agent.md"; [ -f "$F" ] && cat "$F" || echo "WARNING: agent.md missing at $AG" >&2'),
        cmd('F="$AG/guidance/ESSENTIAL.md"; [ -f "$F" ] && { echo "ESSENTIAL RULES:"; cat "$F"; } || echo "WARNING: ESSENTIAL.md missing" >&2'),
        cmd('F="$AG/guidance/INDEX.md"; [ -f "$F" ] && { echo "GUIDANCE INDEX (load on demand):"; cat "$F"; } || true'),
    ],
    "PreToolUse": [
        cmd('printf "%s" "$(cat)" | bash "$AG/hooks/claim-guard.sh" deny'),
        cmd('printf "%s" "$(cat)" | bash "$AG/hooks/worktree-guard.sh"'),
        cmd('printf "%s" "$(cat)" | bash "$AG/hooks/public-metadata-guard.sh"'),
    ],
    "PostToolUse": [
        cmd('bash "$AG/hooks/tool-loop-guardrail.sh"; exit 0'),
    ],
}

# Remove anything this installer added before, so re-running cannot duplicate.
removed = 0
for event in list(hooks.keys()):
    kept = []
    for group in hooks.get(event, []):
        inner = [h for h in group.get("hooks", []) if h.get("_source") != marker]
        if len(inner) != len(group.get("hooks", [])):
            removed += 1
        if inner:
            group["hooks"] = inner
            kept.append(group)
    hooks[event] = kept
    if not hooks[event]:
        del hooks[event]

added = 0
if not uninstall:
    for event, cmds in wanted.items():
        hooks.setdefault(event, [])
        for c in cmds:
            hooks[event].append(entry(c))
            added += 1

action = "uninstall" if uninstall else "install"
print(f"{action}: {removed} existing entr(ies) from a previous run removed, {added} added")

if dry:
    print("DRY RUN: no files written")
    raise SystemExit(0)

backup = f"{settings_path}.bak.{time.strftime('%Y%m%d-%H%M%S')}"
shutil.copy2(settings_path, backup)
cfg["hooks"] = hooks
with open(settings_path, "w") as f:
    json.dump(cfg, f, indent=2)
    f.write("\n")
print(f"wrote {settings_path} (backup: {backup})")
PY
rc=$?
[ $rc -eq 0 ] || exit $rc

if [ "$DRY" = "false" ] && [ "$UNINSTALL" = "false" ]; then
  cp "$REPO"/agents/*.md "$AGENTS_DIR"/ 2>/dev/null && \
    echo "copied $(ls -1 "$REPO"/agents/*.md | wc -l) subagent definition(s) to $AGENTS_DIR"
  chmod +x "$REPO"/hooks/*.sh "$REPO"/hooks/lib/*.sh "$REPO"/scripts/*.sh 2>/dev/null
  # A gate nobody proved can fail is decoration. Prove it here, at install time.
  if bash "$REPO/scripts/secret-scan.sh" --selftest; then
    :
  else
    echo "WARNING: secret-scan selftest FAILED. The commit gate will not protect you." >&2
  fi
  echo
  echo "Done. Start a new Claude Code session and confirm the rules loaded."
  echo "Add your own private identifiers to the scanner with:"
  echo "  bash $REPO/scripts/secret-scan.sh --init"
  echo "Install the git hooks in a repo with:"
  echo "  bash $REPO/hooks/install-hooks.sh /path/to/repo"
fi
