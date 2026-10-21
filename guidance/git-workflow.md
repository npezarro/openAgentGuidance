<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main` (or whatever the default branch is).
- Use the branch assigned to you. If none exists, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Don't start branch names with `test-`.** Some repos have rulesets or branch protection that silently reject pushes to `test-*` branches. You get no error; the branch just never shows up on the remote. Use descriptive names like `add-tests-<module>` or `<module>-tests-<run>`.
- Commit messages explain **why**, not just what. Large commits are fine. Don't split work artificially.
- Before committing:
  1. Run `git status` and make sure nothing unintended is staged.
  2. Run `git diff` and review the actual changes.
  3. Make sure no `.env`, secret, or key files are included.
  4. **Update `context.md`** (the repo's current-state handoff file). This is mandatory on the final commit of a branch (before you create the PR) or at session wrap-up. It isn't required on every intermediate commit.
  5. **Update `progress.md`**: add an entry for the work you're committing.
- Push with `git push -u origin HEAD`. If the network fails, retry up to 4 times with backoff (2s, 4s, 8s, 16s). Don't retry auth failures.

## All Deliverables Go in Repos
Scripts, tools, project assets, analysis docs, reference files and any other output **always go in a git repo** that gets pushed to GitHub. Never leave files as loose filesystem artifacts. GitHub is the source of truth. If a new project or tool set doesn't have a repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions create useful files and then forget to commit them, forget to push them, or save them outside a repo. Local-only files can't be reached from later sessions. A `Write` or `Edit` isn't finished until the file is committed and pushed.

## Every Repo Gets a README and Description
Every repo needs a `README.md` and a GitHub repo description. If you create a repo, or work in one that's missing either, add them.

- **README.md**: what it does (1-2 sentences), how to set it up, and how to run or use it. A developer should understand the project in 60 seconds.
- **GitHub description**: set it with `gh repo edit <owner>/<repo> --description "one-line summary"`.

Both are required when you run `gh repo create`. Pass `--description` and include the README in the initial commit.

## Always Commit and Push Written Files
Write and Edit don't commit. **Commit and push in the same step** whenever you create or change files in a repo. Treat file creation, `git commit` and `git push` as one atomic operation. If any step fails, diagnose and fix it before moving on. Unpushed commits are invisible to other sessions, collaborators and the deploy pipeline.

**Common gap:** when one session touches several repos, it's easy to push some and forget others. After a multi-repo task, run `git status` in each repo and confirm every one is clean.

## Staging Hygiene (applies to every repo)
Any checkout can hold uncommitted work from an earlier or concurrent session. A blanket add quietly ships that work under your commit message. This isn't only a risk in "shared" repos: in practice a repo nobody thought of as shared had a half-finished adapter swept into an unrelated commit.

- **Run `git status` BEFORE staging.** If the tree holds anything you didn't touch, name your paths explicitly.
- **Stage explicit paths. Never use `git add -A` or `git add .`.** For example: `git add guidance/foo.md scripts/bar.sh`.
- **Never use `--no-verify` on a public repo.** A pre-commit sensitive-identifier scanner is the last defense before a username, internal path or token reaches a public repo. If the scanner blocks you, sanitize the content. Don't override it.
- **Before committing, confirm that ONLY your files are staged.** Unstage anything you didn't touch with `git restore --staged <path>`.
- **Review `git show --stat` before pushing.** It catches swept-in files while they're still cheap to fix (reset the commit and redo it with explicit paths).

## Creating PRs (with retry)
After `git push`, GitHub can take a few seconds to register the branch. Check that the branch exists remotely before creating the PR, and retry on failure:

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

- **Never fall back to a "create it manually" URL.** If `gh pr create` still fails after 3 retries, diagnose the error (auth, branch not found, network) and fix it.
- Don't enable auto-merge unless someone explicitly asks for it.

## GitHub REST API PR Creation: Qualify the Head Parameter
When you create PRs through the REST API (Octokit, say) instead of `gh pr create`, the `head` parameter must be qualified as `owner:branch`:

```js
// WRONG: causes "invalid head" errors, especially on newly-pushed branches
await octokit.rest.pulls.create({ head: branch, ... });

// CORRECT
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

GitHub doesn't index a newly pushed branch instantly, and unqualified names fail more often during that window. Wait about 3s after the push before calling `pulls.create`, set `maxAttempts` to 5, and retry on "invalid head". `gh pr create` qualifies the head on its own.

## If You Run an Auto-Merge Bot
If a bot squash-merges PRs automatically when a branch is pushed:

- **"No commits between main and `<branch>`" or "Head sha can't be blank" after a push usually means success.** The bot already opened and merged the PR. Find it with `gh pr list --state all --head <branch>` and reuse that number. Don't push again or open a duplicate: a retry can produce a second merged PR for one logical change.
- **Verify by content, not ancestry.** A squash commit isn't an ancestor of your local commit, so `git merge-base --is-ancestor` returns false and `git branch --merged` shows your branch as unmerged. Use `git diff origin/main <mine> -- <file>` (empty means it landed) or check that every added line is present: `git show origin/main:<file> | grep -Fqx -- "$line"`. Keep the `--`: without it, an added line that starts with `-` (a markdown bullet) is parsed as a grep option and you get false negatives.
- **Opt-out bots merge everything, including branches you never meant to land.** Before the first push of a design branch or work-in-progress branch to a repo with human or design branches, put the repo on the bot's denylist, or use a per-commit override marker if the bot supports one (e.g. `[no-automerge]` in the head commit subject). Running `gh pr create --draft` right after the push is NOT reliable, because the bot can open and merge a non-draft PR within seconds. Converting to draft only works on a PR that already existed before the bot saw the push.
- **Want CI on unfinished work in an unprotected repo? Don't push the branch.** Run the tests locally or trigger CI through `workflow_dispatch`. If it merges anyway and the squash tree matches your work, `git rebase --onto origin/main <first-pushed-sha>` and carry on.
- **Put follow-up fixes after an auto-merge on a FRESH branch off main.** The bot deletes the merged branch, and pushing a second commit to it conflicts every time (main has one squashed commit, your branch has the originals). Run `git checkout -b <new> origin/main`, then `git checkout <old-branch> -- <changed files only>`, commit, push, and close any stale PR. Confirm the push landed with `git ls-remote --heads origin <branch>`, not the local `origin/<branch>` ref, which goes stale the moment the bot deletes the branch.
- **Resolve the default branch name. Don't assume it's `main`:** `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.

## Branch Hygiene
PRs left unmerged cause merge conflicts in every other branch. **This is the #1 cause of stuck work.**

- **Merge PRs promptly.** If a PR is ready and needs no review, merge it in the session that created it: `gh pr merge <number> --merge --delete-branch`. If the merge fails, retry once after 5s. If it still fails, report the specific error.
- **Rebase before opening a PR** with `git fetch origin && git rebase origin/main`. A PR should be mergeable when you create it.
- **Use one branch per task.** Don't leave abandoned branches behind.
- **Clean up stale branches at session start.** Check `gh pr list --state open` and `git branch -a`. If a branch has been idle for more than a few days, rebase and merge it or close it.
- **Prune before counting branches.** Run `git remote prune origin` before `git branch -a` or `git branch -r`. Otherwise tracking refs for deleted branches inflate "open branch" counts.
- **Automated cap and dedup gates must use `git ls-remote`, not `git branch -r`.** Tracking refs only refresh on fetch, and even prune-then-list is racy. `git ls-remote --heads origin 'claude/auto-*'` is authoritative.
- **Verify that automation-created PRs actually merged.** An agent that logs "PR: <link>" and stops can leave a green, mergeable PR sitting for days. As the last step, re-check `gh pr view <n> --json state,mergeable` and merge right then if it's MERGEABLE with passing CI.
- **Don't leave PRs for someone else to merge** unless the task explicitly calls for review.
- **`context.md` and `progress.md` conflict constantly.** Update them as the very last commit, after rebasing on main.
- **If a merge fails with complex code conflicts on a stale branch,** you can close the PR, delete the branch, and redo the work on a fresh branch from main. For automation PRs that contain real hand-written code, first try resolving in an isolated worktree (see below), because closing loses the work. Closing is only lossless for generated PRs such as dependency lockfile bumps, where the tool will recreate the PR.
- **MERGEABLE doesn't mean non-redundant.** A feature PR can show MERGEABLE when its whole patch is already on main (another PR that branched off it carried the code in). Before merging, rebase in a throwaway checkout. If the commit is dropped as "already upstream", or `git diff origin/main <tip>` is empty, close it as superseded: `gh pr close <N> --delete-branch --comment "Superseded by ..."`.
- **A merged PR's "out of scope / follow-up" note sanctions follow-up work.** When a candidate task looks like a duplicate of a merged PR, read that PR's body first. An explicit follow-up note makes the task pre-vetted, and the merged PR often ships helpers you should reuse. Cite the note in the new PR.

### `gh` in a forked checkout can resolve against `upstream`
In a checkout with both `origin` (your fork) and `upstream`, bare `gh pr view <n>` can resolve against the upstream repo. A PR number that happens to exist there will look valid. **Always pass `--repo <owner>/<name>`** before you view, merge, close or comment on a PR in a checkout that might be a fork. The danger isn't a bad merge decision. It's acting on a repo you don't control at all.

## Hook-Executing Repos: Use Worktrees, Not Branch Checkouts
**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is loaded by live hooks, SessionStart scripts or a process manager.** Switching branches silently reverts every guidance file, hook and config to the target branch's version, for every concurrent session, with no error.

```bash
git -C <repo> worktree add /tmp/wt-<repo> -b claude/<task>
# ... edit, commit, push, open PR from inside /tmp/wt-<repo> ...
git -C <repo> worktree remove /tmp/wt-<repo>
```

A worktree that pushes straight to the default branch (an append-only log, for example) must stay detached. Never `checkout -B <default-branch>` inside it, because that collides with the primary checkout's branch.

### Landing a worktree branch
- `git checkout main` inside a worktree fails ("already used by worktree"). Merge from the **primary** checkout: commit in the worktree, run `COMMIT=$(git rev-parse HEAD)`, `cd` to the primary checkout, then run `git merge --ff-only $COMMIT` and push. Run `git worktree remove` from the primary checkout, never while your cwd is inside the worktree.
- **Make teardown conditional on the commit existing.** A hook can block `git commit` and leave the work staged. A later `git merge --ff-only` is then a no-op that exits 0, and `git worktree remove --force` deletes the only copy. Guard it:
  ```bash
  [ "$(git rev-parse <branch>)" != "$(git rev-parse <base>)" ] && \
    git merge --ff-only <branch> && git push && git worktree remove <path>
  ```
  If the worktree is already gone, staged files survive as dangling blobs: `git fsck --unreachable | grep blob`, then `git cat-file -p <sha>`.

### Rescuing an existing branch in a worktree
`git worktree add <path> <existing-branch>` uses the **local** ref, which may be weeks behind `origin/<branch>` if every earlier run worked in worktrees and pushed straight to origin. Merging main into that stale ref shows phantom conflicts that were already resolved upstream. First run `git rev-parse <branch> origin/<branch>`. If they differ, run `git branch -f <branch> origin/<branch>`. This is safe only because the main checkout never has that branch checked out.

### Run-numbered branch name collisions
Before you create a run-numbered branch, check both:
1. `git branch -a | grep <name>` (local ref)
2. `gh pr list --head <name> --state all` (a squash-merged branch whose name might be reused)

`git merge-base --is-ancestor` can't tell "squash-merged" from "diverged". If a name collides, add a suffix (`<name>-2`) instead of investigating or deleting refs.

## Remote Checkouts May Hold Commits That Exist Nowhere Else
Before `git pull` or `git reset` in a checkout you don't own (a server, container or other machine), check whether it's ahead of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

`git reset --hard` destroys those commits permanently. A conflicting pull is a signal to investigate, not a nuisance to force past.

1. **Back up before touching anything.** Run `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup`, and copy the bundle off the machine. A branch on a single host isn't a backup.
2. **Find out whether the commits hold unique content. Don't trust commit subjects.**
   ```bash
   git diff --stat origin/main..<backup-branch>
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"
   ```
   Check each claimed feature in the upstream tree: `git grep -n "<feature>" origin/main -- src/`. A checkout "N commits ahead" can still be strictly poorer, because upstream may have reimplemented the same work through squashed PRs whose SHAs never match.
3. **Choose based on that evidence:**
   - *Superseded (nothing unique):* run `git reset --hard origin/<branch>`. This is safe once you've confirmed runtime state is gitignored and any tracked data file is read-only config.
   - *Genuinely unique content:* port it onto a branch off `origin/main`, commit under a valid identity, push, and only then reset the remote checkout.
   - *You need one fix now:* cherry-pick it onto that checkout's HEAD as a temporary measure.
   
   Then run the repo's tests **on that host**. A big jump in test count is a good sign you recovered real work.
4. **Record the outcome in that checkout's own `context.md`** and commit it there. Docs committed upstream are invisible to a checkout that's far behind.
5. **Report the divergence as an open item.** The owner decides how to reconcile it.

Restore from a bundle with `git fetch /path/to/x.bundle <name>-backup:<name>-backup`.

## Untracked File Shadowing a Tracked Path
If `git checkout -b <new> origin/main` aborts with "untracked working tree files would be overwritten", **don't rm or mv the blocker.** It may be someone else's uncommitted notes. Commit through a worktree instead:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

If you already moved the blocker aside, that's only half the procedure. Switching back to the original branch deletes the file, since it's tracked on one branch and untracked on the other. Record `git status --short` before you start. When you get back, confirm the file exists (restore it from the backup or from `git show origin/main:<file>`), and confirm `git status --short` matches what you recorded.

## Shared Checkouts May Host Another Live Session
One working tree can be edited by several agent sessions at once.

- **`git checkout -- <file>` can delete another session's work.** One `M` in `git status` covers the whole file, not one author. Before restoring, run `git diff <file>` and confirm every hunk is yours. If any hunk isn't, leave the file alone and use a worktree.
- **Another session can commit your untracked files under its own message.** Anything uncommitted in a shared tree is fair game for someone else's `git add`. If you suspect a peer, do the whole edit in `git worktree add /tmp/wt-<repo> <trunk>` from the start.

**Detect concurrent sessions before your first edit:**
```bash
git branch --show-current     # unexpected branch?
git reflog -5                 # checkouts or commits you did not make?
git worktree list             # worktrees you did not create?
git status --short            # record this; your final state must differ only by your files
```

If the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force your duplicate commit. Reset to origin and commit only what's actually missing.

**A peer's unpushed commit:** never `git reset` it, because that destroys work that may exist nowhere else. If the peer session is still live, wait for it. If the commit is genuinely stranded (its author session is gone), push it to **the branch it was committed on** (`git push origin HEAD:<that-branch>`, never to main). Secret-scan the diff first, since you're publishing content you didn't review, and say in your final report that you did it.

## Mergeability and Conflicts

### `mergeable` reads `UNKNOWN` on the first poll
GitHub computes mergeability lazily, so the first `gh pr view N --json mergeable` on a PR that hasn't been checked recently returns `UNKNOWN`. The real value shows up about 6s later. **Anything that gates on mergeability must re-poll.** Otherwise a CONFLICTING PR stays invisible to automation for days.

When a repo seems behind:
1. Run `git status`. A clean tree means the cause is almost never uncommitted work.
2. Run `gh pr list --state open`, then check each PR's mergeability **twice**.
3. Do a non-destructive trial merge with `git merge-tree --write-tree --name-only <default> <branch>`.

**Don't use the legacy 3-argument `git merge-tree <base> <a> <b>`.** It can exit 0 with no conflict markers while a real merge conflicts. When it matters, do an actual trial merge in an isolated worktree:
```bash
git worktree add /tmp/x <branch> --detach && cd /tmp/x && git merge origin/main --no-commit --no-ff
```

### Resolving
- **Merge the default branch INTO the stale branch, never the reverse.** Otherwise you delete everything added to the default branch since the fork.
- **Append-only files must come out lossless.** This must print 0 against both parents:
  ```bash
  comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
  ```
- **Conflicts in append-only logs need chronological reinsertion.** The two sides are usually independent entries from different dates, and the incoming one may be older than entries main gained later. Read each block's date header, move it to where it belongs (which may be far outside the conflict markers), then grep the headers and confirm they're in monotonic order.
- **Merging same-file PRs one at a time doesn't drain a backlog.** Each merge moves main under the others. When N PRs edit the same hotspot file, merge them into one integration branch, resolve once, and land that.
- **Auto-resolve only what's provably safe.** A union resolver should refuse hunks where both sides share a line. Never union YAML frontmatter, because that produces duplicate keys.
- Duplicate commit subjects with different SHAs on the two sides mean sessions have been cherry-picking around a block. Those duplicates are usually what caused the conflict.

### A failing CI check isn't automatically a merge blocker
If `mergeStateStatus` is `UNSTABLE`, inspect the failing job with `gh run view --log-failed`. If the failure is in files the PR doesn't touch and reproduces identically on a fresh checkout of the base branch, the PR didn't cause it and it shouldn't veto an otherwise eligible merge.

### A PR whose head branch was deleted while open
A PR can sit at `mergeStateStatus: UNKNOWN` with green checks forever. `gh pr merge` fails with "Head branch is out of date", and update-branch fails with "head ref does not exist". Check with `git ls-remote origin refs/heads/<branch>`. If that's empty, recreate the branch from the PR's surviving head:
```bash
git ls-remote origin refs/pull/<n>/head                # get <head-sha>
git push origin <head-sha>:refs/heads/<branch-name>
gh api repos/<owner>/<repo>/pulls/<n>/update-branch -X PUT
gh pr merge <n> --squash --delete-branch
```

## Scanners and Hooks on Merges and Rebases
- A pre-commit hook that runs plain `git diff --cached` compares an in-progress merge commit against the **pre-merge HEAD**, so it re-flags all of main's already-approved content. The fix belongs in the hook: when `MERGE_HEAD` exists, diff against `$(git merge-base HEAD MERGE_HEAD)`.
- A pre-push hook that scans `$REMOTE_SHA..$LOCAL_SHA` after a rebase scans everything between the stale pre-rebase tip and the new tip, not just your commits. Re-scan the correct range yourself (`git diff origin/main..HEAD | grep '^+' | grep -v '^+++'` piped into your scanner) before you conclude new content is blocked.
- In both cases, **don't use `--no-verify`**. Isolate the real hits, or commit onto an existing branch and resolve through a path that runs a different check.
- Hooks installed into `.git/hooks` (or through `init.templateDir`) are **copies**. Editing the source changes nothing in existing clones. After a hook edit, reinstall it everywhere, then confirm by grepping the installed copies for a marker from the new code.

## Commit Identity
- **Never hardcode a personal email** with `-c user.email=...`. When email privacy is on, GitHub rejects the push (`GH007: Your push would publish a private email address`, or "push declined due to email privacy restrictions"). The rejection happens at **push** time, so a session that only checks the commit will report work that never landed.
- Commit as `<username>@users.noreply.github.com`. Check what a repo's history already uses with `git log -3 --format=%ae`.
- Recover a bad commit with `git -c user.email=<noreply> commit --amend --no-edit --reset-author`. The check covers the **committer** of every pushed commit, so replayed commits need fixing too, and pushing from a different machine won't help.
- If the global config itself has drifted, set `GIT_AUTHOR_EMAIL` and `GIT_COMMITTER_EMAIL` for the commit. Changing global config is the owner's call.
- General rule: verify the operation that actually publishes, not the local step before it.

## Discrimination Checks: Stash, Never Checkout
To prove a regression test catches the bug, you revert the fix and expect failures. `git checkout -- <dir>` **destroys** an uncommitted fix, with no reflog to recover from. Use stash instead:

```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
<run suite, record failures>
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```

Confirm every new assertion **fails** against the pre-fix code. A test that passes on both versions proves nothing.
