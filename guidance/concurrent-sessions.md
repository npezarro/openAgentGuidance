<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

You may have several Claude sessions running at once, often with permissions bypassed, all sharing one checkout per repo. Collisions keep coming back, and each fix narrows the window without closing it.

**Why it keeps coming back: these are two separate problems, and one mechanism was being asked to solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. The index and working tree are mutable shared state that nobody owns. | Deploy targets (`/var/www/<app>`), process-manager services, a live browser extension, a shared skills directory, a remote server. Only one of each exists. |
| Symptom | `git add -A` commits someone else's uncommitted work; two sessions commit the same file seconds apart. | One session's deploy overwrites another's; two extension reloads tear down each other's service worker. |
| Right fix | **Remove the sharing** (one git worktree per session). | **Serialize** (a real lock) or **partition** (one owner per path). |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. You can carry on past them, so nothing gets serialized. |

A detection hook (one that warns when another session has touched the file you're about to edit) is worth having. Keep it as the backstop, not the strategy.

## Problem A: use a worktree per session

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**`EnterWorktree` is often unavailable.** The tool needs the session's cwd to be inside a git repo. Sessions launched from a non-repo directory, or ones that span several repos, can't use it. Don't skip isolation because of that: the mechanism is git worktrees, and `EnterWorktree` is just one convenience wrapper. This works from anywhere:

```bash
git -C $HOME/<repo> worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/<repo>/.claude/worktrees/<n>/...
git -C $HOME/<repo> merge --no-ff <n> && git -C $HOME/<repo> push
```

Any guard hook should decide "isolated or not" from the target file path, not from cwd, so this cross-repo pattern still counts as isolated. Any "unpushed commits" check should also scan worktrees, so a stranded commit there still gets caught.

Once you're in a worktree, no other session's uncommitted work is in your tree. `git add -A` is then safe **by construction**, and the whole class of bug goes away.

It costs less than you'd expect. Worktrees live under `.claude/worktrees/`, so the canonical checkout **stays where it is**. Cron jobs and process-manager configs that hardcode its path keep working unchanged. They actually get better, because they run against a clean committed tree instead of one several sessions are halfway through editing.

The real costs:
- Each session ends with a merge back to the default branch. Solo work gets more ceremony.
- Git won't check out the same branch in two worktrees. That's a feature (it forces a branch per session), but it changes behavior.
- It does nothing for Problem B.
- Separate clones aren't affected either way. A second clone of the same repo (for example, one on another filesystem that a tool loads from) still has to be pulled on its own.

Add `.claude/worktrees/` to your **global** gitignore (`core.excludesFile`) so you don't need a per-repo step.

## Problem B: take a real lock

Wrap every operation on a named singleton in a blocking lock. A minimal portable wrapper uses `flock`:

```bash
# with-resource-lock.sh <resource> [--timeout N] -- <command...>
mkdir -p /tmp/resource-locks
flock -w "${TIMEOUT:-600}" "/tmp/resource-locks/${RESOURCE//[:\/]/_}.lock" "$@"
```

Have it record the holder (PID, session, start time) in a file so that `--list` can show who holds what right now.

Keep resource names stable. The string is the lock:

| Resource | Covers |
|---|---|
| `deploy:<app>` | `/var/www/<app>` and that app's service |
| `browser-extension` | the live browser extension: reload, debugging protocol, tab state |
| `remote:skills` | the skills directory on a remote host |

Put the lock where everyone goes through it. If deploys already go through one shared skill or script, wrap that one place rather than every per-repo `deploy.sh`. Tools that touch a singleton (an extension-reload command, a skills sync script) should wrap themselves and offer an explicit opt-out env var.

## Diagnostic order when something "keeps reverting"

Before you blame a cache or a cron job:
1. `stat` the origin file and compare its mtime with your deploy time.
2. Run `git log -- <path>` and look for commits from other sessions.
3. List the live sessions (session liveness files, `ps`, or your agent listing tool).

**Don't kill a live session to win a race.** It's usually the operator's own. Check whether its tree is clean and pushed, then ask.

## Deploy from the merged default branch, not from your worktree

A worktree isolates your edits, which is the point. But its generated output (`dist/`, a build directory, an artifact) only reflects your branch. If you deploy from it, you publish a build that's missing whatever landed on the default branch while you worked, and that silently reverts another session's shipped feature. Neither side notices.

Do it in this order:

1. Merge to the default branch (`git merge --no-ff <branch>`).
2. **Regenerate** generated files there instead of resolving them as text. A conflict in `dist/` isn't a real conflict; it's a stale artifact.
3. Run the test suites against the merged output, not against your branch.
4. Deploy, then compare the live build stamp with the one you shipped.

If you don't recognise the live build stamp, before or after your deploy, someone else deployed while you were working. That's the cheapest detector there is, and it only works if every build carries a stamp.

## A relative-path shell edit runs in the shared checkout, not your worktree

The worktree protects you from a stage-everything commit. It does **not** protect you from a shell command that resolves its own path.

Failure pattern: a file is edited correctly in the worktree with an absolute path. A follow-up `perl -0pi -e 's/.../.../' src/file.js` then uses a **relative** path. The shell's cwd had reset to the main repo root between tool calls, so the substitution rewrote the **shared main checkout**, and the worktree file was never edited.

Both checks came back green:
- `node --check` passed on the contaminated file. It only parses syntax and never resolves identifiers, so a reference to an undefined constant passes and fails only at runtime.
- The confirming `grep` found the substitution, but in the wrong tree.

The failure showed up much later as an error that looked unrelated.

Rules:
1. **Use absolute paths for every scripted edit in a worktree** (`perl`, `sed`, `awk`, `mv`, `cp`), not just for the editor tool. A relative path is only safe when the same command sets cwd first.
2. **After any scripted in-place edit, check that the shared checkout is clean.** Run `git -C <worktree> diff --stat` for what you meant to change and `git -C <main-checkout> status --short` for what you didn't. It's the only check that catches this.
3. **Revert a leak surgically** by applying the inverse substitution. `git checkout -- <file>` in a shared checkout would also throw away another live session's uncommitted work in that file.

## Rule Digest

One line per lesson.

**Landing and merging**
- **Never merge from the shared checkout.** `cd <primary> && git merge <my-branch>` merges into whatever branch is checked out *now*, which may not be the one that was there when you started. Land from a dedicated landing worktree, or push your branch and fast-forward the remote.
- **Don't check out the default branch by name inside the landing worktree.** That fails, or ties up the branch the main checkout needs. Use a detached HEAD at `origin/<default>`.
- **A push from the landing worktree doesn't update other long-lived checkouts of the same repo.** Pull them explicitly.
- **`git worktree add <path> <branch> --detach` can resolve to a stale local ref, even right after `git fetch`.** Pass `origin/<branch>` explicitly.
- **A branch that's older than a concurrent session's additions can delete them on merge.** Rebase onto the current default branch and review the diff for deletions you didn't make.
- **On a fast-moving default branch, land with a remote fast-forward push and deploy the file from the latest `origin/<default>`.**
- **The deployed file can be a third, different state.** Build the deploy artifact from what's actually deployed plus only your hunks, not from your branch's copy.
- **When a live session is mid-edit on your exact file, branch from committed HEAD and push a branch.** Don't merge underneath an active writer.
- **A main checkout left on a stray, already-merged branch serves stale content** (including a stale `CLAUDE.md`) and looks like a false "undocumented gap". Check the branch of every repo a sweep touches.

**Shared index and working tree**
- **`git add` uses a shared staging area.** A pre-commit secret gate can block *your* commit because of a peer's staged content. Commit with `git commit --only <paths>` so you don't sweep up a sibling's staged files.
- **A peer's `git add`-ed work that got reverted can be recovered from its dangling blob** (`git fsck --lost-found`).
- **`git reset --hard` in a shared checkout throws away a peer's uncommitted work on every tracked file**, not just the one that caused your conflict. Never run it there. If a peer has already done it to you, rebuild from scratch copies and commit from a worktree.
- **A "stray" uncommitted change in a shared checkout may be a live peer's in-flight edit** that commits partway through your task and moves HEAD. Leave it alone.
- **A worktree can't host an edit that exists only in a sibling's uncommitted working tree.** Wait for it to be committed or ask.
- **When a worktree guard fires, check whether the conflicting change is committed or uncommitted before choosing a path.** Resolve merge conflicts in the worktree branch, not in the canonical checkout. A guard may keep firing from its claim ledger even after the sibling has committed; check git, not just the ledger.
- **A `node_modules/` gitignore rule (with the trailing slash) doesn't match a `node_modules` symlink.** Linking deps into a worktree therefore makes them stageable by `git add -A`. Add a slash-less `node_modules` rule too.
- **Deploying by rsync from the shared checkout can ship a file that still has conflict markers.** Grep for `^<<<<<<<` before you ship.

**Builds in worktrees**
- **A Next.js standalone build inside a worktree nests its output** under the worktree's relative path. Never deploy those artifacts, and when `test -f .next/standalone/server.js` fails, check where `server.js` actually landed before treating it as a build defect. If you build in a directory outside the repo to avoid the nesting, hardlink-copy `node_modules` in (`cp -al`); a symlink makes Turbopack abort.

**Runners, locks and liveness flags**
- **A runner's own lock file doesn't stop a second, manually launched invocation.** Check the lock in every entry point.
- **Before you clear a running/liveness flag to start a fresh run, poll until it's actually false.** Clearing it unconditionally bypasses the guard it exists for, and the old and new runs then drive the same resource at the same time.
- **A "check for a duplicate runner" recipe run by the lock holder's own child process finds itself.** Exclude your own PID ancestry before you report BLOCKED.
- **A lock-free concurrent deploy of the same app can stop production and wipe/rebuild a shared staging directory mid-build**, leaving production down with a partial build. Always deploy under `deploy:<app>`.

**Shared browsers and duplicate jobs**
- **Two agents on one browser profile must claim targets in a shared claims file before the first form fill.** Otherwise they duplicate each other's actions.
- **A message sent twice to a bot can start two concurrent agents racing on the same deliverable** in one checkout. Dedupe on message ID.
- **A parallel session can merge a competing PR for the same task and reset the shared checkout**, silently throwing away your uncommitted edits. Work in a worktree.
- **A follow-up "troubleshoot" request can race the original request's handler on the same file.**
- **Before starting work in a shared folder, check for a parallel workstream:** `git log --since` on the folder, any matching deliverables directory, and idle peer agents.

**Hygiene and verification**
- **Reap stale session ledgers on a schedule**, with a hard minimum age so the guards are never left blind. Alert on how often a guard is overridden, not on how often it denies.
- **Bridging a local session to a web UI can silently drop permission-bypass mode.** Re-check the mode after bridging.
- **Verify a Claude Code settings change with a headless `claude -p` A/B run**, not by reading the transcript.
