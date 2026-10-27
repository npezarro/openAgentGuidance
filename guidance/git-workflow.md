<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main`.
- Use the branch assigned to you. If you don't have one, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Don't start branch names with `test-`.** Some repos have GitHub rulesets or branch protection that reject pushes to `test-*` branches without any error; the branch just never shows up on the remote. Use descriptive names like `add-tests-<module>` or `<module>-tests-<run>`.
- Commit messages explain **why**, not just what. Large commits are fine; don't split work artificially.
- Before committing:
  1. Run `git status` to check that no unintended files are staged.
  2. Run `git diff` to review the actual changes.
  3. Confirm that no `.env`, secrets, or key files are included.
  4. **Update `context.md`** (the current state, for the next agent). This is required on the final commit of a branch (before creating a PR) and at session wrap-up. It is not required on every intermediate commit.
  5. **Update `progress.md`**: add an entry for the work being committed.
- Push: `git push -u origin HEAD`. Retry network failures up to 4 times with backoff (2s, 4s, 8s, 16s). Do not retry auth failures.

## All Deliverables Go in Repos
Scripts, tools, project assets, analysis docs, reference files and any other output **always go in a git repo** that is pushed to GitHub. Never leave files as loose filesystem artifacts. GitHub is the source of truth. If a new project or tool set has no repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions often create useful files (summaries, configs, scripts, reference docs) and then forget to commit them, forget to push them, or save them outside a repo. Local-only files can't be reached between sessions. A `Write` or `Edit` call is not finished until the file is committed and pushed.

## Every Repo Gets a README and Description
Every repo must have a `README.md` and a GitHub repo description. When you create a repo, or work in one that is missing either, add them.

- **README.md**: what it does (1 or 2 sentences), how to set it up, and how to run or use it. Keep it short: a developer should understand the project in 60 seconds.
- **GitHub description**: set it with `gh repo edit <owner>/<repo> --description "one-line summary"`.

Both are required when running `gh repo create`. Use the `--description` flag on creation and add the README in the initial commit.

## Always Commit and Push Written Files
When you create or modify files in any repo, **commit and push in the same step**. Don't move on to other work while untracked or uncommitted files sit in a repo. Unpushed commits are invisible to other sessions, collaborators and the deploy pipeline. Treat file creation, `git commit` and `git push` as one atomic operation. If any step fails, diagnose and fix it before moving on.

**Common gap:** when a task spans several repos, it's easy to push some and forget others. When you finish a multi-repo task, run `git status` in each repo to confirm it is clean.

## Staging Hygiene (applies to every repo)
Any checkout can hold uncommitted work from an earlier session or from a concurrent agent. A blanket add quietly ships that work under your commit message. **This is not a "shared repo" rule; it applies everywhere.**

- **Run `git status` BEFORE staging.** If the tree contains anything you didn't touch, name your paths explicitly.
- **Stage explicit paths. Never use `git add -A` or `git add .`**: `git add guidance/foo.md scripts/bar.sh`. A blanket add can pull in another agent's half-finished feature, or a secret.
- **Never use `--no-verify` on a public repo.** A pre-commit sensitive-identifier scanner is the last line of defense before usernames, internal paths or tokens reach a public repo. If it blocks you, sanitize the content. Don't override it.
- **Before committing, confirm that ONLY your files are staged.** Unstage anything you didn't touch with `git restore --staged <path>`.
- Review `git show --stat` before pushing. That is where a swept-in file shows up.

## Creating PRs (with retry)
After `git push`, GitHub can take a few seconds to register the branch. Check that the branch exists on the remote before creating the PR, and retry on failure:

```bash
# 1. Wait for GitHub to register the pushed branch
for i in 1 2 3 4 5; do
  if gh api "repos/{owner}/{repo}/branches/$(git branch --show-current)" --silent 2>/dev/null; then
    break
  fi
  echo "Waiting for GitHub to register branch (attempt $i)..."
  sleep $((i * 2))
done

# 2. Check for existing PR on this branch
EXISTING=$(gh pr list --state all --head "$(git branch --show-current)" --json number --jq '.[0].number')
if [ -n "$EXISTING" ]; then
  echo "PR #$EXISTING already exists for this branch"
else
  # 3. Create the PR with retry
  for i in 1 2 3; do
    if gh pr create --title "<task>" --body "<context>"; then
      break
    fi
    echo "PR creation failed (attempt $i), retrying in $((i * 3))s..."
    sleep $((i * 3))
  done
fi
```

- **Never fall back to a "create manually" URL.** If `gh pr create` still fails after 3 retries, diagnose the error (auth, branch not found, network) and fix it.
- Do **not** enable auto-merge unless you are explicitly asked to.
- Resolve the default branch instead of assuming it is `main` (some repos use `master`): `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.

## GitHub API PR Creation: Qualify the Head Parameter
When you create PRs through the REST API (Octokit) rather than `gh pr create`, the `head` parameter must be qualified as `owner:branch`.

```js
// WRONG: causes "invalid head" errors, especially on newly-pushed branches
await octokit.rest.pulls.create({ head: branch, ... });

// CORRECT
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

GitHub needs a few seconds to index a newly pushed branch, and unqualified names fail more often during that window. Also wait about 3s after a push before calling `pulls.create`, set `maxAttempts` to 5, and retry on "invalid head" errors. `gh pr create` handles qualification for you.

## Working Alongside an Auto-Merge Bot
If your setup runs a bot that opens and squash-merges PRs from pushed branches, these rules apply:

- **"No commits between main and `<branch>`" or "Head sha can't be blank" after a push is SUCCESS.** It means the bot already opened and merged the PR. Find that PR with `gh pr list --state all --head <branch>` and reuse its number. Don't retry the push and don't open a duplicate.
- **Verify by content, not ancestry.** A squash commit is never an ancestor of your local commit, so `git merge-base --is-ancestor` returns false and `git branch --merged` reports the branch as unmerged. Use `git diff origin/main <mine> -- <file>` instead (empty output means it landed). When checking added lines with grep, use `grep -Fqx -- "$line"`. Without the `--`, a line starting with `-` (a markdown bullet) is parsed as an option and gives false negatives.
- **Follow-up fixes go on a FRESH branch off main.** Once the bot has squash-merged and deleted a branch, a second commit pushed to it conflicts every time. Run `git checkout -b <new> origin/main`, then `git checkout <old-branch> -- <only the changed files>`, commit and push. Use `git ls-remote --heads origin <branch>` to confirm the push landed; the local `origin/<branch>` ref goes stale as soon as the bot deletes the branch.
- **If the bot merges every non-draft PR by default, pushing a branch you don't want merged is unsafe.** Running `gh pr create --draft` right after the push is NOT reliable, because the bot can merge within seconds, before your command runs. Mitigations, from strongest to weakest:
  1. A repo-level exclusion list in the bot. Add product and design repos (anything with human or work-in-progress branches) to it **before their first push**, not after the first incident. Repos that will run parallel agents need this from day one.
  2. A per-commit opt-out marker in the head commit message (for example `[no-automerge]`), if the bot supports one.
  3. To run CI on unfinished work, don't push at all: run the tests locally, or trigger CI with `workflow_dispatch`.
- If something merges unexpectedly and the squash tree matches your work, continue with `git rebase --onto origin/main <first-pushed-sha>` rather than fighting it. If only part of it should be on main, land the right content yourself with `git checkout origin/<branch> -- <owned paths>`.
- **Automated PR creators must check that their own PR actually merged.** As the last step of a session, run `gh pr view <n> --json state,mergeable`, and merge it then if it is MERGEABLE with passing CI. Don't rely on a later sweep as a merge backstop. Verified fixes can otherwise sit unmerged for days.

## Branch Hygiene
Open PRs that sit unmerged cause cascading merge conflicts on every other branch. **This is the main cause of stuck work.**

- **Merge PRs promptly.** When a PR is ready and has no review requirement, merge it in the same session: `gh pr merge <number> --merge --delete-branch`. If that fails (conflict, pending checks), retry once after 5s, then report the specific error.
- **Rebase before opening a PR**: `git fetch origin && git rebase origin/main`. A PR should be mergeable when it is created.
- **One branch per task.** Don't leave abandoned branches behind.
- **Clean up stale branches at session start**: run `gh pr list --state open` and `git branch -a`. Rebase and merge, or close, anything that has been idle for more than a few days.
- **Prune before scanning**: run `git remote prune origin` before `git branch -a` or `git branch -r`. Unpruned refs for deleted branches inflate "open branch" counts.
- **Automation cap and dedup gates MUST use `git ls-remote`, not `git branch -r`.** Remote-tracking refs are stale until the next fetch and prune, and even same-script pruning is racy. `git ls-remote --heads origin 'claude/auto-*'` is authoritative. Gates that read stale refs will trigger "backlog cleanup" on zero real branches.
- **Don't leave PRs for someone else to merge** unless the task requires review.
- **Don't modify `context.md` or `progress.md` on a branch that other branches also modify.** These files conflict constantly. If you have to, make that change the very last commit before merging, after rebasing on main.
- **If a merge fails with code conflicts on a stale branch:** close the PR, delete the branch, and redo the work on a fresh branch from main. The exception is when the branch holds hand-written code that would be lost; then resolve it in an isolated worktree, verify (typecheck, tests, build), push and merge. Closing is right for bot-generated lockfile PRs that will be recreated.
- **MERGEABLE does not mean non-redundant.** A feature PR can be MERGEABLE when its whole patch is already on main (another PR branched off it and carried the code in). Before merging, rebase it in a throwaway checkout. If the commit is dropped ("patch contents already upstream") or `git diff origin/main <tip>` is empty, close it as superseded: `gh pr close <N> --delete-branch --comment "Superseded by ..."`.
- **A merged PR's "out of scope / follow-up" note is sanctioned follow-up work, not a duplicate.** Read the body of a merged PR before you reject a candidate as a duplicate of it. Reuse any helpers it shipped, and cite the scope note in the new PR body.

## `gh` in a Forked Checkout Can Silently Target Upstream
In a checkout with both `origin` (your fork) and `upstream` (the original project), bare `gh pr view <n>` and other `gh` commands without `--repo` can resolve against `upstream`. A PR number that exists upstream will look valid even though you don't control it.

**Rule:** before you view, merge, close or comment on a PR in any checkout that might be a fork, pass `--repo <owner>/<name>` explicitly. Branch-name patterns alone don't prove that a PR is yours. The risk is not a bad decision; it is acting on a repo you don't own.

## Hook-Executing Repos: Use Worktrees, Not Branch Checkouts
**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is used by live hooks, SessionStart scripts or process-manager configs.** The harness runs straight from those paths. Switching branches silently reverts every guidance file, hook and config to the target branch's version, for every concurrent session, with no error.

```bash
git -C "$HOME/<repo>" worktree add /tmp/wt-<repo> -b claude/<task>
# ... edit, commit, push, open PR from inside /tmp/wt-<repo> ...
git -C "$HOME/<repo>" worktree remove /tmp/wt-<repo>
```

A worktree that pushes straight to the default branch (for example an append-only log) must stay detached. Never run `checkout -B <default-branch>` inside it, because that collides with the primary checkout's branch.

### Merge a worktree branch from the primary checkout
- `git checkout main` inside a worktree fails ("already used by worktree"). Running `git worktree remove` while your cwd is inside that worktree leaves the shell without a working directory.
- The working sequence: commit in the worktree, `COMMIT=$(git rev-parse HEAD)`, `cd` to the primary checkout, `git merge --ff-only $COMMIT`, push, then `git worktree remove` from the primary checkout.

### Gate teardown on the commit existing, not on the next line running
A hook can block `git commit` and leave the work staged but uncommitted. If the merge, push or `git worktree remove --force` comes later in the same shell call, or after a `;`, it still runs. `git merge --ff-only` of a branch with no new commit exits 0, so `--force` deletes the worktree that holds the only copy. Make teardown conditional:

```bash
[ "$(git rev-parse <branch>)" != "$(git rev-parse <base>)" ] && \
  git merge --ff-only <branch> && git push && git worktree remove <path>
```

Recovery if it already happened: staged files survive as dangling blobs. Find them with `git fsck --unreachable | grep blob`, then read them with `git cat-file -p <sha>`.

**Same class: a conflict resolver's failed check doesn't stop a `;`-chained add, continue and push.** Join every step with `&&` (or use `set -e`). Gate `git add` on an explicit positive check, not only on the resolver's exit code:

```bash
git diff --check && ! grep -nE '^(<<<<<<<|=======|>>>>>>>)' <file> && git add <file>
```

## Remote Checkouts May Hold Commits That Exist Nowhere Else
Before you `git pull` or `git reset` in a checkout you don't own (a server, a container, another machine), check whether it is **ahead** of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => local-only commits live here
```

`git reset --hard origin/<branch>` destroys those commits permanently. A conflicting pull is a signal to investigate, not something to force past.

1. **Back it up first.** Run `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup`, and copy the bundle off the machine. A branch on a single host is not a backup.
2. **Find out whether the commits contain unique content. Don't trust their subjects.**
   ```bash
   git diff --stat origin/main..<backup-branch>
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"
   ```
   Then check each claimed feature in the upstream tree: `git grep -n "<feature>" origin/main -- src/`. A branch can be several commits "ahead" and still be strictly poorer, because upstream reimplemented the same work through squashed PRs with different SHAs.
3. **Choose based on evidence:**
   - *Superseded fork* (no unique content): `git reset --hard origin/<branch>`. This is safe when runtime state is gitignored; check what the code writes and confirm that any tracked data file is read-only config.
   - *Genuinely unique content*: port it to a branch off `origin/main`, commit it under a valid author identity, push, and only then reset the remote checkout.
   - *You need one fix now and will reconcile later*: cherry-pick onto that checkout's HEAD. This is an interim step, not an outcome.

   Afterwards, run that repo's tests **on that host**.
4. **Record the outcome in that checkout's own `context.md`** and commit it there. Docs committed upstream are invisible to a checkout that is far behind.
5. **Report the divergence as an open item.** Reconciling it is the owner's decision.

Restore from a bundle: `git fetch /path/to/x.bundle <name>-backup:<name>-backup`.

## An Untracked File Shadowing a Tracked Path Blocks Checkout
`git checkout -b <new> origin/main` fails with "untracked working tree files would be overwritten" when an untracked local file sits at a path that is tracked upstream. **Don't `rm` or `mv` the blocker.** It may be someone else's uncommitted notes. Commit through a worktree instead:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

If you moved the blocker aside anyway: the file is tracked on the branch you moved to and untracked on the branch you came from, so checking out the original branch DELETES it. Record `git status --short` before you start. After returning, check that the file exists and restore it if needed (`git show origin/main:<file> > <file>`), then confirm that `git status --short` matches the starting state exactly.

## The Shared Checkout May Host Another Live Agent Session
A single working tree can be edited by several sessions at once.

- **`git checkout -- <file>` can delete another session's uncommitted work.** An `M` in `git status` is one flag for the whole file, not proof that you wrote all of it. Before restoring any file in a shared tree, run `git diff <file>` and confirm that every hunk is yours. If any hunk isn't, leave the file alone and use a worktree.
- **Another session can commit your untracked files under its own message.** Anything uncommitted in a shared tree can be picked up by another process's `git add`.

**Detect a concurrent session BEFORE your first edit:**
```bash
git branch --show-current     # unexpected branch?
git reflog -5                 # checkouts or commits you did not make?
git worktree list             # worktrees you did not create?
git status --short            # record this; your final state must differ only by your files
```
If any of these show another session, branch a worktree off trunk immediately and don't touch the shared tree. When reconciling, if the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force a duplicate commit. Reset to origin and commit only what is genuinely missing.

### Push gates and work that isn't yours
If you run a stop or push gate that blocks on dirty files or unpushed commits:
- **Dirty files:** the gate can't tell "I forgot to push" apart from "another session edited the same path". If it supports acknowledgments, acknowledge one exact path with a written reason, and only after you have proven the file isn't yours (`git diff <file>` shows none of your hunks, and your own content is already on the remote). An acknowledgment must never act as a mute switch: no wildcards, no blank reasons, and unpushed commits still block.
- **A peer's unpushed commit:** the gate should block only on commits that contain files *you* wrote. If the peer session is still live, wait; they may amend. If the commit is genuinely stranded (the authoring session is gone and the work exists nowhere else):
  1. Identify the author and branch: `git log --format='%h %an %ad %s' @{u}..HEAD`, `git branch --show-current`.
  2. Secret-scan the diff you are about to publish.
  3. Push it to the branch it was committed on: `git push origin HEAD:<that-branch>`. Never redirect a peer's commit to main.
  4. Say in your final message that you did this.
- Never `git reset` a peer's commit to clear a gate.

## A PR Stuck CONFLICTING Is Invisible to Automation
**`gh pr view N --json mergeable` returns `UNKNOWN` on the first poll.** GitHub computes mergeability lazily, and only a follow-up read (about 6s later) gives the real `MERGEABLE` or `CONFLICTING`. Any check that gates on mergeability must poll again, or blocked PRs can sit for days without an alert.

Diagnosis order when a repo "seems behind":
1. `git status`. A clean tree means it is almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge. **Don't use the legacy 3-arg `git merge-tree <base> <a> <b>`**: it can exit 0 with no conflict markers when a real merge does conflict. If in doubt, trial-merge in a detached worktree: `git worktree add /tmp/x <branch> --detach && cd /tmp/x && git merge origin/main --no-commit --no-ff`.

**Merge the default branch INTO the stale branch, never the reverse.** Pushing a far-behind branch onto the default branch deletes everything added since it forked. For append-only files, verify that nothing was lost before committing. This must print 0 against both parents:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

**Merging same-file PRs one at a time does not drain a backlog.** Each merge moves the default branch under its siblings and creates new conflicts. When N PRs edit the same hotspot file, merge them into one integration branch, resolve the combined set once, and land that.

**Only auto-resolve what is provably safe.** A union resolver should refuse any hunk where the two sides share a line, and should never union a YAML frontmatter hunk (that produces duplicate keys).

**Append-only log conflicts need chronological reinsertion.** The two blocks are usually independent entries from different times. Read each block's date or run header and move it to where it belongs chronologically, which can be well outside the conflict markers. Then check that the headers are in order.

### UNSTABLE status from a failing check is not automatically a blocker
When `mergeStateStatus` is UNSTABLE, read the failing job (`gh run view --log-failed`) and compare what it checks against the PR's file list. If the same failure reproduces on a fresh clone of the base branch, it predates the PR and should not block an otherwise eligible merge.

### A PR whose head branch was deleted while open stays UNKNOWN forever
Symptoms: green checks, OPEN, `mergeStateStatus: UNKNOWN`, `gh pr merge` says "Head branch is out of date", and `update-branch` says "head ref does not exist". Run `git ls-remote origin refs/heads/<branch>`; empty output confirms it. Recreate the branch from the PR ref:

```bash
git ls-remote origin refs/pull/<n>/head                    # get <head-sha>
git push origin <head-sha>:refs/heads/<branch-name>
gh api repos/<owner>/<repo>/pulls/<n>/update-branch -X PUT
gh pr merge <n> --squash --delete-branch
```

## Discrimination Checks: `git stash push`, Never `git checkout`
To prove that a regression test discriminates, you revert the fix and expect failures. Reverting uncommitted work with `git checkout -- <dir>` destroys it, with no reflog to recover from. Use the stash:

```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part (if any)
<run suite, record failures>
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```

## Scanner Hooks Can Diff the Wrong Range
- **Pre-commit on a merge commit:** a hook that runs `git diff --cached` with no base compares against the pre-merge HEAD, so the default branch's already-approved content is flagged as new. The hook fix: when `MERGE_HEAD` exists, diff against `$(git merge-base HEAD MERGE_HEAD)`.
- **Pre-push after a rebase:** the hook scans `$REMOTE_SHA..$LOCAL_SHA`, and `$REMOTE_SHA` is the stale pre-rebase tip, which is no longer an ancestor. Before deciding the push is genuinely blocked, re-scan the correct range yourself: `git diff origin/main..HEAD | grep '^+' | grep -v '^+++' | <your scanner>`.
- In both cases, **don't use `--no-verify`**. Isolate the real range, and if the content is genuinely clean, leave the work unpushed and fix the hook, or resolve the merge somewhere the hook doesn't misfire.
- Hooks installed into `.git/hooks` (or through `init.templateDir`) are COPIES. Editing the source changes nothing until you reinstall them. Verify by grepping the installed copies for a marker from the new code.

## Commit Identity: Push Fails on Private Emails
With GitHub email privacy enabled, committing under a personal address fails **at push time** with `GH007: Your push would publish a private email address`. A session that only checks that the commit succeeded will report work that never landed.

- Don't pass an explicit `-c user.email=...`. Check which identity the repo's history uses: `git log -3 --format=%ae`.
- Commit as `<username>@users.noreply.github.com`. Fix an existing commit with `git -c user.email=<username>@users.noreply.github.com commit --amend --no-edit --reset-author`.
- GitHub checks the **committer** as well as the author on every commit being pushed, so replayed or cherry-picked commits need fixing too. Pushing from a different machine doesn't help.
- If the global `~/.gitconfig` itself has drifted, set `GIT_AUTHOR_EMAIL` and `GIT_COMMITTER_EMAIL` for the commit, and flag the config for the owner to fix.
- General rule: verify the operation that actually publishes, not the local step before it.

## Run-Numbered Branch Names and Stale Local Refs
- **Before creating a run-numbered branch, check both:** `git branch -a | grep <name>` and `gh pr list --repo <owner>/<repo> --head <name> --state all`. A squash-merged branch fails `git merge-base --is-ancestor`, so ancestry alone can't tell "merged" apart from "diverged". If the name collides, add a suffix (`<name>-2`) instead of investigating or deleting refs.
- **When rescuing an existing PR branch with `git worktree add <path> <branch>` (bare name),** the bare name resolves to the local ref, which may be far behind origin and show phantom conflicts that are already resolved. Check first, then fast-forward the bystander ref:
  ```bash
  git rev-parse <branch> origin/<branch>
  git branch -f <branch> origin/<branch>   # safe only if <branch> is not checked out anywhere
  ```
