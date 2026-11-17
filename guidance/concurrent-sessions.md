<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

When several agent sessions run on one machine at the same time, often with permission prompts disabled, each repo ends up with one checkout that all of them share. Collisions keep coming back, and each fix narrows the window without closing it.

**They keep coming back because there are two separate problems, and one mechanism was being asked to solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. The index and working tree are shared mutable state that nobody owns. | Anything that exists exactly once: a deployed web root, a process-manager service, a live browser extension, a shared skills directory, a remote server. |
| Symptom | `git add -A` commits someone else's uncommitted work; two sessions commit the same file seconds apart. | One session's deploy overwrites another's; two extension reloads tear down each other's service worker. |
| Right fix | **Remove the sharing** (a git worktree per session). | **Serialize** (a real lock) or **partition** (one owner per path). |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. You can proceed past them, so nothing is actually serialized. |

A claim-guard hook (a hook that records which session touched which file and warns on overlap) is useful and does catch real hazards. But it is detection, applied to both columns. Keep it as the backstop, not the strategy.

## Problem A: use a worktree per session

If your harness has a worktree tool:

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**The tool may not be available to you.** `EnterWorktree` requires the session's cwd to be inside a git repo. Sessions started from a non-repo directory, or sessions that span several repos, cannot use it. A rule that cannot be followed is worse than having no rule: it gets skipped without anyone noticing, and that undermines the rest of the file.

The mechanism underneath is plain git worktrees; the tool is only a wrapper. This works from any cwd:

```bash
git -C $HOME/<repo> worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/<repo>/.claude/worktrees/<n>/...
git -C $HOME/<repo> merge --no-ff <n> && git -C $HOME/<repo> push
```

Any guard hooks you build should key on the **target file path**, not on cwd. That way a worktree is treated as isolated even when the session was started elsewhere, and an unpushed-commit checker should scan worktrees too.

Inside a worktree, no other session's uncommitted work is in your tree, so `git add -A` is safe **by construction**. The whole class of bug goes away.

Why this costs less than you might expect: worktrees live under `.claude/worktrees/`, so the canonical checkout **stays exactly where it is**. Cron jobs and process-manager configs that hardcode the repo path keep working without changes. In fact they improve, because they now run against a clean committed tree instead of one that several sessions are editing at once.

The real costs:
- Each session ends with a merge back to the default branch. That is extra ceremony for solo work.
- Git refuses to check out the same branch in two worktrees. That is a feature, because it forces per-session branches, but it does change behavior.
- It does nothing for Problem B.
- Separate clones (for example, a second checkout on another filesystem that a tool loads from) are unaffected either way. They still have to be pulled before they are used.

## Problem B: take a real lock

Wrap every operation on a singleton in a named lock. A minimal portable version uses `flock`:

```bash
# with-resource-lock.sh <resource> [--timeout N] -- <command...>
lockfile="/tmp/resource-lock.$(echo "$resource" | tr '/:' '__').lock"
flock --timeout "${timeout:-600}" "$lockfile" "$@"
```

Add a `--list` mode that shows who holds what (write the holder's PID and command into the lockfile).

Pick a stable naming scheme, because the string itself is the lock:

| Resource | Covers |
|---|---|
| `deploy:<app>` | the app's deployed directory and its service |
| `browser-extension` | the live browser extension: reload, debugging protocol, tab state |
| `<host>:skills` | a shared skills or config directory on a remote host |

Where to put the lock:
- **Extension reload:** have the reload command lock itself, with an env var to opt out.
- **Skills/config sync:** wrap the rsync in a single sync script. The script should also count the synced files across every copy and fail if the counts differ.
- **Deploys:** put the lock in the shared deploy entry point (a skill or wrapper script), not in each repo's `deploy.sh`. That works when the convention is already that every deploy goes through that entry point.

## Diagnostic order when something "keeps reverting"

Before you blame a cache or a cron job:
1. `stat` the origin file and compare its time with your deploy time.
2. Run `git log -- <path>` and look for commits from other sessions.
3. Map the live sessions (for example, from per-session liveness files under `/tmp`).

**Do not kill a live session to win a race.** It is usually the user's own. Check whether its tree is clean and pushed, then ask.

## Deploy from the merged default branch, not from your worktree

A worktree isolates your edits; that is its job. But its generated output (`dist/`, a build directory, an artifact) reflects only your branch. Deploying from it publishes a build that lacks whatever landed on the default branch while you worked, and that quietly reverts another session's shipped feature. Neither session notices, and it may only get fixed by luck when someone redeploys.

Follow this order:

1. Merge to the default branch (`git merge --no-ff <branch>`).
2. **Regenerate** generated files there instead of resolving them as text. A conflict in `dist/` is not a real conflict; it is a stale artifact.
3. Run the test suites against the merged output, not the branch's.
4. Deploy, then compare the live build stamp with the one you shipped.

If the live build stamp is one you don't recognize, before or after your deploy, someone else deployed while you worked. That is the cheapest detector available, and it only works if every build carries a stamp.

## A shell edit with a relative path runs in the shared checkout, not your worktree

The worktree protects you from a stage-everything commit. It does **not** protect you from a shell command that resolves its own path.

The failure looks like this. A file is edited correctly in the worktree using an absolute path. Then a follow-up `perl -0pi -e 's/.../.../' src/file.js` uses a **relative** path. The shell's cwd has reset to the repo root between tool calls, so the substitution rewrites the **shared main checkout**, which now refers to a constant that exists only in the worktree. The worktree file never gets the edit.

It looked fine twice:
- `node --check` passed on the contaminated file. It only parses syntax and never resolves identifiers, so a reference to an undefined constant passes and fails only at runtime.
- The confirming `grep` found the substitution, but in the wrong tree.

The failure shows up much later, as an error that seems unrelated, in a test that should have picked up the change.

Rules:
1. **Use absolute paths for every scripted edit in a worktree** (`perl`, `sed`, `awk`, `mv`, `cp`), not just for the editor tool. A relative path is only safe when the same command sets the cwd itself.
2. **After any scripted in-place edit, check that the shared checkout is still clean.** Run `git -C <worktree> diff --stat` to see what you meant to change and `git -C <main-checkout> status --short` to see what you didn't. This is the only check that catches the leak.
3. **Revert a leak surgically** by reversing the same substitution. Running `git checkout -- <file>` in a shared checkout would also throw away another live session's uncommitted work in that file.

## Rule Digest

One line per lesson.

- **Make the worktree ignore rule global**: put `.claude/worktrees/` in the global gitignore (`core.excludesFile`) on every host, so no repo needs its own entry.
- **Never land a branch by merging from the shared checkout**: `cd <primary> && git merge <my-branch>` merges into **whatever branch is checked out right now**, which may not be the one that was there when you started. Land from a dedicated landing worktree.
- **Don't check out the default branch by name inside that landing worktree**: it gives the shared checkout's state back to you and defeats the point. Use a detached HEAD at the remote ref.
- **A push from the landing worktree does not fast-forward a separate long-lived checkout of the same repo**: pull that checkout explicitly.
- **`git worktree add <path> <branch> --detach` can quietly resolve to a stale local ref, even right after `git fetch origin <branch>`**: name `origin/<branch>` explicitly.
- **A runner's own `.running.lock` does not stop a second invocation started by hand**: the manual path needs to take the same lock.
- **Before clearing a running/liveness flag to start a fresh run, poll until it is actually false instead of clearing it unconditionally**: clearing it early bypasses the guard it exists for, so the old run and the new one drive the same shared resource (a browser window, a worker, a lock file) at once and corrupt it.
- **Hygiene and monitoring**: clean up stale session ledgers on a schedule, with a hard minimum age so the guards never go blind, and alert on how often a guard gets overridden, not on how often it denies.
- **The claim-guard is the backstop**: detection cannot serialize anything, so it is the third line of defense, not the strategy.
- **A main checkout left on a stray branch that was already merged serves stale CLAUDE.md content, which looks like a false "undocumented gap"**: check the checked-out branch of every repo a sweep touches.
- **A `node_modules/` gitignore rule (trailing slash) does not match a `node_modules` symlink**: linking deps into a worktree makes them stageable by `git add -A`. Ignore `node_modules` without the slash too.
- **A Next.js standalone build inside a worktree nests its output**: never deploy those artifacts, and before you call it a build defect when `test -f .next/standalone/server.js` fails, check where `server.js` actually ended up. If you build in a directory outside the repo to avoid the nesting, hardlink-copy `node_modules` in (`cp -al`); a symlink makes Turbopack abort the build.
- **`git add` uses a shared staging area**: a pre-commit secret gate can block YOUR commit because of a peer session's staged content.
- **`git reset --hard` in a shared checkout throws away a peer's uncommitted work on ANY tracked file, not just the one in your conflict**.
- **Two agents on one browser profile (or one scratch dir) must claim targets in a shared claims file before the first form fill**: read the claims file first, or you duplicate a sibling's signups.
- **Deploying by rsync from the shared checkout can ship a file with conflict markers in it**: grep for markers before the rsync, or deploy from a clean ref.
- **Merging a branch that predates a concurrent session's additions deletes those additions**: rebase or merge the default branch into yours first, then review the diff for deletions.
- **A concurrent deploy of the same app without a lock can stop production and wipe or rebuild the shared staging dir mid-build**, leaving production down with a partial build. Lock deploys per app.
- **A recipe that checks a runner lock for duplicates, run by the lock holder's own child process, finds itself**: exclude your own PID ancestry before you report BLOCKED.
- **Before starting work in a shared working folder, check for a parallel workstream**: run `git log --since` on the folder, look at the matching deliverables directory, and check for idle peer agents.
- **Bridging a local session to a web UI can quietly drop its permission mode**: re-check the mode after bridging.
- **A worktree guard can fire on the claim ledger even after the sibling has committed**: check the ledger entry against `git log` before you treat the file as contested.
- **The other side: a worktree cannot host an edit that exists only in a sibling's uncommitted working tree**: wait for the sibling to commit, or coordinate.
- **If a worktree guard blocks resolving a merge conflict in the canonical checkout, resolve it in the worktree branch instead**.
- **Verify a harness settings change with a headless A/B run (`claude -p`), not by reading the transcript**.
- **When the worktree guard fires because a LIVE session is editing your exact file, branch from committed HEAD and push a branch; don't merge under the active writer**.
- **After a peer's `git reset --hard` wipes your uncommitted work, rebuild from scratchpad copies of your scripts and commit from a worktree**: keep scratch copies of anything you can't easily regenerate.
- **A parallel session can merge a competing PR for the SAME task and reset the shared checkout, silently throwing away your uncommitted edits mid-session**: commit early on a branch.
- **When a worktree guard blocks you, first check whether the contested change is committed or uncommitted, then choose the path; under concurrency, deploy only the targeted files**.
- **A "stray" uncommitted change in a shared checkout may be a live peer's in-progress edit that commits mid-task and moves HEAD**: don't discard it, and re-check HEAD before you land.
- **On a fast-moving shared default branch, land by fast-forward-pushing to the remote, and deploy the file from the latest `origin/<default>`**.
- **The DEPLOYED file can be a third, divergent state**: build the deploy artifact from what is deployed plus only your hunks.
- **In a shared checkout, commit with `git commit --only <paths>` so you don't sweep up a sibling's staged files**: if you reverted a sibling's `git add`-ed work, recover it from the dangling blob (`git fsck --lost-found`).
- **A request delivered twice can start two concurrent agents that race on the same deliverable in a shared checkout**: deduplicate at intake, or claim the task before you start.
- **A follow-up "troubleshoot this" request can race the original request's handler on the same file**: check whether the original is still running first.
- **`git pull --rebase --autostash` in a shared checkout can conflict and commit another session's files or conflict markers**: commit your explicit paths BEFORE you pull. If the autostash reapply conflicts, resolve the markers and run `git show --stat HEAD` to confirm only your files landed before you push. Never drop the leftover autostash entry.
- **A recurring or scheduled reply over shared mutable records (a watcher, a heartbeat) can repeat an item a peer session already resolved**: if you carry an open item forward from your own earlier draft instead of re-reading the shared record, you bring back a decision the user already made. Before repeating any open item, re-read the record and check its recent history for a newer decision from a peer.
- **A peer moving a spreadsheet column mid-session silently redirects every later write addressed by column letter**: re-reading before writing protects rows, not columns, and a write to a moved column still reports success. Re-read the header immediately before every column-letter write, not just at session start. Prefer contiguous whole-row writes to scattered single-cell writes, because whole-row writes correct themselves when a column moves.
- **Before pointing a job's cwd or path at a new destination, check whether stale copies of its own state files are already there**: the risk is what already sits at the destination under the same filenames, not what you move there. Diff which files the app actually reads, and prove the migration with a guard message that can only be true if the app read the migrated state, not a stale copy with the same name.
