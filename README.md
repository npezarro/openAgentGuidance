# openAgentGuidance

A harness developed using Claude Code to support more reliable functioning of an agent ecosystem.

It is a set of behavioural rules, on-demand guidance files, git and session hooks, subagent definitions, and templates. Claude Code loads the rules at session start and the hooks enforce the ones that can be enforced mechanically. The public version here has all personal and infrastructure detail removed.

## What is in it

| Path | What it does |
|---|---|
| `agent.md` | The always-loaded ruleset. Kept under 100 lines on purpose: it is injected into every session, so length is a running cost. |
| `guidance/` | Deep-dive files loaded on demand. Each declares a `Load when:` trigger in its first line. |
| `guidance/ESSENTIAL.md` | The rules that get violated most. Always loaded alongside `agent.md`. |
| `guidance/INDEX.md` | Generated from the `Load when:` headers, so the agent knows what exists without reading it all. |
| `hooks/` | Session and git hooks. These are the rules with teeth: a rule a hook can enforce should not rely on the model remembering it. |
| `agents/` | Subagent definitions (reviewer, debugger, architect, security, verifier, and others). |
| `templates/` | A `settings.json` wiring the hooks in, plus context, progress, commit and PR templates. |
| `scripts/install.sh` | Wires the whole thing into `~/.claude/settings.json` and installs the git hooks. |

## Setup

```bash
git clone https://github.com/npezarro/openAgentGuidance.git ~/repos/openAgentGuidance
cd ~/repos/openAgentGuidance
bash scripts/install.sh
```

`install.sh` is idempotent and prints what it would change before changing it. It:

1. Backs up any existing `~/.claude/settings.json` to a timestamped copy.
2. Adds SessionStart hooks that inject `agent.md`, `ESSENTIAL.md` and `guidance/INDEX.md`.
3. Registers the PreToolUse and PostToolUse guards from `hooks/`.
4. Copies the subagent definitions into `~/.claude/agents/`.

To install the git hooks in a specific repo:

```bash
bash ~/repos/openAgentGuidance/hooks/install-hooks.sh /path/to/repo
```

That installs a `pre-commit` secret gate, a `commit-msg` check, and a `pre-push` guard.

The gates call `scripts/secret-scan.sh`, which ships with credential patterns that work out of the box. Add your own private identifiers (usernames, internal hostnames, private repo names) with:

```bash
bash scripts/secret-scan.sh --init      # creates the identifier file
bash scripts/secret-scan.sh --selftest  # proves the gate can actually fail
```

Run `--selftest` after editing patterns. A scanner that matches nothing reports every input as clean, which is indistinguishable from a clean repo.

Optionally set `OPERATOR_NAME` in your environment. The `commit-msg` gate then blocks public commit messages that quote that person issuing an instruction, which is the difference between publishing a rule and publishing who asked for it.

### Verifying it took effect

Start a new Claude Code session and ask it what its rules say. If `agent.md` did not load, the SessionStart hook is not wired. Check directly:

```bash
bash -c 'AG="$HOME/repos/openAgentGuidance"; [ -f "$AG/agent.md" ] && head -3 "$AG/agent.md" || echo "clone not found"'
```

Hooks read this repo **from disk**, never over HTTP. Fetching them from a raw URL fails silently: a `curl -sf` that 404s with a trailing `exit 0` disables the hook with no error and no symptom.

### Keeping it current

```bash
git -C ~/repos/openAgentGuidance pull --ff-only
```

Use `--ff-only`. If it refuses, the clone has local commits and has stopped syncing; that is a condition worth alerting on, because a clone that silently stops updating serves stale rules indefinitely.

## Adapting it

The rules encode opinions. Some will not match how you work, and the file to edit is `agent.md`.

Two conventions worth keeping if you change nothing else:

- **`agent.md` has a hard line budget.** Every line is paid for on every session. When it grows, move detail into a `guidance/` file with a `Load when:` header and run `scripts/gen-manifest.sh`.
- **A rule that a hook can enforce belongs in a hook.** Rules the model must remember get violated; rules a `PreToolUse` hook blocks do not.

## License

MIT. See [LICENSE](LICENSE).
