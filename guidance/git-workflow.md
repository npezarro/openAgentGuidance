<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main`.
- Use the branch assigned to you. If there isn't one, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Don't use `test-` as a branch prefix.** Some repos have rulesets or branch protection that silently reject pushes to `test-*` branches. You get no error, and the branch never appears on the remote. Use descriptive names like `add-tests-<module>` or `<module>-tests-<run>`.
- Commit messages explain **why**, not just what. Large commits are fine; don't split work artificially.
- Before committing:
  1. Run `git status` to check that no unintended files are staged.
  2. Run `git diff` to review the actual changes.
  3. Confirm that no `.env`, secret or key files are included.
  4. **Update `context.md`.** This is required on the final commit of a branch (before creating a PR) or at session wrap-up, but not on every intermediate commit. It records the current state, recent changes and open items for the next agent.
  5. **Update `progress.md`** with an entry for the work being committed.
- Push with `git push -u origin HEAD`. Retry network failures up to 4 times with backoff (2s, 4s, 8s, 16s). Don't retry auth failures.

## All Deliverables Go in Repos
Every script, tool, project asset, analysis doc, reference file or other output goes **in a git repo** and gets pushed to the remote. Never leave files as loose filesystem artifacts: the user can't reach local-only files between sessions. If a new project doesn't have a repo yet, create one (`gh repo create`).

**This is the most common mistake.** Sessions create useful files and then forget to commit, forget to push, or save them outside a repo. Treat every file write as incomplete until it is committed and pushed.

## Every Repo Gets a README and Description
- **README.md**: what the project does (1-2 sentences), how to set it up, and how to run or use it. A developer should understand the project in 60 seconds.
- **Remote description**: one sentence, for example `gh repo edit <owner>/<repo> --description "one-line summary"`.

Both are required at creation: pass `--description` to `gh repo create` and include the README in the initial commit. If you work in a repo that's missing either one, add it.

## Always Commit and Push Written Files
Creating a file, running `git commit` and running `git push` are one operation. If any step fails, diagnose and fix it before you move on. Unpushed commits are invisible to other sessions, collaborators and deploy pipelines.

**Common gap:** in a session that touches several repos, it's easy to push some and forget others. When you finish, run `git status` in each repo.

## Staging Hygiene (applies to EVERY repo)
Any checkout can hold uncommitted work from an earlier session or from a concurrent agent. A blanket add silently ships that work under your commit message. This applies to every repo, not just repos you think of as "shared".

- **Run `git status` BEFORE you stage.** If the tree holds anything you didn't touch, stage your paths by name.
- **Stage explicit paths. Never use `git add -A` or `git add .`:** `git add guidance/foo.md scripts/bar.sh`. A blanket add has swept half-finished unrelated features, and even secrets, into commits.
- **Before committing, confirm that ONLY your files are staged.** Unstage anything else with `git restore --staged <path>`.
- **Never use `--no-verify` on a public repo.** The pre-commit secret and sensitive-identifier scanner is the last line of defense before a leak. If it blocks you, sanitize the content; don't override the scanner.
- After committing, review with `git show --stat` before pushing.

## Creating PRs (with retry)
After `git push`, the remote can take a few seconds to register the branch. Check that the branch exists before you create the PR, and retry on failure:

```bash
# 1. Wait for the remote to register the pushed branch
for i in 1 2 3 4 5; do
  if gh api "repos/{owner}/{repo}/branches/$(git branch --show-current)" --silent 2>/dev/null; then
    break
  fi
  echo "Waiting for GitHub to register branch (attempt $i)..."
  sleep $((i * 2))
done

# 2. Check for an existing PR on this branch
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

- **Never fall back to a "create it manually" URL.** If `gh pr create` still fails after 3 retries, diagnose the cause (auth, missing branch, network) and fix it.
- Don't enable auto-merge unless you're explicitly asked to.

### REST API: qualify the `head` parameter
When you create PRs through the REST API (for example Octokit) rather than `gh`, pass `head` as `owner:branch`:

```js
// WRONG: "invalid head" errors, especially on newly pushed branches
await octokit.rest.pulls.create({ head: branch, ... });
// CORRECT
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

The remote needs a few seconds to index a newly pushed branch. Add a delay of about 3s before `pulls.create`, allow up to 5 attempts, and retry on "invalid head". (`gh pr create` qualifies the head for you.)

## Repos With an Auto-Merge Bot
If a bot squash-merges pushed branches automatically:

- **"No commits between main and `<branch>`" or "Head sha can't be blank" after a push means the merge succeeded.** The bot already opened and merged a PR. Find it with `gh pr list --state all --head <branch>` and reuse that number. Don't push again or open a duplicate: a retry can produce a second merged PR for one change.
- **Verify by content, not ancestry.** A squash commit is never an ancestor of your local commit, so `git merge-base --is-ancestor` and `git branch --merged` report false. Use `git diff origin/<default> <your-sha> -- <files>`: empty output means the change landed.
- **Opt-out bots merge everything.** If the bot merges every non-draft PR by default, a branch you don't want merged yet isn't safe just because you pushed it. Convert the PR to draft right away (`gh pr ready <n> --undo`). Better still, add product or design repos to the bot's denylist before their first push, and support per-commit override markers (for example `[no-automerge]`).
- **Follow-up fixes go on a FRESH branch off main.** After a squash-merge, a second commit pushed to the old branch conflicts every time. Run `git checkout -b <new> origin/main`, then `git checkout <old-branch> -- <changed files>`, commit, push, and close the stale PR. Confirm a push actually landed with `git ls-remote --heads origin <branch>`, not with the local `origin/<branch>` ref.
- **Agents that create PRs must check that the PR merged before ending the session:** `gh pr view <n> --json state,mergeable`. If it shows MERGEABLE and CI is green but it isn't merged, merge it now. Don't rely on a later sweep: verified fixes have sat unmerged for days this way.
- **The default branch isn't always `main`.** Resolve it with `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
- When you verify added lines with grep, use `grep -Fqx -- "$line"`. Without the `--`, a line that starts with `-` (a markdown bullet) is parsed as an option and causes false negatives.

## Branch Hygiene
Open PRs that sit unmerged cause cascading merge conflicts. **This is the number one cause of stuck work.**

- **Merge PRs promptly.** If a PR is ready and needs no review, merge it in the same session: `gh pr merge <number> --merge --delete-branch`. If that fails, retry once after 5s. If it fails again, report the specific error.
- **Rebase before you open a PR:** `git fetch origin && git rebase origin/main`. A PR should be mergeable when you create it.
- **Use one branch per task.** Don't leave abandoned branches behind.
- **Clean up stale branches** at session start with `gh pr list --state open` and `git branch -a`. Rebase and merge or close anything that has been idle for days.
- **Prune before you scan:** run `git remote prune origin` before `git branch -a` or `-r`. Unpruned refs inflate "open branch" counts with branches that no longer exist.
- **Automation gates (caps, dedup, backlog checks) must use `git ls-remote --heads origin '<pattern>'`, not `git branch -r`.** Remote-tracking refs are stale until the next fetch with prune, and even then they race other processes. Only `ls-remote` is authoritative.
- **In a forked checkout, `gh` can resolve against `upstream` instead of `origin`.** A PR number that exists upstream looks valid even though you don't control that repo. Always pass `--repo <owner>/<name>` before you view, merge, close or comment on a PR in any checkout that might be a fork.
- **Don't leave PRs for someone else to merge** unless the task requires review.
- **Keep `context.md` and `progress.md` edits out of shared branches.** These files conflict constantly. Update them in the last commit before merging, after you rebase on main.
- **If a merge fails on code conflicts in a stale branch,** close the PR, delete the branch, and redo the work on a fresh branch from main instead of grinding through complex conflicts.
- **MERGEABLE doesn't mean the PR still adds anything.** Another PR may already have carried its content into main. Before you merge a PR that looks ready, rebase it in a throwaway checkout. If the commit is dropped as "already upstream", or `git diff origin/main <tip>` is empty, close it as superseded (`gh pr close <N> --delete-branch --comment "Superseded by ..."`).
- **Treat a merged PR's "out of scope / follow-up" note as approved follow-up work, not as a duplicate.** Read the merged PR's body before you reject a similar candidate, reuse any helpers it shipped, and cite the scope note in the new PR.

## Repos That Run Live Hooks: Use Worktrees, Not Branch Checkouts
**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is referenced by live hooks, SessionStart scripts or process-manager configs.** Switching branches silently reverts all guidance, hooks and config to whatever the target branch holds, for every concurrent session. Nothing warns you.

```bash
git -C "$HOME/<repo>" worktree add /tmp/wt-<repo> -b claude/<task>
# ... edit, commit, push, open the PR from inside /tmp/wt-<repo> ...
git -C "$HOME/<repo>" worktree remove /tmp/wt-<repo>
```

A worktree that pushes straight to the default branch (for example an append-only log) must stay detached. Never run `checkout -B <default-branch>` inside it, because that collides with the primary checkout's branch.

### Landing a worktree branch
- Running `git checkout main` inside a worktree fails ("already used by worktree"). Running `git worktree remove` while your shell is inside the worktree leaves the shell with no working directory.
- The correct sequence: commit in the worktree, run `COMMIT=$(git rev-parse HEAD)`, `cd` to the primary checkout, run `git merge --ff-only $COMMIT`, push, then run `git worktree remove` from the primary checkout.

### Rescuing an existing branch in a worktree
`git worktree add <path> <existing-branch>` uses the **local** ref, which may be weeks behind origin if every earlier rescue pushed from a worktree. Merging from a stale base produces phantom conflicts that were already resolved. Check first:

```bash
git rev-parse <branch> origin/<branch>        # must match
git branch -f <branch> origin/<branch>        # fast-forward the bystander ref if not
```

## Commit Identity
- Never hardcode an email with `-c user.email=...`. Let git use the repo's configured identity.
- With email privacy on, a commit authored with a personal address is rejected **at push time** (`GH007: Your push would publish a private email address`). The remote checks the **committer** of every pushed commit, so pushing from a different machine doesn't help. Commit as `<username>@users.noreply.github.com`, and fix existing commits with `git -c user.email=<noreply> commit --amend --no-edit --reset-author`.
- In an unfamiliar repo, run `git log -3 --format=%ae` to see which identity its history uses.
- General rule: verify the step that actually publishes (the push), not the local step before it.

## Remote Checkouts May Hold Commits That Exist Nowhere Else
Before you run `git pull` or `git reset` in a checkout you don't own (a server, a container, another machine), check whether it is **ahead**:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

A conflicting pull is a signal to investigate, not a nuisance to force past. Running `reset --hard` would destroy those commits permanently.

1. **Back them up before you touch anything:** `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup` and copy the bundle off the machine.
2. **Check whether the commits contain unique content. Don't trust their subjects:**
   ```bash
   git diff --stat origin/main..<backup-branch>
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"
   git grep -n "<claimed feature>" origin/main -- src/
   ```
   A branch can be several commits "ahead" and still be strictly poorer than upstream, because upstream reimplemented the same work under different SHAs.
3. **Choose based on that evidence:**
   - *Superseded fork* (no unique content): run `git reset --hard origin/<branch>`. This is safe once you confirm that runtime state is gitignored and that tracked data files are config, not state.
   - *Genuinely unique content*: port it onto a branch off `origin/main`, push it, and only then reset the remote checkout.
   - *One fix needed now*: cherry-pick it onto that checkout's HEAD as a stopgap. This isn't a resolution.

   Afterwards, run the repo's tests **on that host**. A big jump in test count is a good sign you recovered real work.
4. **Record the outcome in that checkout's own `context.md`.** Docs committed upstream are invisible to a checkout that is far behind.
5. **Report the divergence as an open item.** Reconciling it is the owner's decision.

Restore from a bundle with `git fetch /path/to/x.bundle <name>-backup:<name>-backup`.

## Untracked File Shadowing a Tracked Path
If `git checkout -b <new> origin/main` aborts with "untracked working tree files would be overwritten", **don't `rm` or `mv` the blocker.** It may be someone else's uncommitted notes. Commit through a worktree instead:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch>
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

If you already moved the blocker aside and switched branches, switching back **deletes** the file: it is tracked on one branch and untracked on the other. To recover:

1. Record `git status --short` before you start.
2. After you return, check that the file exists.
3. If it's gone, restore your backup, or run `git show origin/main:<file> > <file>`.
4. Confirm that `git status --short` matches step 1 exactly.

## A Shared Checkout May Host Another Live Session
**1. `git checkout -- <file>` can delete another session's work.** An `M` in `git status` is one flag for the whole file. It doesn't mean every change is yours. Before you restore any file in a shared tree, run `git diff <file>` and confirm that every hunk is yours. If any hunk isn't yours, leave the file alone and work in a worktree.

**2. Another session can commit your untracked files under its own message.** Anything uncommitted in a shared tree can be picked up by another process's `git add`. When another session might share the checkout, do the whole edit in a worktree from the start.

**Check for a concurrent session BEFORE your first edit:**
```bash
git branch --show-current     # an unexpected branch
git reflog -5                 # checkouts or commits you did not make
git worktree list             # worktrees you did not create
git status --short            # record this; your final state must differ only by your files
```

If the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force your duplicate commit. Reset to origin and commit only what is genuinely missing.

### Unpush gates and other sessions' work
If a stop hook blocks on dirty or unpushed work, it may fire on files or commits that belong to another session.

- **Dirty files:** acknowledge one path at a time, and only after you have *proven* the change isn't yours. That proof is `git diff <file>` showing none of your hunks, plus evidence that your own content is already on the remote. A well-designed ack mechanism takes one path per entry, no wildcards, and a required reason. Acknowledging work you simply forgot to push is exactly the failure the gate exists to catch.
- **A peer's unpushed commit:** if the peer session is still live, wait; it may still amend. Push a peer's commit only when it is genuinely stranded (the authoring session is gone and the work exists nowhere else):
  1. Identify the author and branch: `git log --format='%h %an %ad %s' @{u}..HEAD` and `git branch --show-current`.
  2. Scan the diff for secrets. You are publishing content you didn't review.
  3. Push it to the branch it was committed on (`git push origin HEAD:<that-branch>`). Never redirect it to the mainline.
  4. Say so in your final report.

  Never `git reset` a peer's commit to clear a gate.

## PRs Stuck CONFLICTING
**`gh pr view N --json mergeable` returns `UNKNOWN` on the first poll.** Mergeability is computed lazily, and only a second read about 6s later returns `MERGEABLE` or `CONFLICTING`. Any checker that reads only once will miss blocked PRs indefinitely. **Anything that gates on mergeability must poll again.**

When a repo seems to be behind:
1. `git status`. A clean tree means the cause is almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge. **Don't use the legacy 3-argument `git merge-tree <base> <a> <b>`.** It can exit 0 with no conflict markers on a merge that really conflicts. If in doubt, do a real trial merge in a detached worktree: `git merge origin/main --no-commit --no-ff`.

**Merge the default branch INTO the stale branch, never the reverse.** Pushing a branch that is N commits behind onto the default branch deletes everything added since it forked. For append-only files, verify losslessness against both parents; this must print 0:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

**Merging same-file PRs one at a time doesn't drain a backlog.** Each merge moves the base under its siblings, so PRs that were mergeable become conflicting. When N PRs edit the same hotspot file, merge them all into one integration branch, resolve once, and land that.

**Auto-resolve only what is provably safe.** A union resolver should refuse any hunk where both sides share a line. Never union a YAML frontmatter hunk; it produces duplicate keys.

**Append-only logs need chronological reinsertion.** When rebasing a conflict in a dated run log, the incoming entry is often older than entries main gained after the branch diverged. Read each block's date header, move the block to its correct chronological position (which may be outside the conflict markers), then check that the date headers are monotonic.

**Failing CI under UNSTABLE doesn't automatically block a merge.** Check which files the failing job covers against the PR's file list. If the same failure reproduces on a fresh checkout of the base branch, it predates the PR and shouldn't veto an otherwise eligible merge.

**A PR whose head branch was deleted while it was still OPEN stays stuck at `mergeStateStatus: UNKNOWN` forever.** Green checks plus OPEN state is not proof that it's just waiting. Check with `git ls-remote origin refs/heads/<branch>`. If that's empty, recreate the branch from the PR ref:

```bash
git ls-remote origin refs/pull/<n>/head                       # get the head sha
git push origin <head-sha>:refs/heads/<branch-name>
gh api repos/<owner>/<repo>/pulls/<n>/update-branch -X PUT
gh pr merge <n> --squash --delete-branch
```

## Scanner Hooks and Rewritten History
- **A pre-commit hook that uses plain `git diff --cached` diffs a merge commit against the pre-merge HEAD**, not against the merge-base. When you merge main into a long-stale branch, it flags all of main's already-approved content as new. The hook fix: when `MERGE_HEAD` exists, use `$(git merge-base HEAD MERGE_HEAD)` as the diff base.
- **A pre-push hook that scans `$REMOTE_SHA..$LOCAL_SHA` breaks after a rebase.** The old remote tip is no longer an ancestor, so the range spans all of main. To isolate real hits, scan the correct range yourself: `git diff origin/main..HEAD | grep '^+' | grep -v '^+++' | <your-scanner>`.
- In both cases, **don't use `--no-verify`**. Isolate the real range, confirm that nothing new is flagged, and fix the hook, or leave the work unpushed.
- Hooks installed into `.git/hooks` (or through `init.templateDir`) are **copies**. Editing the source changes nothing until you reinstall them in every clone. To verify a fix, grep the installed copies for a marker from the new code.

## Run-Numbered Branch Name Collisions
Before you create a branch named after a run or sequence number, check both of these:

```bash
git branch -a | grep <name>
gh pr list --repo <owner>/<repo> --head <name> --state all
```

A squash-merged branch fails `git merge-base --is-ancestor`, so that test alone can't tell "merged" from "diverged". The `--state all` PR lookup can. If the name collides, append a suffix (`<name>-2`) rather than deleting refs or digging through history.

## Discrimination Checks: Stash, Never Checkout
To prove that a regression test discriminates, you revert the fix and expect failures. Running `git checkout -- <dir>` **destroys** an uncommitted fix with no way to recover it. Use stash instead:

```bash
git stash push -- src/            # save the uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
<run suite, record failures>
git checkout HEAD -- src/         # restore the committed part
git stash pop                     # restore the uncommitted part
```

Also confirm that every new assertion FAILS against the pre-fix code. A test that passes on both versions proves nothing.
