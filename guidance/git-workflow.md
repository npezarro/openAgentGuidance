<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main` (or whatever the default branch is).
- Use the branch assigned to you. If none exists, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Avoid `test-` as a branch prefix.** Some repos have rulesets or branch protection that silently reject pushes to `test-*` branches: no error, and the branch never appears on the remote. Use names like `add-tests-<module>` or `<module>-tests-<run>` instead.
- Commit messages explain **why**, not just what. Large commits are fine; don't split work artificially.
- Before committing:
  1. `git status` to verify no unintended files are staged.
  2. `git diff` to review the actual changes.
  3. Confirm no `.env`, secrets, or key files are included.
  4. **Update the project's handoff file** (e.g. `context.md`). This is mandatory on the final commit of a branch (before creating a PR) or at session wrap-up, not on every intermediate commit. It records current state so the next agent can pick up the work.
  5. **Update the project's progress log** (e.g. `progress.md`) with an entry for the work being committed.
- Push: `git push -u origin HEAD`. Retry network failures up to 4 times with backoff (2s, 4s, 8s, 16s). Do not retry auth failures.
- Resolve the default branch instead of assuming `main`; some repos use `master`:
  ```bash
  gh repo view --json defaultBranchRef -q .defaultBranchRef.name
  ```

## All Deliverables Go in Repos
When you create scripts, tools, project assets, analysis docs, reference files, or any other output, **always put them in a git repo** and push to the remote. Never leave files as loose filesystem artifacts; the user should not have to dig around the filesystem for deliverables. The remote is the source of truth. If a new project or tool set has no repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions routinely create useful files (summaries, configs, scripts, reference docs) and then forget to commit, forget to push, or save them outside a repo. Local-only files are invisible between sessions. Treat every file write as incomplete until it is committed and pushed.

## Every Repo Gets a README and Description
Every repo must have a `README.md` and a GitHub repo description. When creating a repo, or working in one that is missing either, add them.

- **README.md**: what it does (1-2 sentences), how to set it up, how to run or use it. A developer should understand the project in 60 seconds.
- **GitHub description**: `gh repo edit <owner>/<repo> --description "one-line summary"`. One sentence.

Both are required at `gh repo create` time: pass `--description` and include the README in the initial commit.

## Always Commit and Push Written Files
When you create or modify files in any repo, **commit and push in the same step**. Don't move on to other work with untracked or uncommitted files sitting in a repo. Writing a file does not commit it.

Never leave commits unpushed. Unpushed commits are invisible to other sessions, collaborators, and deploy pipelines. Treat file creation + `git commit` + `git push` as one atomic operation; if any step fails, diagnose and fix it before moving on.

**Verify the step that actually publishes**, not the local step before it. Some failures (e.g. email-privacy rejections) only appear at push time, so a session that only checks that the commit succeeded can report work that never landed.

**Common gap:** when working across several repos in one session, it is easy to push some and forget others. After a multi-repo task, run `git status` in each one and confirm all are clean and pushed.

## Staging Hygiene (any repo with in-flight work)

Any checkout can hold uncommitted work from a previous or concurrent session, and a blanket add silently ships it under your commit message. This is not a "shared repo" rule; it applies to **every** repo. A blanket `git add -A` in an ordinary single-purpose repo has swept a half-finished feature, a scratch script, and a settings change into an unrelated commit.

The check is cheap and unconditional: **run `git status` BEFORE staging.** If the tree holds anything you didn't touch, name your paths explicitly.

- **Stage explicit paths, never `git add -A` / `git add .`.** Name the files you touched: `git add guidance/foo.md scripts/bar.sh`.
- **Never `--no-verify` on a public repo.** A pre-commit secret or sensitive-identifier scanner is the last line of defense before an internal username, path, or token reaches a public repo. If the scanner blocks you, sanitize the content; don't override it.
- **Before committing, confirm ONLY your files are staged.** If you see files you didn't touch, unstage them (`git restore --staged <path>`); they belong to someone else.
- Review the result before pushing: `git show --stat HEAD`.

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

When creating PRs via the REST API (e.g. Octokit) rather than `gh pr create`, the `head` parameter must be fully qualified as `owner:branch`:

```js
// WRONG: causes "invalid head" errors, especially on newly-pushed branches
await octokit.rest.pulls.create({ head: branch, ... });

// CORRECT: qualify with the repo owner
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

**Why:** GitHub needs a few seconds to index a newly-pushed branch, and unqualified names fail more often in that window. Also add a 3s delay before `pulls.create` after a push event, use `maxAttempts` of 5, and retry on "invalid head" errors. `gh pr create` handles qualification itself; this applies to direct API use (e.g. bots).

## Working With an Auto-Merge Bot

If your setup runs a bot that opens and squash-merges PRs automatically on push:

- **"No commits between main and `<branch>`" or "Head sha can't be blank" after a push is SUCCESS, not failure.** The bot already opened and merged the PR, and deleted the branch. Find its PR with `gh pr list --state all --head <branch>` and reuse that number. Do not re-push or open a duplicate; a retry can produce a second merged PR for one logical change.
- Equally, `gh pr create` may report "a pull request already exists". Confirm with `gh pr view <n> --json state,mergedAt`.
- **Verify by content, not ancestry.** A squash commit is not an ancestor of your local commit, so `git merge-base --is-ancestor` and `git branch --merged` both report "unmerged". Check content instead:
  ```bash
  git fetch origin && git log --oneline -3 origin/main
  git cat-file -e origin/main:<path> && echo "landed on main"
  git diff HEAD origin/main -- <paths> --stat   # empty == merged content is identical
  ```
- When verifying added lines with grep, use `grep -Fqx -- "$line"`. Without `--`, any line beginning with `-` (a markdown bullet) is parsed as an option and verification silently reports false negatives.
- **A bot that merges every non-draft PR by default is opt-out, not opt-in.** Pushing a branch you don't want merged yet is not safe by default. Immediate mitigation: convert the PR to draft right after pushing (`gh pr ready <n> --undo`). Durable fix: give the bot a repo-level denylist plus per-commit overrides (e.g. `[no-automerge]` / `[automerge]` in the head commit message), and add any repo with human or design branches to the denylist **before** its first push, not after the first unwanted merge. Branch lanes that have their own mandatory verification step (e.g. `*/fix-*`) must not blind-merge on push before that verification runs.
- **Follow-up fixes after an auto-merge go on a FRESH branch off main.** Pushing a second commit to the already-merged-and-deleted branch conflicts every time (main holds one squashed commit while your branch still has the originals):
  ```bash
  git checkout -b <new> origin/main
  git checkout <old-branch> -- <only the changed files>
  # commit, push the new branch, close the stale PR
  ```
  Verify a push landed with `git ls-remote --heads origin <branch>`, not the local `origin/<branch>` ref, which goes stale the moment the bot deletes the branch.
- **If you create PRs in automation, verify they actually merged before ending the session.** Re-check `gh pr view <n> --json state,mergeable` as the last step and merge right then if MERGEABLE with green CI. Do not rely on a later sweep as a merge backstop; PRs can otherwise sit mergeable for days.

## Branch Hygiene

Open PRs that sit unmerged cause cascading merge conflicts across every other branch. **This is the #1 cause of stuck work.**

- **Merge PRs promptly.** When a PR is ready and has no review requirement, merge it in the same session: `gh pr merge <number> --merge --delete-branch`. If it fails (conflict, checks pending), retry once after 5s; if it still fails, report the specific error.
- **Rebase before opening a PR.** `git fetch origin && git rebase origin/main`, resolve conflicts, then push. A PR should be mergeable when created.
- **One branch per task.** Don't create multiple branches for the same feature or leave abandoned branches behind.
- **Clean up stale branches.** At session start, check `gh pr list --state open` and `git branch -a`. A branch open for more than a few days without activity should be rebased and merged, or closed.
- **Prune before scanning.** Run `git remote prune origin` before enumerating with `git branch -a` / `-r`; otherwise refs for branches already deleted on the remote inflate "open branch" counts.
- **Automation cap/dedup gates MUST use `git ls-remote`, not `git branch -r`.** Remote-tracking refs are only refreshed on fetch and are racy even with pruning. Query the remote directly: `git ls-remote --heads origin 'claude/auto-*'`. Stale tracking refs have triggered "backlog cleanup" modes on zero real open branches.
- **Don't leave PRs for someone else to merge** unless the task requires review.
- **Handoff and progress files conflict constantly.** Update them as the very last commit before merging, after rebasing on main.
- **If a merge fails with complex code conflicts on a stale branch:** close the PR, delete the branch, and redo the work on a fresh branch from main rather than sinking time into the resolution. (Exception: if the branch holds real hand-written code, a targeted resolution in an isolated worktree, verified by build and tests, is better than losing the work. For a dependency-bot lockfile PR, closing and letting the bot recreate it is correct.)
- **MERGEABLE does not mean non-redundant.** A feature PR can show MERGEABLE while its entire patch is already on main (e.g. another PR branched off it and carried the code in). Before merging, rebase in a throwaway checkout: if the commit is dropped as "patch contents already upstream" or `git diff origin/main <tip>` is empty, close it as superseded: `gh pr close <N> --delete-branch --comment "Superseded by ..."`.
- **Merged-PR scope notes are sanctioned follow-up work, not dedup blockers.** When candidate work looks like a duplicate of a merged PR, read that PR's body. An explicit "out of scope / follow-up" note makes it pre-vetted work, and the merged PR often ships helpers the follow-up should reuse. Cite the note in the new PR body.

### `gh` in a forked checkout can silently resolve against `upstream`
In a checkout with both `origin` (your fork) and `upstream` (the project you forked), bare `gh pr view <n>` may resolve against `upstream`. A PR number that exists there looks valid even though you have no control over it, and branch-name patterns can make other people's PRs look automation-owned. **Always pass `--repo <owner>/<name>` explicitly** before viewing, merging, closing, or commenting on a PR in any checkout that might be a fork. The danger isn't a bad merge decision; it is acting on a repo you don't own at all.

## Repos Whose Working Copy Is Live: Use Worktrees, Not Branch Checkouts

**Never `git checkout <branch>` in the main checkout of a repo whose working copy is read by live hooks, session-start scripts, or a process manager config** (e.g. this repo, if your hooks load guidance from its clone). Switching branches silently reverts all guidance, hooks, and config to the target branch's state for every concurrent session: new rules vanish, old ones reappear, hooks change behavior, with no error or warning.

Use a worktree instead:

```bash
git -C $HOME/<repo> worktree add /tmp/wt-<repo> -b claude/<task>
# ... edit, commit, push, open PR from inside /tmp/wt-<repo> ...
git -C $HOME/<repo> worktree remove /tmp/wt-<repo>
# Main checkout stays on main throughout
```

A worktree that pushes directly to the default branch (e.g. for an append-only log) must stay detached and push via refspec (`git push origin HEAD:main`); never `checkout -B <default-branch>` inside it, which collides with the primary checkout's own branch.

## Remote Checkouts May Hold Commits That Exist Nowhere Else

Before `git pull` or `git reset` in a checkout you don't own (a server, a container, another machine), check whether it is **ahead** of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

Non-zero means `git reset --hard origin/<branch>` may destroy work permanently. A conflicting `git pull` is a signal to investigate, not a nuisance to force past.

When you find divergence:

1. **Back it up before touching anything.** `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup` and copy the bundle off the machine. A branch on a single host is not a backup.

2. **Establish whether those commits contain unique content. Do NOT trust the commit subjects.**
   ```bash
   git diff --stat origin/main..<backup-branch>     # net direction of the delta
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"  # its unique source lines
   ```
   Then verify each feature the subjects claim **in the upstream tree**: `git grep -n "<feature>" origin/main -- src/`.

   A branch can be several commits "ahead" and still be strictly poorer: early work that upstream later reimplemented via squashed or re-authored PRs, so SHAs never match. A large net-negative diff with zero files unique to the remote side, where every claimed feature exists upstream, means the remote is a superseded fork.

3. **Choose on evidence:**
   - *Superseded fork* (no unique content): `git reset --hard origin/<branch>`. Safe when runtime state is gitignored; check what the code writes (`output/`, `*.log`, caches) and confirm any tracked data file is read-only config, not state.
   - *Genuinely unique content*: port it onto a branch off `origin/main`, commit under a valid author identity, push, and only then reset the remote checkout.
   - *Need one fix now, reconcile later*: `git fetch origin main && git cherry-pick <sha>` on that checkout. Conflicts are usually files absent from the older HEAD: `git add` the incoming version and `--continue`. This is interim, not an outcome.

   Afterwards run the repo's tests **on that host**. A jump in test count is a good sign you recovered real work.
4. **Record the outcome in that checkout's own handoff file** and commit it there. Docs committed upstream are invisible to a checkout that is far behind.
5. **Surface the divergence as an open item.** Reconciling it is the owner's call.

Restore from a bundle with:
```bash
git fetch /path/to/x.bundle <name>-backup:<name>-backup
```

## Untracked File Shadowing a Tracked Path: Use a Worktree, Never rm

An untracked file at a path that IS tracked on `origin/main` makes `git checkout -b <new> origin/main` abort with "untracked working tree files would be overwritten by checkout".

Do NOT `rm` or `mv` the blocker. It may be someone else's uncommitted notes. Commit through a worktree, which never touches the dirty tree:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

**If you moved the blocker aside anyway**, the `mv` is only half the procedure. The file is tracked on the branch you moved to and untracked on the one you came from, so checking out the original branch DELETES it. Required closing steps:
1. Record `git status --short` BEFORE you start.
2. After returning to the original branch, check the file exists.
3. If gone: restore the backup if it differed, else `git show origin/main:<file> > <file>`.
4. Re-run `git status --short` and confirm it matches step 1 exactly.

Leaving the working tree different from how you found it is a side effect nobody asked for.

## The Shared Checkout May Host Another Live Agent Session

A single working tree can be edited by several sessions at once. Two failures follow from assuming sole ownership:

**1. `git checkout -- <file>` deletes another session's uncommitted work.** An `M` in `git status` is one flag for the whole file, not a claim of single authorship. A file can hold your one-line change and someone else's 50-line uncommitted redesign.

> **Before `git checkout --` on any file in a shared tree, run `git diff <file>` and confirm every hunk is yours.** If a hunk isn't, leave the file alone and work in a worktree.

**2. Another session can commit YOUR uncommitted files under its own message.** Anything untracked or uncommitted in a shared tree is fair game for another process running `git add`. Your later push is then rejected as non-fast-forward against a commit that is byte-identical to your work.

> **When another session may share the checkout, do the whole edit in `git worktree add /tmp/wt-<repo> <trunk>` from the start.** Never leave new files untracked in the shared tree.

**Detect a concurrent session BEFORE the first edit, not at commit time:**
```bash
git branch --show-current     # an unexpected branch
git reflog -5                 # checkouts or commits you did not make
git worktree list             # worktrees you did not create
git status --short            # record this; your final state must differ only by your files
```
If any show another session, branch a worktree off trunk immediately and don't touch the shared tree. Reconciling afterwards: if the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force your duplicate commit; reset to origin and commit only what is genuinely missing.

For automated checkouts that concurrent jobs share and that can switch branches mid-operation, don't trust the ambient staging area: build the commit through a temp index (`GIT_INDEX_FILE=<tmp> git read-tree ...` + `git commit-tree`) and push via an explicit refspec (`git push origin <sha>:refs/heads/<branch>`).

### When a push gate blocks on work that isn't yours

A "don't stop with unpushed work" gate should be **per-commit and per-file**: block only on commits or dirty files containing something this session wrote. If yours fires on a peer's file, prove it first (`git diff <file>` shows zero hunks of yours, and your own content is already on the remote) before acknowledging or bypassing. Any acknowledgement mechanism should name one exact path with a reason, never a wildcard. Acknowledging work you simply forgot to push is exactly the failure the gate exists to catch.

**A peer's unpushed commit.** If the peer session is still live, wait: they may still amend. Only for a genuinely stranded commit (the authoring session is gone and the work exists nowhere else):
1. Identify author and branch: `git log --format='%h %an %ad %s' @{u}..HEAD` and `git branch --show-current`. Confirm it isn't yours.
2. Secret-scan the diff you are about to publish. You did not write or review it; a private repo does not exempt it.
3. Push to the branch it was committed on: `git push origin HEAD:<that-branch>`. Never redirect a peer's commit to the default branch.
4. Say so in your final message.

Never `git reset` a peer's commit to clear a gate; that destroys work that exists nowhere else.

## A PR Stuck CONFLICTING Is Invisible to Automation

**`gh pr view N --json mergeable` returns `UNKNOWN` on the first poll.** GitHub computes mergeability lazily; only a follow-up read (~6s later) returns the real `MERGEABLE`/`CONFLICTING`. A checker that reads the first response finds nothing actionable and moves on, and PRs can sit blocked for days with zero alerts. **Anything gating on mergeability must re-poll.**

Diagnosis order when a repo "seems behind on commits":
1. `git status`: a clean tree means this is almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge.

**Don't use the legacy 3-arg `git merge-tree <base> <a> <b>`.** It can exit 0 with no conflict markers on a merge that genuinely conflicts. If in doubt, do a real trial merge in an isolated worktree:
```bash
git worktree add /tmp/x FETCH_HEAD --detach && cd /tmp/x && git merge origin/main --no-commit --no-ff
```

**Merge the default branch INTO the stale branch, never the reverse.** A branch N commits behind, pushed onto the default branch, deletes everything added there since it forked. Verify losslessness per file before committing a resolution; for append-only files this must print 0 against both parents:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

Duplicate commit subjects with different SHAs on the two sides are the tell that sessions have been cherry-picking around the block; those duplicates usually created the conflict.

**Merging same-file PRs one at a time does not drain a backlog.** Each merge moves the default branch under siblings touching the same file, turning mergeable PRs into conflicting ones. When N PRs edit the same hotspot file, merge them into one integration branch, resolve the combined set once, and land that.

**Auto-resolve only what is provably safe.** A union resolver should refuse any hunk where the two sides share a line rather than deduplicating by guess, and must never union a YAML frontmatter hunk (that produces duplicate keys).

**Rebasing an append-only log needs chronological reinsertion.** When the only conflict is inside a dated narrative log, the two blocks are usually independent entries, not competing edits. Don't just stack the incoming block at the conflict site: on a long-open branch it is often older than entries main gained since. Read each block's own date header, move it to where it belongs chronologically (possibly well outside the conflict markers, e.g. right before the first later entry that references it), then confirm the file's date headers are monotonic.

### An UNSTABLE status with a failing check is not automatically a blocker
When `mergeStateStatus` is `UNSTABLE`, read the failing job (`gh run view --log-failed`) and compare what it fails on with the PR's file list. If the failure reproduces identically on a fresh checkout of the base branch, it is pre-existing and unrelated, and should not veto an otherwise-eligible merge. Your normal merge criteria (verification passed, MERGEABLE, no sensitive paths) still govern.

### A PR whose head branch was deleted while OPEN stays UNKNOWN forever
Symptoms: PR open for hours with green checks and `mergeStateStatus: UNKNOWN`; `gh pr merge` fails "Head branch is out of date"; `update-branch` fails "head ref does not exist"; `git ls-remote origin refs/heads/<branch>` is empty. A "must be up to date with base" rule can never pass with no branch to update. Green checks plus OPEN is not evidence the PR is just waiting its turn.

Fix: the head commit survives at `refs/pull/<n>/head`. Recreate the branch from it:
```bash
git ls-remote origin refs/pull/<n>/head                # get <head-sha>
git push origin <head-sha>:refs/heads/<branch-name>
gh api repos/<owner>/<repo>/pulls/<n>/update-branch -X PUT
gh pr merge <n> --squash --delete-branch
```

## Landing a Worktree Branch

1. **Merge from the PRIMARY checkout, not inside the worktree.** `git checkout main` inside a worktree fails with "'main' is already used by worktree at ..." because the primary checkout holds it. And running `git worktree remove` while your cwd is inside that worktree leaves the shell with no working directory.
2. **Never pass an explicit commit email** (`-c user.email=...`). With GitHub email privacy on, a commit authored or committed with a personal address is rejected at push time ("push declined due to email privacy restrictions" / GH007), after the work was already correct. Let git use the repo's configured identity; check `git log -3 --format='%ae %ce'` to see which identity the history uses. Recover an existing commit with:
   ```bash
   git -c user.email=<username>@users.noreply.github.com commit --amend --no-edit --reset-author
   ```
   The check applies to the **committer** of every replayed commit too, so pushing from a different machine doesn't help.
3. **Gate teardown on the commit existing, not on the next line running.** A hook can block `git commit` and leave the work staged but uncommitted. If merge, push, and `git worktree remove --force` follow on the same line or after `;`, they still run: `git merge --ff-only` of a branch with no new commit is a no-op that exits 0, and `--force` then deletes the worktree holding the only copy.
   ```bash
   # in the worktree
   git commit ...
   COMMIT=$(git rev-parse HEAD)
   # in the primary checkout
   [ "$(git rev-parse <branch>)" != "$(git rev-parse <base>)" ] \
     && git merge --ff-only "$COMMIT" && git push && git worktree remove /tmp/wt
   ```
   Or run teardown as a separate call after reading the commit output. If it already happened: staged files survive as dangling blobs: `git fsck --unreachable | grep blob`, then `git cat-file -p <sha>`.

### Reopening an existing branch in a worktree: check the local ref first
`git worktree add /tmp/wt <existing-branch>` by bare name checks out the **local** ref, which may be weeks behind `origin/<branch>` if every previous rescue worked in a worktree and pushed straight to origin. Merging main into the stale ref surfaces phantom conflicts that were already resolved upstream, and a push of the result is rejected after you've done the work. First:
```bash
git rev-parse <branch> origin/<branch>
git branch -f <branch> origin/<branch>   # if they differ; safe when the main checkout never has it checked out
```

### Run-numbered branch names can collide with a merged branch
Automation that names branches after a run number (`claude/learnings-<N>`) can reuse a name that was already squash-merged and deleted. `git merge-base --is-ancestor` returns false for a squash-merged branch, so it cannot distinguish "merged" from "diverged". Before creating one, check both:
```bash
git branch -a | grep <name>
gh pr list --repo <owner>/<repo> --head <name> --state all
```
On a collision, append a suffix (`<name>-2`) rather than investigating or deleting refs under time pressure.

## Proving a Regression Test Discriminates: Stash, Never Checkout

To show a test catches the bug, you revert the fix, re-run, and expect failures. Reverting with `git checkout -- <dir>` DESTROYS an uncommitted fix; there is no reflog for working-tree files. Use `git stash push -- <dir>`, which reverts identically and `git stash pop` restores exactly. For a partially-committed fix:

```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
# run suite, record failures
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```

Confirm each new assertion actually FAILS against the pre-fix code; tests that pass on both versions prove nothing.

## Scanning Hooks Give False Positives on Merges and Rebases

- **Merge commits:** a pre-commit hook using bare `git diff --cached` diffs an in-progress merge against the pre-merge HEAD, not the merge-base, so it re-flags all of main's already-approved content as newly introduced. Hook fix: when `MERGE_HEAD` exists, diff against `$(git merge-base HEAD MERGE_HEAD)`.
- **Pushes after a rebase:** a pre-push hook scanning `$REMOTE_SHA..$LOCAL_SHA` uses the stale pre-rebase remote tip, which is no longer an ancestor, so the range spans all of main's landed commits. Re-scan the correct range yourself before concluding new content is blocked:
  ```bash
  git diff origin/main..HEAD | grep '^+' | grep -v '^+++' | <your-secret-scanner>
  ```
- In both cases **do not `--no-verify`**. Either isolate the genuine hits and fix them, or commit new content onto an up-to-date branch without the in-place merge and let the conflict be resolved elsewhere.
- Hooks are **copies** in each `.git/hooks` (and in every clone made via `init.templateDir`). Editing the source changes nothing until reinstalled. After any hook fix, verify by grepping the installed copies for a marker from the new code.
