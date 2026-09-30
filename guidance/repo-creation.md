<!-- Load when: checklist for new repos: cross-cutting guidance incorporation, CLAUDE.md structure -->
# Repo Creation Checklist

When you create a new repo or write a new CLAUDE.md, use this checklist so shared guidance is built in from the start.

## Step 0: Create the Remote Before the First Commit

Create the GitHub remote before you make the first commit, not after:

```bash
gh repo create <name> --private   # skip --source/--push
git remote add origin <url>
git commit ...
```

Some pre-commit hooks scan for sensitive identifiers and decide what to allow based on repo visibility. A repo with no remote has unknown visibility, and a safe hook treats unknown as public. The result is that the first commit of a repo meant to be private gets blocked over infra paths or hostnames that a known-private repo would be allowed to commit.

A commit-message scan may still run on private repos. If a tool generates commit messages that contain a hostname (for example, a screenshot or deploy script), use `--no-verify` and add a one-line comment saying why. Don't rewrite the message.

## Before Writing: Bring In Shared Guidance

Before you write the CLAUDE.md, go through your shared guidance for rules that fit this repo's outputs and patterns:

| If the repo... | Put these rules into its CLAUDE.md |
|---|---|
| Outputs to Google Docs | Formatting rules for the target, e.g. no raw markdown syntax in the output |
| Posts to a chat/notification channel | Message format, length limits, which channel, rules on mentions or pings |
| Auto-posts to a blog/CMS | Post format, draft or publish default, rules against duplicate posts |
| Writes in the owner's voice | Voice and style rules |
| Has a deploy target | Deploy procedure, how to verify after deploy, rollback |
| Uses auth/OAuth | Base path and callback URL handling |
| Is a userscript (e.g. Tampermonkey) | Metadata block, how to bump versions, how updates get delivered |
| Drives a browser agent | How pages are read and interaction limits |
| Has tests | Test commands and the rule that tests must pass before a commit |

Write the rules that apply directly into the CLAUDE.md instead of trusting the agent to check shared guidance while it runs. CLAUDE.md loads automatically. Other guidance files don't.

## CLAUDE.md Structure

Every CLAUDE.md should have:

1. **What this repo does** (one paragraph)
2. **Commands** (build, test, dev)
3. **Output format rules** (if the repo produces formatted output)
4. **Key files and architecture** (if not obvious)
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

Add patterns specific to the repo on top of these (e.g. `*.db`, `*.sqlite`, build outputs, log dirs). A missing or incomplete `.gitignore` is a common audit finding on public repos, and it's easy to prevent when you create the repo.

## After Writing: Verify

- [ ] `.gitignore` exists and includes `.env*` plus private key patterns (`*.pem`, `*.key`, `*.p12`, `*.pfx`)
- [ ] No raw markdown syntax in the output format rules if the output goes to Google Docs
- [ ] No secrets, credentials, or private infrastructure details
- [ ] The Commands section matches the `package.json` scripts
- [ ] Output format rules are testable (could you check compliance just by reading the output?)
- [ ] Shared rules are written into the CLAUDE.md, not just linked

## Adding to Automated Scans

After you create the repo:
1. If you run automated scanners or dev agents across your repos, add the new repo to their config list.
2. Make sure `context.md` and `progress.md` exist (start from your templates).

## Public-Readiness: Safe to Be Public, and Usable by a Stranger

Before you call a repo shareable, audit what it depends on at runtime, not only whether it has secrets. A repo can have no secrets, full tests and green CI, and still work for nobody but its author because a required piece runs from a private repo or a private host. A typical failure: a fresh clone installs and then does nothing, because it needs a server that only exists in a private repo, and the README never mentions the config that selects it.

Checklist when asked "is this ready to share":
1. **Runtime dependencies:** what does a fresh clone talk to at runtime? Is each of those things in this repo? Often a half-built local or offline path already exists "for testing". Making it the DEFAULT is usually less work than pulling the private component out.
2. **Docs vs code:** follow the README word for word. Does every config value the code reads show up in the setup steps? Check snippets against a live example you know works, not against memory.
3. **LICENSE:** a public repo without one is "all rights reserved", so no other fix matters until you add it.
4. **Secrets** in the tree AND in the history.
5. **Fork CI:** publish and deploy steps should skip with a warning when ALL their secrets are missing, but still fail when only SOME are set.
6. **Distribution:** unsigned binaries get quarantined on every machine except the one that built them.
7. **Internal docs:** stop tracking internal notes (`context.md`, `progress.md`), but add a tracked, public-safe CLAUDE.md. Otherwise you remove the repo's only orientation doc.

Test the default, unconfigured path with HOME and the environment isolated. If you don't, the owner's dotfiles supply the private config and the test passes for the wrong reason.

## Cross-Repo Sweeps

### Dedupe by git remote, not directory name
Sweeps that loop over local directory names (CLAUDE.md audits, dependency passes, doc syncs) can hit the same GitHub repo twice when two local checkouts share a remote. That opens two PRs against one repo. Build the work list with `git remote get-url origin` and dedupe on that before fanning out.

### Read from the remote, not the local checkout
Local checkouts are often behind their remotes, and earlier fixes may already be merged upstream while the file on disk still looks unpatched. Run `git fetch origin` and read the file from the remote default branch (`git show origin/<default>:CLAUDE.md`) before you conclude anything is missing. Branch audit worktrees from `origin/<default>`, not from local HEAD.

### Resolve each repo's default branch explicitly
Default branches differ between repos (`main` vs `master`), and `origin/HEAD` is often unset in local clones. Falling back to `main` gives `fatal: malformed object name origin/main` and quietly misreports branch status. Look up the default for each repo:

```bash
gh repo view <owner>/<repo> --json defaultBranchRef -q .defaultBranchRef.name
```

### Check squash-merged work by content, not ancestry
A squash-merged branch never becomes an ancestor of the default branch, so `git branch --merged` reports it as unmerged even after the PR has merged. Check that the change landed by comparing content:

```bash
git diff --quiet <branch>:CLAUDE.md origin/<default>:CLAUDE.md
```

Then delete the branch with `git branch -D`. Using `-d` alone leaves stale local branches in every repo the sweep touched.

If an auto-merge bot runs on your agent branches, it may merge a pushed branch before your own `gh pr create` runs. The create call then fails with "No commits between ...". In that setup, don't expect a human to review the PR first.
