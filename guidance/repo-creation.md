<!-- Load when: checklist for new repos: cross-cutting guidance incorporation, CLAUDE.md structure -->
# Repo Creation Checklist

When creating a new repo or writing a new CLAUDE.md, follow this checklist to ensure cross-cutting guidance is incorporated from the start.

## Pre-Write: Cross-Reference Your Guidance

Before writing the CLAUDE.md, scan your guidance set for rules that apply to this repo's output targets and patterns. Typical triggers:

| If the repo... | Look for guidance on... |
|---|---|
| Outputs to a rich-text/doc service | that service's formatting constraints (raw markdown usually does not survive) |
| Posts to your notification channel | message format, rate limits, webhook handling |
| Publishes to a blog or CMS | auto-posting rules, draft vs publish defaults |
| Writes in a specific person's voice | your written-voice rules |
| Has a deploy target | deployment and rollback procedure |
| Uses auth/OAuth | auth and base-path handling |
| Runs as a userscript or browser extension | userscript packaging and permissions |
| Drives a browser agent | browser automation constraints |
| Has tests | testing standards |

Incorporate applicable rules directly into the CLAUDE.md rather than assuming the agent will check guidance files at runtime. CLAUDE.md is loaded automatically; separate guidance files are not.

## CLAUDE.md Structure

Every CLAUDE.md should include:

1. **What this repo does** (one paragraph)
2. **Commands** (build, test, dev)
3. **Output format rules** (if the repo produces formatted output)
4. **Key files and architecture** (if non-obvious)
5. **Constraints** (what NOT to do, security considerations)

## .gitignore Requirements

Every new repo must have a `.gitignore`. At minimum it should exclude:

```
.env*
*.pem
*.key
*.p12
*.pfx
node_modules/
```

Add repo-specific patterns on top (e.g., `*.db`, `*.sqlite`, build outputs, log dirs). A security audit of 30 public repos found 3 repos entirely missing `.gitignore` and 4 with incomplete patterns; both are preventable at creation time.

## Post-Write: Verify

- [ ] `.gitignore` exists and includes `.env*` + private key patterns (`*.pem`, `*.key`, `*.p12`, `*.pfx`)
- [ ] No raw markdown syntax in output format rules if output targets a rich-text doc service
- [ ] No secrets, credentials, or private infrastructure details
- [ ] Commands section matches `package.json` scripts
- [ ] Output format rules are testable (could you check compliance by reading the output?)
- [ ] Cross-cutting rules are incorporated, not just referenced

## Adding to Autonomous Scans

After creating the repo:
1. Add it to the repo list your automated scanners read (learning/auto-dev jobs), if it should be scanned
2. Ensure `context.md` and `progress.md` exist (use your standard templates)

### Public-readiness is two questions: safe to be public, and usable by a stranger

Before calling a repo shareable, audit the DEPENDENCY CLOSURE, not just for secrets. A repo can be free of secrets, fully tested, CI-green, and still unusable by anyone but its author because a required piece of its runtime lives in a private repo or on a private host.

One case: a public-since-creation repo with clean history installed fine from a fresh clone and then did nothing forever, because the app required a relay server that only existed in a private repo, and the README's setup steps never mentioned the config file selecting it. The README's hook snippet also used a schema the consumer rejects, so the documented path had never worked.

Checklist when asked "is this ready to share":
1. Dependency closure: what does a fresh clone talk to at runtime? Is each thing's implementation in this repo? A half-built local/offline path often already exists ("for testing") and making it the DEFAULT is smaller than extracting the private component.
2. Docs vs code: follow the README literally. Does every config the code reads appear in setup? Validate snippets against a known-working live example, not memory.
3. LICENSE: absent on a public repo means all rights reserved, which makes every other fix moot.
4. Secrets in tree AND history.
5. Fork CI: publish/deploy steps should skip with a warning when ALL their secrets are absent, but still error when SOME are set.
6. Distribution: unsigned binaries are quarantined everywhere but the build machine.
7. Internal docs: untrack context.md/progress.md, but add a tracked public-safe CLAUDE.md or you remove the repo's only orientation doc.

Test the unconfigured default path with HOME/env isolated, or your own dotfiles supply the private config and it passes for the wrong reason.

### Audit repos by git remote, not directory name

Cross-repo sweeps (CLAUDE.md compliance audits, dependency passes, doc-sync) that iterate over directory names can double-target a single remote repo. Two local checkouts of the same repo, under different directory names, look like two targets; a sweep treating them as separate would open two PRs against the same repo, violating one-PR-per-repo. Dedupe the work list by `git remote get-url origin` before fanning out, not by directory name.

Second, related failure mode: local checkouts are routinely behind their remotes, and a prior audit's changes are often already merged upstream while the on-disk file still looks unpatched. Auditing the on-disk CLAUDE.md produced three false gaps in one batch. Always `git fetch origin` and read the file from the remote default branch (`git show origin/<default>:CLAUDE.md`) before concluding anything is missing; branch audit worktrees from `origin/<default>`, not from the local HEAD.

### Resolve each repo's default branch, and verify squash-merged content by diffing the file, not by ancestry

Two mechanical failure modes hit a CLAUDE.md compliance audit across ~27 repos.

1. The default branch is not uniformly `main`, and `origin/HEAD` is often unset in local clones. A couple of repos defaulted to `master`; the rest to `main`. `git symbolic-ref --short refs/remotes/origin/HEAD` returned nothing in every checkout, so a fallback to `main` produced `fatal: malformed object name origin/main` and silently mis-reported six branches as unmerged. Resolve the default per repo before branching from it or reading a file off it:

```
gh repo view <owner>/<repo> --json defaultBranchRef -q .defaultBranchRef.name
```

2. Audit branches are often squash-merged, so `git branch --merged origin/<default>` reports them as NOT merged even after the PR is MERGED. Ancestry is the wrong test: the branch tip is never an ancestor of a squash commit. Verify the change actually landed by comparing content, then clean up:

```
git diff --quiet <branch>:CLAUDE.md origin/<default>:CLAUDE.md && git branch -D <branch>
```

Using `git branch -d` alone leaves stale local branches in every repo the sweep touched.

Related: if you run an auto-merge bot, it may open AND merge a PR from each pushed audit branch within about a minute, so the subagents' own `gh pr create` calls fail with "No commits between <default> and <branch>". Every audit PR can be merged before any human sees it, which makes a "PR for review" field a misnomer for that job. Check for auto-merge automation before designing a sweep around human review.
