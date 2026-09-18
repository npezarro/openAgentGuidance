<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

Several agent sessions can run in one home directory at once (a handful live simultaneously is normal), often with permission prompts bypassed, all sharing one checkout per repo. Collisions recur, and each detection-based fix narrows the window without closing it.

**The reason it keeps recurring: this is two problems, and one mechanism was being asked to solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. Index + working tree are mutable shared state with no ownership. | A deploy target directory, a process-manager service, a live browser extension, a shared skills directory, a remote host. Exactly one exists. |
| Symptom | `git add -A` commits someone else's uncommitted work; two sessions commit the same file seconds apart. | One session's deploy overwrites another's; two extension reloads tear down each other's service worker. |
| Right fix | **Eliminate the sharing** (per-session git worktrees). | **Serialize** (a real lock) or **partition** (one owner per path). |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. You can proceed past them, so nothing is serialized. |

A claim-guard hook is good at what it does and does catch real hazards, but it is detection applied to both columns. Keep it as the backstop, not the strategy.

## Problem A: use a worktree per session

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**`EnterWorktree` is often unavailable, and a rule must not assume it is.** The tool requires the SESSION cwd to be inside a git repo, but sessions are routinely launched from a non-repo directory and often span several repos at once. An instruction that cannot be followed is worse than none: it gets silently skipped, and that erodes the rest of the file.

The mechanism is git worktrees; `EnterWorktree` is one convenience wrapper. From anywhere:

```bash
git -C $HOME/<repo> worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/<repo>/.claude/worktrees/<n>/...
git -C $HOME/<repo> merge --no-ff <n> && git -C $HOME/<repo> push
```

Verified from a non-repo cwd: the worktree was created, a path-keyed worktree guard treated the path as isolated (it keys on the target file path, not cwd, precisely so this works), and the unpushed-work check caught a stranded commit there. The whole mechanism works cross-repo; only the tool does not.

Then there is no other session's uncommitted work in your tree, so `git add -A` is safe **by construction** and the whole class disappears.

Why this is cheaper than expected: worktrees live under `.claude/worktrees/`, so the canonical checkout **stays exactly where it is**. Cron lines and process-manager config files that hardcode the canonical absolute path keep working untouched. They get better, in fact: crons start running against a clean committed tree instead of one that several sessions are mid-edit on.

Real costs, stated honestly:
- Each session ends with a merge back. Added ceremony for solo work.
- Git refuses the same branch in two worktrees. That is a feature (it forces per-session branches), but it is a behavior change.
- Zero help for Problem B.
- Separate clones are unaffected either way. A second checkout on another OS or filesystem is still its own clone and still has to be pulled before you act on it.

### Make the ignore rule GLOBAL, not per-repo

```bash
git config --global core.excludesFile ~/.gitignore_global   # contains .claude/worktrees/
```

Set it on every machine you work from, and mirror the file in your private context repo.

Originally this was a per-repo `.gitignore` line, which does not scale: in one measured fleet, 118 of 123 repos lacked it, and adding it to each would have meant 118 commits across repos other sessions are live in. One global config covers every repo including ones created later. Verify in a repo with no local entry: `git status` stays clean with a worktree open, and `git check-ignore -v` attributes the match to the global file.

Caveat: a global excludes file is machine-local and not shared with collaborators. Fine for a solo multi-machine setup; a repo with outside contributors still wants the committed line. Repos that already carry it locally keep it, harmlessly.

For reference, the line itself:

```
.claude/worktrees/
```

Without it the worktree directory shows up as `?? .claude/` in the **canonical** tree, so a `git add -A` there commits an entire nested worktree. Measured: unignored, `git status` in the canonical checkout listed `?? .claude/` the moment a worktree existed. Ignoring it is what makes the canonical tree stay clean.

### Proof it does what it claims

Reproducing a real clobber, with session B in a worktree:

```
canonical tree (session A):   M CLAUDE.md        <- A's uncommitted edit
worktree      (session B):    echo >> progress.md ; git add -A
B staged:                     M  progress.md      <- only its own file
A's CLAUDE.md edit:           untouched
```

Same command that captured another session's work, now inert.

### Two hook fixes worktrees REQUIRE

Worktrees are invisible to a naive push gate, so a session can commit in one, never merge, and stop with no warning at all: trading a loud problem (clobber, which you notice) for a silent one (stranded work, which you do not). Two independent causes, both of which your unpushed-work check must handle:

- `.git` is a **directory** in a normal checkout but a **file** in a linked worktree, so a `-d` entry test skips every worktree ledger entry.
- A worktree branch has **no upstream**, so `@{u}` fails and the unpushed check is skipped. Compare against origin's default branch instead, because for such a branch the question is not "pushed to my upstream" but "does this work exist on the remote yet".

### What NOT to do: collapsing a worktree onto its canonical repo

Tempting (claim ledgers key on repo root, so a worktree looks like a separate repo), and wrong twice over. Tried and reverted:

- The ledger would key on the canonical root while the file lives in the worktree, so `rel_path` resolves to `.claude/worktrees/<name>/…`, which is **gitignored there** and reports clean. Dirty worktree files would look committed.
- Two sessions in separate worktrees genuinely **cannot** clobber each other's working tree, so cross-warning them is a false positive. Per-working-tree scoping is correct.

One related subtlety if you touch repo-root resolution in a guard: run its `check-ignore` test against the tree the file actually lives in. Testing a worktree file against the canonical repo reports every one of them ignored (because of the `.gitignore` entry above) and the session goes completely invisible to the guards.

### Landing a branch: never merge from the shared checkout

`cd <primary> && git merge <my-branch>` merges into **whatever branch is checked out right now**, which is not necessarily the one that was there when you started. Observed: a peer session checked its own branch out in the shared tree mid-run; the merge fast-forwarded that branch instead of the default one, `git push origin <default>` failed non-fast-forward, and two commits were sitting on somebody else's already-merged PR branch. `git status -sb` had read clean and on-default twenty minutes earlier. A clean tree is not evidence the branch is the one you assumed, and re-checking is a race, not a fix.

Land from a worktree of the default branch instead, which cannot be moved under you:

```bash
git worktree add --detach .claude/worktrees/land <default-branch>
cd .claude/worktrees/land
git merge --no-edit origin/<default-branch>      # pick up peers first
git merge --no-edit <my-branch>
git push origin HEAD:<default-branch>            # push the SHA, not a local ref
cd - && git worktree remove .claude/worktrees/land --force
```

If you have already merged onto a peer's branch: `git branch <keep> <your-sha>` to preserve the work, land it from the worktree above, then `git reset --hard origin/<peer-branch>` to restore their branch to exactly what they pushed, and leave it checked out where they left it. Do not switch the shared checkout back to your branch as a courtesy; leaving it where the peer put it is the courtesy.

### Checking out the default branch name inside that landing worktree defeats the whole point

The recipe above works specifically because `git worktree add --detach <default-branch>` never touches `refs/heads/<default-branch>`: it is a detached checkout of a commit, not a branch. Skip the `--detach` (or follow it with `git checkout -B <default-branch> origin/<default-branch>` to "get onto the branch properly") and you recreate the exact problem this section exists to avoid. `refs/heads/<default-branch>` is **shared across every worktree of one repo** (only the index and working tree are per-worktree), so checking it out a second time either errors ("already used by worktree at ...") or, on some git versions, silently succeeds and moves the shared ref out from under the primary checkout. When it silently succeeds, the primary checkout's `git branch --show-current` still reads correctly and `git status` still says "up to date with origin" (both true of the ref), but its **working tree and index never moved**: `git show HEAD:<file>` returns the new content while the file on disk and `git status` show the *old* content staged as a phantom uncommitted diff, with no destructive command ever run there.

Observed symptom: a primary checkout reporting a spurious "31 lines deleted" staged change immediately after a landing worktree's push.

**Recovery:** not corrupted, only stale. Do not `git reset --hard` (it can discard unrelated pre-existing dirty state elsewhere in the same tree); restore just the affected file(s): `git restore --staged <file> && git checkout HEAD -- <file>`.

### A push from the landing worktree does not fast-forward a DIFFERENT long-lived checkout of the same repo

The recipe above lands cleanly (`git push origin HEAD:<default-branch>`), which advances `origin/<default-branch>`. But if some other process has its own separate, persistent checkout of the same repo that it reads files from directly (not via `git show origin/<default-branch>:<file>`), that checkout is not automatically updated by the push. It only updates when something in *that* checkout fetches and fast-forwards.

Concrete class: an automation runner reads its `config.json` straight off disk in its own long-lived checkout, with no `git fetch`/`pull` at startup. Two consecutive runs each landed a real config fix via the worktree recipe above and reported it as done (correctly, for `origin/<default>`), but the runner's own checkout stayed a commit behind for several more runs, so the fix never took effect operationally. The gap was invisible because each run's own "main checkout untouched, pre-existing bookkeeping diffs" note (accurate for *why the tree looks dirty*) was reused as evidence the checkout was fine, without re-diffing `<local-branch>..origin/<default-branch>`.

**How to apply:** landing a branch via the worktree recipe only guarantees `origin/<default-branch>` is correct. If a repo has its own separate checkout that some automation reads directly, that checkout needs its own `git fetch && git merge --ff-only origin/<default-branch>` before the fix is live. Verify with `git log --oneline <local-branch>..origin/<default-branch>`; a non-empty result means it is on the remote but not yet operational anywhere that reads the stale copy.

### `git worktree add <path> <branch> --detach` can silently resolve to a stale LOCAL ref, even right after `git fetch origin <branch>`

A common recipe for staging onto an already-open non-default branch is `git fetch origin <branch>` then `git worktree add <path> <branch> --detach`. `--detach` prevents the shared-ref-move failure above, but it does not fix a different trap: `git worktree add <path> <branch>` resolves `<branch>` by git's normal ref lookup order, which prefers a **local** branch named `<branch>` (`refs/heads/<branch>`) over the remote-tracking ref `refs/remotes/origin/<branch>`. `git fetch origin <branch>` only updates `FETCH_HEAD` and `refs/remotes/origin/<branch>`; it never touches a local branch of the same name. If a prior session in this same checkout ever ran `git worktree add ... <branch>` (without `--detach`) or otherwise created a local `<branch>` ref, that local ref is left behind after the worktree is removed, and every later `git fetch` leaves it exactly where it was.

Observed: several prior automated runs had each left a stale local ref for a shared feature branch in the main checkout. A later run committed a fresh change, fetched the remote branch (by then two commits ahead), created the worktree from the bare branch name, and got a worktree at the STALE local-ref commit, two behind origin, with no error or warning. The subsequent `git push origin HEAD:<branch>` correctly failed non-fast-forward (the safety net that catches this before it silently drops someone else's commits), but a caller that force-pushes on rejection, or that pushes to a differently-named branch instead of the shared one, would not get that warning.

**How to apply:** when staging onto an EXISTING branch (not the default branch, and not a fresh `-b <new-branch>`), always create the worktree from the fully-qualified remote ref: `git worktree add <path> origin/<branch> --detach`, never the bare branch name, even immediately after a fresh `git fetch`. This sidesteps the local-ref ambiguity entirely rather than relying on catching a rejected push. If a push is ever rejected non-fast-forward on such a branch, that means this trap (or a genuine concurrent writer); `git fetch` and rebase onto the true remote tip, do not force-push.

### Enforcement: a `PreToolUse` worktree guard

An advisory rule needs a hook behind it. A `PreToolUse` hook on `Edit|Write` can deny the **first write** to a repo when all three hold:

1. the target is inside a repo under the guarded root (your repos directory, with an env override), **and**
2. it is not already inside `.claude/worktrees/`, **and**
3. another **live** session has written **that same file**.

**Condition 3 was originally "holds that repo", and that was wrong.** Production disagreed within ~15 minutes: two denials against a real peer in two repos, with **zero overlapping files** in both, and that session acked both rather than taking a worktree. Repo-level co-presence is the normal state when several sessions run; it is not a collision. What it actually risks, a stage-everything commit sweeping a peer's uncommitted work, is already blocked by the claim-guard deny arm, so the wider condition bought friction and no protection.

Two bugs surfaced while narrowing it, both worth knowing if you touch ledger matching: ledger paths are absolute but **not normalized** (a real entry contained `/./`, which fails plain equality against a realpath'd target and would have made the guard silently never fire), and an unquoted heredoc expands variables but does **not** interpret `\n`.

Condition 3 is what makes this enforcement rather than friction: a solo session in an uncontested repo never sees it. Give it an escape hatch shared with claim-guard, so one override covers both:

```bash
printf '%s\t%s\n' '<repo-name>' '<reason>' >> /tmp/claude-claim-ack-<sid>
```

**Why PreToolUse and not Stop**, which is the intuitive choice: at Stop the editing has already happened in the shared checkout, so blocking cannot retroactively isolate anything; there is no remediation left, only nagging. Stop also cannot distinguish "correctly skipped" from "forgot", so it would fire on the exempt cases too and train reflexive acks. Stop's correct job here is catching work *stranded in a worktree*, i.e. "did your work escape this machine", not "did you use the workflow".

Key it on the target **file path**, not `cwd`: editing an absolute canonical path from inside a worktree is still unisolated, and `cwd` would call that safe.

Enable it by default for multi-edit work in your repos root. Skip for read-only work, one-file edits and ops. The `.gitignore`/global-excludes prerequisite must be in place for any repo before working in a worktree there.

**Deploys read the canonical checkout**, not your worktree: merge and push before running a deploy or a live reload, or you will ship the pre-worktree code.

## Problem B: take a real lock

A small wrapper that serializes an operation on a named singleton:

```bash
with-resource-lock.sh <resource> [--timeout N] -- <command...>
with-resource-lock.sh --list          # who holds what right now
```

Resource naming scheme (keep it stable, the string IS the lock):

| Resource | Covers |
|---|---|
| `deploy:<app>` | that app's deploy directory and its process-manager service |
| `browser-extension` | the live browser extension: reload, debugger protocol, tab state |
| `remote:skills` | a shared skills directory on a remote host |

Wire it in at the narrowest shared chokepoint:

| Resource | Where |
|---|---|
| `browser-extension` | the extension-reload command self-wraps (with an env var to opt out) |
| `remote:skills` | the skills sync script; it replaces hand-run rsync pairs and also counts `SKILL.md` across all copies, failing on a mismatch |
| `deploy:<app>` | the deploy and staging skills. Wire at the skill, not in 10+ per-repo `deploy.sh` files, because the ecosystem rule is already that deploys go through those skills |

### A runner's own `.running.lock` doesn't stop a second, manually-launched invocation

`.running.lock` pidfiles only serialize a runner script against **itself**: a second cron tick, or a stray restart. They do nothing to stop a human, or another session, from manually re-executing the exact same mission file the runner already dispatched to its own child.

Incident class: an interactive invocation was handed the exact mission file a runner had generated and dispatched to its own headless child two minutes earlier. The runner's `.running.lock` was held the whole time; it just does not cover this path. Both processes would have raced to merge the same open branches, append to the same log files, and bump the same run counter, none of which is safe for two concurrent writers.

**Before executing ANY lock-guarded runner's mission file by hand:**

0. **Ownership pre-check, do this FIRST; it is the common case, and skipping it is what made roughly a quarter of runs self-block.** If the lock PID is an ancestor of your own shell, you ARE the runner's own dispatched child and there is no duplicate: proceed, do not report `BLOCKED:`. Walk the WHOLE ancestry chain, not just your direct parent: a runner spawns `run.sh` → `timeout` → the agent process, so the lock PID sits two or more levels above you.
   ```bash
   pid=$(cat <runner-dir>/.running.lock); p=$$
   while [ "$p" -gt 1 ]; do [ "$p" = "$pid" ] && { echo "OWN RUN: proceed"; break; }; p=$(awk '/^PPid:/{print $2}' /proc/$p/status); done
   ```
   Two explicit signals can confirm the same thing without the walk, and are worth building into any runner you write: stamp the child's own prompt with a `[RUNNER OWNERSHIP ...]` header, and write a `.running.owner` file (`runner_pid=...`) next to the lock. Either signal alone is proof you own the run.
1. `cat <runner-dir>/.running.lock` for a PID.
2. `ps -p <PID>`: confirm it is alive and is the runner script, not a stale pidfile left by a crashed run.
3. `ps --ppid <PID>`: find its spawned agent child.
4. Diff that child's command line against the mission text you were just handed to confirm it is the same run.

Only if step 0 clears you (the lock PID is NOT one of your ancestors) AND a live duplicate is found, stop and report `BLOCKED:`; a genuinely separate run owns the work and will complete it, so do not race it. If the lock PID is dead, it is safe to proceed.

### Lock behavior worth knowing

- Back it with `flock(2)`, so the kernel releases the lock when the holder exits **including on crash or SIGKILL**. A dead session can never wedge a resource.
- Waiting past `--timeout` should exit **75** (`EX_TEMPFAIL`), distinct from the wrapped command's own failures, and name the holder.
- Make it re-entrant within one process tree (an env var listing held locks), so a locked script calling another locked script does not deadlock against itself.

### The gotcha a lock wrapper exists to have already solved

A child process **inherits the lock file descriptor**. Without care, wrapping anything that daemonizes (a process-manager restart, any `nohup`/`setsid` service) hands the inherited fd to a process that outlives the deploy, and the resource is locked *forever*. That is strictly worse than no lock. Run the command as `"$@" 9>&-` to close the fd in the child, and verify with:

```bash
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  ls -l /proc/$p/fd 2>/dev/null | grep -q "claude-resource-lock-<name>" && echo "holds: $p"
done
```

Only the wrapper's own pid should appear.

## The backstop: claim-guard

Detection cannot serialize anything, so this is the third line, not the strategy. It earns its place by catching the case both columns above miss: two sessions that never took a worktree and never took a lock, writing the same path right now.

Two modes:

| | When | Behavior |
|---|---|---|
| `warn` | PostToolUse `Bash\|Edit\|Write` | Names the other live session when it wrote the same file (or the same repo). Deduped: once per path per peer session. |
| `deny` | PreToolUse `Bash` | Exit 2 on `git add -A/--all/.`, `git commit -a/--all`, and `rsync --delete` into a shared deploy target when a live peer holds that repo or deploy target. |

Supporting pieces:

- A write-target inference library infers which files a Bash command writes. Heredocs, redirects and `sed -i` are invisible to a `file_path` tracker, and a real near-miss happened on exactly such a write. Precision beats recall here: a bare `python3` is not a write, only one whose body writes.
- A session heartbeat hook writes `/tmp/claude-session-alive-<sid>` per session (headless included). Without per-session liveness the guard fires on `/tmp` ledgers left by sessions that exited weeks ago.
- Two ledgers: `/tmp/claude-repos-touched-<sid>` is Edit/Write only (authorship, feeds the Stop gate); `/tmp/claude-repos-claimed-<sid>` is Bash-inferred (advisory, guard only). Heuristics must never reach a gate that blocks a session's exit.

**Escape hatch, because a denial must never be a dead end:** `printf '%s\t%s\n' '<target>' '<reason>' >> /tmp/claude-claim-ack-<sid>`. Log denials, overrides and unresolvable targets to a file you can audit.

**Registration.** Hook scripts are versioned in a repo; the wiring lives in `~/.claude/settings.json`, which is in no repo. Mirror it into your private context repo and drift-check it. The wiring:

```jsonc
// PreToolUse, matcher "Bash"
"bash -c 'printf \"%s\" \"$(cat)\" | bash $HOME/<repo>/hooks/claim-guard.sh deny'"
// PostToolUse, matcher "Bash|Edit|Write"  (track first, then guard)
"bash -c 'printf \"%s\" \"$(cat)\" | bash $HOME/<repo>/hooks/track-repo-writes.sh; exit 0'"
"bash -c 'printf \"%s\" \"$(cat)\" | bash $HOME/<repo>/hooks/claim-guard.sh warn; exit 0'"
// PostToolUse, matcher "Bash|Edit|Write|NotebookEdit"
"bash -c 'printf \"%s\" \"$(cat)\" | bash $HOME/<repo>/hooks/session-heartbeat.sh; exit 0'"
```

The `deny` entry deliberately omits `exit 0`: swallowing its exit code turns the block into a no-op.

### Closed gaps

- **False-positives on the command's own text.** Two uncorrelated greps meant a commit message *describing* the dangerous command was denied as if it were the command. Fix: split the command into segments (drop heredoc bodies, unwrap `ssh <host> '<remote>'`, remove string literals before reading arguments) and judge each segment by its own leading command and argument list. Cover it with three regression tests: quoted `-m` message, heredoc commit body, `echo` of the string.
- **The Stop gate was repo-granular.** Fix: intersect each unpushed commit's files against this session's Edit/Write ledger, so it blocks only on commits containing files this session wrote. A peer's unpushed commits are then *reported* rather than blocked, pointing at the push-to-their-branch procedure.

### Remaining gap

A `cd` target built from a variable assigned in an *earlier* turn cannot be resolved (a variable assigned in the same command can be). Have the deny arm log `unresolved-target` rather than passing silently, so the blind spot is auditable. The warn arm still fires on the writes themselves.

## Hygiene and monitoring

**Reap session ledgers (hourly cron).** Sessions never clean up their `/tmp` state. One measurement: 299 files, 1.1MB, **59 alive markers for ~2 live sessions**. Two harms, neither cosmetic: the raw marker count misleads anyone who reads it, and claim-guard iterates every ledger on each qualifying command. Reap at 24h (48x the liveness window) with a hard 2h floor that refuses any shorter age, because a too-eager reap would silently blind the guards rather than fail loudly.

**Guard calibration report (daily cron).** Alert when a guard is being **routed around**, which is the failure nothing else watches for. The signal is the override rate, not the deny count: a guard that fires and is obeyed works; one that fires and gets overridden is indistinguishable from an absent one.

Count **distinct sessions**, not log lines. One ack decision logs a line on every subsequent write, so a line-based rate inflates without bound, and a first pass nearly tuned the threshold against the test suite's own synthetic ids. A real first reading looked like:

```
worktree-guard   sessions denied=3, of which overrode=3 (100%)
claim-guard      sessions denied=5, of which overrode=0   (0%)
```

Every real session that hit the worktree guard routed around it, which is what sent us to narrow condition 3 above.

## Diagnostic order when something "keeps reverting"

Before blaming cache or cron: `stat` the origin file against your deploy time, then `git log -- <path>` for foreign commits, then map live sessions with `/tmp/claude-session-alive-*`.

**Do not kill a live session to win a race.** It is usually one of your own. Check whether its tree is clean and pushed, then ask.

### A main checkout left on a stray already-merged branch serves stale content and reads as a false "undocumented gap"

A prior session (typically a doc-sync run) checks out its own feature branch in the shared main checkout, its PR merges, and nothing ever switches the checkout back to the default branch. The checkout then sits on a branch whose own commits are all upstream on the default branch (via squash-merge, so `git merge-base --is-ancestor <branch> <default>` reports `false` even though the content already landed), but which is missing every commit the default branch gained *afterward*. Symptom: `CLAUDE.md` (or any guidance file) on disk looks like it is missing a recently-documented fix that `git log` on the remote default branch clearly shows as merged, which reads exactly like an uncaptured gap and sends an investigating session toward re-adding content that already exists.

Caught twice independently in one fleet, once nearly causing a run to re-file an entry that had already shipped three commits ahead of what the checkout showed on disk.

**Detect:** `git -C <repo> branch --show-current` vs. the remote's default branch name (`gh repo view --json defaultBranchRef -q .defaultBranchRef.name`). Any mismatch is a candidate.

**Recover, never assume:** `git status --short` first (must be clean; do not touch a dirty tree). Diff the stray branch's unique commits' *content* against the default branch rather than trusting `merge-base --is-ancestor` (squash-merges break literal ancestry): `git diff <stray-unique-commit> origin/<default> -- <changed-files>` should be empty or a strict subset. Only then `git checkout <default> && git pull --ff-only`. If the stray branch carries content NOT present on the default branch, stop and investigate instead of discarding it; this recovery is only safe when the diff confirms nothing unique survives only on the stray branch.

### `node_modules/` with a trailing slash does not ignore a `node_modules` SYMLINK

When you follow the worktree rule and create a worktree to run a repo's tests, the worktree has no `node_modules`. The quick fix is to symlink the main checkout's: `ln -s /abs/path/to/repo/node_modules node_modules`.

That symlink is NOT covered by the near-universal `.gitignore` entry `node_modules/`. A pattern with a trailing slash matches directories only, and to git a symlink is a *blob* (mode 120000), not a directory. So `git add -A` silently stages the symlink, and it lands in the commit and the PR as a one-line file whose contents are an absolute path from your home directory.

Two consequences, both bad: the diff leaks a local absolute path (an infrastructure identifier), and anyone checking the branch out gets a dangling symlink where their dependencies should be. Observed across three repos simultaneously; all three `.gitignore` files used the trailing-slash form, so all three were exposed.

Rules:
1. After linking `node_modules` into a worktree, ALWAYS `rm` the symlink before committing, and prefer `git add <explicit paths>` over `git add -A` in a worktree.
2. Read `git status --short` before every commit in a worktree and treat any unexpected `??` entry as a stop, not noise. An ignore rule that looks like it covers a path may not cover the FORM the path takes.
3. `git diff --staged --stat` before every commit; treat a `node_modules` row as a stop sign. Fix with `git rm --cached node_modules`.
4. To prevent it repo-wide, use the slash-less form `node_modules` in `.gitignore`, which matches a directory OR a file OR a symlink of that name.

Generalizes past `node_modules`: any `.gitignore` entry written as `name/` will miss a symlink called `name` (`dist/`, `build/`, `.next/`, `coverage/`, `venv/`). Symlinking a heavy build or dependency directory into a worktree is exactly the workflow that trips it, so this is a standing hazard of the worktree pattern rather than a one-off.

### A Next.js standalone build inside a worktree nests its output, so those artifacts must never be deployed

Next's standalone output mirrors the project directory *relative to the repo root*. Built from the primary checkout it lands at `.next/standalone/.next/`; built from a worktree it lands at `.next/standalone/<worktree-path>/.next/`. The common build-script line then fails:

```
next build && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static
# cp: cannot create directory '.next/standalone/.next/static': No such file or directory
```

The compile itself SUCCEEDS and every route is listed, so the run reads as passing right up to the `cp` error on the final line.

Rules:
1. **Never deploy artifacts from a worktree build.** The static assets sit where the standalone server will not serve them, which reproduces exactly the unstyled-page failure that static-asset-drift repair exists to fix.
2. Treat that `cp` failure as a hard stop, not a cosmetic warning. It is the signal that the output tree is not the shape the deploy expects.
3. A worktree build is still the right way to *typecheck and validate* a change. Merge to the default branch, then build from the primary checkout to produce anything deployable.

### `git add` inherits a shared staging area: a pre-commit secret gate can block YOUR commit over a peer's content

SYMPTOM: you stage one clean file, and the pre-commit secret scan blocks the commit citing line numbers and identifiers that do not appear anywhere in your file.

CAUSE: several sessions share one checkout, so the git INDEX is shared state too. A peer session had already staged 8 other files. Your `git add <one-file>` adds to that existing index, and the gate scans the whole staged diff, not just your path. In one real case the 8 peer-staged files carried genuine identifier leaks.

DO NOT `git commit --no-verify`. The gate was right; the leaks are real. Committing bypasses it for the peer's content, not just yours.
DO NOT `git reset` or `git stash`. Reset is fine here in practice but broad, and stash TOUCHES THE WORKING TREE, which can yank files out from under a live peer session mid-write.

DO: unstage the peer's paths by name, leaving the working tree untouched, then commit only yours.

```bash
git diff --cached --name-only            # see whose files are actually staged
git restore --staged <peer-path> ...     # index only; files stay on disk
git diff --cached --name-only            # confirm only yours remains
git commit && git push
```

Their content is preserved on disk and loses nothing: it could not have been committed anyway while the gate was blocking it. Report the blocked files as an open item so the leaks get fixed rather than silently re-staged.

GENERAL RULE: before committing in a shared checkout, always run `git diff --cached --name-only` and confirm every staged path is yours.

### `git reset --hard` in a shared checkout discards a peer's uncommitted work on ANY tracked file

SYMPTOM: `git push` rejected as non-fast-forward on a shared checkout (a peer session pushed first). The actual conflict can be benign: two sessions each appending a chronological entry to the tail of the same append-only file, where the right fix is to reset to the new remote tip and re-append at the true tail (rebasing would mis-order the entries).

CAUSE: `git reset --hard origin/<default>` resets the ENTIRE working tree and index to match the given ref, discarding every uncommitted local change, not just the file being fixed. In one incident, `git status --short` run immediately beforehand had shown a second, unrelated modified file (a sync cursor another process updates in place without committing, routinely dirty, which every prior session had explicitly left alone for exactly that reason). The reset discarded it anyway. Because the change had never been `git add`ed, git held no object for it anywhere (not a stash entry, not an index blob, not a dangling object `git fsck --dangling` could find): unrecoverable through git, full stop.

DO NOT treat "routinely dirty, safe to ignore" as "safe to discard". Ignoring a file means reading past it in `git status`, not wiping it with the next destructive command.

RULE: before ANY working-tree-touching command in a shared checkout (`git reset --hard`, `git checkout .`, `git clean -f`), run `git status --short` first and isolate every path that is not yours: `git stash push --include-untracked -- <peer-path>...`, or commit it first if sweeping up stranded peer files is this repo's established convention. This sharpens the reset-vs-stash guidance above: a bare `git reset` (mixed) touches only the INDEX and is safe; `git reset --hard` touches the WORKING TREE exactly like `git stash`/`git checkout --` and inherits the identical "not just your paths" hazard.

BETTER: prefer the worktree pattern (Problem A) for resolving a diverged shared-file conflict too. Do it in a scratch worktree off the fresh remote tip, never in the shared main checkout, so there is no working tree to reset out from under a peer in the first place.

### Two agents on one browser profile must claim targets in a file before the first fill

Two jobs ran the same form-filling task against the same browser profile at once. Symptoms: tabs appearing that this session did not open, and "Timeout waiting for browser response" on roughly every other command.

Detect it, do not guess: the browser relay's logs print per-consumer lines (`[<consumer-id>] Exec: clickAny ...`); consumer IDs that are not yours are another agent. Cross-check with `ps` start times against your own PID chain.

Interleaved fill/click on a shared profile silently corrupts the other agent's half-filled form, and duplicate submissions risk a duplicate record on the far end. Resolution that worked: a `CLAIMS.md` in the shared working dir listing PID -> target, appended to BEFORE the first fill on a new target, plus an explicit statement in the final report that the other job's targets are its to report, not yours. Never assert an outcome for a target another agent drove; you cannot verify it.

Further signals that a sibling job is live in your workspace:
- a file in your scratch dir you did not create (a claims file, an extra credential line)
- the browser tab list showing tabs for sites unrelated to your task
- "Another debugger is already attached to the tab with id: N" from debugger-protocol commands
- your own PID tree not matching the PID recorded in the claims file

Rules:
1. Before the first `fill` on a new target, list your scratch dir and READ any claims/lock file.
2. Append your PID + target to it before driving.
3. Never treat a remote "record already exists" response as evidence your own submit worked. It is equally consistent with a sibling having done it. Verify by logging in, or check the claims file. In a real incident, a second job read exactly that rejection as proof of its own success and wrote a false result plus a bogus credential into shared files.
4. Target tabs by explicit tab id, and assert the URL before acting; a focus-by-substring matches any tab including ones the relay is not tracking, so a loose URL substring can silently drive the wrong page.

### Deploying by rsync from the shared checkout can ship a file with conflict markers in it

A static page built and tested in a worktree, main fast-forwarded, then `dist/` rsynced from the SHARED canonical checkout. Seconds later another live session started a merge in that same checkout and rewrote the very files just sent, leaving conflict markers in them. The rsync won the race by about sixty seconds; had it lost, a public page would have gone out containing literal `<<<<<<<` markers.

Two rules follow.

1. Deploy the artifact you actually verified. rsync from the worktree path you built and ran the tests against, not from the shared checkout, even after a clean fast-forward. The shared checkout is not yours between one command and the next.
2. Check the artifact before it leaves. A generated page that stamps its own build hash gives you a one-line integrity check: grep the stamp and require exactly one match. Two stamps in one file is the signature of a conflicted merge, and it is visible before the upload rather than after. Compare the md5 of the local file against the deployed one afterwards, too: matching the wrong source silently is the failure this catches.

Detection in the wild: the local dist file was 182906 bytes with two build stamps while the committed version was 161069 bytes with one, and `git status` showed `UU` on the same paths.

## Deploy from the merged default branch, not from your worktree

A worktree isolates your edits, which is the point, but its generated output (`dist/`, a build directory, an artifact) only reflects your branch. Deploying from it publishes a build missing whatever landed on the default branch while you worked, which silently reverts another session's shipped feature.

Seen in practice: a static-page deploy from a worktree overwrote a feature a concurrent session had shipped to the same route an hour earlier. Neither side saw it; the other session redeployed for its own reasons and the clobber healed by luck.

The order that avoids it:

1. merge to the default branch (`git merge --no-ff <branch>`)
2. **regenerate** generated files there rather than resolving them as text; a conflict in `dist/` is not a conflict, it is a stale artifact
3. run the suites against the merged output, not the branch's
4. deploy, then compare the live build stamp with the one you shipped

A live build stamp you do not recognise, before or after your deploy, means someone else deployed while you worked. That is the cheapest available detector, and it only works if the build carries a stamp.

## A relative-path shell edit runs in the shared checkout, not your worktree

The worktree protects you from a stage-everything commit. It does **not** protect you from a shell command that resolves its own path.

Observed: a file was edited correctly in the worktree with an absolute path, then a follow-up `perl -0pi -e 's/.../.../' <relative/path.js>` used a **relative** path. The shell's cwd had reset to the repo root between tool calls, so the substitution rewrote the **shared main checkout**, leaving it referencing a constant that only existed in the worktree. The worktree file was never edited at all.

It read as green twice over:
- `node --check` passed on the contaminated file. It parses syntax and never resolves identifiers, so a file referencing an undefined constant type-checks fine and fails only at runtime.
- The confirming `grep` found the substitution, in the wrong tree.

The failure surfaced much later, as an unrelated-looking `spawn ENOENT` from a test that should have picked up the change.

Rules:
1. **Absolute paths for every scripted edit in a worktree** (`perl`, `sed`, `awk`, `mv`, `cp`), not just for the editor tool. A relative path is only safe when the same command re-establishes cwd.
2. **Assert the shared checkout is clean after any scripted in-place edit**: `git -C <worktree> diff --stat` for what you meant to change, `git -C <main-checkout> status --short` for what you did not. One command, and it is the only check that catches this.
3. **Revert a leak surgically** by inverting the same substitution. `git checkout -- <file>` in a shared checkout would also discard another live session's uncommitted work in that file.

### A branch that predates a concurrent session's additions deletes them on merge

Two sessions worked the same task in one shared checkout. The sibling committed two new files straight to the default branch and renamed them into the directory this session owned. This session's feature branch, cut before those files existed, then showed CONFLICTING. The real hazard was not the conflict: `git diff --stat origin/<default>..HEAD` showed the branch DELETING 625 lines across the sibling's two files, because a merge makes the branch's tree authoritative for paths it never knew about. Rebasing hit an add/add conflict and reset the working copy, losing the edit in progress.

What worked: abandon the stale branch, cut a fresh one from current `origin/<default>`, and `git checkout <old-sha> -- <only the files I changed>`. That replays intent without asserting anything about paths a sibling added.

How to apply: before merging any branch older than a few minutes in a repo that other agents write to, run `git diff --stat origin/<default>..HEAD` and read the DELETIONS, not the additions. Deletions of files you never touched mean your branch is stale, not conflicted. Prefer cherry-picking your own changed paths onto a fresh default branch over rebasing, because rebase resolution churns the working tree while sibling agents are still writing to it.

### A lock-free concurrent deploy of the same app can stop prod and rebuild the shared staging dir mid-build, leaving prod down with a partial build

A deploy lock only serializes sessions that USE it. Real incident: two sessions deployed the same app at once; the session not holding the lock ran its promote (stop the service, then a partial rsync) while the other did `rm -rf <staging-dir>` + re-clone + rebuild. Result: prod STOPPED with the standalone `server.js` MISSING and public health 503, and no rsync or build running (the other promote had stalled).

Recovery that WORKS: do NOT roll back to the `.next-backup` (that reverts to the pre-collision build and loses the new work). Instead verify the staging dir holds a COMPLETE build of the default branch (`server.js` present, `git rev-parse` equals the intended commit), then finish the promote from it: rsync staging `.next` + `src` to prod, patch `appDir` in BOTH required-server-files manifests, restart the service, confirm no in-place build is running, health-check, purge the CDN edge cache.

Both sessions' staging dirs clone the default branch, so a complete staging build already carries the integrated work.

Prevention: before `rm -rf`'ing a shared staging dir, check the process manager for an online staging service and for a running build/rsync belonging to another session; the lock is necessary but not sufficient when the other party skips it. Always merge to the default branch first (durable) so a prod artifact race cannot lose the code.

### A lock-holder's own child running a "check the runner lock for a duplicate" recipe detects itself

A runner holds `.running.lock` and spawns one agent child; the duplicate-detection recipe tells the session to read the lock PID, find its child, and report BLOCKED if the mission matches. The session finds its own parent and itself. In one fleet this ended 9 of 40 runs as BLOCKED at roughly a dollar each, and each posted a "confirmed collision" note that the next run cited as evidence. The runner lock makes a second runner impossible; every BLOCKED log showed one start-to-finish cycle inside 60 seconds. The "manual second dispatcher" hypothesis was simply wrong.

How to apply: before treating a lock-holder as a duplicate, walk your own PPid chain (`/proc/$$/status`); if the lock PID is an ancestor you ARE the legitimate child, proceed. Structural fix: have the runner prepend a `[RUNNER OWNERSHIP, READ THIS FIRST]` header to the child's prompt (naming the runner PID and telling the child not to run the duplicate-detection recipe against its own lock) and write `.running.owner` (`runner_pid=...`) beside `.running.lock`. Combined with the ownership pre-check at the top of the recipe above, a legitimate child no longer self-blocks.

### Before starting work in a shared working folder, check for a parallel workstream

Observed: a session spent a morning running research agents and writing a decision memo in a case folder, not knowing that a parallel session the previous afternoon had already added an options doc with three alternative proposals and an existing-feature audit, a frame-by-frame review of the same video the new agents were about to re-analyze, an extra section appended to the first session's own working doc, and a set of live click-through prototypes with source under a separate deliverables folder. The overlap surfaced only by chance. Cost: a partly duplicated agent brief and a wrong diagnosis of the user's block (a decision gap across four candidate approaches, not a knowledge gap).

Pre-flight for any shared working folder:
1. `git log --since=<2 days> --format='%h %ad %s' -- <folder>` and `ls -lat <folder> | head` to see files other sessions added.
2. `ls <deliverables-dir>/ | grep -i <topic>` for an existing deliverables directory on the same topic.
3. `ListAgents` for idle interactive peers started around the same time.
4. grep your own working doc for sections you did not write.

Same class as the clobber hazards in this file, but for silent parallel PROGRESS rather than clobbering.

### Bridging a local session to a web UI can silently drop `bypassPermissions`

A local CLI session attached to a web UI re-applies its permission mode from external metadata on reattach. The CLI refuses a restored `bypassPermissions` unless THAT process was launched with `--dangerously-skip-permissions` (binary string: `externalMetadataToAppState: Refusing restored mode 'bypassPermissions' ... falling back to 'default'`), so the session silently lands in `default` or `auto` and starts prompting again. Evidence in one session: 43 permission-mode records as `bypassPermissions` and 10 as `auto`, with each flip to `auto` immediately adjacent to a bridge-session record.

Diagnose: grep the session jsonl for `"permission-mode"` and tally `permissionMode` values. Durable fix is `permissions.defaultMode` in `settings.json` (requires the bypass disclaimer already accepted), not re-toggling per session.

Related: the same bridge is why hook output (SessionStart blobs, UserPromptSubmit notes, tool/skill listings) renders as visible message bubbles in the web view but stays collapsed in the terminal.

#### Fix and how NOT to chase the log line

Set `permissions.defaultMode: "bypassPermissions"` in `~/.claude/settings.json` (back the file up first). The precondition for a settings-level bypass being honoured is consent, read from `skipDangerousModePermissionPrompt` in user settings; that key is the migrated form of the older `bypassPermissionsModeAccepted`, so a host that once accepted the dialog interactively already satisfies it. Check it before promising anyone this fix will work.

**Verify by A/B, do not assume.** Headless `claude -p` inherits user settings but not the parent's runtime mode, and a headless session cannot show a prompt, so a would-be prompt becomes a hard refusal. Same prompt ("run bash: `echo ... > proof.txt`") in a scratch dir, before and after: before, three separate refusals and no file; after, the file exists. That is the cheapest available proof that a permission-mode change actually took effect. Note `permission-mode` records are NOT written in headless sessions, so tallying them is not a usable signal there.

**Do not try to capture the refusal line passively.** `CLAUDE_CODE_DEBUG_LOG_LEVEL` and `CLAUDE_CODE_DEBUG_LOGS_DIR` do not enable file logging on their own (tested: the log dir stayed empty); `--debug` at launch is required, which you cannot retrofit onto sessions a human starts by hand. The transcript is the better evidence anyway, because it records every `permission-mode` transition unconditionally.

**Detector worth building:** a periodic script that flags `bypassPermissions` coexisting with `default` or `auto` in one session. Keep the signature deliberately narrow: a naive "more than one mode" test false-positives on `plan` and `acceptEdits`, which a user enters on purpose with shift-tab; the failure is the mode being taken away, not chosen. Give it a `--selftest` that scans all sessions regardless of age and must find your known-positive session.

### Verify a settings change with a headless `claude -p` A/B, not by reading the transcript

To prove a permission/settings change actually took effect, run the SAME trivial action in a scratch dir via headless `claude -p` before and after. Headless inherits user settings but NOT the parent session's runtime permission mode, and it cannot display a prompt, so a would-be prompt degrades to a hard refusal: a clean binary signal. Worked example: the prompt `Run the bash command: echo PROOF-$(date +%s) > proof.txt` produced refusals and no file before, and the file after.

Two traps found doing this:
1. Headless sessions do NOT write `permission-mode` records to their transcript, so tallying those is not a usable before/after signal there (it silently reads NOT-RECORDED both times).
2. A naive first test that just asks for a one-word reply proves nothing, because no permission is needed. Pick an action that is REFUSED in the restrictive state.

Related dead end: `CLAUDE_CODE_DEBUG_LOG_LEVEL` and `CLAUDE_CODE_DEBUG_LOGS_DIR` do not enable file logging on their own; `--debug` must be present at launch.

### The worktree guard fires on the claim ledger even after the sibling committed

The worktree guard blocks an edit when another live session wrote the exact file recently (tracked via the claim ledger), NOT via uncommitted state. It can fire on a file even though the sibling has already committed its change and the file on disk equals HEAD (`git status` clean for that file). In that case worktree + merge is correct and merges with zero conflict when the sibling touched other regions or files. The caution that the merge-back is blocked by the sibling's same-file change applies only while that change is still UNCOMMITTED; once committed, a worktree branched from current HEAD merges fine.

Separately, for a one-file change to a shared static dir, deploy just that file (rsync, no `--delete`, no directory) so a whole-dir push cannot clobber siblings' in-progress live edits.

### When the guard fires because a LIVE session is mid-edit on your exact file, branch from committed HEAD and push a branch; do not merge under the active writer

A guard blocked an edit, warning that another LIVE session had written THAT EXACT file seconds ago. Investigation confirmed a genuine live collision: the initial Read was already stale (the file had been restructured underneath), `git status` showed the file uncommitted-modified, and over the next few minutes HEAD ADVANCED while the file stayed dirty and its hash kept changing. The other session was actively committing AND holding further uncommitted changes.

Correct handling:
1. Do NOT ack-and-edit the shared file; that clobbers the other session's active work.
2. Create an isolated worktree from committed HEAD (`git -C <repo> worktree add`), re-read the file FRESH there (never trust the pre-collision Read), make and verify the change, commit, and push a dedicated branch for durability.
3. Do NOT merge to the default branch or deploy while the other session holds uncommitted changes. `git merge` refuses to overwrite the dirty working tree anyway, and HEAD may move again. Leave a clear reconciliation note (rebase the branch onto the final default branch once the other session settles).

Verify-before-claiming still applies: the change was confirmed by rendering the page headless and checking for zero console/page errors across the whole flow. Also note: a committed HEAD can be broken mid-refactor (the file called functions the peer had just deleted), so run the prototype before assuming HEAD is a good base.

### A peer's `git reset --hard` on the shared checkout erases every other session's uncommitted work

Incident: a parallel session merged its PR from a worktree, then ran a reset to the remote tip on the shared checkout. That discarded roughly 40 minutes of another session's uncommitted edits across five files.

Detection: a file you edited is suddenly clean in `git status` and its mtime matches the reflog reset entry.

Recovery: extracted `<script>` bodies saved to a scratchpad for each iteration (as `node --check` inputs) held the full final JS, so the pages were rebuilt on the new HEAD by swapping scripts and re-applying the CSS patches from a saved rebuild script, then tested, deployed from the worktree, merged `--ff-only` and pushed.

Rules:
1. Never reset or checkout the shared checkout while `git status` shows files you did not modify.
2. For multi-file work, commit early from a worktree, not the shared tree.
3. Save every generated patch as a file in your scratchpad, not an inline heredoc, so a wipe is recoverable.

### A parallel session can merge a competing PR for the SAME task and reset the shared checkout, silently discarding your uncommitted edits mid-session

On a shared checkout, two dispatched jobs picked up the same instruction. While one edited in place, a sibling merged its own PR and the working tree was reset to HEAD, silently erasing the first session's uncommitted edits from disk (its work survived only because it had already deployed and still held the full content in context). Uncommitted edits in a shared checkout are not durable; a sibling merge/checkout/reset overwrites them with no conflict.

How to apply:
1. Commit early to lock work into git the moment it builds and passes a syntax check, before smoke-testing or deploying.
2. Keep a `/tmp` backup of your final file so a clobber is recoverable.
3. Re-read HEAD and `git log` before assuming your changes survived, especially when the worktree guard fires (a sibling wrote your exact file).
4. When a competing implementation is already merged, LAYER onto it (keep their merged structure, add only the missing piece) rather than blindly superseding it.
5. Targeted single-file rsync, and `git add` only your paths, so you never clobber siblings' other files.

### Guard block: check committed-vs-uncommitted before choosing the path, and deploy targeted under concurrency

When the worktree guard blocks an Edit because another live session touched the same file in the shared checkout, do not just override.

First run `git status --short <file>` and compare `git show HEAD:<file>` against the working tree: if the concurrent session's change is already COMMITTED (working tree clean), a `git worktree add -b <n>` from HEAD is fully clean and the later `git merge` fast-forwards with no conflict. The messy case is only when their edit is UNCOMMITTED.

Second, when deploying a shared static directory while other sessions are mid-edit on OTHER files in it, rsync only your specific changed files (no `--delete`, not a whole-directory `rsync -az --delete <dir>/`), so you cannot revert another session's not-yet-pushed live edits. Verified end to end: worktree merged fast-forward, targeted rsync, direct and public fetches both 200.

### A "stray" uncommitted change on a shared checkout can be a live peer's in-flight edit that commits mid-task and moves HEAD

On a shared checkout, an uncommitted working-tree diff you diagnose as a "stray reversion of the user's instruction" may actually be another live session's in-flight work. Observed: `git diff` first showed a specific line modified (a longer prompt string reverting the user's committed short one); minutes later `git status` was clean and HEAD had advanced two commits, the peer having committed exactly that intent.

So: before stashing, discarding, or "fixing" a working-tree diff on a shared checkout, re-run `git rev-parse HEAD` and `git log --oneline -5` to see if a peer just moved HEAD. The change may be committed intent, not a stray edit.

Also: when the worktree guard fires on a file whose own README explicitly says it needs targeted edits (worktree merge-back blocked by the sibling's same-file change), record the `/tmp/claude-claim-ack` decision and do a path-scoped `git add <file>` plus single-file rsync deploy rather than a worktree.

### Fast-moving shared default branch: land via remote FF-push, deploy the file from the latest remote tip

When parallel sessions share one checkout AND push the same branch every few seconds, do NOT `git merge` into the canonical checkout: its index is actively mutated, so you race and can wedge a sibling's in-flight merge. Symptom: "unmerged paths" with NO `.git/MERGE_HEAD` and NO conflict markers, index mtime seconds old.

Instead:
1. Commit on your isolated worktree branch.
2. `git merge origin/<default>` INTO your branch there, to resolve in isolation.
3. Land with a remote fast-forward push: `git push origin HEAD:<default>`. An FF-push can never clobber remote commits (it is rejected non-ff if the branch moved; re-merge `origin/<default>` and retry, expect 2-3 retries).

For the single-file deploy, extract from the LATEST remote tip (`git show origin/<default>:<path> > /tmp/x`) and rsync THAT (not your worktree copy) to the target path (no `--delete`, no directory), so you deploy the newest merged version and never regress a sibling change that landed after your push.
