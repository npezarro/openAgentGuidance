<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main` (or whatever the default branch is).
- Use the branch assigned to you. If none exists, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Avoid `test-` as a branch prefix.** Some repos have GitHub rulesets or branch protection that silently reject pushes to `test-*` branches: there is no error, and the branch just never appears on the remote. Use descriptive names like `add-tests-<module>` or `<module>-tests-<run>` instead.
- Commit messages explain **why**, not just what. Large commits are fine; don't split work artificially.
- Before committing:
  1. `git status` to verify no unintended files are staged.
  2. `git diff` to review the actual changes.
  3. Confirm no `.env`, secrets, or key files are included.
  4. **Update `context.md`** (the repo's handoff notes for the next agent: current state, recent changes, open items). This is mandatory on the final commit of a branch (before creating a PR) or at session wrap-up. It is not required on every intermediate commit.
  5. **Update `progress.md`**: add an entry for the work being committed.
- Push: `git push -u origin HEAD`. Retry network failures up to 4 times with backoff (2s, 4s, 8s, 16s). Do not retry auth failures.

## All Deliverables Go in Repos
When creating scripts, tools, project assets, analysis docs, reference files, or any other output, **always put them in a git repo** and push to GitHub. Never leave files as loose filesystem artifacts; the user should not have to dig around the filesystem for deliverables. GitHub is the source of truth. If a new project or tool set doesn't have a repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions routinely create useful files (summaries, configs, scripts, reference docs) and then forget to commit, forget to push, or save them outside a repo. The user cannot access local-only files between sessions. Treat every file write as incomplete until the file is committed and pushed.

## Every Repo Gets a README and Description
Every repo must have a `README.md` and a GitHub repo description. When creating a new repo, or working in one that's missing either, add them.

- **README.md**: what it does (1-2 sentences), how to set it up, and how to run or use it. Keep it concise; a developer should understand the project in 60 seconds.
- **GitHub description**: set via `gh repo edit <owner>/<repo> --description "one-line summary"`. A single sentence that appears on the repo page and in search results.

Both are required when running `gh repo create`. Use the `--description` flag on creation and add the README in the initial commit.

## Always Commit and Push Written Files
When creating or modifying files in any repo, **commit and push in the same step**. Don't move on to other work with untracked or uncommitted files sitting in a repo. Writing a file does not commit it; you must do that explicitly.

When committing to any repo, **always push to the remote branch too**. Unpushed commits are invisible to other sessions, collaborators, and the deploy pipeline. Treat file creation + `git commit` + `git push` as one atomic operation; if any step fails, diagnose and fix it before moving on.

**Common gap:** when working across several repos in one session, it's easy to push some and forget others. After a multi-repo task, run `git status` in each one and confirm all are clean.

## Staging Hygiene (any repo with in-flight work)

Some repos are worked by many agents at once (interactive sessions, scheduled agents, doc-sync jobs). **This is not a "shared repo" rule; it applies to every repo.** Any checkout can hold uncommitted work from a previous session, and a blanket add silently ships it under your commit message. A repo that is not on anyone's "shared" list is exactly where this bites: a `git add -A` can sweep someone's half-finished feature into your unrelated fix.

The check is cheap and unconditional: **run `git status` BEFORE staging.** If the tree holds anything you didn't touch, name your paths explicitly.

- **Stage explicit paths; never `git add -A` or `git add .`** A blanket add sweeps whatever another agent left uncommitted into *your* commit, and can stage a secret along with it. Name the files you touched: `git add docs/foo.md scripts/bar.sh`.
- **Never `--no-verify` on a public repo.** A pre-commit sensitive-identifier scanner is the last line of defense before a username, internal path, or token reaches a public repo. Bypassing it is how leaks ship. If the scanner blocks you, sanitize the content; don't override.
- **Before committing, run `git status` and confirm ONLY your files are staged.** Unstage anything you didn't touch with `git restore --staged <path>`; it belongs to someone else.
- **Review before pushing:** `git show --stat HEAD`. If the commit contains files you didn't intend, `git reset HEAD~1` (soft) and re-commit with explicit paths.

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

# 2. Check for an existing PR on this branch
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

When creating PRs via the GitHub REST API (for example, Octokit) instead of `gh pr create`, the `head` parameter must be fully qualified as `owner:branch`, not just `branch`.

```js
// WRONG: causes "invalid head" errors, especially on newly-pushed branches
await octokit.rest.pulls.create({ head: branch, ... });

// CORRECT: qualify with the repo owner
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

**Why:** GitHub needs a few seconds to index a newly-pushed branch. Unqualified branch names fail more often during that window; qualifying with the owner disambiguates the ref lookup.

**Also:** add a ~3s delay before calling `pulls.create` after a push event, set `maxAttempts` to 5, and retry on "invalid head" errors.

`gh pr create` handles head qualification internally. This only applies when calling the REST API directly (for example, in a merge bot).

## Working With an Auto-Merge Bot

If your repos run a bot that opens and squash-merges PRs for pushed branches, adjust the workflow:

- **Just push; don't race the bot.** The reliable pattern is `git push` and let the bot open and merge the PR. After the push, the remote branch vanishing and `gh pr create` failing with "No commits between main and `<branch>`" or "Head sha can't be blank" is **success**, not failure. Find the bot's PR with `gh pr list --state all --head <branch>` and reuse that number.
- **Do not retry the push.** A retry can produce a second PR that also merges: two merged PRs for one logical change is misleading history even when the diffs are identical.
- **Verify by content, not ancestry.** A squash commit is NOT an ancestor of your local commit (`git merge-base --is-ancestor <mine> origin/main` returns false, and `git branch --merged` reports your branch as unmerged). Check content instead:
  ```bash
  git fetch origin && git log --oneline -3 origin/main
  git cat-file -e origin/main:<path> && echo "landed on main"
  git diff <mine> origin/main -- <paths> --stat   # empty == merged content is identical
  ```
  When verifying added lines with grep, use `grep -Fqx -- "$line"`. Without `--`, any added line starting with `-` (a markdown bullet) is parsed as a grep option and verification silently reports false negatives.
- **Don't assume the default branch is `main`.** Some repos use `master`. Resolve it with `gh repo view --json defaultBranchRef -q .defaultBranchRef.name`.
- **A bot that merges every non-draft PR by default is dangerous for design or human-review branches.** If the bot is opt-out rather than opt-in, pushing a branch you don't want merged yet is not safe. Immediate mitigation: convert the PR to draft right after pushing (`gh pr ready <n> --undo`); draft PRs should never auto-merge. Durable fix: give the bot a repo-level denylist, plus per-commit overrides in the head commit message (for example `[automerge]` to force, `[no-automerge]` to suppress). Add any product or design repo to the denylist before its first non-trivial push, not after a merge-and-revert.
- **Keep the bot away from branches that have their own verification gate.** If another automation creates `fix/*`-style branches and must verify them before merge, make sure the bot recognizes those prefixes as a separate lane, or it will blind-merge them on push before verification runs.
- **In a shared checkout that can switch branches mid-operation**, don't trust the ambient staging area for a clean single-file commit. Build the commit via a temp index (`GIT_INDEX_FILE=<tmp> git read-tree` + `git commit-tree`) and push via an explicit refspec (`git push origin <sha>:refs/heads/<branch>`) instead of relying on the checkout's HEAD.

## Branch Hygiene

Open PRs that sit unmerged cause cascading merge conflicts across all other branches. **This is the #1 cause of stuck work.**

- **Merge PRs promptly.** When a PR is ready and has no review requirement, merge it in the same session: `gh pr merge <number> --merge --delete-branch`. If the merge fails (conflict, checks pending), retry once after 5s. If it still fails, report the specific error.
- **Verify your own PR actually merged before ending the session.** Automation that logs "PR: <link>" and stops can leave verified fixes sitting MERGEABLE + CI green for days. As the last step, run `gh pr view <n> --json state,mergeable` and merge it then if it is ready. Don't rely on a later sweep as a merge backstop.
- **Rebase before opening a PR.** `git fetch origin && git rebase origin/main`, resolve conflicts, then push. A PR should be mergeable when it is created.
- **One branch per task.** Don't create multiple branches for the same feature or leave abandoned branches behind.
- **Clean up stale branches.** At session start, check `gh pr list --state open` and `git branch -a`. If a branch has been open more than a few days without activity, rebase and merge it or close it.
- **Prune remote-tracking refs before scanning.** Run `git remote prune origin` before enumerating with `git branch -a` or `git branch -r`. Without pruning, refs for branches already deleted on GitHub stay local and inflate "open branch" counts (half the "open" branches in a scan can be phantoms).
- **Automation cap/dedup gates MUST use `git ls-remote`, not `git branch -r`.** Local tracking refs are only refreshed on fetch and are racy even with pruning. For cap checks and backlog gates, query the remote directly: `git ls-remote --heads origin 'claude/auto-*'`. Stale tracking refs can otherwise trigger "backlog cleanup" mode when zero real branches are open.
- **`gh` in a forked checkout can silently resolve against `upstream` instead of `origin`.** In a checkout with both `origin` (your fork) and `upstream` (the canonical project), bare `gh pr view <n>` may hit the upstream repo, and a PR number that happens to exist there looks valid. **Always pass `--repo <owner>/<name>` explicitly** before viewing, merging, closing, or commenting on a PR in a possibly-forked checkout. The danger isn't a bad merge decision on your repo; it's acting on a repo you don't control. Also don't infer ownership from branch-name patterns alone; check the PR author.
- **Don't leave PRs for someone else to merge** unless the task explicitly requires review. Unmerged PRs are invisible debt that compounds with every new branch.
- **Don't modify `context.md` or `progress.md` on a branch that other branches also modify** until the very last commit before merging, after rebasing on main. These files conflict constantly.
- **If a merge fails with complex code conflicts on a stale throwaway branch:** close the PR, delete the branch, and redo the work on a fresh branch from main. Exception: if the branch holds real hand-written code, isolate the conflict (see "Legacy merge-tree" below), resolve it, verify with build and tests, and merge, rather than closing and losing the work. Closing is right for generated changes like dependency-bot lockfile PRs, where the bot will recreate them.
- **Follow-up fixes after an auto-merge go on a FRESH branch off main.** If the bot squash-merged and deleted your branch, pushing another commit to that same branch conflicts every time (main holds one squashed commit; your branch holds the originals from the same base). Instead: `git checkout -b <new> origin/main`, then `git checkout <old-branch> -- <only the changed files>`, commit, push, close the stale PR. Verify a push landed with `git ls-remote --heads origin <branch>`, not the local `origin/<branch>` ref, which goes stale the moment the bot deletes the branch.
- **MERGEABLE does not mean non-redundant.** A feature PR can show MERGEABLE while its entire patch is already on main (for example, a doc-update PR branched off the feature branch and carried the code in). Before merging a "ready" PR, rebase it onto `origin/main` in a throwaway checkout: if the commit is dropped as "patch contents already upstream", or `git diff origin/main <tip>` is empty, close it as superseded (`gh pr close <N> --delete-branch --comment "Superseded by ..."`) instead of producing a duplicate merge.
- **A merged PR's "out of scope / follow-up" note is sanctioned work, not a dedup blocker.** When candidate work looks like a duplicate of a recently merged PR, read that PR's body first. An explicit follow-up note makes the candidate pre-vetted work, and the merged PR often ships helpers the follow-up should reuse. Cite the note in the new PR body.

## Staging Changes in Hook-Executing Repos: Use Worktrees, Not Branch Checkouts

**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is referenced by live hooks, SessionStart scripts, or a process manager config** (for example, this repo if your harness loads guidance from its working copy). The harness executes directly from those paths. Switching the branch silently reverts all guidance, hooks, and config to whatever the target branch holds, for every concurrent session and every agent that runs during the switch. There is no error and no warning.

Use a worktree instead:

```bash
# Stage changes for review without touching the main checkout
git -C <repo> worktree add /tmp/wt-<repo> -b claude/<task>
# ... edit, commit, push, open PR from inside /tmp/wt-<repo> ...
git -C <repo> worktree remove /tmp/wt-<repo>
# The main checkout stays on main throughout; hooks keep running from live state
```

**A worktree that pushes directly to the default branch** (for example, an append-only log) must stay detached. Never `checkout -B <default-branch>` inside it; that collides with the primary checkout's own branch.

### Merge a worktree branch from the primary checkout
`git checkout main` inside a worktree fails with "fatal: 'main' is already used by worktree at ..." because the primary checkout holds it. And running `git worktree remove` while your cwd is inside that worktree leaves the shell with no working directory.

Sequence: commit in the worktree -> `COMMIT=$(git rev-parse HEAD)` -> `cd` to the primary checkout -> `git merge --ff-only $COMMIT` -> push -> `git worktree remove` from the primary checkout.

### Refresh a stale local ref before `git worktree add <existing-branch>`
Creating a worktree with `-b <new-branch>` is always fresh. But rescuing an existing long-lived PR branch with `git worktree add /tmp/wt <existing-branch>` resolves the bare name to the **local** ref, which may be weeks behind `origin/<branch>` if every previous rescue worked in a worktree and pushed straight to origin. You then see phantom conflicts that were already resolved upstream, and a resolved push gets rejected as non-fast-forward after the work is done.

Before adding the worktree:
```bash
git rev-parse <branch> origin/<branch>        # must match
git branch -f <branch> origin/<branch>        # if they differ
```
Forcing is safe here only because that ref is never checked out in the main checkout (which stays on the default branch).

## Remote Checkouts May Hold Commits That Exist Nowhere Else

Before `git pull` or `git reset` in a checkout you don't own (a server, a container, another machine), check whether it is **ahead** of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

Non-zero means that checkout holds commits that may exist nowhere else, and `git reset --hard origin/<branch>` destroys them permanently. A conflicting `git pull` is a signal to investigate, not a nuisance to force past.

When you find divergence:

1. **Back it up before touching anything.** `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup` and copy the bundle off the machine. A branch on a single host is not a backup.

2. **Establish whether those commits contain unique content. Do NOT trust commit subjects.**

   ```bash
   git diff --stat origin/main..<backup-branch>     # net direction of the delta
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"  # its unique source lines
   ```

   Then verify each feature the subjects claim **in the upstream tree**: `git grep -n "<feature>" origin/main -- src/`.

   A branch can be "7 commits ahead" and still be strictly poorer: early work that upstream later reimplemented properly, often via squashed or re-authored PRs whose SHAs never match. A net diff of a few hundred lines added against thousands removed, with zero files unique to the remote side, is the signature of a superseded fork.

3. **Choose on evidence:**
   - *Superseded fork* (no unique content): `git reset --hard origin/<branch>`. Safe when runtime state is gitignored; check what the code actually writes (`output/`, `*.log`, caches) and confirm any tracked data file is read-only config, not state.
   - *Genuinely unique content*: port it onto a branch off `origin/main`, commit under a valid author identity, push, and only then reset the remote checkout. Don't leave it stranded.
   - *Need one fix now, reconcile later*: cherry-pick onto that checkout's HEAD (`git fetch origin main && git cherry-pick <sha>`). Conflicts are usually files that didn't exist on the older HEAD: `git add` the incoming version and `--continue`. This is interim, not an outcome.

   Run the repo's tests **on that host** afterwards. A big jump in test count is a good sign you recovered real work.
4. **Record the outcome in that checkout's own `context.md`** (a warning if unresolved, a RESOLVED note if reconciled) and commit it there. Docs committed upstream are invisible to a checkout that is dozens of commits behind.
5. **Surface the divergence as an open item.** Reconciling it is the owner's call.

Restore from a bundle with:
```bash
git fetch /path/to/x.bundle <name>-backup:<name>-backup
```

## Untracked File Shadowing a Tracked Path: Use a Worktree, Never rm

A repo can hold an UNTRACKED file at a path that IS tracked on `origin/main` (common where automated sessions drop env or scratch files). `git checkout -b <new> origin/main` then aborts with "untracked working tree files would be overwritten by checkout".

Do NOT `rm` or `mv` the blocker to unblock yourself. You didn't create it; it may be someone's uncommitted notes. Commit through a worktree, which never touches the dirty tree:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

**If you moved the blocker aside anyway, the mv is only half the procedure.** The file is tracked on the branch you moved TO and untracked on the branch you came FROM, so `git checkout <original-branch>` DELETES it from the working tree. If you already discarded your backup, it silently vanishes. Required steps whenever you mv a shadow file:

1. Record `git status --short` BEFORE you start.
2. After returning to the original branch, check the file exists.
3. If gone: restore the backup if it differed, else `git show origin/main:<file> > <file>`.
4. Re-run `git status --short` and confirm it matches step 1 exactly.

Leaving the working tree different from how you found it is a side effect nobody asked for.

## The Shared Checkout May Host Another Live Agent Session

A single working tree can be edited by several agent sessions at once. Two failures come from assuming sole ownership:

**1. `git checkout --` can delete another session's uncommitted work.** `git status` shows `M <file>` as one flag for the whole file, but that file can hold your one-line change AND dozens of lines of someone else's uncommitted edits. Restoring it wipes both.

> **Before `git checkout -- <file>` in a shared tree, run `git diff <file>` and confirm every hunk is yours.** If any hunk isn't, leave the file alone and work in a worktree.

**2. Another session can commit YOUR uncommitted files under its own message.** Anything untracked or modified in a shared tree is fair game for another process running `git add`. Your later push is then rejected as non-fast-forward, and the "conflicting" commit is byte-identical to your work.

> **When another session may share the checkout, do the whole edit in `git worktree add /tmp/wt-<repo> <trunk>` from the start.** Never leave new files untracked in the shared tree.

**Detect a concurrent session BEFORE the first edit, not at commit time:**
```bash
git branch --show-current     # an unexpected branch (e.g. claude/<something>)
git reflog -5                 # checkouts or commits you did not make
git worktree list             # worktrees you did not create
git status --short            # record this; your final state must differ only by your files
```
If any of these show another session, branch a worktree off trunk immediately and never touch the shared tree. When reconciling afterwards: if the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), don't force a duplicate commit; reset to origin and commit only what is genuinely missing.

### A peer's unpushed commit
If an "unpushed work" gate blocks you because of a commit you didn't write:

- **If the authoring session is still live, wait.** They may be mid-turn and may still amend.
- **If the commit is genuinely stranded** (the authoring session is gone and the work exists nowhere else), push it rather than leaving it:
  1. Identify author and branch: `git log --format='%h %an %ad %s' @{u}..HEAD` and `git branch --show-current`. Confirm it isn't yours.
  2. Secret-scan the diff. You're publishing content you didn't write or review; a private repo doesn't exempt it.
  3. Push to the branch it was committed on: `git push origin HEAD:<that-branch>`. Never redirect a peer's commit to the default branch; that is a scope change you have no mandate for.
  4. Say so in your final report.
- **Never `git reset` a peer's commit to clear a gate.** That destroys work that exists nowhere else.

Gates that check for unpushed work should be per-commit: block only on commits containing files this session wrote, and name (but not block on) peers' commits.

## A PR Stuck CONFLICTING Is Invisible to Automation

**`gh pr view N --json mergeable` returns `UNKNOWN` on the first poll.** GitHub computes mergeability lazily; only a follow-up read (~6s later) returns the real `MERGEABLE` or `CONFLICTING`. A checker that reads the first response sees nothing actionable and moves on, which is how PRs sit blocked for days with zero alerts. **Anything gating on mergeability must re-poll.**

Diagnosis order when a repo "seems behind on commits":
1. `git status`: a clean tree means this is almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge.

**Merge the default branch INTO the stale branch, never the reverse.** A branch N commits behind will, if pushed onto the default branch, delete everything added there since it forked. For append-only files, verify losslessness before committing a resolution; this must print 0 against both parents:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

Duplicate commit subjects with different SHAs on the two sides are the tell that sessions have been cherry-picking around the block; those duplicates usually created the conflict.

**Merging same-file PRs one at a time does not drain a backlog.** Each merge moves the default branch under siblings that touch the same file, turning mergeable PRs into conflicting ones (a backlog can grow while you "clear" it). When N PRs edit the same hotspot file, merge them into one integration branch, resolve the combined set once, and land that.

**Auto-resolve only what is provably safe.** A union resolver should refuse any hunk where both sides share a line rather than dedupe by guess, and must never union a YAML frontmatter hunk (it produces duplicate keys).

### Legacy 3-arg `git merge-tree` misses real conflicts
`git merge-tree $(git merge-base A B) A B` (the legacy form) can exit 0 with no conflict markers while GitHub shows CONFLICTING and a real merge conflicts. Use the modern form (`git merge-tree --write-tree --name-only <default> <branch>`) or an actual trial merge in an isolated worktree:
```bash
git worktree add /tmp/x FETCH_HEAD --detach && cd /tmp/x && git merge origin/main --no-commit --no-ff
```

### Rebasing a conflict in an append-only log: reinsert chronologically
When the only conflict is inside an append-only narrative log (run logs, progress files), the two blocks are usually independent entries from different dates, not competing edits. Tacking the incoming block on at the conflict site puts it out of order, because a long-open branch's entries are often OLDER than what main gained since. Read each block's date or run header, move it to where it belongs chronologically (which may be well outside the conflict region, for example right before the first later entry that references it), then verify the file's date headers are monotonic.

### A failing CI check is not automatically a merge blocker
If a PR shows `mergeStateStatus=UNSTABLE` because a check failed, inspect the failure (`gh run view <id> --log-failed`) and compare the failing files against the PR's file list. If the same failure reproduces on a fresh checkout of the base branch with no PR changes, it predates the PR and should not veto an otherwise-eligible merge. Your other merge criteria (verification passed, MERGEABLE, no sensitive paths) still govern.

## Commit Identity: Use the Noreply Email

With GitHub email privacy on, committing with a personal address as author or committer makes the push fail with `remote: error: GH007: Your push would publish a private email address` (or "push declined due to email privacy restrictions"). The failure happens at **push** time, so a session that only checks the commit succeeded will report work that never landed.

- Never pass an explicit email via `-c user.email=...`. Let git use the repo's configured identity.
- In an unfamiliar repo, check `git log -3 --format=%ae` to see which identity history already uses.
- Recover an already-made commit: `git -c user.email=<username>@users.noreply.github.com commit --amend --no-edit --reset-author`, then re-push.
- GitHub checks the **committer** email of every replayed commit, not just the author, so the rejection follows the commits: pushing from another machine doesn't help.

General rule: verify the operation that actually publishes, not the local step before it.

## Discrimination Checks: `git stash push` a Directory, Never `git checkout` It

To prove a regression test discriminates, you revert the fix, rerun the suite, and expect failures. Reverting with `git checkout -- <dir>` DESTROYS an uncommitted fix; there is no reflog for working-tree files, so recovery means re-applying every edit by hand.

Use `git stash push -- <dir>` instead: same clean revert, and `git stash pop` restores the work exactly. It's safe whether or not the fix is committed, so make it the default.

For a partially-committed branch:
```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
<run suite, record failures>
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```

## Secret Scanners Can Diff the Wrong Range After a Merge or Rebase

Pre-commit and pre-push scanners that compute their diff naively produce floods of false positives on stale branches:

- **Pre-commit on a merge commit:** `git diff --cached` with no extra args diffs against the **pre-merge HEAD** (the stale branch tip), so all of main's already-approved content is re-flagged as new. Fix in the hook: when `MERGE_HEAD` exists, diff against `$(git merge-base HEAD MERGE_HEAD)`.
- **Pre-push after a rebase:** the hook scans `$REMOTE_SHA..$LOCAL_SHA`, where `$REMOTE_SHA` is the stale pre-rebase tip. After a rebase it is no longer an ancestor, so the range spans all of main's landed commits.

Before concluding you're blocked on new content, re-scan the correct range yourself:
```bash
git diff origin/main..HEAD | grep '^+' | grep -v '^+++' | <your-scanner>
```
If the remaining hits are verbatim in `origin/main` or in the original branch tip, they are pre-existing, not yours. **Still do not use `--no-verify`.** Options: commit new content onto a fresh branch off main instead of merging the stale one, or leave the push for the owner to resolve. If the scanner hook is installed as copies in every repo (for example via `init.templateDir`), fixing the source changes nothing until you reinstall it everywhere; verify by grepping the installed copies for a marker from the new code.

## Run-Numbered Branch Names Can Collide

When automation names branches after a run number (e.g. `claude/learnings-<N>`), a later run can reuse a stem that already exists or was already squash-merged. `git merge-base --is-ancestor origin/<branch> origin/main` returns false for a squash-merged branch, so it can't distinguish "merged" from "exists and diverged".

Before creating a run-numbered branch, check both:
1. `git branch -a | grep <branch>`: catches a local ref.
2. `gh pr list --repo <owner>/<repo> --head <branch> --state all`: catches a squash-merged branch whose ref was deleted.

On a collision, append a suffix (`<branch>-2`) rather than deleting refs or investigating squash history under time pressure. The suffix is always safe.
