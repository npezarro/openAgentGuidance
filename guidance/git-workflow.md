<!-- Load when: branching, PRs, merge procedures, commit messages -->
# Git Workflow

## Branch Rules
- Never commit directly to `main`.
- Use the branch assigned to you. If none exists, create one: `agent/<task-name>` or `claude/<task-name>`.
- **Avoid `test-` as a branch prefix.** Some repos have GitHub rulesets or branch protection that silently reject pushes to `test-*` branches (no error, branch just doesn't appear on remote). Use descriptive names like `add-tests-<module>` or `<module>-tests-<run>` instead.
- Commit messages explain **why**, not just what. Large commits are fine; don't split work artificially.
- Before committing:
  1. `git status` to verify no unintended files staged.
  2. `git diff` to review the actual changes.
  3. Confirm no `.env`, secrets, or key files are included.
  4. **Update `context.md`** (or your repo's equivalent running-context doc), mandatory on the final commit of a branch (before creating a PR) or during session wrap-up. Not required on every intermediate commit.
  5. **Update `progress.md`**: add an entry for the work being committed.
- Push: `git push -u origin HEAD`. Retry network failures up to 4x with backoff (2s, 4s, 8s, 16s). Do not retry auth failures.

## All Deliverables Go in Repos
When creating scripts, tools, project assets, analysis docs, reference files, or any other output, **ALWAYS put them in a git repo and push to the remote**. Never leave files as loose filesystem artifacts; nobody should have to dig around the filesystem for deliverables. The remote is the source of truth. If a new project or tool set doesn't have a repo yet, create one with `gh repo create`.

**This is the most common mistake.** Sessions routinely create useful files (summaries, configs, scripts, reference docs) and then either forget to commit, forget to push, or save them outside a repo. Local-only files are inaccessible between sessions. Treat every `Write` or `Edit` call as incomplete until the file is committed and pushed.

## Every Repo Gets a README and Description
Every repo must have a `README.md` and a remote repo description. When creating a new repo or working in one that's missing either, add them.

- **README.md**: What it does (1-2 sentences), how to set it up, and how to run/use it. Keep it concise; a developer should understand the project in 60 seconds.
- **Repo description**: Set via `gh repo edit <owner>/<repo> --description "one-line summary"`. Should be a single sentence that appears on the repo page and in search results.

Both are required when running `gh repo create`. Use `--description` flag on creation. Add the README as part of the initial commit.

## Always Commit and Push Written Files
When creating or modifying files in any repo (via Write, Edit, or any other method), **ALWAYS commit and push in the same step**. Don't move on to other work with untracked or uncommitted files sitting in a repo. The Write tool doesn't commit; you must do it explicitly.

When committing to any repo, **ALWAYS push to the remote branch as well**. Never leave commits unpushed. Unpushed commits are invisible to other sessions, collaborators, and the deploy pipeline. Treat file creation + `git commit` + `git push` as a single atomic operation; if any step fails, diagnose and fix it before moving on.

**Common gap:** When working across multiple repos in one session, it's easy to push some and forget others. After finishing a multi-repo task, verify all repos are clean: `git status` in each one.

## Staging Hygiene (ANY repo with in-flight work)

Some repos are worked by many agents at once (interactive sessions, scheduled learning agents, doc-sync jobs, autonomous dev runs). **This is not a "shared repo" rule; it applies to ANY repo.** Any checkout can hold uncommitted work from a previous session, and a blanket add silently ships it under your commit message.

> A `git add -A` in a repo nobody considered "shared" once swept a half-finished feature adapter, a scratch script, and a settings change into an unrelated one-line commit. It was caught on the `git show --stat` review before pushing; the commit was reset and re-made with explicit paths. The rule below already existed; only its perceived scoping made it look inapplicable.

The check is cheap and unconditional: **run `git status` BEFORE staging.** If the tree holds anything you didn't touch, name your paths explicitly.

Two rules prevent one agent's commit from corrupting another's work or leaking secrets:

- **Stage explicit paths, never `git add -A` / `git add .`** in any repo. A blanket add sweeps whatever another agent left uncommitted in the working tree into *your* commit. This has actually happened: a concurrent session's `git add -A` bundled an unrelated agent's doc file with its own change, and staged a secret alongside it. Name the files you touched: `git add guidance/foo.md scripts/bar.sh`.
- **Never `--no-verify` on a public repo.** A pre-commit sensitive-identifier scanner is the last line of defense before a machine username, internal path, or token reaches a public repo. Bypassing it is how leaks ship. If the scanner blocks you, sanitize the content; don't override. (In the incident above the scanner correctly blocked the leak; the proper fix went out sanitized via a PR, and the `--no-verify` local commit was orphaned.)
- **Before committing, `git status` and confirm ONLY your files are staged.** If you see files you didn't touch, unstage them (`git restore --staged <path>`); they belong to another agent.

## Creating PRs (with retry)

After `git push`, the remote may take a few seconds to register the branch. Always verify the branch exists remotely before creating the PR, and retry on failure:

```bash
# 1. Wait for the remote to register the pushed branch
for i in 1 2 3 4 5; do
  if gh api "repos/{owner}/{repo}/branches/$(git branch --show-current)" --silent 2>/dev/null; then
    break
  fi
  echo "Waiting for the remote to register branch (attempt $i)..."
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
// WRONG — causes "invalid head" errors, especially on newly-pushed branches
await octokit.rest.pulls.create({ head: branch, ... });

// CORRECT — qualify with the repo owner
await octokit.rest.pulls.create({ head: `${owner}:${branch}`, ... });
```

**Why:** GitHub needs a few seconds to fully index a newly-pushed branch. Unqualified branch names fail more often during this window. Qualifying with the owner disambiguates the ref lookup and makes the API more reliable.

**Also:** Add a 3s delay before calling `pulls.create` after a push event; the remote's internal indexing isn't instant. Increase `maxAttempts` to 5 and retry on "invalid head" errors.

**Note:** The `gh pr create` CLI handles head qualification internally. This only applies when using the REST API directly (e.g., in an automated merge bot).

**If your setup runs an auto-merge bot:** given the bot's speed advantage, the reliable agent workflow is to just `git push` the branch and **not** call `gh pr create` at all; let the bot squash-merge it. After the push, the remote branch vanishing and `gh pr create` failing with "No commits between main and `<branch>`" / "Head sha can't be blank" is **success**, not failure; don't retry or treat it as an error.
- **Verify by content, not ancestry.** The squash commit is NOT an ancestor of your local commit (`git merge-base --is-ancestor <mine> origin/main` returns false), but `git diff origin/main <mine> -- <file>` will show identical content. Check the diff, not `git log --ancestry-path`.
- **Shared checkouts can switch branches mid-operation** on a machine that concurrent jobs also use. Don't trust the ambient staging area for a clean single-file commit; build it via a temp index (`GIT_INDEX_FILE=<tmp> git read-tree` + `git commit-tree`) and push via an explicit refspec (`git push origin <sha>:refs/heads/<branch>`) instead of relying on the current checkout's HEAD.

## Branch Hygiene

Open PRs that sit unmerged cause cascading merge conflicts across all other branches. **This is the #1 cause of stuck work.** Prevent this:

- **Merge PRs promptly.** When a PR is ready and has no review requirements, merge it in the same session you created it. Use `gh pr merge <number> --merge --delete-branch`. If the merge fails (merge conflict, checks pending), retry once after 5s. If it still fails, report the specific error.
- **Rebase before opening a PR.** Run `git fetch origin && git rebase origin/main` and resolve any conflicts before pushing. A PR should be mergeable at the time it is created.
- **One branch per task.** Don't create multiple branches for the same feature or leave abandoned branches behind.
- **Clean up stale branches.** At session start, check `gh pr list --state open` and `git branch -a`. If a branch has been open for more than a few days without activity, either rebase and merge it or close it.
- **Prune remote-tracking refs before scanning.** Before enumerating branches with `git branch -a` or `git branch -r`, run `git remote prune origin` (and any other remotes). Without pruning, remote-tracking refs for branches deleted on the remote remain locally and inflate "open branch" counts in automated scanners. Observed: half of a scanner's reported "open branches" were phantom stale refs from a prior cleanup that hadn't been pruned.
- **Automation cap/dedup gates MUST use `git ls-remote`, not `git branch -r`.** `git branch -r` reads local remote-tracking refs that are only refreshed on `git fetch --prune`; pruning in the same script helps but is still racy if another process deleted the branch between runs. For cap checks, backlog gates, and any automation that needs to know which branches *currently* exist on the remote, query the remote directly: `git ls-remote --heads origin 'claude/auto-*'`. This is always authoritative. Observed failure: three consecutive automation runs triggered backlog-cleanup mode against 0 real open branches because stale tracking refs for already-merged branches lingered.
- **Don't leave PRs for someone else to merge** unless the task explicitly requires review. Unmerged PRs are invisible debt that compounds with every new branch.
- **Never modify `context.md` or `progress.md` on a branch that other branches also modify.** These files conflict constantly. If you must update them, do it as the very last commit before merging, after rebasing on main. An auto-merger can resolve context/progress conflicts locally, but code conflicts in these files alongside real code conflicts will block the merge entirely.
- **If a merge fails with code conflicts:** close the PR, delete the branch, and redo the work on a fresh branch from main. Don't waste time resolving complex merge conflicts on stale branches.
- **Follow-up fixes after an auto-merge go on a FRESH branch off main.** An auto-merger squash-merges a pushed branch within ~30s and deletes it remotely. Pushing a second commit to that same branch then conflicts every time (main holds one squashed commit while your branch still has the individual originals from the same base) and `gh pr create` may fail with `No commits between main and <branch> / Head sha can't be blank` because the branch no longer exists server-side. Do this instead: `git checkout -b <new> origin/main`, then `git checkout <old-branch> -- <only the changed files>`, commit, push the new branch, close the stale PR. Verify a push actually landed with `git ls-remote --heads origin <branch>` rather than trusting the local `origin/<branch>` ref, which goes stale the moment the merger deletes the branch.

- **MERGEABLE ≠ non-redundant.** A feature PR can show MERGEABLE yet have its entire patch already on `main`; this happens when a doc-sync or doc-update PR branched off the feature branch and carried the code into main via its own merged PR. Before merging any feature PR that looks "ready," run `git rebase origin/main` in a throwaway checkout: if the commit is silently dropped ("patch contents already upstream") or `git diff origin/main <tip>` is empty, the content already landed. Close the original feature PR as superseded (`gh pr close <N> --delete-branch --comment "Superseded by ..."`) rather than producing a duplicate merge.

### An auto-merger may self-merge EVERY non-draft PR from ANY pushed branch by default

If your setup runs an auto-merge bot, check whether its default is opt-out rather than opt-in: any PR it creates from a pushed branch (including a one-off human or design branch never meant to reach `main`) gets merged within seconds, with no review checkmark step. Pushing a branch you don't want merged yet is not safe by default; you must actively block it.

- **Immediate mitigation:** convert the PR to draft right after pushing (`gh pr ready <n> --undo`). Draft PRs are never auto-merged.
- **Durable fix:** give the auto-merger a repo-level `EXCLUDED_REPOS` denylist. Repos on it no longer auto-merge on push or PR events, while still auto-merging recognized safe lanes (doc-sync, audit, scheduled-summary, automated-fix branch prefixes). Support a per-commit override in the head commit message: `[automerge]` forces a merge even on an excluded repo; `[no-automerge]` / `[skip-am]` suppresses merging anywhere.
- Add any new product or design repo (one with real human or design branches, as opposed to a tooling repo relying on blind auto-merge for its own `feat/*`/`fix/*` branches) to the denylist **before** its first non-lane push, not after. Observed failure: pushed design branches were merged and reverted twice before a denylist existed.

## Staging Changes in Hook-Executing Repos: Use Worktrees, Not Branch Checkouts

**Never run `git checkout <branch>` in the main checkout of a repo whose working copy is referenced by live hooks or SessionStart scripts.** The session harness executes directly from these working-copy paths. Switching their branch silently reverts all guidance, hooks, and config to whatever the target branch holds (new rules vanish, retired rules reappear, hooks change behavior) for every concurrent session and every agent that runs during or after the switch.

**The safe pattern:** use a git worktree instead.

```bash
# Stage changes for review without touching the main checkout
git -C $HOME/<repo> worktree add /tmp/learnings-wt-<repo> -b claude/learnings-<run>
# ... make edits, commit, push, open PR from inside /tmp/learnings-wt-<repo> ...
git -C $HOME/<repo> worktree remove /tmp/learnings-wt-<repo>
# Main checkout stays on main throughout; hooks keep running from live state
```

**Real incident:** a scheduled learning agent checked out its staging branch inside the guidance repo. The core rules file reverted to an older version, new hooks disappeared, and the live harness ran in the wrong state for the duration of the session. All of this was silent: no error, no warning.

**Repos requiring worktrees:** any repo whose working-copy path appears in a hook path, a SessionStart hook, or a process-manager config that loads guidance at runtime.

### Autonomous runs must self-verify their own PRs actually merged
Three separate bot-created PRs across different repos sat MERGEABLE + CI SUCCESS for 2-4 days before a periodic checker caught and merged them. Each was a genuine, already-verified fix; the PR just never got merged after creation. Root cause: the run's closeout logs "PR: <link>" but doesn't check `gh pr view <n> --json state` before ending the session, so a merge step that silently didn't fire (or was never attempted) goes unnoticed until the next checker pass. **Fix:** re-check `gh pr view --json state,mergeable` for the PR you just created as the last step of your own session, and merge it right then if MERGEABLE + CI SUCCESS, instead of relying on a periodic checker as a merge backstop.

### Merged-PR scope notes are sanctioned follow-up work, not dedup blockers
When candidate work looks like a duplicate of a recently MERGED PR, read the merged PR's body before rejecting it. An explicit "out of scope / flagged as a follow-up" note converts the candidate from forbidden duplicate into sanctioned, pre-vetted follow-up work, and the merged PR often ships infrastructure the follow-up should reuse instead of re-inventing (a scope note plus a new `safeJsonParse` helper in one merged PR made the follow-up PR both sanctioned and cheaper). Cite the scope note in the new PR body to make the lineage reviewable.

## Remote Checkouts May Hold Commits That Exist Nowhere Else

Before `git pull`/`git reset` in a checkout you do not own (a server, a container, another machine), check whether it is **ahead** of origin:

```bash
git fetch origin <branch>
git rev-list --count origin/<branch>..HEAD   # non-zero => LOCAL-ONLY commits live here
```

Non-zero means that checkout holds commits that may exist nowhere else. `git reset --hard origin/<branch>` destroys them permanently. A conflicting `git pull` is a *signal* to investigate, not a nuisance to force past.

**Observed:** a remote checkout sat 7 ahead / 65 behind. The 7 commits (atomic writes, cron scheduling, log rotation, alerting) were absent from both the local clone and the remote. A pull conflicted on a data file and `package.json`; the reflexive `reset --hard` would have erased all of it.

When you find divergence:

1. **Back it up before touching anything.** `git branch -f <name>-backup HEAD`, then `git bundle create /tmp/x.bundle <name>-backup` and copy the bundle off the machine. A branch on a single host is not a backup. This costs nothing and makes every later step risk-free.

2. **Establish whether those commits actually contain unique content. Do NOT trust the commit subjects.**

   ```bash
   git diff --stat origin/main..<backup-branch>     # net direction of the delta
   comm -13 <(git ls-tree -r --name-only origin/main | sort) \
            <(git ls-tree -r --name-only <backup-branch> | sort)   # files ONLY on that side
   git diff origin/main..<backup-branch> -- src/ | grep -E "^\+[^+]"  # its unique source lines
   ```

   Then verify each feature the subjects claim, **in the upstream tree**: `git grep -n "<feature>" origin/main -- src/`.

   A branch can be "7 commits ahead" and still be strictly poorer: early work that upstream later reimplemented properly, often via PRs that were squashed or re-authored so the shas never match. In the case above the subjects promised atomic writes, cron scheduling, log rotation and alerting. The diff was **+185 / −5,602 with ZERO files unique to the remote checkout**, its 74 unique source lines were superseded versions of refactored functions, and every claimed feature was verifiably present upstream and better (the atomic write was a single `renameSync(tmpPath, ...)` in the pipeline module). The remote checkout was *missing* three adapters, four modules, ~20 test files, CI and dependency automation. Reset was correct; the initial conservative "cherry-pick, never reset" read was wrong.

3. **Then choose, on evidence:**
   - *Superseded fork* (no unique content): `git reset --hard origin/<branch>`. Safe when runtime state is gitignored; check what the code actually writes (`output/`, `*.log`, caches) and confirm any tracked data file is read-only config, not state.
   - *Genuinely unique content*: port it onto a branch off `origin/main`, commit under a valid author identity, push, and only then reset the remote checkout. Do not leave it stranded. If the push is rejected with `push declined due to email privacy restrictions`, GitHub is checking the **committer** email of every replayed commit, not just the author; that rejection follows the commits, not the pusher, so pushing from elsewhere doesn't help.
   - *Need one fix now, reconcile later*: cherry-pick onto that checkout's HEAD (`git fetch origin main && git cherry-pick <sha>`). Conflicts are usually files that did not exist on the older HEAD; `git add` the incoming version and `--continue`. This is an interim measure, not an outcome.

   Verify by running that repo's tests **on that host** afterwards. A jump in test count (16 → 283 in the case above) is a good signal you recovered real work.
4. **Record the outcome in that checkout's own running-context doc** (a warning if unresolved, a RESOLVED note if reconciled) and commit it there. Docs committed upstream are invisible to a checkout that is 65 commits behind; the warning has to live where the next session will actually read it.
5. **Surface the divergence as an open item.** Reconciling it is the owner's call.

Restore from a bundle with:
```bash
git fetch /path/to/x.bundle <name>-backup:<name>-backup
```

### Untracked file shadowing a tracked path blocks checkout; use a worktree, never rm
A repo can hold an UNTRACKED file at a path that IS tracked on origin/main (common in repos where automated sessions drop env or scratch files). `git checkout -b <new> origin/main` then aborts with "untracked working tree files would be overwritten by checkout".

Do NOT rm or mv the blocker to unblock yourself. In one observed case the blocker was an untracked env-notes file the session did not create; deleting it to land an unrelated docs commit would have destroyed someone else's uncommitted infra notes.

Correct move: commit through a worktree, which never touches the dirty tree:

```bash
git worktree add /tmp/wt -b <branch> origin/main
cp <file> /tmp/wt/<path> && cd /tmp/wt && git add <path>
git diff --staged | grep -inE '(api[_-]?key|secret|token|password|bearer|-----BEGIN)'
git commit && git push -u origin <branch> && gh pr create
cd <repo> && git worktree remove /tmp/wt --force && git worktree prune
```

Related: in a repo running a PR + auto-merger flow, `gh pr create` can report "a pull request already exists" (or fail with "No commits between main and <branch>") because the merger opened AND merged one within seconds of the push. Do not treat either as a failed create. Confirm with `gh pr view <n> --json state,mergedAt`, or verify directly:

```bash
git fetch origin && git log --oneline -3 origin/main
git cat-file -e origin/main:<path> && echo "landed on main"
git diff HEAD origin/main -- <paths> --stat   # empty == merged content is identical
```

**If you moved the blocker aside anyway: the mv is only half the procedure.**
The worktree route above avoids this entirely and is still preferred. But if you did `mv <file> /tmp/<file>.bak` and switched branches, the file is tracked on the branch you moved TO and untracked on the branch you came FROM, so `git checkout <original-branch>` DELETES it from the working tree. If you already discarded the backup (e.g. you diffed it against the tracked copy, found them identical, and cleaned up), the file silently vanishes from a tree where it existed before you started.

Recovery / required closing steps whenever you mv a shadow file:
  1. Record `git status --short` BEFORE you start.
  2. After returning to the original branch, re-check the file exists.
  3. If gone: restore the backup if it differed, else `git show origin/main:<file> > <file>`.
  4. Re-run `git status --short` and confirm it matches step 1 exactly.

Leaving the working tree in a different state than you found it is a silent side effect nobody asked for. Never assume the checkout was symmetric; verify.

## The shared checkout may host another live agent session

A single working tree can be edited by several agent sessions at once. Two distinct failures came out of one session that assumed sole ownership:

**1. `git checkout --` deleted another session's uncommitted WIP.** To isolate its own edits, the session copied its touched files to /tmp, then restored the shared tree with `git checkout -- <files>`. `git status` had listed one source file as a single `M` entry, but that file held BOTH the one-line change AND ~50 lines of the other session's unrelated, uncommitted redesign. The copy captured their work and the restore deleted it; it survived only because the /tmp copy still had it.

> **Before `git checkout --` on any file in a shared tree, run `git diff <file>` and confirm every hunk is yours.** An `M` in `git status` is one flag for the whole file, not a claim of single authorship. If a hunk is not yours, leave the file alone and work in a worktree instead.

**2. The other session committed MY uncommitted files under its own message.** While a new component sat untracked in the shared checkout, the concurrent session `git add`-ed it, wrote its own commit message, and pushed it. The later push was rejected as non-fast-forward, and the "conflicting" commit turned out to be byte-identical to the original work. Anything uncommitted in a shared tree is fair game for another process running `git add`.

> **When another session may share the checkout, do the whole edit in `git worktree add /tmp/wt-<repo> <trunk>` from the start.** Never leave new files untracked in the shared tree.

**Detect a concurrent session BEFORE the first edit, not at commit time:**
```bash
git branch --show-current     # an unexpected branch (e.g. claude/<something>)
git reflog -5                 # checkouts or commits you did not make
git worktree list             # worktrees you did not create
git status --short            # record this; your final state must differ only by your files
```
If any of these show another session, branch a worktree off trunk immediately and never touch the shared tree. Reconciling afterwards: if the remote already has your content (`git diff HEAD origin/<branch> -- <paths>` is empty), do not force your duplicate commit; reset to origin and commit only what is genuinely missing.

### Acknowledging a gate hit that is not your work

If your setup runs an unpushed-work gate at session end, it typically blocks on any file **this session wrote** that is still dirty. It cannot tell "I forgot to push" from "I wrote this, reverted it, and another session's edits are now on the same path", and in a shared checkout the second case is real (see the section above).

When you have *proven* the dirt is not yours, acknowledge the exact path in whatever ack mechanism the gate provides, with a reason:

```bash
printf '%s\t%s\n' "<repo>/<path>" "reason it is not yours" \
  >> "/tmp/claude-repos-ack-${SESSION_ID}"
```

The gate then reports the path in a non-blocking message and appends it to its ack log with the session id, timestamp, and reason.

A well-designed ack is deliberately **not** a mute switch:
- one line acknowledges exactly one path; there is no wildcard,
- a line with no reason still blocks,
- any other dirty tracked file still blocks,
- unpushed **commits** still block regardless of any ack.

Prove it before you use it (`git diff <file>` showing zero hunks of yours, plus evidence your own content is already on the remote). Acknowledging work you simply forgot to push is the exact failure such a gate exists to catch.

### A peer's unpushed commit (read this before acting)

The right gate design is **per-commit**: intersect each unpushed commit's files against this session's Edit/Write ledger and block only on commits containing a file *you* wrote. A peer's commit is named in the message but does not block.

So if a well-designed gate fires on a repo, it is because a commit contains **your own** file. Push that. Do not reach for the procedure below reflexively; publishing a peer's unreviewed work is a real action with real risk, and it should rarely be necessary.

**When the peer's session is still live, waiting is right.** A session once hit a raw block and correctly declined to push a peer's two-minute-old commit while that session was still running; the peer pushed it themselves shortly after. They are mid-turn and may still amend. The procedure below is for a genuinely *stranded* commit: the authoring session is gone and the work exists nowhere else.

When a commit really is stranded, push it rather than waiting or resetting:

1. **Identify the author and branch** with `git log --format='%h %an %ad %s' @{u}..HEAD` and `git branch --show-current`. Confirm it is not yours before touching it.
2. **Secret-scan the diff** you are about to publish. You are pushing content you did not write and did not review; the repo being private does not exempt it.
3. **Push to the branch it was committed on**: `git push origin HEAD:<that-branch>`. Never redirect a peer's commit to `main`/`master`; they chose that branch, and landing it on a mainline is a scope change you have no mandate for.
4. **Say so in your final message.** You published someone else's work; that belongs in the report, not buried in a tool call.

Cost of doing this: if the peer later amends or rebases that commit, their next push needs a force. That is strictly better than leaving their work stranded local-only, which is the exact loss the gate exists to prevent.

Do **not** `git reset` a peer's commit to clear the gate; that destroys work that exists nowhere else.

### An auto-merger merges `claude/*` branches on push, so `gh pr create` races it
During a 28-repo compliance audit, every `git push -u origin claude/<audit-branch>` was intercepted by the auto-merge service, which opened AND squash-merged its own PR within seconds. The subsequent `gh pr create` then failed with "No commits between <default> and claude/<audit-branch>".

Consequences and the correct handling:
1. Treat "No commits between..." after pushing a `claude/*` branch as SUCCESS, not failure. The bot already landed the change. Find its PR with `gh pr list --state all --head <branch>` and reuse that PR number; do not re-push or open a duplicate.
2. Do NOT retry the push. In one repo a retry produced a second PR that also merged; the diffs were byte-identical so nothing duplicated in the file, but two merged PRs for one logical change is misleading history.
3. Because the bot SQUASH-merges, `git branch --merged origin/<default>` reports the local audit branch as unmerged even though its content landed. Verify by comparing content (every added line present in `git show origin/<default>:<file>`), not by SHA ancestry, before deleting the local branch.
4. Default branch is not uniformly `main`; some repos use `master`. Resolve it with `gh repo view --json defaultBranchRef -q .defaultBranchRef.name` rather than assuming.
5. When verifying added lines with grep, use `grep -Fqx -- "$line"`. Without the `--`, any added line beginning with `-` (a markdown bullet) is parsed as a grep option and the verification silently reports false negatives.

## A PR stuck CONFLICTING is invisible to automation

**`gh pr view N --json mergeable` returns `UNKNOWN` on the first poll.** GitHub computes mergeability lazily; the first read of a PR that has not been checked recently is always `UNKNOWN`, and only a follow-up read (~6s later) returns the real `MERGEABLE`/`CONFLICTING`.

Any checker that reads the first response sees `UNKNOWN`, finds nothing actionable, and moves on. That is how four PRs in one repo sat blocked for five days with zero alerts while one of them accumulated 40 commits and its default branch moved 60 ahead. **Anything gating on mergeability must re-poll.**

Diagnosis order when a repo "seems behind on commits":
1. `git status`; a clean tree means this is almost never uncommitted work.
2. `gh pr list --state open`, then check each PR's mergeability **twice**.
3. `git merge-tree --write-tree --name-only <default> <branch>` for a non-destructive trial merge.

**Merge the default branch INTO the stale branch, never the reverse.** A branch that is N commits behind will, if pushed onto the default branch, delete everything added there since it forked. Verify losslessness per file before committing a resolution; for append-only files this must print 0 against both parents:

```bash
comm -23 <(git show MERGE_HEAD:<file> | sort -u) <(sort -u <file>) | grep -c .
```

Duplicate commit subjects with different SHAs on the two sides are the tell that sessions have been cherry-picking around the block; those duplicates are usually what created the conflict.

**Merging same-file PRs one at a time does not drain a backlog.** Each merge moves the default branch under the siblings that touch the same file, so previously-mergeable PRs become conflicting. Clearing 12 doc PRs this way moved one backlog from 22 to 25 conflicting, with 13 PRs newly broken. When N PRs edit the same hotspot file, merge them into a single integration branch, resolve the combined set once, and land that.

**Auto-resolve only what is provably safe.** A union resolver should refuse any hunk where the two sides share a line, rather than deduplicating by guess, and never union a YAML frontmatter hunk, which produces duplicate keys.

### Merge a worktree branch from the primary checkout, and never hardcode the commit email
Two failures hit in one command while landing a worktree branch:

1. `git checkout main` INSIDE a worktree fails with "fatal: 'main' is already used by worktree at ..." because the primary checkout holds it. Then `git worktree remove` ran while cwd was inside that worktree, leaving the shell with no working directory. Merge from the PRIMARY checkout instead: commit in the worktree, capture the SHA, then `cd` to the primary checkout and `git merge --ff-only <sha>`.

2. Committing with an explicit personal email via `-c user.email=...` got the push rejected: "push declined due to email privacy restrictions". Repos are typically already configured with the correct noreply identity. Never pass an explicit email; let git use the repo's configured identity, or the commit has to be amended with `--reset-author` and redone.

**Why:** both failed after the work was already correct, turning a clean landing into recovery.

**How to apply:** commit in the worktree -> `COMMIT=$(git rev-parse HEAD)` -> `cd` primary -> `git merge --ff-only $COMMIT` -> push -> `git worktree remove` from the primary checkout. Omit `-c user.email` entirely.

### Discrimination checks: `git stash push` a dir, never `git checkout` it
To prove a regression test actually discriminates, you revert the fix, re-run the suite, and expect failures. Reverting with `git checkout -- <dir>` DESTROYS the uncommitted fix: there is no reflog entry for working-tree files, so the only recovery is re-applying every edit by hand (cost in one observed run: 10 re-applied edits, because the change had not been committed).

Use `git stash push -- <dir>` instead. It gives the identical clean revert, and `git stash pop` restores the work exactly. If the fix is already committed, `git checkout <base-sha> -- <dir>` is safe because `git checkout HEAD -- <dir>` restores it, but the stash form is safe in BOTH cases, so make it the default.

Sequence that works for a partially-committed branch:
```bash
git stash push -- src/            # save uncommitted part
git checkout <base-sha> -- src/   # revert the committed part
# run suite, record failures
git checkout HEAD -- src/         # restore committed part
git stash pop                     # restore uncommitted part
```

### Legacy 3-arg `git merge-tree` misses conflicts that `git merge` finds
A bot-created PR showed `mergeable: CONFLICTING` on the remote. The legacy 3-arg form `git merge-tree $(git merge-base origin/main FETCH_HEAD) origin/main FETCH_HEAD` exited 0 with zero diff3-style conflict markers: a false all-clear. Only an actual trial merge in an isolated worktree surfaced the real conflict:

```bash
git worktree add /tmp/x FETCH_HEAD --detach
cd /tmp/x && git merge origin/main --no-commit --no-ff
```

Use the modern form (`git merge-tree --write-tree --name-only <default> <branch>`) or a real trial merge; the legacy 3-arg form does not reliably surface conflicts that a real merge does.

Once the conflict was isolated to one file it was resolved (kept the default branch's superseding doc section, deleted a status note that was explicitly self-removing per its own commit message), verified with typecheck/tests/build, pushed to the PR branch, CI re-ran green, then merged: recovering real code (two new exported functions, their call sites, and tests) instead of defaulting to close-and-lose-the-work. That is the right move for a bot-authored feature PR, unlike a dependency-bot lockfile PR, where closing and letting the bot recreate it is correct because there is no hand-written content to lose.
