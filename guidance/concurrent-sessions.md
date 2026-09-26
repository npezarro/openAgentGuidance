<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim guards, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

When several Claude sessions run at once on one machine, often with permissions skipped, they end up sharing one checkout per repo. They collide again and again. A fix that only detects the collision makes the race window smaller but never closes it.

**It keeps coming back because it is two problems, and one mechanism was being asked to solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. The index and working tree are shared, changeable state that nobody owns. | Deploy target directories, process-manager services, a live browser extension, a shared skills directory, a remote server. Exactly one of each exists. |
| Symptom | `git add -A` commits someone else's uncommitted work; two sessions commit the same file seconds apart. | One session's deploy overwrites another's; two extension reloads tear down each other's service worker. |
| Right fix | **Remove the sharing** (a git worktree per session). | **Serialize** (a real lock) or **partition** (one owner per path). |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. You can proceed past them, so nothing gets serialized. |

A claim guard (a hook that warns when another session has touched the file you are editing) is useful and catches real hazards. But it is detection, applied to both columns. Keep it as the backstop, not the strategy.

## Problem A: use a worktree per session

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**`EnterWorktree` is often unavailable, and a rule that assumes it will be there gets skipped.** The tool needs the session's cwd to be inside a git repo. Sessions launched from a directory that is not a repo, or sessions that work across several repos, cannot use it. An instruction nobody can follow is worse than no instruction: it gets skipped without anyone noticing, and that weakens the rest of the file.

The mechanism is git worktrees. `EnterWorktree` is just one convenient wrapper around them. From anywhere:

```bash
git -C "$HOME/<repo>" worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/<repo>/.claude/worktrees/<n>/...
git -C "$HOME/<repo>" merge --no-ff <n> && git -C "$HOME/<repo>" push
```

This works from a non-repo cwd and across repos. Any guard hook you run should decide isolation from the target file's path, not from the cwd, so that a worktree path counts as isolated wherever the session started. An "unpushed commits" check should also scan worktrees, so a commit left stranded in one gets caught.

With a worktree, no other session's uncommitted work is in your tree. `git add -A` is then safe **by construction**, and the whole class of collision goes away.

Why this is cheaper than it looks: the worktrees live under `.claude/worktrees/`, so the canonical checkout **stays exactly where it is**. Crontab lines and process-manager configs that hardcode the canonical path keep working without changes. They actually improve: crons now run against a clean committed tree instead of one that several sessions are editing at once.

Real costs:
- Each session ends with a merge back to the default branch. That is extra ceremony for solo work.
- Git refuses to check out the same branch in two worktrees. This is a feature (it forces a branch per session), but it changes behavior.
- It does nothing for Problem B.
- Separate clones are not affected either way. A second clone of the same repo (for example, one on another filesystem that a browser loads an extension from) still has to be pulled before it is used.

## Problem B: take a real lock

Wrap every operation on a singleton in a named, blocking lock. `flock` is portable enough:

```bash
mkdir -p /tmp/locks
flock --timeout 600 "/tmp/locks/deploy:<app>.lock" -- <command...>
```

A small wrapper script (`with-resource-lock.sh <resource> [--timeout N] -- <command...>`, plus a `--list` mode that shows who holds what) is worth writing. It lets you record the holder's PID and command next to the lock.

Keep the resource names stable, because the name string IS the lock:

| Resource | Covers |
|---|---|
| `deploy:<app>` | that app's deploy target directory and its service |
| `browser-extension` | the live browser extension: reload, debugger protocol, tab state |
| `remote:skills` | a skills or config directory synced to a remote host |

Where to put the lock:
- **In the tool itself** when possible. For example, an extension-reload command should wrap itself, with an env var to opt out.
- **In the single entry point for the operation.** If every deploy goes through one deploy skill or script, put the lock there, not in ten per-repo `deploy.sh` files.
- **In a sync script that replaces hand-run commands.** Have it verify the result too (for example, count files in every copy and fail on a mismatch).

## Diagnostic order when something "keeps reverting"

Before blaming a cache or a cron:
1. `stat` the origin file and compare its mtime with your deploy time.
2. Run `git log -- <path>` and look for commits from other sessions.
3. Map the live sessions (process list, or session-liveness marker files if your hooks write them).

**Do not kill a live session to win a race.** It is usually the operator's own session. Check whether its tree is clean and pushed, then ask.

## Deploy from the merged default branch, not from your worktree

A worktree isolates your edits, which is the point. But its generated output (`dist/`, a build directory, an artifact) reflects only your branch. Deploying from it publishes a build that is missing whatever landed on the default branch while you worked. That quietly reverts features other sessions have already shipped.

Do it in this order:

1. Merge to the default branch (`git merge --no-ff <branch>`).
2. **Regenerate** generated files there. Do not resolve them as text: a conflict in `dist/` is not a real conflict, it is a stale artifact.
3. Run the test suites against the merged output, not the branch's.
4. Deploy, then compare the live build stamp with the one you shipped.

If you see a live build stamp you do not recognise, before or after your deploy, someone else deployed while you worked. This is the cheapest detector there is, and it only works if your builds carry a stamp.

## A relative-path shell edit runs in the shared checkout, not your worktree

A worktree protects you from a commit that stages everything. It does **not** protect you from a shell command that works out its own path.

Here is how it fails. You edit a file correctly in the worktree using an absolute path. Then a follow-up `perl -0pi -e 's/.../.../' src/server.js` uses a **relative** path. The shell's cwd has reset to the repo root between tool calls, so the substitution rewrites the **shared main checkout**, and the worktree file never gets edited.

Both checks look green:
- `node --check` passes on the contaminated file. It only parses syntax and never resolves identifiers, so a file that references an undefined constant passes and fails only at runtime.
- The confirming `grep` finds the substitution, but in the wrong tree.

The failure shows up much later, as an error that seems unrelated.

Rules:
1. **Use absolute paths for every scripted edit in a worktree** (`perl`, `sed`, `awk`, `mv`, `cp`), not just in the editor tool. A relative path is safe only when the same command sets the cwd again.
2. **Check that the shared checkout is still clean after any scripted in-place edit.** `git -C <worktree> diff --stat` shows what you meant to change; `git -C <main-checkout> status --short` shows what you did not mean to change. This is the only check that catches this failure.
3. **Undo a leak surgically** by inverting the same substitution. `git checkout -- <file>` in a shared checkout would also throw away another live session's uncommitted work in that file.

## Rule Digest

**Setup and hygiene**
- **Ignore `.claude/worktrees/` in your global gitignore** (`core.excludesFile`) on every host, so no repo needs its own step.
- **`node_modules/` with a trailing slash does not match a `node_modules` symlink.** If you symlink deps into a worktree, `git add -A` will stage the link. Use `node_modules` without the slash.
- **Clear out stale session ledgers on a schedule**, with a hard minimum age so the guards never go blind. Alert on how often a guard gets overridden, not on how often it denies.
- **A main checkout left on a stray, already-merged branch serves stale CLAUDE.md content.** Check `git branch --show-current` before reporting a documentation gap.
- **Before starting work in a shared folder, look for a parallel workstream:** `git log --since=<recent>` on the folder, any matching deliverables directory, and idle peer agents.

**Landing a branch**
- **Never merge from the shared checkout.** `cd <primary> && git merge <my-branch>` merges into whatever branch is checked out right now, which may not be the one that was there when you started.
- **Land from a dedicated landing worktree that stays detached.** Checking out the default branch by name inside it defeats the point. Use `git worktree add <path> origin/<branch> --detach`, merge, then `git push origin HEAD:<branch>`.
- **Name the remote ref explicitly.** `git worktree add <path> <branch> --detach` can resolve to a stale local ref even right after `git fetch origin <branch>`.
- **When the default branch moves fast, land with a fast-forward push to the remote** and deploy files from the latest `origin/<branch>`, not from your local copy.
- **A push from the landing worktree does not fast-forward any other long-lived checkout of the same repo.** Pull it explicitly if something reads from it.
- **A branch that was cut before another session's additions can delete them on merge.** Rebase onto the latest default branch and read the diff against it before landing.
- **A worktree guard blocks resolving a merge conflict in the canonical checkout.** Resolve it in the worktree branch instead.

**The shared index and working tree**
- **`git add` works on a shared staging area.** A pre-commit secret gate can block YOUR commit because of a peer's staged content, and a plain commit can sweep in a peer's staged files. Commit with `git commit --only <paths>`.
- **`git reset --hard` in a shared checkout throws away every session's uncommitted work on every tracked file,** not just the file causing your conflict. Never run it there.
- **Keep copies of in-progress scripts outside the checkout (a scratch directory).** If a peer resets the shared tree, rebuild from those copies and commit from a worktree.
- **A sibling's work that was `git add`-ed and then reverted can be recovered from the dangling blob:** `git fsck --lost-found`.
- **A "stray" uncommitted change may be a live peer's in-flight edit** that will commit mid-task and move HEAD. Do not clean it up.
- **When a guard fires, first check whether the flagged edit is committed or uncommitted.** The guard can fire on the claim ledger even after the sibling has committed.
- **A worktree cannot see an edit that exists only in a sibling's uncommitted working tree.** Wait for the commit or ask.
- **If a LIVE session is mid-edit on your exact file, branch from the committed HEAD and push a branch.** Do not merge while the other session is still writing.

**Deploys and singletons**
- **A deploy of the same app with no lock can stop production and wipe and rebuild a shared staging directory mid-build.** That leaves production down with a partial build. Always take `deploy:<app>`.
- **An rsync deploy from the shared checkout can ship a file with conflict markers in it.** Run `grep -rn '^<<<<<<<\|^>>>>>>>'` over the payload before syncing.
- **The deployed file can be a third, separate version** that matches neither your branch nor the default branch. Build the deploy artifact from the deployed file plus only your hunks, and deploy only the files you changed while other sessions are active.
- **A Next.js standalone build inside a worktree nests its output under the worktree path.** Never deploy those artifacts.
- **A runner's own lock file does not stop a second invocation launched by hand.** The manual path has to take the same lock.
- **A check that says "is the runner lock held by a duplicate?" run by the lock holder's own child process will find itself.** Exclude your own PID ancestry before reporting BLOCKED.
- **Two agents driving one browser profile must claim their targets in a shared file before the first form fill.** Read the claims file first, or you will duplicate a sibling's actions.

**Duplicate dispatch**
- **A message sent twice, a retry or troubleshoot flag, or a parallel session picking up the same task can start two agents on one deliverable.** One of them may merge a competing PR and reset the shared checkout under the other. Check for a sibling working on the same task before you start, and again before you land.

**Verifying the environment**
- **Bridging a local session to a web UI can quietly drop the permission mode.** Check the active mode after bridging.
- **Verify a Claude Code settings change with a headless `claude -p` A/B run**, not by reading the transcript.
