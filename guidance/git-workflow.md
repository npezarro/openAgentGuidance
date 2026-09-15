<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main` (or whatever the default branch is).
- Use the branch you were assigned. If there isn't one, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Don't use `test-` as a branch prefix.** Some repos have rulesets or branch protection that silently reject pushes to `test-*` branches. You get no error; the branch just never shows up on the remote. Use names like `add-tests-<module>` or `<module>-tests-<run>` instead.
- Commit messages should explain **why**, not just what. Large commits are fine, so don't split work up artificially.
- Before committing:
  1. Run `git status` to check that no unintended files are staged.
  2. Run `git diff` to review the actual changes.
  3. Confirm no `.env`, secrets, or key files are included.
  4. **Update `context.md`**. This is required on the final commit of a branch (before you open a PR) or at session wrap-up, but not on every intermediate commit. It records current state, open items, and what the next agent needs to know.
  5. **Update `progress.md`** with an entry for the work you're committing.
- Push with `git push -u origin HEAD`. Retry network failures up to 4 times with backoff (2s, 4s, 8s, 16s). Don't retry auth failures.

## All Deliverables Go in Repos
Scripts, tools, project assets, analysis docs, reference files and any other output **always go in a git repo** that is pushed to the remote. Never leave files lying loose on the filesystem. The remote is the source of truth. If a new project or tool set has no repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions often create useful files (summaries, configs, scripts, reference docs), then forget to commit, forget to push, or save them outside a repo. Local-only files can't be reached from later sessions. Until a file is committed and pushed, treat every write or edit as unfinished.

## Every Repo Gets a README and Description
Every repo needs a `README.md` and a remote repo description. If you create a repo, or work in one that lacks either, add them.

- **README.md**: what the project does (1-2 sentences), how to set it up, and how to run or use it. Keep it short. A developer should understand the project in 60 seconds.
- **Repo description**: set it with `gh repo edit <owner>/<repo> --description "one-line summary"`. Write one sentence; it shows on the repo page and in search results.

Both are required when you run `gh repo create`. Pass the `--description` flag at creation and include the README in the initial commit.

## Always Commit and Push Written Files
When you create or change files in a repo, **commit and push in the same step**. Don't move on while untracked or uncommitted files sit in the repo.

When you commit, **always push to the remote branch too**. Unpushed commits are invisible to other sessions, collaborators and the deploy pipeline. Treat write + `git commit` + `git push` as one atomic operation. If any step fails, find the cause and fix it before you continue.

**Common gap:** when a session spans several repos, it's easy to push some and forget others. After a multi-repo task, run `git status` in each repo to confirm it's clean.

## Staging Hygiene (ANY repo with in-flight work)

**This applies to every repo, not just ones you know are shared.** Any checkout can hold uncommitted work from an earlier session, and a blanket add quietly ships that work under your commit message.

Lesson: in a repo nobody thought of as shared, a `git add -A` swept a half-finished adapter, a scrape script and a settings change into an unrelated commit. A `git show --stat` review before pushing caught it. The rule already existed, but it had been scoped in a way that made it look like it didn't apply.

The check is cheap and always required: **run `git status` BEFORE staging.** If the tree holds anything you didn't touch, stage your paths by name.

- **Stage explicit paths. Never use `git add -A` or `git add .`** in any repo. A blanket add pulls whatever another agent left uncommitted into *your* commit, and that can include secrets. Name the files you touched: `git add guidance/foo.md scripts/bar.sh`.
- **Never use `--no-verify` on a public repo.** A pre-commit sensitive-identifier scanner is the last defense before a username, internal path or token lands on a public remote. Bypassing it is how leaks ship. If the scanner blocks you, remove the identifier from the content; don't override the scanner.
- **Before committing, run `git status` and confirm ONLY your files are staged.** If you see files you didn't touch, unstage them with `git restore --staged <path>`. They belong to another agent.

## Creating PRs (with retry)

After `git push`, GitHub can take a few seconds to register the branch. Check that the branch exists on the remote before you create the PR, and retry on failure:

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

**Never fall back to a "create manually" URL.** If `gh pr create` still fails after 3 retries, work out the cause (auth, branch not found, network) and fix it. Don't tell the user to create the PR by hand.

- Don't enable auto-merge unless someone explicitly asks for it.

## GitHub API PR Creation: Qualify the Head Parameter

If you create PRs through the GitHub REST API (for example with Octokit) instead of `gh pr create`, the `head` parameter must be fully qualified as `owner:branch`, not just `branch`.

```js
// WRONG: causes "invalid head" errors, especially on newly-pushed branches
await octokit.rest.pulls.create({ head: branch, ... });

// CORRECT: qualify with the repo owner
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

**Why:** GitHub needs a few seconds to index a newly pushed branch. Unqualified branch names fail more often during that window, and qualifying with the owner makes the ref lookup unambiguous.

**Also:** in automation, wait about 3s after a push event before calling `pulls.create`, allow up to 5 attempts, and retry on "invalid head" errors. The `gh pr create` CLI qualifies the head for you; this only matters when you call the REST API directly.

## If Your Repos Use an Auto-Merge Bot

Some setups run a bot that opens a PR and squash-merges it within seconds of a branch being pushed. If yours does:

- **"No commits between main and `<branch>`" or "Head sha can't be blank" from `gh pr create` right after a push means success.** The bot already opened and merged the change. Find its PR with `gh pr list --state all --head <branch>` and use that number. Don't re-push or open a duplicate: a retry can produce a second merged PR for the same change, which makes history misleading.
- **Verify by content, not ancestry.** A squash commit is not an ancestor of your local commit, so `git merge-base --is-ancestor` and `git branch --merged` report "unmerged" even though the change landed. Check instead:
  ```bash
  git fetch origin && git log --oneline -3 origin/main
  git diff HEAD origin/main -- <paths> --stat   # empty == merged content is identical
  ```
  When you verify added lines with grep, use `grep -Fqx -- "$line"`. Without the `--`, a line that starts with `-` (such as a markdown bullet) is read as a grep option and the check gives false negatives.
- **Put follow-up fixes on a FRESH branch off main.** After the bot deletes the merged branch, a second commit pushed to the same name conflicts every time, because main has one squashed commit while your branch still has the originals. Instead: `git checkout -b <new> origin/main`, `git checkout <old-branch> -- <only the changed files>`, commit, push, and close any stale PR. Confirm the push landed with `git ls-remote --heads origin <branch>`; the local `origin/<branch>` ref goes stale as soon as the bot deletes the branch.
- **Default is often opt-out: every non-draft PR from any pushed branch gets merged.** That includes design or experimental branches never meant for main. For a branch that shouldn't merge yet, convert its PR to draft right after pushing (`gh pr ready <n> --undo`). If the bot supports a repo denylist or commit-message overrides (for example `[no-automerge]`), add product repos with real human or design branches to the denylist *before* their first push, not after an unwanted merge.
- **Resolve the default branch; don't assume it.** Some repos use `master`. Use `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
- **Automation that creates PRs must confirm they actually merged.** Logging "PR: <link>" isn't enough. As the session's last step, run `gh pr view <n> --json state,mergeable`, and merge right away if it's MERGEABLE with passing CI. Otherwise verified fixes can sit unmerged for days.

## Branch Hygiene

PRs left open and unmerged cause cascading merge conflicts across every other branch. **This is the #1 cause of stuck work.** To prevent it:

- **Merge PRs promptly.** If a PR is ready and needs no review, merge it in the session that created it: `gh pr merge <number> --merge --delete-branch`. If the merge fails (conflict, checks pending), retry once after 5s. If it fails again, report the specific error.
- **Rebase before opening a PR.** Run `git fetch origin && git rebase origin/main` and resolve conflicts before you push. A PR should be mergeable when it's created.
- **One branch per task.** Don't create several branches for one feature or leave abandoned branches behind.
- **Clean up stale branches.** At session start, check `gh pr list --state open` and `git branch -a`. If a branch has sat for more than a few days with no activity, rebase and merge it, or close it.
- **Prune remote-tracking refs before scanning.** Run `git remote prune origin` (and the same for any other remotes) before listing branches with `git branch -a` or `git branch -r`. Without pruning, refs for branches already deleted on the remote stick around locally and inflate "open branch" counts.
- **Cap and dedup gates in automation MUST use `git ls-remote`, not `git branch -r`.** `git branch -r` reads local tracking refs, which only refresh on fetch and can be stale even when you prune in the same script. To know which branches exist on the remote *right now*, ask the remote: `git ls-remote --heads origin 'claude/auto-*'`.
- **In a forked checkout, always pass `--repo <owner>/<name>` to `gh`.** If a repo has both `origin` (your fork) and `upstream` (the canonical project), bare `gh pr view <n>` can resolve against `upstream`. A PR number that exists upstream will look valid even though you don't control it. Before you view, merge, close or comment on anything in a checkout that might be a fork, use an explicit `--repo`. The risk isn't a bad merge decision; it's acting on a repo you don't own.
- **Don't leave PRs for someone else to merge** unless the task explicitly requires review. Unmerged PRs are invisible debt that grows with every new branch.
- **Keep `context.md` and `progress.md` edits out of branches that other branches also touch.** These files conflict constantly. If you must update them, make that the very last commit before merging, after rebasing on main.
- **If a merge fails with code conflicts on a stale branch** that holds no hand-written content worth saving, close the PR, delete the branch, and redo the work on a fresh branch from main. If the branch *does* hold real code, resolve the conflict in an isolated worktree, verify (typecheck, tests, build), push, and merge. Closing it throws the work away. Closing and recreating is right for generated content like dependency lockfile PRs.
- **MERGEABLE doesn't mean non-redundant.** A feature PR can show MERGEABLE while its whole patch is already on main, for example when another PR that branched off it carried the code in. Before merging a PR that looks ready, run `git rebase origin/main` in a throwaway checkout. If the commit is dropped ("patch contents already upstream") or `git diff origin/main <tip>` is empty, close the PR as superseded (`gh pr close <N> --delete-branch --comment "Superseded by ..."`).
- **Read a merged PR's body before rejecting a similar change as a duplicate.** An explicit "out of scope / follow-up" note makes the candidate sanctioned follow-up work, and the merged PR often ships helpers the follow-up should reuse. Cite the scope note in the new PR body.
- **An UNSTABLE merge state with a failing CI check isn't automatically a blocker.** Run `gh run view --log-failed` and compare the failing files against the PR's diff. If the same failure reproduces on a fresh checkout of the base branch, it came before this PR and has nothing to do with it, so it shouldn't veto an otherwise eligible merge.

## Staging Changes in Hook-Executing Repos: Use Worktrees, Not Branch Checkouts

**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is referenced by live hooks, SessionStart scripts or process-manager configs.** The harness runs directly from those paths. Switching the branch silently swaps all guidance, hooks and config to whatever the target branch holds: new rules vanish, retired rules come back, hooks behave differently. That affects every concurrent session and every agent that runs during or after the switch, and nothing warns you.

**The safe pattern is a worktree:**

```bash
# Stage changes for review without touching the main checkout
git -C <repo> worktree add /tmp/wt-<repo> -b claude/<task>
# ... make edits, commit, push, open PR from inside /tmp/wt-<repo> ...
git -C <repo> worktree remove /tmp/wt-<repo>
# Main checkout stays on main throughout; hooks keep running from live state
```

**Repos that require worktrees:** any repo whose working-copy path appears in a hook, a SessionStart command, or a process-manager config that loads files at runtime.

**A worktree that pushes straight to the default branch** (for example, an append-only log) must stay detached. Never run `checkout -B <default-branch>` inside it, because that collides with the primary checkout's branch.

### Rescuing an existing branch with `git worktree add <path> <branch>` can pick up a stale local ref

`git worktree add /tmp/wt -b <new>` always creates a fresh branch. But `git worktree add /tmp/wt <existing-branch>` (bare name) resolves to the **local** ref. For a long-lived branch that earlier sessions updated only from worktrees pushing straight to origin, that local ref can be weeks behind `origin/<branch>`. Merging main into the stale ref then shows phantom conflicts that were already resolved on origin, and any resolution you push gets rejected as non-fast-forward.

**Fix:** before creating the worktree, compare `git rev-parse <branch> origin/<branch>`. If they differ, fast-forward the local ref first with `git branch -f <branch> origin/<branch>`. That's safe because the ref is only a bystander pointer and the main checkout stays on main.

### Merge a worktree branch from the primary checkout

- `git checkout main` *inside* a worktree fails with "fatal: 'main' is already used by worktree at ...". Running `git worktree remove` while your cwd is inside that worktree leaves the shell with no working directory.
- **Sequence:** commit in the worktree, run `COMMIT=$(git rev-parse HEAD)`, `cd` to the primary checkout, run `git merge --ff-only $COMMIT`, push, then `git worktree remove <path>` from the primary checkout.

## Commit Identity: Verify the Step That Publishes

- **Never pass an explicit personal email** (`-c user.email=...`). With email privacy on, GitHub rejects the push with `GH007: Your push would publish a private email address` or "push declined due to email privacy restrictions". It fails at **push** time, so a session that only checks the commit succeeded will report work that never landed.
- Let git use the repo's configured identity, usually `<username>@users.noreply.github.com`. In an unfamiliar repo, run `git log -3 --format=%ae` to see which identity its history uses.
- To recover a commit that was already made: `git -c user.email=<username>@users.noreply.github.com commit --amend --no-edit --reset-author`, then push again.
- The rejection checks the **committer** email of every commit being pushed, not only the author. It follows the commits, so pushing from another machine doesn't help. Rewrite the identity on each affected commit.

## Remote Checkouts May Hold Commits That Exist Nowhere Else

Before running `git pull` or `git reset` in a checkout you don't own (a server, a container, another machine), check whether it's **ahead** of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

A non-zero count means the checkout holds commits that may exist nowhere else, and `git reset --hard origin/<branch>` would destroy them for good. A `git pull` that conflicts is a *signal* to investigate, not an obstacle to force past.

When you find divergence:

1. **Back it up before touching anything.** Run `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup`, and copy the bundle off the machine. A branch on one host isn't a backup. This costs nothing and makes every later step safe.

2. **Find out whether those commits hold unique content. Do NOT trust the commit subjects.**

   ```bash
   git diff --stat origin/main..<backup-branch>     # net direction of the delta
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"  # its unique source lines
   ```

   Then check each feature the subjects claim **in the upstream tree**: `git grep -n "<feature>" origin/main -- src/`.

   A branch can be "7 commits ahead" and still be strictly poorer. It may be early work that upstream later reimplemented properly through squashed or re-authored PRs, so the SHAs never match. Lesson: a checkout whose subjects promised atomic writes, scheduling, log rotation and alerting turned out to have zero unique files and a net diff of thousands of lines *removed*. Every claimed feature was present upstream in a better form. The reset was the correct call, and the first cautious read ("cherry-pick, never reset") was wrong.

3. **Then choose based on that evidence:**
   - *Superseded fork* (no unique content): `git reset --hard origin/<branch>`. This is safe when runtime state is gitignored. Check what the code actually writes (`output/`, `*.log`, caches) and confirm any tracked data file is read-only config, not state.
   - *Genuinely unique content*: port it onto a branch off `origin/main`, commit under a valid identity, push, and only then reset the remote checkout. Don't leave the work stranded.
   - *Need one fix now, reconcile later*: cherry-pick onto that checkout's HEAD (`git fetch origin main && git cherry-pick <sha>`). Conflicts are usually files that didn't exist on the older HEAD: `git add` the incoming version and `--continue`. This is a stopgap, not a resolution.

   Afterwards, run the repo's tests **on that host**. A big jump in test count is a good sign you recovered real work.
4. **Record the outcome in that checkout's own `context.md`** (a warning if unresolved, a RESOLVED note if reconciled) and commit it there. Docs committed upstream are invisible to a checkout that's far behind, so the note has to live where the next session will read it.
5. **Report the divergence as an open item.** Reconciling it is the owner's decision.

Restore from a bundle with:
```bash
git fetch /path/to/x.bundle <name>-backup:<name>-backup
```

## Untracked File Shadowing a Tracked Path: Use a Worktree, Never rm

A repo can hold an UNTRACKED file at a path that IS tracked on origin/main. `git checkout -b <new> origin/main` then aborts with "untracked working tree files would be overwritten by checkout".

**Don't rm or mv the blocking file to get unblocked.** If you didn't create it, it may be someone else's uncommitted notes, and deleting it to land an unrelated commit destroys them.

Commit through a worktree instead, since it never touches the dirty tree:
```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

**If you moved the file aside anyway, the mv is only half the procedure.** The file is tracked on the branch you moved TO and untracked on the branch you came FROM, so `git checkout <original-branch>` DELETES it from the working tree. If you've already thrown away the backup, the file silently disappears. Required steps:
1. Record `git status --short` BEFORE you start.
2. After returning to the original branch, check the file still exists.
3. If it's gone: restore your backup if it differed, else `git show origin/main:<file> > <file>`.
4. Run `git status --short` again and confirm it matches step 1 exactly.

Leaving the working tree different from how you found it is a silent side effect nobody asked for. Verify it; don't assume.

## The Shared Checkout May Host Another Live Agent Session

One working tree can be edited by several agent sessions at the same time. Two failures come from assuming you own it:

**1. `git checkout --` deletes another session's uncommitted work.** `git status` shows `M <file>` as a single entry, but the file can hold your one-line change *and* many lines of another session's unrelated, uncommitted work. Restoring the file wipes out both.

> **Before `git checkout --` on any file in a shared tree, run `git diff <file>` and confirm every hunk is yours.** An `M` in `git status` is one flag for the whole file, not proof that you wrote all of it. If any hunk isn't yours, leave the file alone and work in a worktree.

**2. Another session commits YOUR uncommitted files under its own message.** An untracked file you created in the shared checkout can be `git add`-ed and pushed by a concurrent session. Your later push is then rejected as non-fast-forward, and the "conflicting" commit turns out to be byte-identical to your work. Anything uncommitted in a shared tree is fair game for another process running `git add`.

> **If another session may share the checkout, do the whole edit in `git worktree add /tmp/wt-<repo> <trunk>` from the start.** Never leave new files untracked in the shared tree.

**Detect a concurrent session BEFORE your first edit, not at commit time:**
```bash
git branch --show-current     # an unexpected branch (e.g. claude/<something>)
git reflog -5                 # checkouts or commits you did not make
git worktree list             # worktrees you did not create
git status --short            # record this; your final state must differ only by your files
```
If any of these show another session, branch a worktree off trunk right away and never touch the shared tree. To reconcile afterwards: if the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force your duplicate commit. Reset to origin and commit only what's genuinely missing.

### A peer's unpushed commit

If a push gate or check flags unpushed commits, first confirm they're yours: `git log --format='%h %an %ad %s' @{u}..HEAD`. If the gate fires on a commit that contains a file *you* wrote, push it.

If the commit belongs to another session:
- **If that session is still live, wait.** It may be mid-turn and may still amend the commit.
- **Only if the commit is genuinely stranded** (the authoring session is gone and the work exists nowhere else) should you publish it:
  1. Identify the author and branch (`git branch --show-current`). Confirm the commit isn't yours before touching it.
  2. **Secret-scan the diff** you're about to publish. You didn't write or review it, and a private repo doesn't exempt it.
  3. **Push to the branch it was committed on**: `git push origin HEAD:<that-branch>`. Never redirect a peer's commit to the default branch. They chose that branch, and landing it on mainline is a scope change you have no mandate for.
  4. **Say so in your final message.** You published someone else's work, and that belongs in the report.

**Never `git reset` a peer's commit to clear a gate.** That destroys work that exists nowhere else. The same goes for any "acknowledge and skip" mechanism for dirty files: use it only after proving with `git diff <file>` that no hunk is yours and that your own content is already on the remote. Acknowledging work you simply forgot to push is exactly the failure such gates exist to catch.

## A PR Stuck CONFLICTING Is Invisible to Automation

**`gh pr view N --json mergeable` returns `UNKNOWN` on the first poll.** GitHub computes mergeability lazily. The first read of a PR that hasn't been checked recently is usually `UNKNOWN`, and only a second read (about 6s later) returns the real `MERGEABLE` or `CONFLICTING`. A checker that trusts the first response sees nothing to act on and moves on, which is how conflicting PRs sit for days with no alert. **Anything that gates on mergeability must poll again.**

Diagnosis order when a repo "seems behind":
1. `git status`. A clean tree means it's almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge.

**Don't trust the legacy 3-arg `git merge-tree <base> <a> <b>`.** It can exit 0 with no conflict markers when a real merge does conflict. Use the `--write-tree` form above. If in doubt, do an actual trial merge in an isolated worktree: `git worktree add /tmp/x <branch> --detach && cd /tmp/x && git merge origin/main --no-commit --no-ff`.

**Merge the default branch INTO the stale branch, never the other way.** A branch that's N commits behind will, if pushed onto the default branch, delete everything added there since it forked. Before committing a resolution, verify per file that nothing was lost. For append-only files this must print 0 against both parents:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

Duplicate commit subjects with different SHAs on the two sides mean sessions have been cherry-picking around the block. Those duplicates are usually what caused the conflict.

**Merging same-file PRs one at a time doesn't drain a backlog.** Each merge moves the default branch under the sibling PRs that touch the same file, so ones that were mergeable become conflicting. When N PRs edit the same hotspot file, merge them into a single integration branch, resolve the combined set once, and land that.

**Auto-resolve only what's provably safe.** A union resolver should refuse any hunk where both sides share a line rather than guess at deduplication, and it should never union a YAML frontmatter hunk (that produces duplicate keys).

### Rebasing an append-only log conflict: reinsert chronologically

When the only conflict in a rebase is inside an append-only narrative log, the two blocks are usually independent entries from different dates, not competing edits. Resolving by keeping one block and tacking the other on at the conflict site leaves the log out of order: a long-open branch's entries are often OLDER than entries main gained after the branch diverged. Main may even contain later entries that reference the incoming content, so the correct position can be well outside the conflict markers.

**Fix:** read each block's date or run-number header, move the block to where it belongs chronologically, then grep the file's entry headers and confirm they're in monotonic order. Also grep for cross-references to the incoming content and confirm they now come after the entry they point to.

## Run-Numbered Branch Name Collisions

A branch is named after the run that *created* it. A later run that reuses the same numeric stem can collide with it. You'll see `git worktree add ... -b <branch>` fail with "already exists", or worse, a local ref that points somewhere old.

**Before creating any run-numbered branch, check both:**
1. `git branch -a | grep <branch>` catches a local ref.
2. `gh pr list --repo <owner>/<repo> --head <branch> --state all` catches a branch that was squash-merged and deleted but whose name is being reused.

`git merge-base --is-ancestor origin/<branch> origin/main` returns false for a squash-merged branch, so it can't tell "merged" apart from "exists and diverged". The `gh pr list --state all` check is the reliable one.

**If you find a collision, add a suffix** (`<branch>-2`) rather than deleting refs or digging through squash history under time pressure.

## Discrimination Checks: `git stash push` a Directory, Never `git checkout` It

To prove a regression test really discriminates, you revert the fix, rerun the suite, and expect failures. Reverting with `git checkout -- <dir>` DESTROYS an uncommitted fix. Working-tree files have no reflog, so the only way back is re-applying every edit by hand.

Use `git stash push -- <dir>` instead. It reverts just as cleanly, and `git stash pop` restores the work exactly. It's safe whether or not the fix is committed, so make it the default.

For a branch where part of the fix is committed:
```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
# run suite, record failures
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```

## Scanning Hooks and Rewritten History: Check the Diff Range

Sensitive-identifier hooks can report false positives in bulk after merges and rebases, because they scan the wrong range:

- **Pre-commit on a merge commit:** `git diff --cached` with no base diffs against the pre-merge HEAD (the stale branch's tip), not the merge-base. All of main's already-approved content gets flagged as new. The hook fix is to use `$(git merge-base HEAD MERGE_HEAD)` as the diff base when `MERGE_HEAD` exists.
- **Pre-push after a rebase:** the hook scans `$REMOTE_SHA..$LOCAL_SHA`, where `$REMOTE_SHA` is the stale, pre-rebase remote tip. Rebasing rewrote history, so that ref is no longer an ancestor, and the range spans all of main's landed commits.

**What to do:**
- **Don't use `--no-verify`.** Bypassing the scanner for one merge turns off the last line of leak defense.
- Re-scan the correct range yourself to isolate genuine hits: `git diff origin/main..HEAD | grep '^+' | grep -v '^+++'`, piped into your scanner. If hits remain, check whether they're already present verbatim on main.
- If the hook can't be fixed right away, commit new content onto a branch without merging main locally, and resolve conflicts through the hosting platform's UI.
- **Hooks are copies in each clone's `.git/hooks`** (and in `init.templateDir` if you use one). Editing the source changes nothing until you reinstall the hooks everywhere. After a hook fix, verify by grepping the *installed* copies for a marker from the new code, not by reading the source.
