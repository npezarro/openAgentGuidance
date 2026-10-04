<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

When several agent sessions run on one machine at once, often with permission prompts disabled, and they all share one checkout per repo, they collide. Each detection-based fix narrows the window without closing it.

**It keeps recurring because there are two problems, and one mechanism keeps getting asked to solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. The index and working tree are mutable shared state that nobody owns. | Deployed app directories, process-manager services, a live browser extension, a shared skills directory, a remote server. Exactly one of each exists. |
| Symptom | `git add -A` commits someone else's uncommitted work; two sessions commit the same file seconds apart. | One session's deploy overwrites another's; two extension reloads tear down each other's service worker. |
| Right fix | **Eliminate the sharing** (a git worktree per session). | **Serialize** (a real lock) or **partition** (one owner per path). |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. A session can proceed past them, so nothing is serialized. |

A claim/edit-detection hook (one that records which session touched which file and warns or blocks on overlap) is worth having, and it does catch real hazards. But it is detection, and it gets applied to both columns. Keep it as the backstop, not the strategy.

## Problem A: use a worktree per session

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**`EnterWorktree` is often unavailable.** The tool needs the session's cwd to be inside a git repo. Sessions launched from a non-repo directory, or sessions that span several repos, can't use it. If the rule depends on a tool that can't be used, sessions skip it silently, and that teaches them to ignore the rest of the file.

The underlying mechanism is git worktrees, and `EnterWorktree` is only one wrapper around it. This works from anywhere:

```bash
git -C $HOME/<repo> worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/<repo>/.claude/worktrees/<n>/...
git -C $HOME/<repo> merge --no-ff <n> && git -C $HOME/<repo> push
```

Any guard hook should decide whether you are isolated from the **target file path**, not from cwd, so a worktree created from a non-repo cwd still counts as isolated. An unpushed-commit checker should also scan worktrees, or commits get stranded there.

Once you work in a worktree, no other session's uncommitted work is in your tree. `git add -A` is then safe **by construction**, and that whole class of bug goes away.

It costs less than you'd expect. Worktrees live under `.claude/worktrees/`, so the canonical `$HOME/<repo>` checkout **stays exactly where it is**. Cron jobs and process-manager configs that hardcode the canonical path keep working. They actually improve, because they now run against a clean committed tree instead of one that several sessions are editing.

The real costs:
- Every session ends with a merge back to the default branch, which adds ceremony to solo work.
- Git refuses to check out the same branch in two worktrees. That is a feature (it forces per-session branches), but it changes behavior.
- It does nothing for Problem B.
- A separate clone, such as a checkout on another filesystem used to load a browser extension, is unaffected either way. You still have to pull it before reloading from it.

## Problem B: take a real lock

Serialize every operation on a named singleton through one lock wrapper. A minimal portable version uses `flock`:

```bash
# with-resource-lock.sh <resource> [--timeout N] -- <command...>
mkdir -p /tmp/resource-locks
exec flock -w "${TIMEOUT:-600}" "/tmp/resource-locks/${RESOURCE//[:\/]/_}.lock" "$@"
```

Give it a `--list` mode that shows who holds what, by writing the holder's PID and command into the lock file.

Keep the resource names stable, because the name string *is* the lock:

| Resource | Covers |
|---|---|
| `deploy:<app>` | the app's deployed directory and its process-manager service |
| `browser-extension` | the live browser extension: reload, debugging protocol, tab state |
| `<host>:skills` | the skills directory on a remote host |

Where to wire it in:
- The extension-reload command should wrap itself in the lock, with an env var to opt out.
- The skills sync script should take the lock instead of a hand-run rsync. It should also count skill files across every copy and fail if the counts differ.
- Deploys should take `deploy:<app>` inside the deploy skill or wrapper that every deploy already goes through, not in each repo's own deploy script.

## Diagnostic order when something "keeps reverting"

Before blaming a cache or a cron job:
1. `stat` the origin file and compare its mtime with your deploy time.
2. `git log -- <path>` to look for commits from other sessions.
3. Map the live sessions (from session-alive marker files, process list, or your agent-listing tool).

**Never kill a live session to win a race.** It usually belongs to the human operator. Check whether its tree is clean and pushed, then ask.

## Deploy from the merged default branch, not from your worktree

A worktree isolates your edits, which is the point. But its generated output (`dist/`, a build directory, an artifact) reflects only your branch. If you deploy from it, you publish a build that is missing whatever landed on the default branch while you worked. That silently reverts another session's shipped feature, and neither side notices.

Do it in this order:

1. Merge to the default branch (`git merge --no-ff <branch>`).
2. **Regenerate** generated files there instead of resolving them as text. A conflict in `dist/` is not a real conflict; it is a stale artifact.
3. Run the test suites against the merged output, not against your branch's output.
4. Deploy, then compare the live build stamp with the one you shipped.

If the live build stamp is one you don't recognise, before or after your deploy, someone else deployed while you worked. This is the cheapest detector there is, and it only works if every build carries a stamp.

## A relative-path shell edit runs in the shared checkout, not your worktree

A worktree protects you from a stage-everything commit. It does **not** protect you from a shell command that resolves a path on its own.

Here is the failure mode. You edit a file correctly in the worktree using an absolute path. A follow-up `perl -0pi -e 's/.../.../' src/server.js` uses a **relative** path. The shell's cwd has reset to the repo root between tool calls, so the substitution rewrites the **shared main checkout**, which now references a constant that exists only in the worktree. The worktree file never gets edited.

Both checks report green:
- `node --check` passes on the contaminated file. It parses syntax and never resolves identifiers, so a reference to an undefined constant fails only at runtime.
- The confirming `grep` finds the substitution, but in the wrong tree.

The failure surfaces much later as an unrelated-looking error (for example `spawn ENOENT` from a test that should have picked up the change).

Rules:
1. **Use absolute paths for every scripted edit in a worktree** (`perl`, `sed`, `awk`, `mv`, `cp`), not just for the editor tool. A relative path is safe only when the same command sets cwd first.
2. **After any scripted in-place edit, check that the shared checkout is still clean.** Run `git -C <worktree> diff --stat` for what you meant to change and `git -C <main-checkout> status --short` for what you didn't. This is the only check that catches the leak.
3. **Revert a leak surgically** by inverting the same substitution. `git checkout -- <file>` in a shared checkout would also throw away another live session's uncommitted work in that file.

## Rule Digest

One line per lesson.

- **Ignore worktree directories globally.** Put `.claude/worktrees/` in a global gitignore on every host, so no repo needs its own step.
- **Never land a branch by merging from the shared checkout.** `cd <primary> && git merge <my-branch>` merges into whatever branch is checked out *now*, which may not be the one that was there when you started. Land from a dedicated landing worktree, or push your branch and fast-forward the remote.
- **Don't check out the default branch by name inside the landing worktree.** That reintroduces the shared-branch problem the worktree was meant to avoid. Use a detached HEAD at `origin/<default>`.
- **A push from the landing worktree doesn't update other long-lived checkouts of the same repo.** Pull them explicitly if a cron job or service reads from them.
- **`git worktree add <path> <branch> --detach` can resolve to a stale LOCAL ref even right after `git fetch`.** Name `origin/<branch>` explicitly.
- **A runner's own lock file doesn't stop a second invocation launched by hand.** The manual path has to take the same lock.
- **Hygiene:** reap stale session ledgers on a schedule, with a hard minimum age so the guards are never blinded. Alert on a guard's override rate, not its deny count.
- **A main checkout left on a stray, already-merged branch serves stale instruction files.** That shows up as a false "undocumented gap". Check `git branch --show-current` before you trust what you read there.
- **A `node_modules/` gitignore rule (trailing slash) doesn't match a `node_modules` symlink.** Linking dependencies into a worktree makes the symlink stageable by `git add -A`. Add a slash-less `node_modules` rule as well.
- **A Next.js standalone build inside a worktree nests its output under the worktree path.** Never deploy those artifacts. If `test -f .next/standalone/server.js` fails, check where `server.js` actually landed before you call it a build defect.
- **`git add` shares one staging area.** A pre-commit secret scan can block *your* commit over a peer session's staged content. Commit from a worktree, or use `git commit --only <paths>`.
- **`git reset --hard` in a shared checkout discards a peer's uncommitted work on every tracked file,** not just the file causing your conflict. Never run it there.
- **Two agents on one browser profile must claim targets in a shared claims file before the first form fill.** Otherwise they duplicate each other's submissions. Read the claims file first.
- **Deploying by rsync from the shared checkout can ship a file that still has conflict markers.** Grep for `^<<<<<<<` before every rsync deploy.
- **A branch that predates a concurrent session's additions deletes them when merged.** Rebase or merge the latest default branch into your branch first, and review the diff for deletions you didn't make.
- **A deploy without a lock can collide with another deploy of the same app.** One can stop production and wipe or rebuild the shared build directory while the other is mid-build, leaving production down with a partial build. Always deploy under `deploy:<app>`.
- **A lock holder's own child process can see the lock and report itself as a duplicate.** Exclude your own PID ancestry before reporting BLOCKED.
- **Before starting work in a shared folder, check for a parallel workstream.** Run `git log --since` on the folder, check the matching deliverables directory, and list idle peer agents.
- **Bridging a local session to a web UI can silently drop its permission mode.** Re-check the mode after bridging.
- **A worktree guard can keep firing on the claim ledger after the sibling session has committed.** Check whether the sibling's work is committed before you override it.
- **A worktree can't host an edit that exists only in a sibling's uncommitted working tree.** Wait for the commit, or coordinate with that session.
- **If the guard blocks you from resolving a merge conflict in the canonical checkout, resolve it on your worktree branch instead.**
- **Verify a settings change with a headless A/B run** (`claude -p` with and without the change), not by reading a transcript.
- **If a LIVE session is mid-edit on your exact file, branch from committed HEAD and push a branch.** Don't merge under an active writer.
- **If a peer's `git reset --hard` erased your uncommitted work, rebuild from scratchpad copies and commit from a worktree.** Keep scratch copies of non-trivial scripts for exactly this case.
- **A parallel session can merge a competing PR for the same task and reset the shared checkout,** silently discarding your uncommitted edits. Commit early on your own branch.
- **When a worktree guard blocks you, check whether the conflicting work is committed or uncommitted before choosing a path.** Under concurrency, deploy only the files you changed.
- **A "stray" uncommitted change in a shared checkout can be a live peer's edit in progress.** It may commit mid-task and move HEAD. Don't clean it up.
- **On a fast-moving shared default branch, land by fast-forward push to the remote,** and deploy the file from the latest `origin/<default>`.
- **The deployed file can be a third divergent state.** Build the deploy artifact from the deployed version plus only your hunks.
- **Use `git commit --only <paths>` in a shared checkout** so you don't sweep up a sibling's staged files. If a sibling's work was staged and then reverted, recover it from the dangling blob (`git fsck --lost-found`).
- **A request sent twice spawns two concurrent agents that race on the same deliverable.** Dedupe incoming requests before dispatching them.
- **A follow-up "troubleshoot" request can race the original handler on the same file.** Check whether the original handler is still running before you start.
