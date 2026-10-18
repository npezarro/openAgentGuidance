<!-- Load when: checklist for new repos: cross-cutting guidance incorporation, CLAUDE.md structure -->
# Repo Creation Checklist

Use this checklist when you create a new repo or write a new CLAUDE.md, so cross-cutting guidance is built in from the start.

## Step 0: Create the Remote Before the First Commit

Create the GitHub remote before the first commit, not after it: run `gh repo create <name> --private` (skip `--source`/`--push`), then `git remote add origin <url>`, then commit. If a pre-commit hook scans for sensitive identifiers based on repo visibility, a repo with no remote has unknown visibility. The fail-safe default is to scan unknown repos as public, so the first commit of a repo you meant to keep private gets blocked over infra paths or hostnames that a known-private repo would pass.

Commit-message scans can also run on private repos. If a tool auto-generates commit messages that contain a hostname (for example, a screenshot or deploy script), use `--no-verify` with a one-line comment explaining why. Don't rewrite the message.

## Pre-Write: Cross-Reference Your Shared Guidance

Before you write the CLAUDE.md, check what the repo outputs and which patterns it uses, then pull in the shared rules that apply:

| If the repo... | Incorporate rules for... |
|---|---|
| Outputs to Google Docs | Doc formatting (no raw markdown syntax in the output; use native headings and lists) |
| Posts to a chat platform | Message length limits, formatting, and which channel gets which kind of post |
| Auto-posts to a blog or CMS | Draft vs publish defaults, dedupe, and content review before posting |
| Writes in the owner's voice | The owner's style and voice rules |
| Has a deploy target | Deploy procedure, post-deploy verification, and rollback |
| Uses auth/OAuth | Callback URLs and base-path handling when served under a subpath |
| Is a userscript | Metadata block, `@match` scope, and update URL conventions |
| Drives a browser | How pages are read and what the agent may click or submit |
| Has tests | Test commands, what must pass before commit, and how to stub external services |

Write the applicable rules directly into the CLAUDE.md. Don't assume the agent will look up guidance files at runtime: CLAUDE.md loads automatically, and guidance files don't.

## CLAUDE.md Structure

Every CLAUDE.md should include:

1. **What this repo does** (one paragraph)
2. **Commands** (build, test, dev)
3. **Output format rules** (if the repo produces formatted output)
4. **Key files and architecture** (if non-obvious)
5. **Constraints** (what NOT to do, security considerations)

## .gitignore Requirements

Every new repo must have a `.gitignore`. At minimum, it should exclude:

```
.env*
*.pem
*.key
*.p12
*.pfx
node_modules/
```

Add patterns specific to the repo on top of these (for example `*.db`, `*.sqlite`, build outputs, log dirs). A missing or incomplete `.gitignore` is one of the most common findings in public-repo security audits, and it is easy to prevent when you create the repo.

## Post-Write: Verify

- [ ] `.gitignore` exists and includes `.env*` plus private key patterns (`*.pem`, `*.key`, `*.p12`, `*.pfx`)
- [ ] Output format rules contain no raw markdown syntax if the output goes to Google Docs
- [ ] No secrets, credentials, or private infrastructure details
- [ ] Commands section matches the `package.json` scripts
- [ ] Output format rules are testable (could you check compliance by reading the output?)
- [ ] Cross-cutting rules are written into the CLAUDE.md, not just referenced

## Register the Repo With Automation

After you create the repo:
1. If any autonomous scan or agent pipeline should cover the repo, add it to that pipeline's repo list.
2. Make sure `context.md` and `progress.md` exist (start from your templates).

## Public-Readiness Is Two Questions: Safe to Be Public, and Usable by a Stranger

Before you call a repo shareable, audit its dependency closure, not just its secrets. A repo can have no secrets, full tests, and green CI, and still work for nobody but its author because part of its runtime lives in a private repo or on a private host. A typical failure: a fresh clone installs and then does nothing, because the app needs a server that exists only in a private repo and the README never mentions the config that selects it.

Checklist when asked "is this ready to share":
1. **Dependency closure:** what does a fresh clone talk to at runtime? Is each piece implemented in this repo? Often a half-built local or offline path already exists "for testing", and making it the default is less work than extracting the private component.
2. **Docs vs code:** follow the README literally. Does every config value the code reads show up in the setup steps? Check snippets against a known-working live example, not memory.
3. **LICENSE:** a public repo with no license means all rights reserved, and that makes every other fix moot.
4. **Secrets:** check both the tree AND the history.
5. **Fork CI:** publish/deploy steps should skip with a warning when ALL of their secrets are absent, but still error when only SOME are set.
6. **Distribution:** unsigned binaries get quarantined on every machine except the one that built them.
7. **Internal docs:** if you untrack `context.md`/`progress.md`, add a tracked, public-safe CLAUDE.md. Otherwise you remove the repo's only orientation doc.

Test the unconfigured default path with HOME and env isolated. If you don't, the owner's dotfiles supply the private config and the test passes for the wrong reason.

## Cross-Repo Sweeps: Dedupe by Git Remote, Not Directory Name

Two local directories can be checkouts of the same GitHub repo. A sweep (CLAUDE.md compliance audit, dependency pass, doc sync) that iterates over directory names will target that repo twice and open two PRs against it. Dedupe the work list by `git remote get-url origin` before you fan out.

- Pass `--repo <owner>/<name>` to `gh pr create`, using the remote's owner and name. By default `gh` infers the repo from the current directory, and a local directory name that differs from the remote will target the wrong repo or one that doesn't exist.
- Fix the source list itself. A rule that relies on every future session remembering to dedupe by hand will fail again. Remove duplicate entries from whatever repo list a pipeline reads, so there is nothing left to dedupe when it fans out.
- Local checkouts are often behind their remotes, and an earlier audit's changes may already be merged upstream. Run `git fetch origin` and read the file from the remote default branch (`git show origin/<default>:CLAUDE.md`) before you decide anything is missing. Branch audit worktrees from `origin/<default>`, not from local HEAD.

## Cross-Repo Sweeps: Resolve Default Branches via gh, Verify Squash Merges by Content

1. **Default branches aren't always `main`, and `origin/HEAD` is often unset.** Some repos default to `master`. In many clones, `git symbolic-ref --short refs/remotes/origin/HEAD` returns nothing, and falling back to `main` gives `fatal: malformed object name origin/main` and silently misreports branches as unmerged. Resolve the default for each repo before you branch from it or read from it:

   ```bash
   gh repo view <owner>/<repo> --json defaultBranchRef -q .defaultBranchRef.name
   ```

2. **Squash-merged branches never show up as merged by ancestry.** `git branch --merged origin/<default>` reports them as NOT merged even after the PR merges, because the branch tip is never an ancestor of a squash commit. Compare content to check that the change landed:

   ```bash
   git diff --quiet <branch>:CLAUDE.md origin/<default>:CLAUDE.md
   ```

   Then clean up with `git branch -D`. Using `git branch -d` alone leaves stale local branches in every repo the sweep touched.

3. **Auto-merge bots can race your PR creation.** If a bot opens and merges PRs from pushed `claude/*` branches within seconds, your own `gh pr create` fails with "No commits between <default> and <branch>", and no human ever reviews the change. Know whether your branches are auto-merged before you report a sweep's output as "PRs for review".
