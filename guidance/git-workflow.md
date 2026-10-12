<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main`.
- Use the branch assigned to you. If none exists, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Avoid `test-` as a branch prefix.** Some repos have rulesets or branch protection that silently reject pushes to `test-*` branches. There is no error; the branch just never appears on the remote. Use descriptive names like `add-tests-<module>` or `<module>-tests-<run>` instead.
- Commit messages explain **why**, not just what. Large commits are fine; don't split work artificially.
- Before committing:
  1. `git status` to verify no unintended files are staged.
  2. `git diff` to review the actual changes.
  3. Confirm no `.env`, secrets, or key files are included.
  4. **Update `context.md`**. This is mandatory on the final commit of a branch (before creating a PR) or during session wrap-up. It is not required on every intermediate commit.
  5. **Update `progress.md`**: add an entry for the work being committed.
- Push: `git push -u origin HEAD`. Retry network failures up to 4x with backoff (2s, 4s, 8s, 16s). Do not retry auth failures.
- **Default branch is not always `main`.** Some repos use `master`. Resolve it rather than assuming: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.

## All Deliverables Go in Repos
When creating scripts, tools, project assets, analysis docs, reference files, or any other output, **always put them in a git repo** and push to the remote. Never leave files as loose filesystem artifacts; the user should not have to dig around the filesystem for deliverables. The remote is the source of truth. If a new project or tool set doesn't have a repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions routinely create useful files (summaries, configs, scripts, reference docs) and then forget to commit, forget to push, or save them outside a repo. The user cannot access local-only files between sessions. Treat every file write or edit as incomplete until the file is committed and pushed.

## Every Repo Gets a README and Description
Every repo must have a `README.md` and a GitHub repo description. When creating a new repo or working in one that's missing either, add them.

- **README.md**: what it does (1-2 sentences), how to set it up, and how to run/use it. Keep it concise; a developer should understand the project in 60 seconds.
- **GitHub description**: set via `gh repo edit <owner>/<repo> --description "one-line summary"`. A single sentence that appears on the repo page and in search results.

Both are required when running `gh repo create`. Use the `--description` flag on creation and add the README in the initial commit.

## Always Commit and Push Written Files
When creating or modifying files in any repo, **always commit and push in the same step**. Don't move on to other work with untracked or uncommitted files sitting in a repo. Writing a file does not commit it; you must do it explicitly.

When committing to any repo, **always push to the remote branch as well**. Unpushed commits are invisible to other sessions, collaborators, and deploy pipelines. Treat file creation + `git commit` + `git push` as a single atomic operation; if any step fails, diagnose and fix it before moving on.

**Verify the operation that actually publishes, not the local step before it.** Some failures (for example email-privacy rejections) only happen at push time, so a session that only checks the commit succeeded will report work that never landed.

**Common gap:** when working across multiple repos in one session, it's easy to push some and forget others. After a multi-repo task, run `git status` in each one and confirm all are clean and pushed.

## Staging Hygiene (any repo)

Any checkout can hold uncommitted work from a previous session or a concurrent agent, and a blanket add silently ships it under your commit message. This is not a "shared repo" rule; it applies to every repo. A one-off `git add -A` in an ordinary project repo can sweep a half-finished adapter, a scratch script, and a settings change into an unrelated commit.

The check is cheap and unconditional: **run `git status` BEFORE staging.** If the tree holds anything you didn't touch, name your paths explicitly.

- **Stage explicit paths, never `git add -A` / `git add .`**. Name the files you touched: `git add guidance/foo.md scripts/bar.sh`. A blanket add can bundle another agent's work, and can stage a secret.
- **Never `--no-verify` on a public repo.** A pre-commit sensitive-identifier scanner is the last line of defense before a username, internal path, or token reaches a public repo. If the scanner blocks you, sanitize the content; don't override it.
- **Before committing, confirm ONLY your files are staged.** If you see files you didn't touch, unstage them (`git restore --staged <path>`); they belong to someone else.
- **Review `git show --stat` before pushing.** It is the last cheap point to catch a swept-in file; if you find one, reset the commit and redo it with explicit paths.

## Creating PRs (with retry)

After `git push`, GitHub may take a few seconds to register the branch. Verify the branch exists remotely before creating the PR, and retry on failure:

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
  # Update the existing PR if needed, or merge it
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

**Never fall back to a "create manually" URL.** If `gh pr create` fails after 3 retries, diagnose the error (auth, branch not found, network) and fix it. Do not tell the user to create the PR manually.

- Do **not** enable auto-merge unless explicitly asked.

## GitHub API PR Creation: Qualify the Head Parameter

When creating PRs via the GitHub REST API (Octokit) rather than `gh pr create`, the `head` parameter must be fully qualified as `owner:branch`, not just `branch`.

```js
// WRONG: causes "invalid head" errors, especially on newly-pushed branches
await octokit.rest.pulls.create({ head: branch, ... });

// CORRECT: qualify with the repo owner
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

**Why:** GitHub needs a few seconds to fully index a newly-pushed branch. Unqualified branch names fail more often during this window; qualifying with the owner disambiguates the ref lookup.

**Also:** add a 3s delay before calling `pulls.create` after a push event, set `maxAttempts` to 5, and retry on "invalid head" errors. `gh pr create` handles head qualification internally; this only applies to direct REST API use (for example in automation bots).

## Working Alongside an Auto-Merge Bot

If your setup runs a bot that opens and squash-merges PRs for pushed branches, these rules apply.

- **Pushing a branch can be enough.** The bot may open and merge its own PR within seconds. After the push, the remote branch vanishing and `gh pr create` failing with "No commits between main and `<branch>`" or "Head sha can't be blank" is **success**, not failure. Find the bot's PR with `gh pr list --state all --head <branch>` and reuse that number. A "pull request already exists" error means the same thing. Confirm with `gh pr view <n> --json state,mergedAt`.
- **Do not retry the push.** A retry can produce a second merged PR for one logical change, which is misleading history even when the diffs are identical.
- **Verify by content, not ancestry.** A squash commit is NOT an ancestor of your local commit (`git merge-base --is-ancestor <mine> origin/main` returns false, and `git branch --merged` reports the branch as unmerged), but the content is there:
  ```bash
  git fetch origin && git log --oneline -3 origin/main
  git cat-file -e origin/main:<path> && echo "landed on main"
  git diff HEAD origin/main -- <paths> --stat   # empty == merged content is identical
  ```
  When checking added lines with grep, use `grep -Fqx -- "$line"`. Without the `--`, any line starting with `-` (a markdown bullet) is parsed as an option and silently reports false negatives.
- **Opt-out bots merge everything.** If the bot merges every non-draft PR from any pushed branch, pushing a branch you don't want merged is not safe by default. Immediate mitigation: convert the PR to draft right after pushing (`gh pr ready <n> --undo`), or use a per-commit suppression marker in the commit subject if your bot supports one (for example `[no-automerge]`). Durable fix: put product/design repos (ones with real human or WIP branches) on the bot's repo denylist **before their first push**, not after the first unwanted merge. Any repo where parallel agents will push WIP checkpoint branches needs this up front. If WIP did get merged, land the real content on `main` yourself afterward (`git checkout origin/<branch> -- <owned paths>`) rather than fighting the squash.
- **Follow-up fixes after an auto-merge go on a FRESH branch off main.** Pushing a second commit to an already-squash-merged branch conflicts every time (main holds one squashed commit; your branch still has the originals). Instead: `git checkout -b <new> origin/main`, then `git checkout <old-branch> -- <only the changed files>`, commit, push the new branch, close the stale PR. Verify a push landed with `git ls-remote --heads origin <branch>`, not the local `origin/<branch>` ref, which goes stale the moment the bot deletes the branch.
- **Automation that creates PRs must verify they merged.** Logging "PR: <link>" is not closure. As the last step of the session, re-check `gh pr view <n> --json state,mergeable` and merge it then if mergeable and CI is green, rather than relying on some later sweep as a backstop.

## Branch Hygiene

Open PRs that sit unmerged cause cascading merge conflicts across all other branches. **This is the #1 cause of stuck work.**

- **Merge PRs promptly.** When a PR is ready and has no review requirements, merge it in the same session: `gh pr merge <number> --merge --delete-branch`. If the merge fails (conflict, checks pending), retry once after 5s. If it still fails, report the specific error.
- **Rebase before opening a PR.** Run `git fetch origin && git rebase origin/main` and resolve conflicts before pushing. A PR should be mergeable when created.
- **One branch per task.** Don't create multiple branches for the same feature or leave abandoned branches behind.
- **Clean up stale branches.** At session start, check `gh pr list --state open` and `git branch -a`. If a branch has been open more than a few days without activity, rebase and merge it or close it.
- **Prune remote-tracking refs before scanning.** Before enumerating with `git branch -a` or `git branch -r`, run `git remote prune origin`. Unpruned refs for already-deleted branches inflate "open branch" counts.
- **Automation cap/dedup gates MUST use `git ls-remote`, not `git branch -r`.** `git branch -r` reads local tracking refs that are only refreshed on fetch, and is racy even with pruning. For any automation that needs to know which branches currently exist on the remote: `git ls-remote --heads origin 'claude/auto-*'`. Stale tracking refs otherwise trigger "backlog" logic on zero real branches.
- **In a forked checkout, always pass `--repo`.** In a repo with both `origin` (your fork) and `upstream` (the canonical project), bare `gh pr view <n>` may resolve against `upstream`. A PR number that exists upstream will look valid even though you don't control it, and branch-name patterns alone can make someone else's PR look automation-owned. Before any view, merge, close, or comment: `gh pr view <n> --repo <owner>/<name>`. The danger is acting on a repo outside your control at all.
- **Don't leave PRs for someone else to merge** unless the task explicitly requires review. Unmerged PRs are invisible debt.
- **Never modify `context.md` or `progress.md` on a branch that other branches also modify** until the very last commit before merging, after rebasing on main. These files conflict constantly.
- **If a merge fails with complex code conflicts on a stale branch:** close the PR, delete the branch, and redo the work on a fresh branch from main. (Exception: if the branch holds real hand-written code, isolate and resolve the conflict instead of discarding the work. Closing is right for generated content like dependency-bot lockfile PRs, which get recreated.)
- **MERGEABLE does not mean non-redundant.** A feature PR can show MERGEABLE yet have its whole patch already on `main` (for example, another PR branched off it and carried the code in). Before merging, run `git rebase origin/main` in a throwaway checkout: if the commit is dropped ("patch contents already upstream") or `git diff origin/main <tip>` is empty, close it as superseded (`gh pr close <N> --delete-branch --comment "Superseded by ..."`).
- **Read a merged PR's scope notes before rejecting work as duplicate.** An explicit "out of scope / follow-up" note in a merged PR makes the candidate sanctioned follow-up work, and the merged PR often ships helpers the follow-up should reuse. Cite the note in the new PR body.
- **UNSTABLE with a failing check is not automatically a blocker.** Check which files the failing job covers against the PR's file list. If the failure reproduces identically on the base branch with no PR changes applied, it is pre-existing and should not veto an otherwise eligible merge.

## Staging Changes in Hook-Executing Repos: Use Worktrees, Not Branch Checkouts

**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is read by live hooks, session-start scripts, or a process manager config.** The harness executes from that working copy. Switching its branch silently reverts all guidance, hooks, and config to whatever the target branch holds (new rules vanish, removed rules reappear, hooks change behavior) for every concurrent session. There is no error or warning.

Use a worktree instead:

```bash
git -C <repo> worktree add /tmp/wt-<repo> -b claude/<task>
# ... edit, commit, push, open PR from inside /tmp/wt-<repo> ...
git -C <repo> worktree remove /tmp/wt-<repo>
# Main checkout stays on main throughout; hooks keep running from live state
```

**A worktree pushing directly to the default branch** (for example an append-only log) must stay detached; never `checkout -B <default-branch>` inside it, since that collides with the primary checkout's branch.

### Merge a worktree branch from the primary checkout

- `git checkout main` INSIDE a worktree fails with "'main' is already used by worktree" because the primary checkout holds it. And running `git worktree remove` while your cwd is inside that worktree leaves the shell with no working directory.
- Sequence: commit in the worktree, `COMMIT=$(git rev-parse HEAD)`, `cd` to the primary checkout, `git merge --ff-only $COMMIT`, push, then `git worktree remove` from the primary checkout.

**Gate teardown on the commit existing, not on the next line running.** A hook can block `git commit` and leave work staged but uncommitted. If merge/push/`git worktree remove --force` follows on the same line or after `;`, it still runs: `git merge --ff-only` of a branch with no new commit is a no-op that exits 0, and `--force` deletes the worktree holding the only copy. Make teardown conditional:

```bash
[ "$(git rev-parse <branch>)" != "$(git rev-parse <base>)" ] && \
  git merge --ff-only <branch> && git push && git worktree remove <path>
```

If it already happened: staged files survive as dangling blobs. `git fsck --unreachable | grep blob`, then `git cat-file -p <sha>`.

### Rescuing an existing branch in a worktree: sync the local ref first

`git worktree add <path> <existing-branch>` (bare name) checks out the **local** ref, which may be weeks behind `origin/<branch>` if every previous run worked in worktrees and pushed straight to origin. Merging main into the stale ref shows phantom conflicts that were already resolved upstream, and the result gets rejected as non-fast-forward after you've done the work. Before creating the worktree:

```bash
git rev-parse <branch> origin/<branch>          # compare
git branch -f <branch> origin/<branch>          # fast-forward if they differ
```

(`branch -f` is safe here because the main checkout never has that branch checked out.)

### Run-numbered branch names can collide

A branch name reused from an earlier, already-squash-merged branch can collide or overwrite the stale PR ref. `git merge-base --is-ancestor` returns false for squash-merged branches, so it can't distinguish "merged" from "diverged". Before creating a numbered branch, check both:

```bash
git branch -a | grep <name>
gh pr list --repo <owner>/<repo> --head <name> --state all
```

If either hits, append a suffix (`<name>-2`) rather than investigating or deleting refs.

## Remote Checkouts May Hold Commits That Exist Nowhere Else

Before `git pull`/`git reset` in a checkout you don't own (a server, a container, another machine), check whether it is **ahead** of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

Non-zero means `git reset --hard origin/<branch>` may destroy work permanently. A conflicting `git pull` is a signal to investigate, not a nuisance to force past.

When you find divergence:

1. **Back it up before touching anything.** `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup` and copy the bundle off the machine. A branch on a single host is not a backup.

2. **Establish whether those commits contain unique content. Do NOT trust commit subjects.**

   ```bash
   git diff --stat origin/main..<backup-branch>     # net direction of the delta
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"  # its unique source lines
   ```

   Then verify each feature the subjects claim **in the upstream tree**: `git grep -n "<feature>" origin/main -- src/`. A checkout can be "N commits ahead" and still be strictly poorer: early work that upstream later reimplemented via squashed or re-authored PRs, so the SHAs never match. A large net-negative diff with zero files unique to the remote side is the tell.

3. **Then choose, on evidence:**
   - *Superseded fork* (no unique content): `git reset --hard origin/<branch>`. Safe when runtime state is gitignored; check what the code writes (`output/`, `*.log`, caches) and confirm any tracked data file is read-only config, not state.
   - *Genuinely unique content*: port it onto a branch off `origin/main`, commit under a valid author identity, push, and only then reset the remote checkout.
   - *Need one fix now, reconcile later*: `git fetch origin main && git cherry-pick <sha>`. Conflicts are usually files that didn't exist on the older HEAD; `git add` the incoming version and `--continue`. This is interim, not an outcome.

   Run that repo's tests **on that host** afterwards. A jump in test count is a good sign you recovered real work.
4. **Record the outcome in that checkout's own `context.md`** and commit it there. Docs committed upstream are invisible to a checkout that is far behind; the note has to live where the next session will read it.
5. **Surface the divergence as an open item.** Reconciling it is the owner's call.

Restore from a bundle:
```bash
git fetch /path/to/x.bundle <name>-backup:<name>-backup
```

### Untracked file shadowing a tracked path: use a worktree, never rm

An untracked file at a path that IS tracked on origin/main makes `git checkout -b <new> origin/main` abort with "untracked working tree files would be overwritten". Do NOT rm or mv the blocker; it may be someone else's uncommitted notes. Commit through a worktree instead:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

**If you moved the blocker aside anyway:** the file is tracked on the branch you moved to and untracked on the one you came from, so `git checkout <original-branch>` DELETES it. Required closing steps:
1. Record `git status --short` BEFORE you start.
2. After returning to the original branch, check the file exists.
3. If gone: restore the backup if it differed, else `git show origin/main:<file> > <file>`.
4. Re-run `git status --short` and confirm it matches step 1 exactly.

Leaving the working tree different from how you found it is a side effect the user never asked for.

## The Shared Checkout May Host Another Live Agent Session

A single working tree can be edited by several sessions at once. Two failures follow from assuming sole ownership:

**1. `git checkout -- <file>` can delete another session's uncommitted work.** An `M` in `git status` is one flag for the whole file, not a claim of single authorship; the file may hold your one-line change and another session's 50-line redesign.

> **Before `git checkout --` on any file in a shared tree, run `git diff <file>` and confirm every hunk is yours.** If a hunk isn't yours, leave the file alone and work in a worktree.

**2. Another session can commit your uncommitted files under its own message.** Anything untracked or uncommitted in a shared tree is fair game for another process running `git add`. Your later push then gets rejected as non-fast-forward against a commit containing your own work.

> **When another session may share the checkout, do the whole edit in `git worktree add /tmp/wt-<repo> <trunk>` from the start.** Never leave new files untracked in the shared tree.

**Detect a concurrent session BEFORE the first edit:**
```bash
git branch --show-current     # an unexpected branch
git reflog -5                 # checkouts or commits you did not make
git worktree list             # worktrees you did not create
git status --short            # record this; your final state must differ only by your files
```
If any show another session, branch a worktree off trunk immediately. Reconciling afterward: if the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force your duplicate commit; reset to origin and commit only what's genuinely missing.

### A peer's unpushed commit

If a stop/push gate blocks on unpushed commits, check authorship first: `git log --format='%h %an %ad %s' @{u}..HEAD`. **If the authoring session is still live, wait;** it may still amend. Only for a genuinely stranded commit (the authoring session is gone and the work exists nowhere else):

1. Identify the author and branch (`git branch --show-current`). Confirm it isn't yours.
2. Secret-scan the diff you're about to publish. You didn't write or review it; a private repo doesn't exempt it.
3. Push to the branch it was committed on: `git push origin HEAD:<that-branch>`. Never redirect a peer's commit to `main`.
4. Say so in your final message.

Never `git reset` a peer's commit to clear a gate; that destroys work that exists nowhere else. Similarly, never acknowledge or suppress a gate on a dirty file unless you've proven (via `git diff <file>`) that none of its hunks are yours and your own content is already on the remote.

## Merge Conflicts and Stuck PRs

**`gh pr view N --json mergeable` returns `UNKNOWN` on the first poll.** GitHub computes mergeability lazily; only a follow-up read (~6s later) returns the real `MERGEABLE`/`CONFLICTING`. A checker that reads the first response sees nothing actionable and moves on, which is how conflicting PRs sit blocked for days with zero alerts. **Anything gating on mergeability must re-poll.**

Diagnosis order when a repo "seems behind on commits":
1. `git status`: a clean tree means this is almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge.

**Do not use the legacy 3-arg `git merge-tree <base> <a> <b>`.** It can exit 0 with no conflict markers on a merge that really conflicts. If in doubt, do a real trial merge in an isolated worktree: `git worktree add /tmp/x <branch> --detach && cd /tmp/x && git merge origin/main --no-commit --no-ff`.

**Merge the default branch INTO the stale branch, never the reverse.** A branch N commits behind, pushed onto the default branch, deletes everything added there since it forked. Verify losslessness per file before committing a resolution; for append-only files this must print 0 against both parents:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

Duplicate commit subjects with different SHAs on both sides are the tell that sessions have been cherry-picking around the block; those duplicates usually created the conflict.

**Merging same-file PRs one at a time does not drain a backlog.** Each merge moves the default branch under siblings touching the same file, so previously mergeable PRs become conflicting. When N PRs edit the same hotspot file, merge them into a single integration branch, resolve once, and land that.

**Auto-resolve only what is provably safe.** A union resolver should refuse any hunk where both sides share a line rather than deduplicating by guess, and never union a YAML frontmatter hunk (it produces duplicate keys).

**Append-only logs need chronological reinsertion, not append-at-conflict-site.** Conflicting blocks in a dated run log are usually independent entries. The incoming branch's entries are often OLDER than what main gained since it diverged, and the correct spot may be well outside the conflict markers (for example right before a later entry that references it). Read each block's date header, move it where it belongs, then confirm the file's date headers are monotonic.

**A PR whose head branch was deleted while still OPEN gets stuck at `mergeStateStatus: UNKNOWN` forever.** Green checks plus OPEN state is not evidence it's just waiting. Check `git ls-remote origin refs/heads/<branch>`; if empty, the head commit survives at `refs/pull/<n>/head`:
```bash
git push origin <head-sha>:refs/heads/<branch-name>   # sha via git ls-remote origin refs/pull/<n>/head
gh api repos/<owner>/<repo>/pulls/<n>/update-branch -X PUT
gh pr merge <n> --squash --delete-branch
```

## Commit-Scanning Hooks and Merges/Rebases

- **A pre-commit hook using bare `git diff --cached` diffs a merge commit against the pre-merge HEAD**, not the merge-base. On a long-stale branch it re-flags all of main's already-approved content as newly introduced. Fix in the hook: when `MERGE_HEAD` exists, diff against `$(git merge-base HEAD MERGE_HEAD)`. Until fixed, avoid the merge (commit new content onto a fresh branch from main) rather than bypassing the hook.
- **A pre-push hook scanning `$REMOTE_SHA..$LOCAL_SHA` breaks after a rebase.** The remote SHA is the stale pre-rebase tip, no longer an ancestor of HEAD, so the range spans all of main's landed commits. Re-scan the correct range yourself (`git diff origin/main..HEAD | grep '^+' | grep -v '^+++'` through your scanner) to see whether anything new is actually flagged.
- In both cases: **do not `--no-verify`.** If hooks are installed into many repos via `init.templateDir`, bypassing one silently removes the last leak check. Leave it unpushed and fix the range instead.

## Commit Identity

- **Never pass an explicit personal email** (`-c user.email=...`). With GitHub email privacy on, the push fails with `GH007: Your push would publish a private email address`. The check applies to the **committer** email of every pushed commit, not just the author, so pushing from elsewhere doesn't help.
- Use the repo's configured identity, or `<username>@users.noreply.github.com`. Check `git log -3 --format=%ae` in an unfamiliar repo to see which identity its history uses.
- Recover an already-made commit: `git -c user.email=<username>@users.noreply.github.com commit --amend --no-edit --reset-author`, then re-push.

## Discrimination Checks: `git stash push`, never `git checkout`

To prove a regression test discriminates, you revert the fix, re-run the suite, and expect failures. Reverting with `git checkout -- <dir>` DESTROYS an uncommitted fix with no reflog to recover it. Use `git stash push -- <dir>` instead; `git stash pop` restores it exactly. For a partially committed branch:

```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
<run suite, record failures>
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```

Also confirm every new assertion actually FAILS against the pre-fix code; a test that passes on both versions proves nothing.
