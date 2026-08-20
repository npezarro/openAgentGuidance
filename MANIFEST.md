# Manifest

The full catalog of guidance files. `guidance/INDEX.md` is the subset injected at SessionStart; this file lists everything.

Both are generated from each guidance file's `Load when:` header, which is the single source of truth. After adding or renaming a guidance file:

```bash
bash scripts/gen-manifest.sh          # rewrite both in place
bash scripts/gen-manifest.sh --check  # exit 1 if either is stale
```

Wire `--check` into CI so a new guidance file cannot land undiscoverable. A file the index does not list is a file the agent will never load.

## Guidance files

<!-- BEGIN GENERATED guidance table (scripts/gen-manifest.sh) -->
3 guidance files (3 indexed at SessionStart via `guidance/INDEX.md`, 0 cold). Descriptions come from each file's "Load when:" header.

| File | Load when |
|---|---|
| `guidance/ESSENTIAL.md` | AUTO-LOADED at SessionStart: top most-violated rules |
| `guidance/code-review.md` | self-review checklist before committing |
| `guidance/testing.md` | writing and running tests, cross-layer invariants |
<!-- END GENERATED -->

## Other components

| Path | What it does |
|---|---|
| `agent.md` | Always-loaded ruleset. Hard line budget, since it is injected every session. |
| `hooks/` | Session and git hooks. A rule a hook can enforce should not depend on the model remembering it. |
| `hooks/lib/` | Shared helpers, so the commit gate and the metadata gate cannot drift apart. |
| `agents/` | Subagent definitions, copied to `~/.claude/agents/` by the installer. |
| `templates/` | Context, progress, commit and PR templates. |
| `scripts/secret-scan.sh` | The gate the git hooks call. Ships with working credential patterns and a `--selftest`. |
| `scripts/install.sh` | Idempotent installer. |
