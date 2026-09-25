<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

Several agent sessions can run at once on one machine, often with permissions bypassed, and all sharing one checkout per repo. Collisions between them keep coming back, and each fix that only detects them narrows the window without closing it.

**Why it keeps coming back: there are two separate problems, and one mechanism was being asked to solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. The index and working tree are mutable shared state that nobody owns. | Deploy targets, process-manager services, a live browser extension, a shared skills or config directory, a remote server. Only one of each exists. |
| Symptom | `git add -A` commits someone else's uncommitted work; two sessions commit the same file seconds apart. | One session's deploy overwrites another's; two extension reloads tear down each other's service worker. |
| Right fix | **Remove the sharing** (a git worktree per session). | **Serialize** (a real lock) or **partition** (one owner per path). |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. You can proceed past them, so nothing is serialized. |

A detection hook (a "claim guard" that warns when a peer touched the same file) is worth keeping as a backstop. It is not the strategy.

## Pre-flight before working in any shared folder

Before you start, check whether a parallel workstream already exists. Otherwise you may duplicate hours of a peer's research or prototypes, or misdiagnose the task.

1. `git log --since="2 days ago" --format='%h %ad %s' -- <folder>` and `ls -lat <folder> | head` to find files other sessions added.
2. Look in any deliverables or scratch directory for a folder on the same topic.
3. List live or idle peer sessions (for example with `ListAgents`) that started around the same time.
4. Grep your own working doc for sections you did not write.

## Problem A: use a worktree per session

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**`EnterWorktree` is often unavailable.** The tool needs the session's cwd to be inside a git repo. Sessions launched from a non-repo directory, or ones that span several repos, can't use it. A rule that can't be followed gets skipped quietly, and that weakens every other rule in the file. So use the underlying mechanism directly; it works from any cwd:

```bash
git -C $HOME/<repo> worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/<repo>/.claude/worktrees/<n>/...
git -C $HOME/<repo> merge --no-ff <n> && git -C $HOME/<repo> push
```

After that, no other session's uncommitted work is in your tree, so `git add -A` is safe **by construction** and this whole class of bug goes away.

Why it's cheap: the worktrees live under `.claude/worktrees/`, so the canonical checkout **stays exactly where it is**. Crontab lines and process-manager configs that hardcode the canonical path keep working. They get better, in fact, because crons now run against a clean committed tree instead of one several sessions are editing at once.

The real costs:
- Each session ends with a merge back to the default branch. That's extra ceremony for solo work.
- Git refuses to check out the same branch in two worktrees. That's a feature (it forces a branch per session), but it changes behavior.
- It does nothing for Problem B.
- A separate clone (for example a checkout on another filesystem that a tool loads from) is not affected either way, and still needs its own pull.

### Ignore the worktree directory globally

```bash
git config --global core.excludesFile ~/.gitignore_global   # file contains: .claude/worktrees/
```

Without this, the canonical tree shows `?? .claude/` as soon as a worktree exists, and a `git add -A` there commits an entire nested worktree. A per-repo `.gitignore` line doesn't scale across many repos, and adding it means a commit into each repo while other sessions are live in it. One global setting covers every repo, including repos created later. To verify, run `git status` in a repo with no local entry while a worktree is open; it should stay clean, and `git check-ignore -v` should attribute the match to the global file.

Caveat: a global excludes file exists only on your machine. A repo with outside contributors still needs the committed `.claude/worktrees/` line.

### Proof it works

```
canonical tree (session A):   M CLAUDE.md        <- A's uncommitted edit
worktree      (session B):    echo >> progress.md ; git add -A
B staged:                     M  progress.md      <- only its own file
A's CLAUDE.md edit:           untouched
```

### Your push gate has to see worktrees

If a Stop hook checks for unpushed work, make sure it handles worktrees. Otherwise you trade a loud problem (a clobber, which you notice) for a silent one (work stranded in a worktree, which you don't). Two common causes:

- In a normal checkout `.git` is a **directory**, but in a linked worktree it's a **file**. A `-d .git` test skips every worktree.
- A worktree branch has **no upstream**, so `@{u}` fails and the check gets skipped. Compare against origin's default branch instead. The question for such a branch is "does this work exist on the remote yet", not "is it pushed to my upstream".

### Don't collapse a worktree onto its canonical repo in your guards

It's tempting to key guard ledgers on the canonical repo root. That's wrong twice over:
- The file's relative path becomes `.claude/worktrees/<name>/...`, which is gitignored in the canonical repo and reports as clean. Dirty worktree files would look committed.
- Two sessions in separate worktrees genuinely can't clobber each other's working tree, so warning them about each other is a false positive. Scope guards to each working tree.

If a guard tests `check-ignore`, run it against the tree the file actually lives in. Otherwise every worktree file reads as ignored and the session becomes invisible to the guards.

### Landing a branch: never merge from the shared checkout

`cd <primary> && git merge <my-branch>` merges into **whatever branch is checked out right now**. A peer may have switched the shared checkout to its own branch in the meantime. Then your merge fast-forwards the peer's branch, your push to the default branch fails non-fast-forward, and your commits end up on someone else's already-merged PR branch. A clean `git status -sb` twenty minutes ago proves nothing, and re-checking just before merging is still a race, not a fix.

Land from a detached worktree of the default branch instead. Nobody can move it under you:

```bash
git worktree add --detach .claude/worktrees/land origin/<default-branch>
cd .claude/worktrees/land
git merge --no-edit origin/<default-branch>      # pick up peers first
git merge --no-edit <my-branch>
git push origin HEAD:<default-branch>            # push the SHA, not a local ref
cd - && git worktree remove .claude/worktrees/land --force
```

If you already merged onto a peer's branch: run `git branch <keep> <your-sha>` to keep your work, land it from the worktree above, then `git reset --hard origin/<peer-branch>` to restore their branch to exactly what they pushed. Leave it checked out where they left it. Don't switch the shared checkout back to your branch as a courtesy; leaving it alone is the courtesy.

### Keep `--detach` in the landing worktree

The recipe works because a detached worktree never touches `refs/heads/<default-branch>`. Drop `--detach`, or follow it with `git checkout -B <default-branch> origin/<default-branch>`, and you recreate the problem. Branch refs are **shared across all worktrees of one repo**; only the index and working tree belong to each worktree. Checking the branch out a second time either errors, or on some git versions succeeds silently and moves the shared ref. When it succeeds, the primary checkout's `git branch --show-current` and `git status` still look right, but its working tree and index never moved. `git show HEAD:<file>` returns the new content, while the file on disk is old and shows as a phantom staged diff.

**Recovery:** nothing is corrupted, just stale. Don't `git reset --hard`, because it can discard unrelated dirty state. Restore only the affected files: `git restore --staged <file> && git checkout HEAD -- <file>`.

### Create worktrees for existing branches from the remote ref

`git worktree add <path> <branch> --detach` resolves `<branch>` with git's normal lookup, and that prefers a **local** `refs/heads/<branch>` over `refs/remotes/origin/<branch>`. `git fetch origin <branch>` never updates a local branch of the same name. A leftover local ref from an earlier session gives you a worktree at a stale commit, with no warning. Your push then fails non-fast-forward. That's the safety net working, but a caller that force-pushes on rejection would drop someone else's commits.

**Rule:** when you stage onto an existing non-default branch, always use the fully qualified remote ref:

```bash
git fetch origin <branch>
git worktree add <path> origin/<branch> --detach
```

A rejected non-fast-forward push means either this trap or a real concurrent writer. Fetch and rebase onto the true remote tip. Never force-push.

### A push doesn't update a separate long-lived checkout

Landing via a worktree only guarantees that `origin/<default-branch>` is correct. If some automation reads files directly from its own persistent checkout of the repo (with no fetch or pull at startup), your fix isn't live there until that checkout fast-forwards:

```bash
git -C <that-checkout> fetch && git -C <that-checkout> merge --ff-only origin/<default-branch>
git -C <that-checkout> log --oneline <local-branch>..origin/<default-branch>   # non-empty = still stale
```

Don't reuse a note like "checkout untouched, tree dirty for known reasons" as evidence that the checkout is current. Re-run the diff.

### Deploys read the canonical checkout

Merge and push before you run a deploy or reload that reads from the canonical checkout. Otherwise you ship the code as it was before your worktree.

## Enforcement: a worktree guard (PreToolUse)

A rule in a doc is only advisory. A `PreToolUse` hook on `Edit|Write` can enforce it by denying the **first write** to a repo when all three of these hold:

1. the target is inside a repo under your guarded root, **and**
2. it isn't already inside `.claude/worktrees/`, **and**
3. another **live** session has written **that same file**.

**Don't make condition 3 "another session holds that repo".** Several sessions sharing a repo is the normal state, not a collision. Guarding at repo level produces denials with zero overlapping files, and sessions learn to override them. The real risk at repo level (a stage-everything commit sweeping up a peer's work) belongs to a separate deny rule on those commands.

Implementation traps:
- Ledger paths may be absolute but not normalized (for example containing `/./`). Normalize both sides before comparing, or the guard quietly never fires.
- An unquoted heredoc expands variables but does **not** interpret `\n`.
- Key the check on the **target file path**, not on `cwd`. Editing an absolute canonical path from inside a worktree is still not isolated.

**Why PreToolUse and not Stop:** at Stop the edit has already happened in the shared checkout, so blocking can't isolate anything after the fact. Stop also can't tell "correctly skipped" apart from "forgot", so it would fire on exempt cases and train people to ack by reflex. Stop's job is catching work stranded in a worktree.

Give it an escape hatch shared with any claim guard, for example a per-session ack file:

```bash
printf '%s\t%s\n' '<repo-name>' '<reason>' >> /tmp/claude-claim-ack-<sid>
```

Skip worktrees for read-only work, one-file edits, and ops tasks.

### When the guard fires, check committed vs uncommitted first

Run `git status --short <file>` and compare `git show HEAD:<file>` with the working tree.
- **The peer's change is committed** (working tree clean for that file): branch a worktree from HEAD. The later merge fast-forwards with no conflict.
- **The peer is actively editing** (file dirty, hash changing, HEAD moving): don't ack and edit the shared file. Create a worktree from committed HEAD and re-read the file **fresh** there (your earlier Read may be stale). Make and verify the change, commit, and push a dedicated branch. Don't merge to the default branch or deploy while the peer holds uncommitted changes; git refuses anyway. Leave a note saying the branch needs rebasing once the peer settles. Committed HEAD can itself be broken mid-refactor, so run it before trusting it as a base.
- **The code you need to edit exists only in the peer's uncommitted tree:** a worktree from HEAD has nothing to anchor your hunks to. Edit in place with an explicit ack, and keep your hunks separate from the peer's work-in-progress hunks when you build the deploy artifact (see "The deployed file can be a third state" below).

### Resolving a conflict the guard won't let you edit

If merging your branch in the canonical checkout conflicts, and the guard blocks edits to the conflicted file there:

```bash
git -C <canonical> merge --abort
git -C <worktree> merge <default-branch> --no-edit     # reproduce the conflict where you may edit
# resolve and commit in the worktree
git -C <canonical> merge <branch> --ff-only
```

## Problem B: take a real lock

Wrap each operation on a singleton in a named lock:

```bash
with-resource-lock.sh <resource> [--timeout N] -- <command...>
with-resource-lock.sh --list          # who holds what right now
```

Keep the resource names stable, because the string *is* the lock:

| Resource | Covers |
|---|---|
| `deploy:<app>` | the app's deploy directory and its service |
| `browser-extension` | the live browser extension: reload, debugger attach, tab state |
| `<host>:skills` | a shared skills/config directory on a remote host |

Put the lock where everyone already goes: in the shared deploy skill, or self-wrapped in the reload command, not scattered across per-repo deploy scripts.

Properties a good lock wrapper needs:
- It's backed by `flock(2)`, so the kernel releases the lock when the holder exits, **including on crash or SIGKILL**. A dead session can never wedge a resource.
- A wait past `--timeout` exits **75** (`EX_TEMPFAIL`), separate from the wrapped command's own failures, and names the holder.
- It's re-entrant within one process tree (for example through an env var listing held locks), so a locked script calling another locked script doesn't deadlock.

### The fd-inheritance gotcha

A child process **inherits the lock file descriptor**. If the command you wrap daemonizes (`pm2 restart`, `nohup`, `setsid`), the service keeps the fd after the deploy ends and holds the lock *forever*. That's worse than having no lock. Close the fd in the child by running the command as `"$@" 9>&-`. To verify:

```bash
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  ls -l /proc/$p/fd 2>/dev/null | grep -q "<lock-file-name>" && echo "holds: $p"
done
```

Only the wrapper's own pid should show up.

### A lock only serializes sessions that use it

If another session deploys the same app without the lock, it can stop production and run a partial sync while you `rm -rf` and rebuild the shared staging directory. The result is production down with a partial build.
- **Recovery:** don't roll back to the pre-collision backup, because that loses the new work. Verify the staging directory holds a complete build of the intended commit (server entrypoint present, `git rev-parse` matches), then finish the promote from it and health-check.
- **Prevention:** before you wipe a shared staging directory, check the process manager for a running staging service and look for another session's build or rsync in progress. Always merge to the default branch first, so the code survives an artifact race.

### A runner's own pidfile lock doesn't stop a manual second run

A `.running.lock` pidfile only serializes a runner script against itself (a second cron tick). It does nothing to stop a person or another session from executing the same mission file by hand. Two concurrent executions would race on the same PRs, logs, and state counters.

Before you execute a lock-guarded runner's mission by hand:

0. **Ownership pre-check. Do this first; it's the common case.** If the lock PID is one of your own ancestors, you *are* the runner's dispatched child. Proceed, and don't report `BLOCKED`. Walk the whole chain, because runners typically go `run.sh` → `timeout` → `claude`:
   ```bash
   pid=$(cat <runner-dir>/.running.lock); p=$$
   while [ "$p" -gt 1 ]; do [ "$p" = "$pid" ] && { echo "OWN RUN, proceed"; break; }; p=$(awk '/^PPid:/{print $2}' /proc/$p/status); done
   ```
   Skipping this makes legitimate runs detect themselves and block, and each false `BLOCKED` report then gets cited as "evidence" of collisions. A runner can make ownership explicit: stamp an ownership header into the child's prompt and write a `.running.owner` file (`runner_pid=...`) beside the lock.
1. `cat <runner-dir>/.running.lock` to get the PID.
2. `ps -p <PID>` to confirm it's alive and really is the runner, not a stale pidfile.
3. `ps --ppid <PID>` to find its spawned agent child.
4. Diff that child's command line against the mission you were handed.

Stop and report `BLOCKED` only if step 0 doesn't clear you **and** there's a live duplicate. If the lock PID is dead, it's safe to proceed.

## Git hygiene in a shared checkout

### The index is shared too: check what's staged before every commit

Your `git add <one-file>` adds to an index a peer may already have staged into. A pre-commit secret gate then blocks *your* commit because of *their* content.

- **Don't** `git commit --no-verify`. The gate is right, and bypassing it ships the peer's leaks.
- **Don't** `git stash`. It touches the working tree and can yank files away from a live peer mid-write.
- **Do** unstage the peer's paths by name. That changes only the index:
  ```bash
  git diff --cached --name-only            # whose files are staged?
  git restore --staged <peer-path> ...     # index only; files stay on disk
  git diff --cached --name-only            # confirm only yours remain
  ```
- Or commit only your paths: `git commit --only -m "MSG" -- path/to/file`. Put `-m` **before** `--`, or git parses the message as a pathspec.

Report the blocked files as an open item so the leaks get fixed rather than quietly re-staged.

### `git reset --hard` discards a peer's uncommitted work on any tracked file

A bare `git reset` (mixed) touches only the index. `git reset --hard`, `git checkout .`, and `git clean -f` rewrite the **working tree** and discard every uncommitted change in it. Changes that were never `git add`ed exist in no git object and can't be recovered. "Routinely dirty, safe to ignore" means you read past the file in `git status`; it doesn't mean the file is safe to wipe.

**Rule:** before any command that touches the working tree in a shared checkout, run `git status --short` and isolate every path that isn't yours (`git stash push --include-untracked -- <peer-path>...`, or commit it first if that's the repo's convention). Better: resolve diverged-branch conflicts in a scratch worktree off the fresh remote tip, never in the shared checkout.

### Recovering from a peer's reset

- **Detect it:** a file you edited is suddenly clean in `git status`, and its mtime matches a `reset: moving to ...` entry in the reflog.
- **Staged-then-discarded content** still exists as a blob:
  ```bash
  git fsck --no-reflogs --lost-found
  # grep the dangling blobs for a signature string, then:
  git cat-file -p <blob> > file
  ```
- **Never-staged content** is gone from git. Rebuild it from your own copies. Save every generated patch or extracted script as a file in a scratch directory, not an inline heredoc, so a wipe is recoverable. Or rebuild from a prior Read of the file that's still in your context.
- **Prevention:** commit early, from a worktree, as soon as the change builds and passes a syntax check, before smoke-testing or deploying. Keep a `/tmp` backup of the final file.

### A diff that looks like a "stray" change may be a peer's work in progress

Before you stash, discard, or "fix" a working-tree diff you didn't make, run `git rev-parse HEAD` and `git log --oneline -5`. A peer may commit it minutes later and move HEAD; what looked like a stray reversion was intended work.

### A stale branch deletes a sibling's additions when merged

If a peer committed new files to the default branch after you cut your branch, merging can make your branch's tree authoritative for paths it never knew about. Before you merge any branch more than a few minutes old in a repo other agents write to:

```bash
git diff --stat origin/<default-branch>..HEAD
```

Read the **deletions**. If it deletes files you never touched, your branch is stale, not conflicted. Cut a fresh branch from the current default branch and replay only your files with `git checkout <old-sha> -- <your files>`. Prefer that over rebasing, because resolving a rebase churns the working tree while peers are still writing to it.

### A checkout left on an already-merged branch serves stale docs

A session checks out its feature branch in the shared checkout, its PR merges, and nobody switches back. The checkout now lacks everything the default branch gained since. A guidance file on disk then looks like it's missing a documented fix that the remote clearly has, and that sends you off to re-add content that already exists.

- **Detect:** compare `git -C <repo> branch --show-current` with `gh repo view <repo> --json defaultBranchRef -q .defaultBranchRef.name`.
- **Recover:** `git status --short` must be clean; don't touch a dirty tree. Squash merges break ancestry, so compare *content*, not `merge-base --is-ancestor`: `git diff <stray-unique-commit> origin/<default> -- <changed-files>` should be empty or a strict subset. Only then run `git checkout <default> && git pull --ff-only`. If the stray branch holds content the default branch lacks, stop and investigate.

### When the default branch is moving fast, land with a remote fast-forward push

When peers push the same branch every few seconds, don't merge into the canonical checkout. Its index is being mutated as you work, and you can wedge a peer's in-flight merge. The symptom is "unmerged paths" with no `MERGE_HEAD` and no conflict markers. Instead:

```bash
# on your worktree branch
git merge origin/<default-branch>          # resolve in isolation
git push origin HEAD:<default-branch>      # rejected if main moved: re-merge and retry (expect 2-3 tries)
```

A fast-forward push can never clobber remote commits.

## Worktree-specific traps

### A `name/` gitignore rule doesn't match a symlink called `name`

Worktrees have no `node_modules`, so people symlink the main checkout's copy in. A trailing-slash pattern (`node_modules/`) matches directories only, and to git a symlink is a blob (mode 120000). `git status` shows `?? node_modules` as an untracked **file**, and `git add -A` commits a symlink holding an absolute path from your home directory. That leaks an infrastructure path and leaves a dangling link for anyone who checks out the branch.

- Read `git diff --staged --stat` and `git status --short` before every commit in a worktree. Treat any unexpected `??` entry or `node_modules` row as a stop sign.
- Remove the symlink before committing (`git rm --cached node_modules` if it's already staged), and prefer `git add <explicit paths>` over `git add -A` in a worktree.
- Or use the slash-less pattern `node_modules`, which matches a directory, file, or symlink.
- The same applies to `dist/`, `build/`, `.next/`, `coverage/`, and `venv/`.

### A Next.js standalone build in a worktree nests its output

Standalone output mirrors the project path relative to the repo root. From a worktree it lands at `.next/standalone/<worktree-path>/.next/`, so a build script like this fails on its last step:

```
next build && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static
# cp: cannot create directory '.next/standalone/.next/static': No such file or directory
```

The compile succeeds and lists every route, so the run looks like a pass until that final line. **Never deploy artifacts built in a worktree**: the static assets end up where the server won't serve them, and you get an unstyled page. Treat the `cp` failure as a hard stop. Worktree builds are fine for typechecking and validation; build deployables from the primary checkout after merging.

### A relative-path shell edit runs in the shared checkout, not your worktree

The shell's cwd can reset to the canonical repo root between tool calls, so a follow-up command like `perl -0pi -e 's/.../.../' src/file.js` rewrites the **shared checkout** and never touches your worktree. It can look green twice: `node --check` parses syntax but never resolves identifiers, and a confirming `grep` finds the substitution in the wrong tree.

1. Use **absolute paths** for every scripted edit in a worktree (`perl`, `sed`, `awk`, `mv`, `cp`), unless the same command sets its own cwd.
2. After any scripted in-place edit, run `git -C <worktree> diff --stat` for what you meant to change and `git -C <main-checkout> status --short` for what you didn't.
3. Revert a leak surgically by inverting the same substitution. `git checkout -- <file>` in a shared checkout also discards a live peer's uncommitted work in that file.

## Deploying under concurrency

### Deploy from the merged default branch, not from your worktree

A worktree's generated output reflects only your branch. Deploying it publishes a build without whatever landed on the default branch meanwhile, and silently reverts a peer's shipped feature.

1. Merge to the default branch (`git merge --no-ff <branch>`).
2. **Regenerate** generated files there instead of resolving them as text. A conflict in `dist/` is a stale artifact, not a real conflict.
3. Run the test suites against the merged output.
4. Deploy, then check that the live build stamp matches the one you shipped.

A live build stamp you don't recognize, before or after your deploy, means someone else deployed while you worked. That check only works if your builds carry a stamp.

### Deploy the artifact you verified, and check it before it leaves

Rsyncing from the shared checkout right after a clean fast-forward can still ship files a peer's merge just rewrote with conflict markers in them. The shared checkout isn't yours between one command and the next.

- Rsync from the path you built and tested.
- If the page stamps its own build hash, grep for the stamp and require exactly one match. Two stamps is the signature of a conflicted merge.
- Afterward, compare checksums of the local and deployed files.

### Deploy only your files into a shared static directory

When peers are editing other files in the same deployed directory, rsync only your changed files: no `--delete`, no whole-directory sync. That way you can't revert a peer's live edits that haven't been pushed yet. For a single file, extract it from the **latest** default branch (`git show origin/<default-branch>:<path> > /tmp/x`) and deploy that, so you never regress a peer change that landed after your push. If the host sits behind a CDN edge cache, check the cache status header when you verify, or you may be validating the old deploy.

### The deployed file can be a third state

A peer may have deployed newer work than HEAD without committing it, while also holding different uncommitted work in progress in the shared tree. In that case neither "rsync my working copy" (ships the peer's untested work) nor "rsync the default branch's copy" (drops the peer's deployed work) is safe.

1. Fetch the deployed file: `ssh <host> cat <path> > /tmp/deployed`.
2. Diff it against your local copy to see every divergence.
3. Build the artifact as the **deployed file plus only your hunks**, with a scripted string replacement that asserts each anchor matches exactly once.
4. Upload it and confirm by `sha256sum` that the remote file equals your artifact.
5. For git, commit only your hunks against HEAD on a worktree branch and push that branch. If the fast-forward into the shared checkout is blocked by the peer's dirty tree, that's your signal to push the branch rather than force the merge.

## Duplicate agents on the same task

### One request can spawn two agents

A message sent twice, or a "retry/troubleshoot" reaction dispatched as its own job while the original handler is still running, gives you two agents on the same task in the same checkout. They rename over each other's files, delete survivors during cleanup, and double-update shared external resources.

Signals that a live peer is present:
- `git status` changes between your commands
- the worktree guard reports another live session wrote this exact file
- a file you didn't create appears, or a file's mtime is now
- another agent process whose start time matches the request dispatch
- an uncommitted diff that already implements the **same** feature

Rules:
1. Before any `rm`, `mv`, or commit in a shared checkout, run `git status` and heed the guard. If a file you didn't create is present, **read** it; don't delete or overwrite it.
2. If the original run is still in flight, **stand down**: don't edit or commit. Review its implementation read-only, watch for its commit and verify it, and take over only if that process dies and leaves orphaned dirty work.
3. If a competing implementation has already merged, **layer onto it**: keep its structure and add only the missing piece.
4. Don't double-commit the same paths or double-update shared external resources the other session owns.
5. If you delete a peer's untracked file by accident, restore it from your own earlier Read of it. Git can't bring it back.
6. Put the substance in your final message anyway, because the peer's commit may win the files.

### Two agents driving one browser profile need a claims file

When two jobs drive the same browser profile, interleaved fills and clicks corrupt each other's half-filled forms, and duplicate submissions can create duplicate records with third parties.

- **Detect, don't guess:** the browser tool's logs may show per-consumer IDs that aren't yours. Other signs are tabs you didn't open, "another debugger is already attached", and timeouts on every other command. Cross-check with `ps` start times against your own PID chain.
- Before the first `fill` on a new target, list the shared scratch directory and **read** any claims file. Then append `PID -> target` to it before you drive the form.
- Never take a vendor's "record already exists" response as proof that your own submit worked. It's equally consistent with a sibling having submitted. Verify by logging in, or check the claims file.
- Target tabs by explicit tab ID and assert the URL before acting. A loose URL substring can drive the wrong page.
- In your report, say that the other job's targets are its to report. Never assert an outcome for a target you didn't drive.

## The backstop: a claim guard

Detection can't serialize anything, so it's the third line of defense. It earns its place by catching two sessions that took neither a worktree nor a lock and are writing the same path right now.

| Mode | When | Behavior |
|---|---|---|
| `warn` | PostToolUse `Bash\|Edit\|Write` | Names the other live session when it wrote the same file. Deduped: once per path per peer. |
| `deny` | PreToolUse `Bash` | Exits 2 on `git add -A/--all/.`, `git commit -a/--all`, and `rsync --delete` into a deploy directory when a live peer holds that repo or target. |

Design notes:
- **Infer Bash writes.** Heredocs, redirects, and `sed -i` are invisible to a tracker that only watches `file_path`. Favor precision over recall: a bare `python3` isn't a write; one whose body writes a file is.
- **Parse commands into segments** before judging them. Drop heredoc bodies, unwrap `ssh <host> '<remote>'`, and strip string literals. Otherwise a commit message that *describes* `git add -A` gets denied as if it ran it.
- **Track liveness per session** with a heartbeat file. Otherwise the guard fires on ledgers left by sessions that exited weeks ago.
- **Keep two ledgers:** authoritative Edit/Write authorship (which may feed a Stop gate) and heuristic Bash-inferred claims (advisory only). Heuristics must never reach a gate that blocks a session from exiting.
- **Scope the Stop gate to files:** intersect each unpushed commit's files with this session's own write ledger. Block only on commits containing files this session wrote, and just report a peer's unpushed commits.
- **Log** denials, overrides, and unresolvable targets (for example a `cd` target built from a variable set in an earlier turn), so blind spots can be audited.
- **Always provide an escape hatch** (the ack file above). A denial must never be a dead end.
- In hook registration, the `deny` entry must **not** end in `exit 0`. Swallowing its exit code turns the block into a no-op.

## Hygiene and monitoring

- **Reap stale session state.** Sessions never clean up their `/tmp` ledgers and markers. The pile-up misleads anyone reading raw marker counts, and it slows guards that iterate every ledger. Reap on an hourly cron at a generous age (for example 24h) with a hard floor (for example 2h) that refuses anything shorter, because an over-eager reap silently blinds the guards.
- **Watch whether guards get routed around.** The signal is the **override rate**, not the deny count. A guard that fires and is obeyed works; a guard that fires and gets overridden is no different from having none. Count **distinct sessions**, not log lines, because one ack decision logs on every later write. Alert when the rate of sessions that were denied and then overrode is high.
- **Verify distribution after editing a hook.** If hooks are copied into each repo's `.git/hooks` or a template directory, editing the source changes nothing. Grep the **installed** copies for a marker from the new code.

## Diagnostic order when something "keeps reverting"

1. `stat` the origin file and compare it with your deploy time.
2. `git log -- <path>` for commits you didn't make.
3. Map the live sessions (heartbeat files, `ps`, `ListAgents`).

Only after that should you suspect a cache or a cron.

**Don't kill a live session to win a race.** It's usually the operator's own. Check whether its tree is clean and pushed, then ask.
