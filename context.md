# context.md

## Last Updated
2026-08-21: GitHub repo description replaced (it still described the superseded lessons model); portfolio now links here instead of the private source. Earlier: repo created, rebuilt from a lessons feed into the working harness, 19 guidance files published.

## What This Repo Is

The **public mirror** of a private agent-guidance system. It is the harness itself (ruleset, guidance, hooks, subagent definitions, installer) with personal and infrastructure detail removed, not a collection of extracted principles. The usability bar: a stranger clones it and runs `scripts/install.sh`.

**This repo is downstream. Do not author content here** except for the two hand-maintained files below. Everything else is generated from the private source and will be overwritten by the daily sync.

## Current State

- **Live and public.** CI (`public-content-scan`) green. Anonymous read verified.
- **20 guidance files** (19 synced + `ESSENTIAL.md`), 14 hooks + `lib/`, 8 subagent definitions, 4 templates, 3 scripts.
- **`scripts/secret-scan.sh`** is the gate the git hooks call. Ships with credential patterns and `--selftest`. Verified: blocks 4 real credential shapes, passes tricky negatives including `export API_KEY="$SECRET_FROM_ENV"`.
- **`scripts/install.sh`** is idempotent (7 hook entries before and after a re-run) and backs up `settings.json`.
- **Git hooks verified end to end**: a commit containing a credential shape produced zero commits; an ordinary commit succeeded.

## How Content Arrives

The private source repo runs `publish-open-guidance.sh` daily at 05:30. It rewrites changed allowlisted files to strip private detail, screens them, regenerates the index, and pushes. It fails closed: a missing scanner, an empty pattern list, or any screening hit aborts the run.

**Two files are hand-maintained here and never auto-synced:** `agent.md` and `guidance/ESSENTIAL.md`. A machine rewrite either guts them or leaks the incidents they encode. The publisher prints a warning naming them when the private originals change. **That warning is the only signal that these two are drifting**: nothing else will catch it.

## Ungated surfaces (nothing in git can see these)

The repo **description**, topics and homepage never pass through git, so none of the three commit gates (`pre-commit` on content, `commit-msg` on the message, `pre-push` on the diff) can check them. `hooks/public-metadata-guard.sh` gates `gh` writes for *anonymity*, not accuracy, and only on commands a session actually runs. The description survived the 2026-08-19 rebuild still advertising the superseded essay model, which is the first line a visitor reads and the indexed `<meta name="description">`; replaced 2026-08-21. **If the shape of this repo changes again, the description is a separate thing to change.** Same failure class as the two hand-maintained files below: outside the automated path, so the automation reports success and never touches it.

## Open Work

- `agent.md` and `guidance/ESSENTIAL.md` want a human read before this is shared widely. Highest-value, hand-written, unreviewed.
- **Inbound link:** `portfolio` (public) links here from its README, `index.html`, the generated `projects/agent-guidance.html`, and variants `a/`, `b/`, `c/`. Its copy cites concrete counts (19 guidance files, 8 subagent definitions). If those counts change materially, that copy goes stale.
- 19 of 48 source guidance files are published. Deployment, auth, chat-integration, blog-posting, browser-tooling and writing-voice files were excluded as infrastructure-specific. Restoring any is one line in the source repo's publish set.
- A rewrite is non-deterministic, so an unchanged file re-run produces slightly different text. The publisher only touches changed files, so this shows up as churn only when the source actually moved.

## Environment Notes

- **Deploy target:** GitHub only. Nothing is hosted or built from this repo.
- **Default branch:** `main`. Push over SSH: an OAuth token without `workflow` scope cannot create or update `.github/workflows/`.
- **CI:** `.github/workflows/public-scan.yml`. Requires the `SENSITIVE_PATTERNS` repo secret; it fails closed if unset rather than passing a scan it cannot perform. Scans added lines on push, sweeps the whole tree weekly.
- **`.secret-scan-allow`** exempts two legitimately secret-shaped strings (a docs placeholder DSN, the scanner's own selftest fixture). `--selftest` deliberately ignores the allowlist, or exempting a fixture would turn the gate into a no-op that reports passing.

## Conventions Worth Keeping

- `agent.md` has a hard line budget: it is injected every session, so length is a running cost.
- A rule a hook can enforce belongs in a hook. Rules the model must remember get violated.
- After adding or renaming a guidance file, run `scripts/gen-manifest.sh`. A file the index does not list is a file the agent never loads.

Detailed session history lives in the private source repo, not here.
