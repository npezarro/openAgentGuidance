<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

When several agent sessions run at once on the same machine, often with permission prompts disabled, they can all end up sharing one checkout per repo. They will collide. Each detection fix narrows the window without closing it.

**Why it keeps recurring: there are two problems here, and one mechanism keeps being asked to solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. The index and working tree are mutable shared state that nobody owns. | Things that exist exactly once: a deploy directory, a process-manager service, a live browser extension, a shared skills directory, a remote server. |
| Symptom | `git add -A` commits another session's uncommitted work, or two sessions commit the same file seconds apart. | One session's deploy overwrites another's, or two extension reloads tear down each other's service worker. |
| Right fix | **Remove the sharing** (one git worktree per session). | **Serialize** with a real lock, or **partition** so each path has one owner. |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. You can proceed past them, so nothing gets serialized. |

A claim-guard hook (one that records which session touched which file and warns on overlap) is useful and does catch real hazards. It is still detection, though, and here it gets applied to both columns. Keep it as the backstop, not the strategy.

## Problem A: one worktree per session

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**`EnterWorktree` is often unavailable, so don't write rules that assume it.** The tool needs the session's cwd to be inside a git repo. Sessions launched from a non-repo directory, or sessions that span several repos, can't use it. A rule that can't be followed is worse than having no rule: it gets skipped quietly, and that weakens the rest of the file.

The real mechanism is git worktrees. `EnterWorktree` is just one wrapper around it. This works from any directory:

```bash
git -C "$HOME/repos/<repo>" worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/repos/<repo>/.claude/worktrees/<n>/...
git -C "$HOME/repos/<repo>" merge --no-ff <n> && git -C "$HOME/repos/<repo>" push
```

Any guard hook that enforces isolation should decide based on the target file path, not the cwd, so that cross-repo worktree work counts as isolated. Any "unpushed commits" checker should scan worktrees too, so a commit stranded in one gets caught.

With a worktree, no other session's uncommitted work is in your tree, so `git add -A` is safe **by construction** and this whole class of bug goes away.

It costs less than you'd expect. Worktrees live under `.claude/worktrees/`, so the canonical `$HOME/repos/<repo>` **stays exactly where it is**. Crontab lines and process-manager configs that hardcode the canonical path keep working without changes. They actually improve: scheduled jobs run against a clean committed tree instead of one several sessions are editing at the same time.

The real costs:
- Every session ends with a merge back to the default branch. That's extra ceremony for solo work.
- Git won't check out the same branch in two worktrees. This is a feature, since it forces per-session branches, but it does change behavior.
- It does nothing for Problem B.
- Separate clones (for example, a second checkout on another filesystem used to load a browser extension) are unaffected either way. They still have to be pulled before use.

## Problem B: take a real lock

Wrap any operation on a singleton in a named lock. A small wrapper script around `flock` is enough:

```bash
with-resource-lock.sh <resource> [--timeout N] -- <command...>
with-resource-lock.sh --list          # who holds what right now
```

Keep the resource names stable, because the string IS the lock:

| Resource | Covers |
|---|---|
| `deploy:<app>` | the app's deploy directory and its managed service |
| `browser-extension` | the live browser extension: reload, CDP, tab state |
| `remote:skills` | a skills directory synced to a remote host |

Where to wire the lock in:
- **The tool itself.** Make an extension-reload command acquire `browser-extension` on its own, with an env var to opt out.
- **The sync script** for a shared skills directory. Have it also count the skill files across every copy and fail when the counts don't match.
- **The deploy entry point**, not each repo's deploy script. If deploys already go through one shared skill or command, wire `deploy:<app>` there once instead of in a dozen per-repo scripts.

## Diagnostic order when something "keeps reverting"

Before you blame a cache or a cron job:
1. `stat` the origin file and compare its mtime to your deploy time.
2. `git log -- <path>` to look for commits from other sessions.
3. List the live sessions (session-alive marker files, `ListAgents`, process list).

**Don't kill a live session to win a race.** It is usually the operator's own. Check whether its tree is clean and pushed, then ask.

## Deploy from the merged default branch, not from your worktree

A worktree isolates your edits, which is the point. But its generated output (`dist/`, a build directory, an artifact) only reflects your branch. If you deploy from it, you publish a build that is missing whatever landed on the default branch while you worked, and that silently reverts another session's shipped feature. The other session may never notice, or may heal it by luck on its next deploy.

Do it in this order:

1. Merge to the default branch (`git merge --no-ff <branch>`).
2. **Regenerate** generated files there instead of resolving them as text. A conflict in `dist/` isn't a real conflict; it's a stale artifact.
3. Run the test suites against the merged output, not your branch's.
4. Deploy, then compare the live build stamp with the one you shipped.

If you see a live build stamp you don't recognize, before or after your deploy, someone else deployed while you worked. That is the cheapest detector available, and it only works if every build carries a stamp.

## A relative-path shell edit runs in the shared checkout, not your worktree

A worktree protects you from a stage-everything commit. It does **not** protect you from a shell command that resolves its own path.

The failure looks like this. You edit a file correctly in the worktree with an absolute path. Then you run a follow-up like `perl -0pi -e 's/.../.../' src/server.js` with a **relative** path. The shell's cwd reset to the repo root between tool calls, so the substitution rewrites the **shared main checkout**, which now references a symbol that only exists in the worktree. The worktree file never got the edit.

It looks green twice:
- `node --check` (or any syntax-only check) passes on the contaminated file. It checks syntax but never resolves identifiers, so the reference to an undefined constant only fails at runtime.
- The confirming `grep` finds the substitution, but in the wrong tree.

The failure shows up much later as an unrelated-looking error, such as `spawn ENOENT` from a test that should have picked up the change.

Rules:
1. **Use absolute paths for every scripted edit in a worktree** (`perl`, `sed`, `awk`, `mv`, `cp`), not just for the editor tool. A relative path is only safe when the same command sets the cwd first.
2. **Check that the shared checkout is clean after any scripted in-place edit.** Run `git -C <worktree> diff --stat` to see what you meant to change and `git -C <main-checkout> status --short` to see what you didn't. This is the only check that catches the problem.
3. **Revert a leak surgically** by applying the inverse of the same substitution. `git checkout -- <file>` in a shared checkout would also throw away any other live session's uncommitted work in that file.

## Rule Digest

One line per lesson.

- **Make the worktree ignore rule global.** Put `.claude/worktrees/` in your global gitignore on every host so no repo needs its own entry.
- **Never land a branch by merging from the shared checkout.** `cd <primary> && git merge <my-branch>` merges into **whatever branch is checked out right now**, which may not be the one that was there when you started. Land from a dedicated landing worktree, or by fast-forward pushing to the remote.
- **Don't check out the default branch name inside the landing worktree.** It brings back the sharing the worktree was supposed to remove.
- **A push from the landing worktree doesn't fast-forward other long-lived checkouts of the same repo.** Pull those explicitly if anything reads from them.
- **`git worktree add <path> <branch> --detach` can resolve to a stale LOCAL ref, even right after `git fetch origin <branch>`.** Use `origin/<branch>` explicitly.
- **A runner's own lock file doesn't stop a second invocation launched by hand.** The manual path has to take the same lock.
- **Hygiene and monitoring.** Reap stale session ledgers on a schedule, with a hard minimum age so the guards never go blind. Alert on how often a guard gets overridden, not on how often it denies.
- **Claim-guard is the backstop.** Detection can't serialize anything, so it is the third line of defense, not the strategy.
- **A main checkout left on a stray, already-merged branch serves stale docs (CLAUDE.md and the like) and shows up as a false "undocumented gap".** Check the branch of every repo a sweep touches.
- **A `node_modules/` gitignore rule (trailing slash) doesn't match a `node_modules` symlink.** If you link deps into a worktree, `git add -A` will stage the link. Add a slash-less `node_modules` rule too.
- **A Next.js standalone build inside a worktree nests its output.** Never deploy those artifacts. If a check like `test -f .next/standalone/server.js` fails, find where `server.js` actually landed before calling it a build defect. If you build from a worktree outside the repo to avoid the nesting, you still need `node_modules` hardlink-copied in (`cp -al`); a symlink makes Turbopack abort the build.
- **`git add` uses a shared staging area.** A pre-commit secret gate can block YOUR commit because of a peer session's staged content.
- **`git reset --hard` in a shared checkout throws away a peer's uncommitted work on ANY tracked file**, not just the one causing your conflict.
- **Agents sharing one browser profile must claim targets in a shared file before the first form fill.** Read the claims file first, or you duplicate a sibling's submissions.
- **Deploying by rsync from the shared checkout can ship a file containing conflict markers.** Deploy from a clean, verified tree.
- **A branch that predates a concurrent session's additions deletes them on merge.** Rebase or merge the default branch in first, and diff what the merge removes.
- **A lock-free concurrent deploy of the same app can stop production and wipe or rebuild a shared staging directory mid-build**, leaving production down with a partial build. Take `deploy:<app>`.
- **A lock holder's own child process running a "check the lock for a duplicate" recipe detects itself.** Exclude your own PID ancestry before reporting BLOCKED.
- **Before starting work in a shared folder, check for a parallel workstream.** Run `git log --since` on the folder, check any matching deliverables directory in your private context repo, and look for idle peers with `ListAgents`.
- **Bridging a local session to a web UI can silently drop the bypass-permissions mode.** Re-check the mode after bridging.
- **A worktree guard can fire on the claim ledger even after the sibling has committed.** Check the actual git state before treating it as a live conflict.
- **A worktree can't host an edit that exists only in a sibling's uncommitted working tree.** Wait for the commit, or coordinate.
- **A worktree guard blocks resolving a merge conflict in the canonical checkout.** Resolve it in the worktree branch instead.
- **Verify a Claude Code settings change with a headless `claude -p` A/B run**, not by reading the transcript.
- **If the guard fires because a LIVE session is mid-edit on your exact file**, branch from committed HEAD and push a branch. Don't merge underneath the active writer.
- **After a peer's `git reset --hard` wipes your uncommitted work**, rebuild from scratchpad copies of your scripts and commit from a worktree.
- **A parallel session can merge a competing PR for the SAME task and reset the shared checkout**, silently discarding your uncommitted edits mid-session. Commit early, in a worktree.
- **When a worktree guard blocks you, check committed vs uncommitted state before choosing a path.** Under concurrency, deploy only the specific files you changed.
- **A "stray" uncommitted change in a shared checkout may be a live peer's in-flight edit** that will commit mid-task and move HEAD. Leave it alone.
- **On a fast-moving shared default branch, land with a fast-forward push to the remote**, and deploy the file from the latest `origin/<default>`.
- **The DEPLOYED file can be a third divergent state.** Build the deploy artifact from the deployed version plus only your hunks.
- **In a shared checkout, commit with `git commit --only <paths>`** so you don't sweep up a sibling's staged files. If you reverted a sibling's `git add`-ed work, recover it from the dangling blob (`git fsck --lost-found`).
- **A double-sent request message can spawn two concurrent agents** that race on the same deliverable in a shared checkout. Dedupe at dispatch, or claim the task before starting.
- **A troubleshoot or retry flag can race the original request handler on the same file.** Check whether the original handler is still running first.
