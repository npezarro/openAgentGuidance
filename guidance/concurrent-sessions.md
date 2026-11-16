<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

You may run several agent sessions on one machine at the same time, often with permission prompts disabled, all sharing one checkout per repo. Collisions keep coming back, and each fix narrows the window without closing it.

**Why it keeps coming back: these are two separate problems, and one mechanism was being asked to solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. The index and working tree are mutable shared state that nobody owns. | Deploy target directories, process-manager services, a live browser extension, a shared skills directory, a remote server. Only one of each exists. |
| Symptom | `git add -A` commits someone else's uncommitted work; two sessions commit the same file seconds apart. | One session's deploy overwrites another's; two extension reloads tear down each other's service worker. |
| Right fix | **Remove the sharing** (one git worktree per session). | **Serialize** (a real lock) or **partition** (one owner per path). |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. Sessions can carry on past them, so nothing is serialized. |

A detection hook (a "claim guard" that warns when another live session has touched a file) does catch real hazards. But it is detection applied to both columns. Keep it as the backstop, not the strategy.

## Problem A: use a worktree per session

If your harness has a worktree tool:

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**The tool is often unavailable, so don't write rules that depend on it.** `EnterWorktree` needs the session's cwd to be inside a git repo. Sessions launched from a non-repo directory, or spanning several repos, can't use it. A rule that can't be followed gets skipped silently, and that weakens the rest of the file.

The real mechanism is git worktrees; the tool is just a wrapper. This works from any directory:

```bash
git -C $HOME/<repo> worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/<repo>/.claude/worktrees/<n>/...
git -C $HOME/<repo> merge --no-ff <n> && git -C $HOME/<repo> push
```

This works across repos from a non-repo cwd as long as your guard hooks decide "is this isolated?" from the **target file path** and not from cwd. Your unpushed-work checks should also scan worktrees, so a commit stranded there still gets reported.

Then your tree contains no other session's uncommitted work, so `git add -A` is safe **by construction** and the whole class of bug goes away.

It's cheaper than it looks: worktrees live under `.claude/worktrees/`, so the canonical checkout **stays where it is**. Crontab entries and process-manager configs that hardcode the canonical path keep working, and they get better, because they now run against a clean committed tree instead of one several sessions are editing.

Make `.claude/worktrees/` ignored globally (in your global gitignore) so no per-repo step is needed.

The real costs:
- Every session ends with a merge back to the default branch. That's extra ceremony for solo work.
- Git refuses to check out the same branch in two worktrees. That's a feature (it forces per-session branches), but it changes behavior.
- It does nothing for Problem B.
- Separate clones (for example a copy on another filesystem that a browser loads an extension from) are unaffected either way. They still have to be pulled before you reload from them.

## Problem B: take a real lock

Serialize every operation on a named singleton with a blocking lock. `flock` is a portable way to do it:

```bash
mkdir -p /tmp/resource-locks
flock --timeout 600 "/tmp/resource-locks/deploy:<app>.lock" -- <command...>
```

Wrap this in a small script (for example `with-resource-lock.sh <resource> [--timeout N] -- <command...>`) that also has a `--list` mode showing who holds what, by writing the holder's PID and command next to the lock.

Keep the resource names stable, because the string **is** the lock:

| Resource | Covers |
|---|---|
| `deploy:<app>` | that app's deploy target directory and its service |
| `browser-extension` | the live browser extension: reload, debugging protocol, tab state |
| `remote:skills` | a skills or config directory synced to a remote host |

Put the lock where everyone already passes through:
- The extension reload command should take the lock itself, with an env var to opt out.
- The skills sync script should replace any hand-run rsync. It should also count the files across every copy and fail on a mismatch.
- Put the deploy lock in the shared deploy entry point (a deploy skill or wrapper), not in each repo's deploy script, as long as the rule is that every deploy goes through that entry point.

## Diagnostic order when something "keeps reverting"

Before you blame caching or cron:
1. `stat` the origin file and compare it with your deploy time.
2. `git log -- <path>` to look for commits by other sessions.
3. List the live sessions (whatever liveness markers your sessions write).

**Don't kill a live session to win a race.** It is usually the operator's own. Check whether its tree is clean and pushed, then ask.

## Deploy from the merged default branch, not from your worktree

A worktree isolates your edits, which is the point. But its generated output (`dist/`, a build directory, an artifact) only reflects your branch. Deploying from it ships a build that's missing whatever reached the default branch while you worked, which silently reverts another session's shipped feature. Neither side notices, and when the other session redeploys, the damage gets fixed by luck.

Do it in this order:

1. Merge to the default branch (`git merge --no-ff <branch>`).
2. **Rebuild** generated files there instead of resolving their conflicts as text. A conflict in `dist/` isn't a real conflict, just a stale artifact.
3. Run the test suites against the merged output, not the branch's.
4. Deploy, then compare the live build stamp with the one you shipped.

If the live build stamp is one you don't recognise, before or after your deploy, someone else deployed while you worked. That's the cheapest detector there is, and it only works if every build carries a stamp.

## A relative-path shell edit runs in the shared checkout, not your worktree

A worktree protects you from a stage-everything commit. It **doesn't** protect you from a shell command that resolves its own path.

Here's how it fails. You edit a file in the worktree using an absolute path. A follow-up `perl -0pi -e 's/.../.../' src/server.js` uses a **relative** path. The shell's cwd has reset to the canonical repo root between tool calls, so the substitution rewrites the **shared checkout**, which now references a constant that only exists in the worktree. The worktree file never gets edited.

Two checks still pass:
- `node --check` passes on the contaminated file. It only parses syntax and never resolves identifiers, so a reference to an undefined constant fails only at runtime.
- The confirming `grep` finds the substitution, but in the wrong tree.

The failure shows up much later, as an error in a test that should have picked up the change and looks unrelated.

Rules:
1. **Use absolute paths for every scripted edit in a worktree** (`perl`, `sed`, `awk`, `mv`, `cp`), not just in the editor tool. A relative path is only safe when the same command sets the cwd.
2. **After any scripted in-place edit, check that the shared checkout is still clean.** Run `git -C <worktree> diff --stat` to see what you meant to change and `git -C <main-checkout> status --short` to see what you didn't mean to change. This is the only check that catches the leak.
3. **Undo a leak surgically** by running the opposite substitution. `git checkout -- <file>` in a shared checkout would also throw away another live session's uncommitted work in that file.

## Rule Digest

One line per lesson.

**Landing and merging**
- **Never merge from the shared checkout.** `cd <primary> && git merge <my-branch>` merges into whatever branch is checked out *right now*, which may not be the one that was there when you started. Land from a dedicated landing worktree, or fast-forward-push to the remote.
- **Don't check out the default branch by name inside a landing worktree.** That puts the shared branch back into a second working tree and undoes the isolation. Land on a detached HEAD or push `HEAD:<default>`.
- **A push from the landing worktree does not update a different long-lived checkout of the same repo.** Anything that reads that other checkout (crons, services) still sees the old tree until it is pulled.
- **`git worktree add <path> <branch> --detach` can pick up a stale local ref, even right after `git fetch origin <branch>`.** Name `origin/<branch>` explicitly and check the resolved SHA.
- **If your main moves fast, land by fast-forward-pushing to the remote and deploy the file from the latest `origin/<default>`**, not from your local view.
- **A branch that predates another session's additions deletes them when merged** if conflicts are resolved toward your side. Rebase onto the current default branch first and diff the result.
- **When the worktree guard fires because a live session is editing your exact file right now, branch from committed HEAD and push a branch.** Don't merge underneath the active writer.
- **The guard can block you from resolving a merge conflict in the canonical checkout.** Resolve it on the worktree branch instead.
- **When the guard fires, first check whether the other session's change is committed or uncommitted.** Committed: rebase onto it. Uncommitted: work around it. Under concurrency, deploy only the specific files you changed.
- **The guard can keep firing on the claim ledger after the other session has committed.** Check git before treating the block as live.
- **A worktree can't hold an edit that exists only in another session's uncommitted working tree.** Wait for the commit, or ask.

**Shared staging area and destructive git**
- **`git add` inherits a shared index.** A pre-commit secret gate can block *your* commit because of another session's staged content. Commit with `git commit --only <paths>` so you don't sweep up their staged files.
- **`git reset --hard` in a shared checkout throws away other sessions' uncommitted work on every tracked file**, not just the one causing your conflict. Never run it there.
- **If a peer resets the shared checkout under you, your uncommitted edits are gone.** Rebuild from scratchpad copies of your scripts and commit from a worktree. A file that was `git add`ed and then reverted can often be recovered from its dangling blob (`git fsck --lost-found`).
- **`git pull --rebase --autostash` in a shared checkout can conflict and commit another session's files or conflict markers.** Commit your explicit paths before pulling. If the autostash reapply conflicts, resolve the markers and run `git show --stat HEAD` to confirm only your files landed before pushing. Never drop the leftover autostash entry.
- **A "stray" uncommitted change in a shared checkout may be a live session's in-progress edit.** It can be committed mid-task and move HEAD under you.
- **Deploying by rsync from the shared checkout can ship a file with conflict markers in it.** Grep the deploy set for `^<<<<<<<` first, or deploy from a clean tree.
- **The deployed file can be a third version that matches neither branch.** Build the deploy artifact from the live file plus only your changes.

**Gitignore and build quirks in worktrees**
- **A `node_modules/` rule (trailing slash) doesn't match a `node_modules` symlink.** Symlinking deps into a worktree makes them stageable by `git add -A`. Add a `node_modules` rule without the slash as well.
- **A Next.js standalone build inside a worktree nests its output.** Never deploy those artifacts, and when `test -f .next/standalone/server.js` fails, check where `server.js` actually ended up before calling the build broken. If you build outside the repo to avoid the nesting, hardlink-copy `node_modules` in (`cp -al`); a symlink makes Turbopack abort the build.
- **A main checkout left on a stray, already-merged branch serves stale `CLAUDE.md` content** that looks like a false "undocumented gap". Check the checked-out branch of every repo a sweep touches.

**Singletons, runners and locks**
- **Two deploys of the same app without a lock can stop production and wipe or rebuild a shared staging directory mid-build**, leaving production down with a partial build. This is exactly what the `deploy:<app>` lock prevents.
- **A runner's own `.running.lock` doesn't stop a second invocation started by hand.** Make manual entry points take the same lock.
- **Before clearing a running/liveness flag to start a fresh run, poll until it is actually false.** Clearing it early bypasses the guard it exists for and lets the old and new runs drive the same resource (a named browser window, a worker, a lock file) at once.
- **When a lock holder's child process runs "check the runner lock for a duplicate", it finds itself.** Exclude your own PID ancestry before reporting BLOCKED.
- **Two agents sharing one browser profile must claim their targets in a shared file before the first form fill**, and must read that claims file first, or they repeat each other's actions (for example duplicate signups).

**Duplicate dispatch and parallel workstreams**
- **Before starting in a shared working folder, check for a parallel workstream:** run `git log --since=...` on the folder, check the matching deliverables directory in your private context repo, and look at idle peer agents.
- **A request sent twice by a dispatcher spawns two agents** that race on the same deliverable in a shared checkout. One may merge a competing PR and reset the checkout, discarding the other's edits. Dedupe at dispatch, or claim the task first.
- **A follow-up or troubleshoot trigger can race the original request's handler on the same file.**
- **A recurring or scheduled reply over shared records (a watcher, a heartbeat) can repeat an item another session already resolved.** Carrying an open item forward from your own earlier draft instead of re-reading the shared record brings back a decision the user already made. Before repeating any open item, re-read the record and check its recent history for a newer decision.

**Harness behavior**
- **Bridging a local session to a web UI can silently drop its bypass-permissions mode.** Re-check the permission mode after bridging.
- **Verify a settings change with a headless `claude -p` A/B run**, not by reading the transcript.

**Hygiene and monitoring**
- **Clean up stale session ledgers on a schedule, with a hard minimum age so the guards are never blinded.** Alert on a guard's override rate, not its deny count.
- **The claim guard is the third line of defense, not the strategy.** Detection can't serialize anything. Worktrees solve Problem A and locks solve Problem B.
