<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main`.
- Use the branch assigned to you. If none exists, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Avoid `test-` as a branch prefix.** Some repos have rulesets or branch protection that silently reject pushes to `test-*` branches. There is no error; the branch just never appears on the remote. Use names like `add-tests-<module>` or `<module>-tests-<run>` instead.
- Commit messages explain **why**, not just what. Large commits are fine; don't split work artificially.
- Before committing:
  1. `git status` to verify no unintended files are staged.
  2. `git diff` to review the actual changes.
  3. Confirm no `.env`, secrets, or key files are included.
  4. **Update `context.md`** (current state, open items, what the next agent needs to know). This is mandatory on the final commit of a branch (before creating a PR) or at session wrap-up. It is not required on every intermediate commit.
  5. **Update `progress.md`**: add an entry for the work being committed.
- Push: `git push -u origin HEAD`. Retry network failures up to 4x with backoff (2s, 4s, 8s, 16s). Do not retry auth failures.

## All Deliverables Go in Repos
When creating scripts, tools, project assets, analysis docs, reference files, or any other output, **always put them in a git repo** (for example under `$HOME/repos/`) and push to the remote. Never leave files as loose filesystem artifacts. The remote is the source of truth. If a new project or tool set doesn't have a repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions routinely create useful files and then forget to commit, forget to push, or save them outside a repo. Local-only files are inaccessible between sessions. Treat every file write as incomplete until it is committed and pushed.

## Every Repo Gets a README and Description
Every repo must have a `README.md` and a GitHub repo description. When creating a new repo or working in one that's missing either, add them.

- **README.md**: what it does (1-2 sentences), how to set it up, and how to run or use it. A developer should understand the project in 60 seconds.
- **GitHub description**: set via `gh repo edit <owner>/<repo> --description "one-line summary"`.

Both are required when running `gh repo create`. Use the `--description` flag on creation and add the README in the initial commit.

## Always Commit and Push Written Files
When creating or modifying files in any repo, **commit and push in the same step**. Don't move on with untracked or uncommitted files sitting in a repo. Writing a file does not commit it.

Never leave commits unpushed. Unpushed commits are invisible to other sessions, collaborators, and the deploy pipeline. Treat file creation + `git commit` + `git push` as one atomic operation; if any step fails, diagnose and fix it before moving on.

**Common gap:** when working across several repos in one session, it's easy to push some and forget others. After a multi-repo task, run `git status` in each one.

## Staging Hygiene (any repo with in-flight work)

Any checkout can hold uncommitted work from a previous or concurrent session, and a blanket add silently ships it under your commit message. This is not limited to "shared" repos; it applies everywhere.

The check is cheap and unconditional: **run `git status` BEFORE staging.** If the tree holds anything you didn't touch, name your paths explicitly.

- **Stage explicit paths; never `git add -A` or `git add .`** A blanket add sweeps whatever another agent left uncommitted into *your* commit, including secrets. Name the files you touched: `git add guidance/foo.md scripts/bar.sh`.
- **Never `--no-verify` on a public repo.** A pre-commit sensitive-identifier scanner is the last line of defense before a username, internal path, or token reaches a public repo. If the scanner blocks you, sanitize the content; don't override.
- **Before committing, confirm ONLY your files are staged.** If you see files you didn't touch, unstage them (`git restore --staged <path>`). They belong to someone else.
- Review `git show --stat` before pushing. If something foreign slipped in, reset the commit and re-make it with explicit paths.

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

When creating PRs via the REST API (Octokit) rather than `gh pr create`, the `head` parameter must be fully qualified as `owner:branch`.

```js
// WRONG: causes "invalid head" errors, especially on newly-pushed branches
await octokit.rest.pulls.create({ head: branch, ... });

// CORRECT: qualify with the repo owner
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

**Why:** GitHub needs a few seconds to index a newly-pushed branch, and unqualified names fail more often in that window. Also add a ~3s delay before calling `pulls.create` after a push event, use up to 5 attempts, and retry on "invalid head". `gh pr create` handles qualification internally; this only applies to direct API use (e.g., in bots).

## If You Run an Auto-Merge Bot

If your setup has a bot that opens and squash-merges PRs from pushed branches, these rules apply:

- **Racing it is normal.** After a push, the remote branch vanishing and `gh pr create` failing with "No commits between main and `<branch>`" or "Head sha can't be blank" means the bot already merged. Treat it as **success**. Find its PR with `gh pr list --state all --head <branch>`; do not re-push or open a duplicate (a retry can produce a second merged PR for one logical change).
- **Verify by content, not ancestry.** A squash commit is NOT an ancestor of your local commit (`git merge-base --is-ancestor` returns false, and `git branch --merged` reports the branch unmerged). Use `git diff origin/main <mine> -- <file>`, or confirm every added line is present in `git show origin/<default>:<file>`. When grepping lines, use `grep -Fqx -- "$line"`; without `--`, a line starting with `-` (a markdown bullet) is parsed as an option and yields false negatives.
- **Default branch is not always `main`.** Resolve it: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
- **Opt-out bots merge everything.** If the bot merges every non-draft PR from any pushed branch, pushing a branch you don't want merged is not safe by default:
  - Add product/design repos (those with real human or design branches) to the bot's repo denylist **before** their first push, not after the first incident. The same applies to any repo that will run parallel agents pushing WIP branches.
  - A per-commit opt-out marker in the commit subject (e.g. `[no-automerge]`) is the fast mitigation if your bot supports one.
  - `gh pr create --draft` right after `git push` is NOT reliable: the bot can open and merge a non-draft PR within seconds, before your call runs. Converting to draft only works on a PR that exists before the bot sees the push.
  - For a CI-only check of unfinished work, don't push the branch at all. Run tests locally or trigger CI via `workflow_dispatch`. If it merges anyway and the squash matches your work, `git rebase --onto origin/main <first-pushed-sha>` and continue.
  - If WIP already got squash-merged, land the real content on `main` yourself afterward (`git checkout origin/<branch> -- <owned paths>`) rather than fighting the squash.
- **Branch-pattern rules must not bypass verification.** If a branch prefix (e.g. `fix-*`) is meant to go through a verification gate before merging, make sure the bot doesn't blind-merge that prefix on push first.
- **Shared checkouts can switch branches mid-operation.** For a clean single-file commit in a checkout other jobs also use, build the commit via a temp index (`GIT_INDEX_FILE=<tmp> git read-tree` + `git commit-tree`) and push with an explicit refspec (`git push origin <sha>:refs/heads/<branch>`) rather than trusting the ambient staging area or HEAD.

## Branch Hygiene

Open PRs that sit unmerged cause cascading merge conflicts across all other branches. **This is the #1 cause of stuck work.**

- **Merge PRs promptly.** When a PR is ready and has no review requirement, merge it in the same session: `gh pr merge <number> --merge --delete-branch`. If the merge fails, retry once after 5s; if it still fails, report the specific error.
- **Rebase before opening a PR.** `git fetch origin && git rebase origin/main`, resolve conflicts, then push. A PR should be mergeable when created.
- **One branch per task.** No duplicate or abandoned branches.
- **Clean up stale branches.** At session start, check `gh pr list --state open` and `git branch -a`. If a branch has been idle for more than a few days, rebase and merge it, or close it.
- **Prune before scanning.** Run `git remote prune origin` before enumerating with `git branch -a` / `-r`. Otherwise refs for branches already deleted on the remote inflate "open branch" counts.
- **Automation cap/dedup gates MUST use `git ls-remote`, not `git branch -r`.** Remote-tracking refs are only refreshed on fetch and are racy even with pruning. For cap checks and backlog gates, query the remote: `git ls-remote --heads origin 'claude/auto-*'`.
- **In a forked checkout, `gh` may silently resolve against `upstream` instead of `origin`.** A PR number that exists upstream will look valid even though you don't own it. **Always pass `--repo <owner>/<name>`** when viewing, merging, closing, or commenting on a PR in a checkout that might be a fork. The danger is not a bad merge decision; it's acting on a repo outside your control.
  - **Fix the generator, not just the consumer.** If a bare `gh` call runs inside a loop or inventory builder, make it pass `--repo` (derived from `git remote get-url origin`) so phantom upstream entries never enter the inventory. Don't leave a recurring manual skip as the permanent mitigation.
- **Don't leave PRs for someone else to merge** unless the task explicitly requires review.
- **Avoid modifying `context.md` / `progress.md` on branches that other branches also modify.** These conflict constantly. Update them as the very last commit before merging, after rebasing on main.
- **If a merge fails with complex code conflicts on a stale branch:** close the PR, delete the branch, and redo the work on a fresh branch from main.
- **Follow-up fixes after a squash merge go on a FRESH branch off main.** Pushing a second commit to an already-squash-merged branch conflicts every time (main holds one squashed commit, your branch holds the originals), and the branch may no longer exist server-side. Instead: `git checkout -b <new> origin/main`, `git checkout <old-branch> -- <only the changed files>`, commit, push, close the stale PR. Verify a push landed with `git ls-remote --heads origin <branch>`, not the local `origin/<branch>` ref.
- **MERGEABLE does not mean non-redundant.** A feature PR can show MERGEABLE while its entire patch is already on main (another PR that branched off it carried the code in). Before merging a "ready" PR, `git rebase origin/main` in a throwaway checkout: if the commit is dropped as "patch contents already upstream", or `git diff origin/main <tip>` is empty, close it as superseded: `gh pr close <N> --delete-branch --comment "Superseded by ..."`.
- **Automation that opens PRs must verify they merged.** As the last step of the session that created a PR, run `gh pr view <n> --json state,mergeable` and merge it right then if MERGEABLE with green CI. Don't rely on a later sweep as the merge backstop; ready PRs otherwise sit for days.
- **A merged PR's scope notes are sanctioned follow-up, not dedup blockers.** When candidate work looks like a duplicate of a recently merged PR, read its body. An explicit "out of scope / follow-up" note makes the candidate pre-vetted follow-up work, and the merged PR often ships helpers the follow-up should reuse. Cite the scope note in the new PR body.

## Staging Changes in Hook-Executing Repos: Use Worktrees, Not Branch Checkouts

**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is read by live hooks, SessionStart scripts, or a process manager config.** The harness executes from those paths. Switching branches silently reverts all guidance, hooks, and config to whatever the target branch holds, for every concurrent session, with no error or warning.

Use a worktree instead:

```bash
git -C $HOME/repos/<repo> worktree add /tmp/wt-<repo> -b claude/<task>
# ... edit, commit, push, open PR from inside /tmp/wt-<repo> ...
git -C $HOME/repos/<repo> worktree remove /tmp/wt-<repo>
# Main checkout stays on main; hooks keep running from live state
```

**A worktree pushing directly to the default branch** (e.g. an append-only log) must stay detached. Never `checkout -B <default-branch>` inside it; that collides with the primary checkout's branch.

## Remote Checkouts May Hold Commits That Exist Nowhere Else

Before `git pull` or `git reset` in a checkout you don't own (a server, a container, another machine), check whether it is **ahead** of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

Non-zero means `git reset --hard origin/<branch>` may destroy work permanently. A conflicting `git pull` is a signal to investigate, not a nuisance to force past.

When you find divergence:

1. **Back it up first.** `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup` and copy the bundle off the machine. A branch on a single host is not a backup.

2. **Establish whether those commits contain unique content. Do NOT trust commit subjects.**

   ```bash
   git diff --stat origin/main..<backup-branch>     # net direction of the delta
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"  # its unique source lines
   ```

   Then verify each claimed feature **in the upstream tree**: `git grep -n "<feature>" origin/main -- src/`. A branch can be several commits "ahead" and still be strictly poorer: early work that upstream later reimplemented via squashed or re-authored PRs, so the SHAs never match. A large net deletion with zero files unique to the remote side is the tell.

3. **Then choose, on evidence:**
   - *Superseded fork* (no unique content): `git reset --hard origin/<branch>`. Safe when runtime state is gitignored; check what the code actually writes (`output/`, `*.log`, caches) and confirm any tracked data file is read-only config, not state.
   - *Genuinely unique content*: port it onto a branch off `origin/main`, commit under a valid author identity, push, and only then reset the remote checkout. If the push is rejected for email privacy, see the identity section below; the rejection follows the commits, not the pusher.
   - *Need one fix now, reconcile later*: cherry-pick onto that checkout's HEAD (`git fetch origin main && git cherry-pick <sha>`). Conflicts are usually files that didn't exist on the older HEAD; `git add` the incoming version and `--continue`. This is interim, not an outcome.

   Verify by running that repo's tests **on that host** afterwards. A big jump in test count is a good sign you recovered real work.
4. **Record the outcome in that checkout's own `context.md`** and commit it there. Docs committed upstream are invisible to a checkout that is far behind.
5. **Surface the divergence as an open item.** Reconciling it is the owner's call.

Restore from a bundle with:
```bash
git fetch /path/to/x.bundle <name>-backup:<name>-backup
```

## Untracked File Shadowing a Tracked Path: Use a Worktree, Never rm

An untracked file can sit at a path that IS tracked on `origin/main`. `git checkout -b <new> origin/main` then aborts with "untracked working tree files would be overwritten by checkout".

Do NOT `rm` or `mv` the blocker to unblock yourself. If you didn't create it, it may be someone else's only copy of uncommitted notes. Commit through a worktree, which never touches the dirty tree:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

If `gh pr create` reports "a pull request already exists" or "No commits between main and `<branch>`", an auto-merge bot may have opened and merged it already. Confirm:

```bash
gh pr view <n> --json state,mergedAt
git fetch origin && git log --oneline -3 origin/main
git cat-file -e origin/main:<path> && echo "landed on main"
git diff HEAD origin/main -- <paths> --stat   # empty == merged content is identical
```

**If you moved the blocker aside anyway, the `mv` is only half the procedure.** The file is tracked on the branch you moved TO and untracked on the branch you came FROM, so `git checkout <original-branch>` deletes it. Required closing steps:
1. Record `git status --short` BEFORE you start.
2. After returning to the original branch, re-check the file exists.
3. If gone: restore the backup if it differed, else `git show origin/main:<file> > <file>`.
4. Re-run `git status --short` and confirm it matches step 1 exactly.

Leaving the working tree different from how you found it is a silent side effect nobody asked for.

## The Shared Checkout May Host Another Live Session

A single working tree can be edited by several agent sessions at once. Two failure modes:

**1. `git checkout --` deletes another session's uncommitted WIP.** `git status` shows one `M` flag per file, not a claim of single authorship. A file you touched with a one-line change may also hold dozens of lines of another session's uncommitted work; restoring it deletes theirs.

> **Before `git checkout --` on any file in a shared tree, run `git diff <file>` and confirm every hunk is yours.** If a hunk is not yours, leave the file alone and work in a worktree.

**2. Another session commits YOUR uncommitted files under its own message.** Anything uncommitted in a shared tree is fair game for another process running `git add`. Your later push is then rejected as non-fast-forward against a commit that is byte-identical to your work.

> **When another session may share the checkout, do the whole edit in `git worktree add /tmp/wt-<repo> <trunk>` from the start.** Never leave new files untracked in the shared tree.

**Detect a concurrent session BEFORE the first edit:**
```bash
git branch --show-current     # an unexpected branch
git reflog -5                 # checkouts or commits you did not make
git worktree list             # worktrees you did not create
git status --short            # record this; your final state must differ only by your files
```
If any of these show another session, branch a worktree off trunk immediately. Reconciling afterwards: if the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force your duplicate commit; reset to origin and commit only what is genuinely missing.

### A peer's unpushed commit

If an "unpushed work" gate fires on a commit you did not author:
- **When the peer session is still live, wait.** They may be mid-turn and may still amend.
- **When the commit is genuinely stranded** (authoring session gone, work exists nowhere else), push it rather than waiting or resetting:
  1. Identify author and branch: `git log --format='%h %an %ad %s' @{u}..HEAD` and `git branch --show-current`.
  2. Secret-scan the diff. You are publishing content you didn't write or review; a private repo doesn't exempt it.
  3. Push to the branch it was committed on: `git push origin HEAD:<that-branch>`. Never redirect a peer's commit to `main`.
  4. Say so in your final message.
- Never `git reset` a peer's commit to clear a gate; that destroys work that exists nowhere else.
- Never acknowledge or suppress a gate for work you simply forgot to push. Prove it isn't yours first (`git diff <file>` shows zero hunks of yours, and your own content is already on the remote).

## A PR Stuck CONFLICTING Is Invisible to Automation

**`gh pr view N --json mergeable` often returns `UNKNOWN` on the first poll.** GitHub computes mergeability lazily; only a follow-up read (~6s later) returns `MERGEABLE`/`CONFLICTING`. A checker that reads only the first response sees nothing actionable, and PRs can sit blocked for days with no alert. **Anything gating on mergeability must re-poll.**

Diagnosis order when a repo "seems behind on commits":
1. `git status`: a clean tree means this is almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge.

**Do not use the legacy 3-arg `git merge-tree <base> <a> <b>`.** It can exit 0 with no conflict markers where a real merge conflicts. When in doubt, do a real trial merge in an isolated worktree: `git worktree add /tmp/x <branch> --detach && cd /tmp/x && git merge origin/main --no-commit --no-ff`.

**Merge the default branch INTO the stale branch, never the reverse.** A branch N commits behind, pushed onto the default branch, deletes everything added there since it forked. For append-only files, verify losslessness against both parents; this must print 0:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

Duplicate commit subjects with different SHAs on the two sides mean sessions have been cherry-picking around the block; those duplicates usually created the conflict.

**Merging same-file PRs one at a time does not drain a backlog.** Each merge moves the default branch under its siblings and breaks previously mergeable PRs. When N PRs edit the same hotspot file, merge them into one integration branch, resolve once, and land that.

**Auto-resolve only what is provably safe.** A union resolver should refuse any hunk where both sides share a line rather than dedupe by guess, and must never union a YAML frontmatter hunk (it produces duplicate keys).

**For a conflicting automated PR with hand-written code, resolve rather than close.** Resolve, re-run typecheck/tests/build, push to the PR branch, let CI re-run, then merge. Closing and letting the generator recreate is right only for machine-generated PRs with nothing hand-written to lose (e.g. dependency lockfile bumps).

### Rebasing an append-only log: reinsert chronologically

When the only conflict is inside an append-only narrative log, the two blocks are usually independent entries from different times. Appending the incoming block at the conflict site often puts it out of order, because a long-open branch's entries can be older than entries main gained since. Read each block's own date or run header, find where it belongs chronologically (possibly well outside the conflict region, e.g. just before the first later entry that references it), and move it there. Verify the file's date headers are monotonic afterwards.

### UNSTABLE status from a failing check is not automatically a blocker

When `mergeStateStatus` is UNSTABLE, run `gh run view --log-failed` and compare the failing files against the PR's file list. If the failure reproduces identically on a fresh checkout of the base branch, it is pre-existing and should not veto an otherwise eligible merge. Your other merge criteria (verification passed, MERGEABLE, no sensitive paths) still govern.

### A PR whose head branch was deleted while OPEN stays UNKNOWN forever

Symptoms: open PR with green checks and `mergeStateStatus: UNKNOWN` for hours; `gh pr merge` fails "Head branch is out of date"; update-branch fails "head ref does not exist". Check `git ls-remote origin refs/heads/<branch>`; if empty, the branch is gone and no "up to date with base" rule can ever pass. The head commit survives at `refs/pull/<n>/head`:

```bash
git ls-remote origin refs/pull/<n>/head               # get <head-sha>
git push origin <head-sha>:refs/heads/<branch-name>
gh api repos/<owner>/<repo>/pulls/<n>/update-branch -X PUT
gh pr merge <n> --squash --delete-branch
```

## Landing a Worktree Branch Safely

**Merge from the primary checkout.** `git checkout main` inside a worktree fails ("already used by worktree") because the primary holds it, and running `git worktree remove` from inside the worktree leaves your shell with no working directory. Sequence: commit in the worktree, `COMMIT=$(git rev-parse HEAD)`, `cd` to the primary checkout, `git merge --ff-only $COMMIT`, push, then `git worktree remove` from the primary.

**Gate teardown on the commit existing, not on the next line running.** A hook can block `git commit` and leave work staged but uncommitted. If merge/push/`git worktree remove --force` follows on the same line, it still runs: `git merge --ff-only` of a branch with no new commit is a no-op that exits 0, and `--force` deletes the worktree holding the only copy. Make teardown conditional:

```bash
[ "$(git rev-parse <branch>)" != "$(git rev-parse <base>)" ] && git merge --ff-only <branch> && git push && git worktree remove ...
```

or run it as a separate call after reading the commit output. Recovery if it already happened: staged files survive as dangling blobs; `git fsck --unreachable | grep blob`, then `git cat-file -p <sha>`.

**Chain every step with `&&` (or `set -e`), never `;`.** A conflict resolver whose own internal check fails leaves the file untouched, but a `;`-chained `git add && git rebase --continue && git push` still runs and publishes raw conflict markers. Gate `git add` on an explicit positive check, such as `git diff --check` or `! grep -nE '^(<<<<<<<|=======|>>>>>>>)' <file>`, not just the resolver's exit code.

## Commit Identity and Email Privacy

- **Never pass an explicit personal email** (`-c user.email=...`). If the account has email privacy enabled, the push is rejected with `GH007: Your push would publish a private email address`. The failure happens at PUSH time, not commit time, so a session that only checks the commit succeeded reports work that never landed. Verify the operation that publishes, not the local step before it.
- Commit as `<username>@users.noreply.github.com`. Check `git log -3 --format=%ae` in an unfamiliar repo to see which identity its history uses.
- Recover an already-made commit: `git -c user.email=<username>@users.noreply.github.com commit --amend --no-edit --reset-author`, then re-push.
- The check covers the **committer** of every replayed commit, not just the author, so pushing from another machine doesn't help.
- The global `~/.gitconfig` itself can drift off the noreply address. If the ambient identity is wrong, set `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL` for the commit (or amend with `--author='<name> <noreply-email>'`). Fixing the global config is the owner's call.

## Discrimination Checks: `git stash push` a Directory, Never `git checkout` It

To prove a regression test discriminates, you revert the fix, re-run the suite, and expect failures. Reverting with `git checkout -- <dir>` DESTROYS an uncommitted fix with no reflog to recover from. Use `git stash push -- <dir>` instead; `git stash pop` restores it exactly.

For a partially committed branch:
```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
<run suite, record failures>
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```

Confirm every new assertion FAILS against the pre-fix code; a test that passes against both versions proves nothing.

## Scanner Hooks Can Compute the Wrong Diff Range

Sensitive-content hooks can flag main's already-approved content as new:
- **pre-commit on a merge commit:** `git diff --cached` diffs against the pre-merge HEAD, so finishing `git merge origin/main` on a stale branch re-flags everything main gained. Hook fix: when `MERGE_HEAD` exists, diff against `$(git merge-base HEAD MERGE_HEAD)`.
- **pre-push after a rebase:** the hook scans `$REMOTE_SHA..$LOCAL_SHA`, where the remote SHA is the stale pre-rebase tip, no longer an ancestor of HEAD, so the range spans all of main's landed commits.

Before concluding a push is blocked on new content, re-scan the correct range yourself (`git diff origin/main..HEAD | grep '^+' | grep -v '^+++'` piped to your scanner). Even when every hit is a false positive, **do not use `--no-verify`**. Commit only the new content onto a fresh branch off current main instead of merging or rebasing the stale branch, or fix the hook. Hooks installed via `init.templateDir` are copies in each `.git/hooks`; after fixing the source, reinstall across all clones and grep the INSTALLED copies for a marker from the new code.

## Branch Name Collisions and Stale Local Refs

**Before creating a run-numbered or reused branch name, check both axes:**
1. `git branch -a | grep <name>`: catches a local ref.
2. `gh pr list --repo <owner>/<repo> --head <name> --state all`: catches a squash-merged branch whose ref was deleted.

`git merge-base --is-ancestor` cannot distinguish "squash-merged" from "diverged", so it is not a reliable guard. If a collision is found, append a suffix (`<name>-2`) rather than investigating or deleting refs under time pressure.

**Rescuing an existing branch with `git worktree add <path> <branch>` (bare name) uses the LOCAL ref**, which may be far behind `origin/<branch>` if all recent work was pushed from worktrees. You then see phantom conflicts that were already resolved upstream, and your resolution push gets rejected as non-fast-forward. Check first:

```bash
git rev-parse <branch> origin/<branch>
git branch -f <branch> origin/<branch>   # if they differ; safe only when the ref is not checked out anywhere
```

Then create the worktree.
