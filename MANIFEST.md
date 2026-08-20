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
20 guidance files (20 indexed at SessionStart via `guidance/INDEX.md`, 0 cold). Descriptions come from each file's "Load when:" header.

| File | Load when |
|---|---|
| `guidance/ESSENTIAL.md` | AUTO-LOADED at SessionStart: top most-violated rules |
| `guidance/code-review.md` | self-review checklist before committing |
| `guidance/concurrent-sessions.md` | several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" |
| `guidance/context-progress.md` | context.md and progress.md specs |
| `guidance/debugging.md` | diagnosing issues, log analysis |
| `guidance/deep-research.md` | research depth and methodology before producing guides or recommendations |
| `guidance/dependencies.md` | evaluating and adding packages |
| `guidance/fact-checking.md` | verifying external, actionable claims (prices, eligibility rules, offers, versions) before asserting them |
| `guidance/git-workflow.md` | branching, PRs, merge procedures, commit messages |
| `guidance/learning-capture.md` | when and where to persist operational learnings |
| `guidance/measurement-windows.md` | auditing a logger/collector's coverage, or a metric whose denominator comes from a different source than its numerator |
| `guidance/operational-safety.md` | self-deploy loops, restart storms, hook loops |
| `guidance/prior-work-lookup.md` | finding past conversations and prior work |
| `guidance/process-hygiene.md` | spawned processes, temp files, port conflicts |
| `guidance/repo-creation.md` | checklist for new repos: cross-cutting guidance incorporation, CLAUDE.md structure |
| `guidance/resource-awareness.md` | server resource checks |
| `guidance/secrets-hygiene.md` | secret rotation, history rewrite, detection patterns |
| `guidance/stop-hook-safety.md` | tiered stop hook classification, guard library, Tier 3 recursion prevention |
| `guidance/testing.md` | writing and running tests, cross-layer invariants |
| `guidance/when-to-fan-out.md` | deciding whether to spawn subagents (Task fan-out / parallel bash / Workflow) vs stay single-agent; concurrency-safe 3-phase pattern |
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
