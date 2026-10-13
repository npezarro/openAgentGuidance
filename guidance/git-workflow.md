<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main`.
- Use the branch assigned to you. If none exists, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Avoid `test-` as a branch prefix.** Some repos have GitHub rulesets or branch protection that silently reject pushes to `test-*` branches. There is no error; the branch just never appears on the remote. Use descriptive names like `add-tests-<module>` or `<module>-tests-<run>` instead.
- Commit messages explain **why**, not just what. Large commits are fine; don't split work artificially.
- Before committing:
  1. `git status` to verify no unintended files are staged.
  2. `git diff` to review the actual changes.
  3. Confirm no `.env`, secrets, or key files are included.
  4. **Update `context.md`** (the repo's current-state handoff file for the next agent). This is mandatory on the final commit of a branch (before creating a PR) or at session wrap-up. It is not required on every intermediate commit.
  5. **Update `progress.md`**: add an entry for the work being committed.
- Push: `git push -u origin HEAD`. Retry network failures up to 4x with backoff (2s, 4s, 8s, 16s). Do not retry auth failures.

## All Deliverables Go in Repos
When creating scripts, tools, project assets, analysis docs, reference files, or any other output, **always put them in a git repo** and push to GitHub. Never leave files as loose filesystem artifacts; the user should not have to dig around the filesystem for deliverables. GitHub is the source of truth. If a new project or tool set doesn't have a repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions routinely create useful files (summaries, configs, scripts, reference docs) and then forget to commit, forget to push, or save them outside a repo. The user cannot access local-only files between sessions. Treat every file write or edit as incomplete until the file is committed and pushed.

## Every Repo Gets a README and Description
Every repo must have a `README.md` and a GitHub repo description. When creating a new repo or working in one that's missing either, add them.

- **README.md**: what it does (1-2 sentences), how to set it up, and how to run/use it. Keep it concise; a developer should understand the project in 60 seconds.
- **GitHub description**: set via `gh repo edit <owner>/<repo> --description "one-line summary"`. One sentence that appears on the repo page and in search results.

Both are required when running `gh repo create`. Use the `--description` flag on creation. Add the README as part of the initial commit.

## Always Commit and Push Written Files
When creating or modifying files in any repo, **always commit and push in the same step**. Don't move on to other work with untracked or uncommitted files sitting in a repo. Writing a file doesn't commit it; you must do that explicitly.

When committing to any repo, **always push to the GitHub remote branch as well**. Never leave commits unpushed. Unpushed commits are invisible to other sessions, collaborators, and the deploy pipeline. Treat file creation + `git commit` + `git push` as a single atomic operation; if any step fails, diagnose and fix it before moving on.

**Common gap:** when working across multiple repos in one session, it's easy to push some and forget others. After finishing a multi-repo task, verify all repos are clean: `git status` in each one.

## Staging Hygiene (ANY repo with in-flight work)

Some repos are worked by many agents at once (interactive sessions, scheduled agents, doc-sync jobs). **This is not a "shared repo" rule; it applies to ANY repo.** Any checkout can hold uncommitted work from a previous session, and a blanket add silently ships it under your commit message. In practice, a `git add -A` in a repo nobody thought of as shared has swept a half-finished adapter, a scratch script, and a settings change into an unrelated commit; it was only caught by reviewing `git show --stat` before pushing.

The check is cheap and unconditional: **run `git status` BEFORE staging.** If the tree holds anything you didn't touch, name your paths explicitly.

- **Stage explicit paths, never `git add -A` / `git add .`** in any repo. A blanket add sweeps whatever another agent left uncommitted into *your* commit, including secrets. Name the files you touched: `git add guidance/foo.md scripts/bar.sh`.
- **Never `--no-verify` on a public repo.** A pre-commit sensitive-identifier scanner is the last line of defense before a username, internal path, or token reaches a public GitHub repo. Bypassing it is how leaks ship. If the scanner blocks you, sanitize the content; don't override.
- **Before committing, `git status` and confirm ONLY your files are staged.** If you see files you didn't touch, unstage them (`git restore --staged <path>`); they belong to another agent.

## Creating PRs (with retry)

After `git push`, GitHub may take a few seconds to register the branch. Always verify the branch exists remotely before creating the PR, and retry on failure:

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

**Why:** GitHub needs a few seconds to fully index a newly-pushed branch. Unqualified branch names fail more often during this window. Qualifying with the owner disambiguates the ref lookup.

**Also:** add a 3s delay before calling `pulls.create` after a push event, set `maxAttempts` to 5, and retry on "invalid head" errors. The `gh pr create` CLI handles head qualification internally; this only applies when calling the REST API directly (e.g. in automation bots).

## Working Alongside an Auto-Merge Bot

If your repos run a bot that opens and squash-merges PRs from pushed branches, the reliable agent workflow is often to just `git push` the branch and let the bot merge it. In that setup:

- **After a push, the remote branch vanishing and `gh pr create` failing with "No commits between main and `<branch>`" / "Head sha can't be blank" / "a pull request already exists" is success, not failure.** The bot already landed the change. Find its PR with `gh pr list --state all --head <branch>` and reuse that number. Do not retry the push or open a duplicate; a retry can produce a second merged PR for one logical change, which is misleading history.
- **Verify by content, not ancestry.** The squash commit is NOT an ancestor of your local commit (`git merge-base --is-ancestor <mine> origin/main` returns false, and `git branch --merged` reports the branch unmerged), but `git diff origin/main <mine> -- <file>` will be empty. Check the diff, or confirm with `gh pr view <n> --json state,mergedAt`:
  ```bash
  git fetch origin && git log --oneline -3 origin/main
  git cat-file -e origin/main:<path> && echo "landed on main"
  git diff HEAD origin/main -- <paths> --stat   # empty == merged content is identical
  ```
- **When verifying added lines with grep, use `grep -Fqx -- "$line"`.** Without the `--`, any added line beginning with `-` (a markdown bullet) is parsed as a grep option and verification silently reports false negatives.
- **Don't assume the default branch is `main`.** Resolve it: `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
- **Shared checkouts can switch branches mid-operation** when concurrent jobs use the same working tree. Don't trust the ambient staging area for a clean single-file commit; build it via a temp index (`GIT_INDEX_FILE=<tmp> git read-tree` + `git commit-tree`) and push via an explicit refspec (`git push origin <sha>:refs/heads/<branch>`).

### An auto-merge bot that is opt-out merges branches you never meant to land
If the bot's default is to merge every non-draft PR from any pushed branch, pushing a branch you don't want merged yet is not safe. Human or design branches, and parallel agents pushing WIP checkpoints in a brand-new repo, have been merged within minutes of the first push.

- **Immediate mitigation:** convert the PR to draft right after pushing (`gh pr ready <n> --undo`), or use a per-commit opt-out marker in the commit subject if your bot supports one (e.g. `[no-automerge]`).
- **Durable fix:** give the bot a repo-level denylist, and add any product/design repo, or any repo that will run parallel agents, to it **before its first push**, not after the first incident. Keep narrowly-scoped safe lanes (doc-sync, fix branches that have their own verification gate) auto-merging if needed.
- If WIP already got squash-merged, land the real content on `main` yourself afterward (`git checkout origin/<branch> -- <owned paths>`) rather than fighting the squash.

## Branch Hygiene

Open PRs that sit unmerged cause cascading merge conflicts across all other branches. **This is the #1 cause of stuck work.** Prevent this:

- **Merge PRs promptly.** When a PR is ready and has no review requirements, merge it in the same session you created it: `gh pr merge <number> --merge --delete-branch`. If the merge fails (conflict, checks pending), retry once after 5s. If it still fails, report the specific error.
- **Verify your own PR actually merged.** As the last step of a session, re-check `gh pr view <n> --json state,mergeable` for the PR you created, and merge it right then if MERGEABLE and CI is green. A closeout that logs "PR: <link>" without checking state lets verified fixes sit unmerged for days.
- **Rebase before opening a PR.** Run `git fetch origin && git rebase origin/main` and resolve conflicts before pushing. A PR should be mergeable at the time it is created.
- **One branch per task.** Don't create multiple branches for the same feature or leave abandoned branches behind.
- **Clean up stale branches.** At session start, check `gh pr list --state open` and `git branch -a`. If a branch has been open more than a few days without activity, rebase and merge it or close it.
- **Prune remote-tracking refs before scanning.** Before enumerating with `git branch -a` or `git branch -r`, run `git remote prune origin`. Without pruning, refs for branches already deleted on GitHub linger and inflate "open branch" counts.
- **Automation cap/dedup gates MUST use `git ls-remote`, not `git branch -r`.** `git branch -r` reads local tracking refs that are only refreshed on fetch, and is racy even with pruning. For cap checks and backlog gates, query the remote directly: `git ls-remote --heads origin 'claude/auto-*'`. Stale tracking refs for already-merged branches have triggered "backlog cleanup" mode with zero real open branches.
- **In a forked checkout, always pass `--repo <owner>/<name>` to `gh`.** With both `origin` (your fork) and `upstream` (the canonical repo), bare `gh pr view <n>` can silently resolve against `upstream`. A PR number that exists there looks valid even though you don't control it; inventory built this way has listed PRs from unrelated external accounts and PRs that don't exist on your fork at all. The danger is not a bad merge decision; it is acting (view, merge, close, comment) on a repo outside your control.
- **Don't leave PRs for someone else to merge** unless the task explicitly requires review. Unmerged PRs are invisible debt that compounds with every new branch.
- **Never modify `context.md` or `progress.md` on a branch that other branches also modify.** These files conflict constantly. If you must update them, do it as the very last commit before merging, after rebasing on main.
- **If a merge fails with code conflicts:** close the PR, delete the branch, and redo the work on a fresh branch from main. Don't sink time into complex conflicts on stale branches. (Exception: a PR carrying real hand-written code worth recovering; see "Trial merges" below.)
- **Follow-up fixes after an auto-merge go on a FRESH branch off main.** If the bot squash-merges and deletes your branch, pushing a second commit to that same branch conflicts every time (main holds one squashed commit; your branch still has the originals), and `gh pr create` fails because the branch no longer exists server-side. Instead: `git checkout -b <new> origin/main`, then `git checkout <old-branch> -- <only the changed files>`, commit, push, close the stale PR. Verify a push landed with `git ls-remote --heads origin <branch>` rather than trusting the local `origin/<branch>` ref.
- **MERGEABLE ≠ non-redundant.** A feature PR can show MERGEABLE yet have its entire patch already on `main` (e.g. a doc-sync PR that branched off it carried the code in). Before merging a PR that looks "ready," run `git rebase origin/main` in a throwaway checkout: if the commit is dropped ("patch contents already upstream") or `git diff origin/main <tip>` is empty, close it as superseded (`gh pr close <N> --delete-branch --comment "Superseded by ..."`) instead of producing a duplicate merge.
- **Merged-PR scope notes are sanctioned follow-up work, not dedup blockers.** When candidate work looks like a duplicate of a recently merged PR, read that PR's body first. An explicit "out of scope / follow-up" note makes the candidate pre-vetted follow-up work, and the merged PR often shipped helpers the follow-up should reuse. Cite the scope note in the new PR body.

## Staging Changes in Hook-Executing Repos: Use Worktrees, Not Branch Checkouts

**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is executed by live hooks or startup scripts** (e.g. this repo, if your session hooks load guidance from its clone). Switching its branch silently reverts all guidance, hooks, and config to whatever the target branch holds, for every concurrent session. New rules vanish, retired rules reappear, hooks change behavior, with no error or warning.

**The safe pattern:** use a git worktree.

```bash
# Stage changes for review without touching the main checkout
git -C <repo> worktree add /tmp/wt-<repo> -b claude/<task>
# ... make edits, commit, push, open PR from inside /tmp/wt-<repo> ...
git -C <repo> worktree remove /tmp/wt-<repo>
# Main checkout stays on main throughout; hooks keep running from live state
```

**Applies to:** any repo whose path appears in a hook, startup script, or process-manager config that loads it at runtime.

**A worktree that pushes directly to the default branch** (e.g. for an append-only log) must stay detached; never `checkout -B <default-branch>` inside it, which collides with the primary checkout's own branch.

## Merging a Worktree Branch

1. **Merge from the PRIMARY checkout, not inside the worktree.** `git checkout main` inside a worktree fails with "'main' is already used by worktree at ...". And never run `git worktree remove` while your cwd is inside that worktree; the shell is left with no working directory.
2. **Never hardcode a commit email** with `-c user.email=...`. Let git use the repo's configured identity (see the email-privacy section below).

Sequence: commit in the worktree, `COMMIT=$(git rev-parse HEAD)`, `cd` to primary, `git merge --ff-only $COMMIT`, push, then `git worktree remove` from the primary checkout.

**Gate teardown on the commit existing, not on the next line running.** A hook can block `git commit` and leave work staged but uncommitted. If merge/push/`git worktree remove --force` sits later in the same shell chain, it still runs: `git merge --ff-only <branch>` with no new commit is a no-op that exits 0, so the chain "succeeds" and `--force` deletes the worktree holding the only copy. Make teardown conditional:

```bash
[ "$(git rev-parse <branch>)" != "$(git rev-parse <base>)" ] && \
  git merge --ff-only <branch> && git push && git worktree remove <path>
```

Or run it as a separate call after reading the commit output. If it already happened: staged files survive as dangling blobs; `git fsck --unreachable | grep blob`, then `git cat-file -p <sha>`.

**Rescuing an existing PR branch: sync the local ref first.** `git worktree add <path> <existing-branch>` (bare name) uses the local ref, which can be weeks behind `origin/<branch>` if every previous rescue worked in a worktree and pushed straight to origin. You then resolve phantom conflicts that were already fixed upstream and end with a rejected non-fast-forward push. Before adding the worktree:

```bash
git rev-parse <branch> origin/<branch>          # differ?
git branch -f <branch> origin/<branch>          # safe if the ref is never checked out in the main checkout
```

## Remote Checkouts May Hold Commits That Exist Nowhere Else

Before `git pull`/`git reset` in a checkout you do not own (a server, a container, another machine), check whether it is **ahead** of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

Non-zero means that checkout holds commits that may exist nowhere else. `git reset --hard origin/<branch>` destroys them permanently. A conflicting `git pull` is a *signal* to investigate, not a nuisance to force past.

When you find divergence:

1. **Back it up before touching anything.** `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup` and copy the bundle off the machine. A branch on a single host is not a backup.

2. **Establish whether those commits contain unique content. Do NOT trust commit subjects.**

   ```bash
   git diff --stat origin/main..<backup-branch>     # net direction of the delta
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"  # its unique source lines
   ```

   Then verify each feature the subjects claim, **in the upstream tree**: `git grep -n "<feature>" origin/main -- src/`.

   A branch can be "7 commits ahead" and still be strictly poorer: early work that upstream later reimplemented properly, often via squashed or re-authored PRs so the SHAs never match. A diff of a few hundred added lines against thousands removed, with zero files unique to the remote side, is a superseded fork; the "cherry-pick, never reset" instinct is wrong there.

3. **Then choose, on evidence:**
   - *Superseded fork* (no unique content): `git reset --hard origin/<branch>`. Safe when runtime state is gitignored; check what the code actually writes (`output/`, `*.log`, caches) and confirm any tracked data file is read-only config, not state.
   - *Genuinely unique content*: port it onto a branch off `origin/main`, commit under a valid author identity, push, and only then reset the remote checkout. Don't leave it stranded. If the push is rejected for email privacy, see below; that rejection follows the commits, not the pusher.
   - *Need one fix now, reconcile later*: `git fetch origin main && git cherry-pick <sha>` onto that checkout's HEAD. Conflicts are usually files that didn't exist on the older HEAD: `git add` the incoming version and `--continue`. This is interim, not an outcome.

   Verify by running that repo's tests **on that host** afterwards. A big jump in test count is a good sign you recovered real work.
4. **Record the outcome in that checkout's own `context.md`** and commit it there. Docs committed upstream are invisible to a checkout that is dozens of commits behind.
5. **Surface the divergence as an open item.** Reconciling it is the owner's call.

Restore from a bundle with:
```bash
git fetch /path/to/x.bundle <name>-backup:<name>-backup
```

## Untracked File Shadowing a Tracked Path: Use a Worktree, Never rm

A repo can hold an UNTRACKED file at a path that IS tracked on `origin/main` (common where automated sessions drop env/scratch files). `git checkout -b <new> origin/main` then aborts with "untracked working tree files would be overwritten by checkout".

Do NOT rm or mv the blocker. It may be someone else's uncommitted notes. Commit through a worktree, which never touches the dirty tree:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

**If you moved the blocker aside anyway, the mv is only half the procedure.** The file is tracked on the branch you moved TO and untracked on the one you came FROM, so `git checkout <original-branch>` DELETES it. If you already discarded the backup, it silently vanishes. Required closing steps:
1. Record `git status --short` BEFORE you start.
2. After returning to the original branch, re-check the file exists.
3. If gone: restore the backup if it differed, else `git show origin/main:<file> > <file>`.
4. Re-run `git status --short` and confirm it matches step 1 exactly.

Leaving the working tree in a different state than you found it is a side effect nobody asked for.

## The Shared Checkout May Host Another Live Agent Session

A single working tree can be edited by several agent sessions at once. Two distinct failures:

**1. `git checkout --` deletes another session's uncommitted WIP.** `git status` shows one `M` per file, not per author. A file can hold your one-line change AND ~50 lines of another session's unrelated work; restoring it to "isolate your edits" deletes theirs.

> **Before `git checkout -- <file>` in a shared tree, run `git diff <file>` and confirm every hunk is yours.** If any hunk isn't, leave the file alone and work in a worktree.

**2. Another session commits YOUR uncommitted files under its own message.** Anything untracked or uncommitted in a shared tree is fair game for another process's `git add`. Your later push is then rejected as non-fast-forward against a commit containing your own work.

> **When another session may share the checkout, do the whole edit in `git worktree add /tmp/wt-<repo> <trunk>` from the start.** Never leave new files untracked in the shared tree.

**Detect a concurrent session BEFORE the first edit, not at commit time:**
```bash
git branch --show-current     # an unexpected branch (e.g. claude/<something>)
git reflog -5                 # checkouts or commits you did not make
git worktree list             # worktrees you did not create
git status --short            # record this; your final state must differ only by your files
```
If any show another session, branch a worktree off trunk immediately. Reconciling afterwards: if the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force your duplicate commit; reset to origin and commit only what is genuinely missing.

### A peer's unpushed commit
If an "unpushed work" gate blocks you on a commit you didn't write:

- **If the peer session is still live, wait.** They may be mid-turn and may still amend.
- **If the commit is genuinely stranded** (the authoring session is gone and the work exists nowhere else), push it rather than waiting or resetting:
  1. **Identify the author and branch:** `git log --format='%h %an %ad %s' @{u}..HEAD` and `git branch --show-current`. Confirm it isn't yours.
  2. **Secret-scan the diff** you're about to publish. You didn't write or review it; a private repo doesn't exempt it.
  3. **Push to the branch it was committed on:** `git push origin HEAD:<that-branch>`. Never redirect a peer's commit to `main`/`master`; that's a scope change you have no mandate for.
  4. **Say so in your final message.** Publishing someone else's work belongs in the report.
- **Never `git reset` a peer's commit to clear a gate.** That destroys work that exists nowhere else.
- Never mark dirty files as "not mine" to silence a gate without proof (`git diff <file>` showing zero hunks of yours, plus your own content already on the remote). Acknowledging work you simply forgot to push is the exact failure such a gate exists to catch.

## A PR Stuck CONFLICTING Is Invisible to Automation

**`gh pr view N --json mergeable` returns `UNKNOWN` on the first poll.** GitHub computes mergeability lazily; only a follow-up read (~6s later) returns the real `MERGEABLE`/`CONFLICTING`. A checker that reads the first response sees nothing actionable and moves on; PRs have sat blocked for days with zero alerts this way. **Anything gating on mergeability must re-poll.**

Diagnosis order when a repo "seems behind on commits":
1. `git status`: a clean tree means it's almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge.

**Merge the default branch INTO the stale branch, never the reverse.** A branch N commits behind will, if pushed onto the default branch, delete everything added there since it forked. Verify losslessness per file before committing a resolution; for append-only files this must print 0 against both parents:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

Duplicate commit subjects with different SHAs on the two sides are the tell that sessions have been cherry-picking around the block; those duplicates usually created the conflict.

**Merging same-file PRs one at a time does not drain a backlog.** Each merge moves the default branch under siblings that touch the same file, turning mergeable PRs conflicting. When N PRs edit the same hotspot file, merge them into a single integration branch, resolve the combined set once, and land that.

**Auto-resolve only what is provably safe.** A union resolver should refuse any hunk where the two sides share a line rather than dedupe by guess, and never union a YAML frontmatter hunk (it produces duplicate keys).

### Trial merges: the legacy 3-arg `git merge-tree` misses conflicts
`git merge-tree $(git merge-base A B) A B` (legacy form) can exit 0 with no conflict markers on a PR GitHub reports as CONFLICTING. Use the modern `git merge-tree --write-tree --name-only <default> <branch>`, or an actual trial merge in an isolated worktree:

```bash
git worktree add /tmp/x FETCH_HEAD --detach && cd /tmp/x && git merge origin/main --no-commit --no-ff
```

Once the conflict is isolated, resolving it, re-running typecheck/tests/build, and pushing to the PR branch is often better than closing: a PR with real hand-written code is worth recovering. (A dependency-bot lockfile PR is the opposite case: close it and let the bot recreate it.)

### Rebasing an append-only log conflict needs chronological reinsertion
When the only conflict is in an append-only narrative log, the two blocks are usually independent entries from different times, not competing edits. Appending the incoming block at the conflict site produces an out-of-order log, because a long-open branch's entries are often OLDER than entries main gained since. Read each block's date/run header, find where it belongs chronologically (possibly well outside the conflict region, e.g. right before a later entry that references it), and move it there. Verify by grepping the file's date headers and confirming they're monotonic.

### A failing CI check is not automatically a merge blocker
When `mergeStateStatus` is `UNSTABLE` because a check failed, read the failure (`gh run view --log-failed`) and compare the files it complains about against the PR's file list. If the same failure reproduces on a fresh checkout of the base branch with none of the PR's changes, it's pre-existing and shouldn't veto an otherwise-eligible merge. Your other merge criteria (verification passed, MERGEABLE, no sensitive paths) still govern.

### A PR whose head branch was deleted while OPEN is stuck at `UNKNOWN` forever
Symptoms: open for hours with green checks, `mergeStateStatus: UNKNOWN`, `gh pr merge` fails "Head branch is out of date", `update-branch` fails "head ref does not exist", and `git ls-remote origin refs/heads/<branch>` is empty. A "must be up to date with base" rule can never pass with no branch to update. The head commit survives at `refs/pull/<n>/head`; recreate the branch from it:

```bash
git ls-remote origin refs/pull/<n>/head                # get <head-sha>
git push origin <head-sha>:refs/heads/<branch-name>
gh api repos/<owner>/<repo>/pulls/<n>/update-branch -X PUT
gh pr merge <n> --squash --delete-branch
```

Check `git ls-remote origin refs/heads/<branch>` before assuming a long-`UNKNOWN` PR is just waiting its turn.

## Run-Numbered Branch Name Collisions
Automation that names branches after a run number (e.g. `claude/learnings-<N>`) can reuse a name that was already squash-merged and deleted. `git merge-base --is-ancestor origin/<branch> origin/main` returns false for a squash-merged branch, so it cannot distinguish "merged" from "exists and diverged". Before creating such a branch, check both:

```bash
git branch -a | grep <branch>                                  # local ref
gh pr list --repo <owner>/<repo> --head <branch> --state all   # previously merged/closed PR
```

If a collision is found, **append a disambiguating suffix** (`<branch>-2`) rather than deleting refs or investigating squash history.

## Commit Identity and Email Privacy

GitHub rejects a push with `GH007: Your push would publish a private email address` (or "push declined due to email privacy restrictions") when a commit's author or **committer** email is a real address and email privacy is on. The failure happens at PUSH time, so a session that only verifies the commit succeeded will report work that never landed.

- Commit as `<username>@users.noreply.github.com`. Never pass a personal email via `-c user.email=...`.
- Check what identity the repo's history uses before committing in an unfamiliar repo: `git log -3 --format=%ae`.
- Recover an already-made commit: `git -c user.email=<username>@users.noreply.github.com commit --amend --no-edit --reset-author`, then re-push. For replayed commits, the committer email on every one must be fixed; pushing from a different machine doesn't help.
- The global `~/.gitconfig` itself can drift off the noreply address. When the ambient identity is wrong, don't "just use the configured identity"; set `GIT_AUTHOR_EMAIL`/`GIT_COMMITTER_EMAIL` for the commit or amend with `--author='<name> <noreply-email>'`. Fixing the global config is the owner's call.

General rule: verify the operation that actually publishes, not the local step before it.

## Scanner Hooks Can Scan the Wrong Range After a Merge or Rebase

- **Pre-commit during a merge:** a hook using plain `git diff --cached` diffs a merge commit against the **pre-merge HEAD**, not the merge-base. Merging current main into a months-stale branch then re-flags all of main's already-approved content as new (dozens of false hits). Hook fix: when `MERGE_HEAD` exists, diff against `$(git merge-base HEAD MERGE_HEAD)`.
- **Pre-push after a rebase:** a hook scanning `$REMOTE_SHA..$LOCAL_SHA` uses the stale pre-rebase tip as `$REMOTE_SHA`. That's no longer an ancestor, so the range spans all of main's landed commits. Re-scan the correct range yourself first, e.g. `git diff origin/main..HEAD | grep '^+' | grep -v '^+++' | <your-scanner>`, before concluding the push is blocked on new content.
- **Either way, do NOT `--no-verify`.** If the false positives can't be resolved, commit new content onto an existing open branch without the in-place merge, and leave the merge to be resolved on GitHub.
- **Hooks are copies.** Hooks installed via `.git/hooks` or `init.templateDir` are copied into each clone; editing the source changes nothing in existing repos. After any hook fix, re-run your installer across all local clones and verify by grepping the INSTALLED copies for a marker from the new code.

## Discrimination Checks: `git stash push` a Directory, Never `git checkout` It

To prove a regression test discriminates, you revert the fix, re-run the suite, and expect failures. Reverting with `git checkout -- <dir>` DESTROYS an uncommitted fix; working-tree files have no reflog, so the only recovery is redoing every edit by hand.

Use `git stash push -- <dir>`, then `git stash pop`. It's safe whether or not the fix is committed. For a partially-committed branch:

```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
<run suite, record failures>
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```
