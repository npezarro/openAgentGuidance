<!-- Load when: several sessions share one checkout; worktrees, resource locks, claim-guard, "it keeps reverting" -->
# Concurrent Sessions on the Same Repo

Several agent sessions can run against one machine at once, all with permission prompts
skipped, all sharing one checkout per repo. Collisions of this kind recur, and each
narrowing fix tends to shrink the window without closing it.

**The reason it keeps recurring: this is two problems, and one mechanism was being asked to
solve both.**

| | Problem A: shared working tree | Problem B: singletons |
|---|---|---|
| What | N sessions, one checkout. Index + working tree are mutable shared state with no ownership. | A deploy target directory, a process-manager service, a live browser extension, a shared skills directory, a remote host. Exactly one exists. |
| Symptom | `git add -A` commits someone else's uncommitted work; two sessions commit the same file seconds apart. | One session's deploy overwrites another's; two extension reloads tear down each other's service worker. |
| Right fix | **Eliminate the sharing** (per-session git worktrees). | **Serialize** (a real lock) or **partition** (one owner per path). |
| Wrong fix | Detection. It can only narrow the race. | Advisory warnings. You can proceed past them, so nothing is serialized. |

A claim-detection hook is good at what it does and does catch real hazards, but it is
detection applied to both columns. Keep it as the backstop, not the strategy.

## Problem A: use a worktree per session

```
EnterWorktree                 # creates .claude/worktrees/<name> on a new branch
... do the work, commit ...
ExitWorktree { action: keep|remove }
```

**`EnterWorktree` is often unavailable, and a rule that assumes otherwise will be silently
skipped.** The tool requires the SESSION cwd to be inside a git repo, and sessions are
frequently launched from a non-repo directory (a home dir) and routinely span several repos
at once. An instruction that cannot be followed is worse than none: it gets skipped, and
that erodes the rest of the file.

The mechanism is git worktrees; `EnterWorktree` is one convenience wrapper. From anywhere:

```bash
git -C $HOME/<repo> worktree add .claude/worktrees/<n> -b <n>
# then edit via $HOME/<repo>/.claude/worktrees/<n>/...
git -C $HOME/<repo> merge --no-ff <n> && git -C $HOME/<repo> push
```

Verified from a non-repo cwd: the worktree was created, a path-keyed worktree guard treated
the path as isolated (it keys on the target file path, not cwd, precisely so this works),
and the unpushed-work check caught a stranded commit there and labelled it as living in a
worktree. The whole mechanism works cross-repo; only the tool does not.

Then there is no other session's uncommitted work in your tree, so `git add -A` is safe
**by construction** and the whole class disappears.

Why this is cheaper than expected: worktrees live under `.claude/worktrees/`, so the
canonical checkout **stays exactly where it is**. Any cron entries or process-manager
config files that hardcode the canonical repo path keep working untouched. They get better,
in fact: scheduled jobs start running against a clean committed tree instead of one that
several sessions are mid-edit on.

Real costs, stated honestly:
- Each session ends with a merge back to the default branch. Added ceremony for solo work.
- Git refuses the same branch in two worktrees. That is a feature (it forces per-session
  branches), but it is a behavior change.
- Zero help for Problem B.
- Separate clones are unaffected either way. A second checkout on another filesystem or OS
  is still its own clone and still has to be pulled before you act on it.

### Make the ignore rule GLOBAL, not per-repo

```bash
git config --global core.excludesFile ~/.gitignore_global   # contains .claude/worktrees/
```

Set it on every machine you work from, and mirror the file in your private context repo so
it can be restored.

The per-repo `.gitignore` line does not scale: in one measured setup, 118 of 123 repos
lacked it, and adding it to each would have meant 118 commits across repos other sessions
are live in. One global config covers every repo including ones created later. Verify in a
repo with no local entry: `git status` should stay clean with a worktree open, and
`git check-ignore -v <path>` should attribute the match to the global file.

Caveat: a global excludes file is machine-local and not shared with collaborators. Fine for
a solo multi-machine setup; a repo with outside contributors still wants the committed
line. Repos that already carry it locally keep it, harmlessly.

For reference, the line itself:

```
.claude/worktrees/
```

Without it the worktree directory shows up as `?? .claude/` in the **canonical** tree, so a
`git add -A` there commits an entire nested worktree. Measured: unignored, `git status` in
the canonical checkout listed `?? .claude/` the moment a worktree existed. Ignoring it is
what makes the canonical tree stay clean.

### Proof it does what it claims

Reproducing a clobber, with session B in a worktree:

```
canonical tree (session A):   M CLAUDE.md        <- A's uncommitted edit
worktree      (session B):    echo >> progress.md ; git add -A
B staged:                     M  progress.md      <- only its own file
A's CLAUDE.md edit:           untouched
```

The same command that captured another session's work is now inert.

### Two hook fixes worktrees REQUIRE

Worktrees are invisible to a naive push gate, so a session can commit in one, never merge,
and stop with no warning at all: trading a loud problem (clobber, which you notice) for a
silent one (stranded work, which you do not). Two independent causes, both worth fixing in
any unpushed-work check you run:

- `.git` is a **directory** in a normal checkout but a **file** in a linked worktree, so a
  `-d` entry test skips every worktree ledger entry.
- A worktree branch has **no upstream**, so `@{u}` fails and the unpushed check is skipped.
  Compare against origin's default branch instead, because for such a branch the question
  is not "pushed to my upstream" but "does this work exist on the remote yet".

### What NOT to do: collapsing a worktree onto its canonical repo

Tempting (a claim guard keys ledgers on repo root, so a worktree looks like a separate
repo), and wrong twice over. Tried and reverted:

- The ledger would key on the canonical root while the file lives in the worktree, so
  `rel_path` resolves to `.claude/worktrees/<name>/…`, which is **gitignored there** and
  reports clean. Dirty worktree files would look committed.
- Two sessions in separate worktrees genuinely **cannot** clobber each other's working
  tree, so cross-warning them is a false positive. Per-working-tree scoping is correct.

One related subtlety if you touch repo-root resolution: run its `check-ignore` test against
the tree the file actually lives in. Testing a worktree file against the canonical repo
reports every one of them ignored (because of the ignore entry above) and the session goes
completely invisible to the guards.

### Landing a branch: never merge from the shared checkout

`cd <primary> && git merge <my-branch>` merges into **whatever branch is checked out
right now**, which is not necessarily the one that was there when you started. Observed: a
peer session checked its own branch out in the shared tree mid-run; the merge
fast-forwarded that branch instead of the default one, `git push origin master` failed
non-fast-forward, and two commits ended up sitting on somebody else's already-merged
branch. `git status -sb` had read `## master...origin/master` twenty minutes earlier.
A clean tree is not evidence the branch is the one you assumed, and re-checking is a
race, not a fix.

Land from a worktree of the default branch instead, which cannot be moved under you:

```bash
git worktree add --detach .claude/worktrees/land <default-branch>
cd .claude/worktrees/land
git merge --no-edit origin/<default-branch>      # pick up peers first
git merge --no-edit <my-branch>
git push origin HEAD:<default-branch>            # push the SHA, not a local ref
cd - && git worktree remove .claude/worktrees/land --force
```

If you have already merged onto a peer's branch: `git branch <keep> <your-sha>` to
preserve the work, land it from the worktree above, then `git reset --hard
origin/<peer-branch>` to restore their branch to exactly what they pushed, and leave it
checked out where they left it. Do not switch the shared checkout back to your branch as
a courtesy; leaving it where the peer put it is the courtesy.

### Enforcement: a PreToolUse worktree guard

An advisory rule is only advisory, so back it with a `PreToolUse` hook on `Edit|Write`. It
should deny the **first write** to a repo when all three hold:

1. the target is inside a repo under the guarded root (your repos directory, overridable by
   env var), **and**
2. it is not already inside `.claude/worktrees/`, **and**
3. another **live** session has written **that same file**.

**Condition 3 must be file-level, not repo-level.** A first implementation used "holds that
repo" and production disagreed within ~15 minutes: two denials against a real peer with
**zero overlapping files** in both, and that session acked both rather than taking a
worktree. Repo-level co-presence is the normal state when several sessions run; it is not a
collision. What it actually risks, a stage-everything commit sweeping a peer's uncommitted
work, is already blocked by the claim guard's deny arm, so the wider condition bought
friction and no protection.

Two bugs surfaced while narrowing it, both worth knowing if you touch ledger matching:
ledger paths are absolute but **not normalized** (a real entry contained `/./`, which
fails plain equality against a realpath'd target and would have made the guard silently
never fire), and an unquoted heredoc expands variables but does **not** interpret `\n`.

Condition 3 is what makes this enforcement rather than friction: a solo session in an
uncontested repo never sees it. Escape hatch (share it with the claim guard, so one
override covers both):

```bash
printf '%s\t%s\n' '<repo-name>' '<reason>' >> /tmp/claude-claim-ack-<sid>
```

**Why PreToolUse and not Stop**, which is the intuitive choice: at Stop the editing has
already happened in the shared checkout, so blocking cannot retroactively isolate
anything; there is no remediation left, only nagging. Stop also cannot distinguish
"correctly skipped" from "forgot", so it would fire on the exempt cases too and train
reflexive acks. Stop's correct job here is catching work *stranded in a worktree*, i.e.
"did your work escape this machine", not "did you use the workflow".

Key it on the target **file path**, not `cwd`: editing an absolute canonical path from
inside a worktree is still unisolated, and `cwd` would call that safe.

Keep a test suite for it. Verified live: a real `Write` to a contested repo was blocked,
the file was not created, and the ack let the retry through.

**Enable it by default** for multi-edit work in your repos root. Skip for read-only work,
one-file edits and ops. Apply the ignore prerequisite above before working in a worktree in
any repo.

**Deploys read the canonical checkout**, not your worktree: merge and push before running a
deploy or a live reload, or you will ship the pre-worktree code.

## Problem B: take a real lock

A lock wrapper serializes an operation on a named singleton:

```bash
with-resource-lock.sh <resource> [--timeout N] -- <command...>
with-resource-lock.sh --list          # who holds what right now
```

Resource naming scheme (keep it stable, the string IS the lock):

| Resource | Covers |
|---|---|
| `deploy:<app>` | the app's served directory and its process-manager service |
| `browser-extension` | the live browser extension: reload, debugger attach, tab state |
| `remote:skills` | a shared skills directory on a remote host |

Wire it in at the chokepoint, not at every leaf:

| Resource | Where |
|---|---|
| `browser-extension` | the extension-reload command self-wraps (env var opts out) |
| `remote:skills` | the skills sync script; it also counts files across all copies and fails on a mismatch |
| `deploy:<app>` | the deploy and staging skills. Wired at the skill, not in per-repo `deploy.sh` files, because the rule is already that deploys go through those skills |

## Hygiene and monitoring

**Reap stale session ledgers** (hourly cron). Sessions never clean up their `/tmp` state.
Measured once: 299 files, 1.1MB, **59 alive markers for ~2 live sessions**. Two harms,
neither cosmetic: the raw marker count misleads anyone who reads it, and the claim guard
iterates every ledger on each qualifying command. Reap at 24h (48x your liveness window)
with a hard 2h floor that refuses any shorter age, because a too-eager reap would silently
blind the guards rather than fail loudly.

**Run a guard-calibration report** (daily cron). Alert when a guard is being **routed
around**, which is the failure nothing else watches for. The signal is the override rate,
not the deny count: a guard that fires and is obeyed works; one that fires and gets
overridden is indistinguishable from an absent one.

Count **distinct sessions**, not log lines. One ack decision logs a line on every
subsequent write, so a line-based rate inflates without bound; and beware tuning the
threshold against your own test suite's synthetic session ids. A first real reading looked
like:

```
worktree-guard   sessions denied=3, of which overrode=3 (100%)
claim-guard      sessions denied=5, of which overrode=0   (0%)
```

Every real session that hit the worktree guard routed around it. That is the reading that
tells you the guard is unproven, and the report is what tells you whether a fix took. The
general lesson: a check can sit at 0% effectiveness for a long time behind a fallback that
keeps the end state looking healthy, and only an override-rate metric surfaces it.

Behavior worth knowing in any lock wrapper you build:
- Back it with `flock(2)`, so the kernel releases the lock when the holder exits
  **including on crash or SIGKILL**. A dead session can never wedge a resource.
- Waiting past `--timeout` should exit **75** (`EX_TEMPFAIL`), distinct from the wrapped
  command's own failures, and name the holder.
- Make it re-entrant within one process tree via an env var listing held locks, so a locked
  script calling another locked script does not deadlock against itself.

### The gotcha this script exists to have already solved

A child process **inherits the lock file descriptor**. Without care, wrapping anything that
daemonizes (a process-manager restart, any `nohup`/`setsid` service) hands the inherited fd
to a process that outlives the deploy, and the resource is locked *forever*. That is
strictly worse than no lock. Run the command as `"$@" 9>&-` to close the fd in the child.
If you write another lock wrapper, do the same, and verify with:

```bash
for p in $(ls /proc | grep -E '^[0-9]+$'); do
  ls -l /proc/$p/fd 2>/dev/null | grep -q "claude-resource-lock-<name>" && echo "holds: $p"
done
```

Only the wrapper's own pid should appear.

## The backstop: the claim guard

Detection cannot serialize anything, so this is the third line, not the strategy. It earns
its place by catching the case both columns above miss: two sessions that never took a
worktree and never took a lock, writing the same path right now.

Two modes:

| | When | Behavior |
|---|---|---|
| `warn` | PostToolUse `Bash\|Edit\|Write` | Names the other live session when it wrote the same file (or the same repo). Deduped: once per path per peer session. |
| `deny` | PreToolUse `Bash` | Exit 2 on `git add -A/--all/.`, `git commit -a/--all`, and `rsync --delete` into a deploy target when a live peer holds that repo or deploy target. |

Supporting pieces:

- A write-target inference helper infers which files a Bash command writes. Heredocs,
  redirects and `sed -i` are invisible to a `file_path` tracker, and a real near-miss
  happened on exactly such a write. Precision beats recall here: a bare `python3` is not a
  write, only one whose body writes.
- A session heartbeat hook writes `/tmp/claude-session-alive-<sid>` per session (headless
  included). Without per-session liveness the guard fires on `/tmp` ledgers left by sessions
  that exited weeks ago.
- Two ledgers: `/tmp/claude-repos-touched-<sid>` is Edit/Write only (authorship, feeds the
  Stop gate); `/tmp/claude-repos-claimed-<sid>` is Bash-inferred (advisory, guard only).
  Heuristics must never reach a gate that blocks a session's exit.

**Escape hatch, because a denial must never be a dead end:**
`printf '%s\t%s\n' '<target>' '<reason>' >> /tmp/claude-claim-ack-<sid>`. Log denials,
overrides and unresolvable targets to a file you can read later.

**Registration.** The scripts are versioned in this repo; the wiring lives in
`~/.claude/settings.json`, which is in no repo. Mirror it into your private context repo
and drift-check it. Restore by hand with:

```jsonc
// PreToolUse, matcher "Bash"
"bash -c 'printf \"%s\" \"$(cat)\" | bash $HOME/<repo>/hooks/claim-guard.sh deny'"
// PostToolUse, matcher "Bash|Edit|Write"  (track first, then guard)
"bash -c 'printf \"%s\" \"$(cat)\" | bash $HOME/<repo>/hooks/track-repo-writes.sh; exit 0'"
"bash -c 'printf \"%s\" \"$(cat)\" | bash $HOME/<repo>/hooks/claim-guard.sh warn; exit 0'"
// PostToolUse, matcher "Bash|Edit|Write|NotebookEdit"
"bash -c 'printf \"%s\" \"$(cat)\" | bash $HOME/<repo>/hooks/session-heartbeat.sh; exit 0'"
```

The `deny` entry deliberately omits `exit 0`: swallowing its exit code turns the block into
a no-op.

### Closed gaps

- **False-positives on the command's own text.** Two uncorrelated greps meant a commit
  message *describing* the dangerous command was denied as if it were the command. Fix:
  split the command into segments (drop heredoc bodies, unwrap `ssh <host> '<remote>'`,
  remove string literals before reading arguments) and judge each segment by its own
  leading command and argument list. Cover it with regression tests for a quoted `-m`
  message, a heredoc commit body, and an `echo` of the string.
- **A repo-granular Stop gate.** Fix: intersect each unpushed commit's files against this
  session's Edit/Write ledger, so it blocks only on commits containing files this session
  wrote. A peer's unpushed commits are then *reported* rather than blocked, pointing at the
  push-to-their-branch procedure.

### Remaining gap

A `cd` target built from a variable assigned in an *earlier* turn cannot be resolved (a
variable assigned in the same command can be). Have the deny arm log `unresolved-target`
rather than passing silently, so the blind spot is auditable. The warn arm still fires on
the writes themselves.

## Diagnostic order when something "keeps reverting"

Before blaming cache or cron: `stat` the origin file against your deploy time, then
`git log -- <path>` for foreign commits, then map live sessions with
`/tmp/claude-session-alive-*`.

**Do not kill a live session to win a race.** It is usually your own, or a teammate's.
Check whether its tree is clean and pushed, then ask.

### A `node_modules/` gitignore entry with a trailing slash does not ignore a `node_modules` symlink

When you follow the worktree rule and create a worktree to run a repo's tests, the worktree
has no `node_modules`. The quick fix is to symlink the main checkout's:
`ln -s /path/to/repo/node_modules node_modules`.

That symlink is NOT covered by the near-universal `.gitignore` entry `node_modules/`. A
pattern with a trailing slash matches directories only, and to git a symlink is a *blob*
(mode 120000), not a directory. So `git add -A` silently stages the symlink, and it lands in
the commit and the PR as a one-line file whose contents are an absolute path from your home
directory. Observed simultaneously across three repos whose `.gitignore` files all used the
trailing-slash form.

Two consequences, both bad: the diff leaks a local absolute path (an infrastructure
identifier), and anyone checking the branch out gets a dangling symlink where their
dependencies should be.

Rules:
1. After linking `node_modules` into a worktree, `rm` the symlink before committing, and
   prefer `git add <explicit paths>` over `git add -A` in a worktree.
2. Read `git status --short` before every commit in a worktree and treat any unexpected
   `??` entry as a stop, not noise. Run `git diff --staged --stat` too, and treat a
   `node_modules` row as a stop sign. `git rm --cached node_modules` to fix.
3. If you want the link ignored, the pattern must be `node_modules` with no trailing slash,
   which matches a directory OR a file OR a symlink of that name.

Generalizes past `node_modules`: any `.gitignore` entry written as `name/` will miss a
symlink called `name` (`dist/`, `build/`, `.next/`, `coverage/`, `venv/`). Symlinking a
heavy build or dependency directory into a worktree is exactly the workflow that trips it,
so this is a standing hazard of the worktree pattern rather than a one-off.

### A framework standalone build inside a worktree nests its output, so those artifacts must never be deployed

Some bundlers mirror the project directory *relative to the repo root* in their output
tree. Built from the primary checkout the output lands at `.next/standalone/.next/`; built
from a worktree it lands at `.next/standalone/<worktree-path>/.next/`. A build script line
like this then fails:

```
next build && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static
# cp: cannot create directory '.next/standalone/.next/static': No such file or directory
```

The compile itself SUCCEEDS and every route is listed, so the run reads as passing right up
to the `cp` error on the final line.

Rules:
1. **Never deploy artifacts from a worktree build.** The static assets sit where the
   standalone server will not serve them, which reproduces exactly the unstyled-page
   failure that static-asset-drift repairs exist for.
2. Treat that `cp` failure as a hard stop, not a cosmetic warning. It is the signal that
   the output tree is not the shape the deploy expects.
3. A worktree build is still the right way to *typecheck and validate* a change. Merge to
   the default branch, then build from the primary checkout to produce anything deployable.

### `git add` inherits a shared staging area: a pre-commit secret gate can block YOUR commit over a peer's content

SYMPTOM: you stage one clean file, and the pre-commit secret scan blocks the commit citing
line numbers and identifiers that do not appear anywhere in your file.

CAUSE: several sessions share one checkout, so the git INDEX is shared state too. A peer
session had already staged 8 other files. Your `git add <one-file>` adds to that existing
index, and the gate scans the whole staged diff, not just your path. Observed with 8
peer-staged files carrying real repo-name and ssh identifier leaks.

DO NOT: `git commit --no-verify`. The gate was right; the leaks are real. Committing
bypasses it for the peer's content, not just yours.
DO NOT: `git reset` or `git stash`. Reset is fine here in practice but broad, and stash
TOUCHES THE WORKING TREE, which can yank files out from under a live peer session mid-write.

DO: unstage the peer's paths by name, leaving the working tree untouched, then commit only
yours.

```bash
git diff --cached --name-only            # see whose files are actually staged
git restore --staged <peer-path> ...     # index only; files stay on disk
git diff --cached --name-only            # confirm only yours remains
git commit && git push
```

Their content is preserved on disk and loses nothing: it could not have been committed
anyway while the gate was blocking it. Report the blocked files as an open item so the leaks
get fixed rather than silently re-staged.

GENERAL RULE: before committing in a shared checkout, always run
`git diff --cached --name-only` and confirm every staged path is yours.

### Two agents on one browser profile must claim targets in a file before the first fill

Two jobs ran the same form-filling task against the same browser profile at once. Symptoms:
tabs appearing that this session did not open, and timeouts waiting for a browser response
on roughly every other command.

Detect it, do not guess: your browser relay's log output prints per-consumer lines with
consumer IDs; IDs that are not yours are another agent. Cross-check with `ps` start times
against your own PID chain. Other signals that a sibling job is live in your workspace:

- a file in your scratch dir you did not create (a claims file, an extra credential line)
- a tab listing showing sites unrelated to your task
- "Another debugger is already attached to the tab with id: N" from debugger commands
- your own PID tree not matching the PID recorded in the claims file

Interleaved fill/click on a shared profile silently corrupts the other agent's half-filled
form, and duplicate submissions to the same site risk a duplicate account record. In one
run a sibling job re-drove an already-claimed target, got a vendor de-duplication rejection
("a record matching these details already exists"), and then misread that rejection as
proof its OWN submit had succeeded, writing a false success into its results file.

Rules:
1. Before the first `fill` on a new target, list your scratch dir and READ any claims or
   lock file.
2. Append your PID and target to it before driving.
3. Never treat a vendor "record already exists" response as evidence your own submit
   worked. It is equally consistent with a sibling having done it. Verify by logging in, or
   check the claims file.
4. Target tabs by explicit tab id, and assert the URL before acting; a focus-by-substring
   matches any browser tab including ones the relay is not tracking, so a loose URL
   substring can silently drive the wrong page.
5. Never assert an outcome for a target another agent drove. You cannot verify it. State
   explicitly in your final report that the other job's targets are its to report, not
   yours.

### Deploying by rsync from the shared checkout can ship a file with conflict markers in it

Observed: a static page was built and tested in a worktree, the default branch was
fast-forwarded, then `dist/` was rsynced from the SHARED canonical checkout. Seconds later
another live session started a merge in that same checkout and rewrote the very files just
sent, leaving conflict markers in them. The rsync happened to win the race by about sixty
seconds; had it lost, a public page would have gone out containing literal `<<<<<<<`
markers. The local dist file was 182906 bytes with two build stamps while the committed
version was 161069 bytes with one, and `git status` showed `UU` on the same paths.

Two rules follow.

1. Deploy the artifact you actually verified. rsync from the worktree path you built and ran
   the tests against, not from the shared checkout, even after a clean fast-forward. The
   shared checkout is not yours between one command and the next.
2. Check the artifact before it leaves. A generated page that stamps its own build hash
   gives you a one-line integrity check: grep the stamp and require exactly one match. Two
   stamps in one file is the signature of a conflicted merge, and it is visible before the
   upload rather than after. Compare the md5 of the local file against the deployed one
   afterwards, too: matching the wrong source silently is the failure this catches.

## Deploy from the merged default branch, not from your worktree

A worktree isolates your edits, which is the point, but its generated output (`dist/`, a
build directory, an artifact) only reflects your branch. Deploying from it publishes a
build missing whatever landed on the default branch while you worked, which silently
reverts another session's shipped feature.

Observed: a static-page deploy from a worktree overwrote a feature that a concurrent
session had shipped to the same route an hour earlier. Neither side saw it; the other
session redeployed for its own reasons and the clobber healed by luck.

The order that avoids it:

1. merge to the default branch (`git merge --no-ff <branch>`)
2. **regenerate** generated files there rather than resolving them as text; a conflict in
   `dist/` is not a conflict, it is a stale artifact
3. run the suites against the merged output, not the branch's
4. deploy, then compare the live build stamp with the one you shipped

A live build stamp you do not recognise, before or after your deploy, means someone else
deployed while you worked. That is the cheapest available detector, and it only works if
the build carries a stamp.

## A relative-path shell edit runs in the shared checkout, not your worktree

The worktree protects you from a stage-everything commit. It does **not** protect you from
a shell command that resolves its own path.

Observed: a file was edited correctly in the worktree with an absolute path, then a
follow-up `perl -0pi -e 's/.../.../' docker/bridge-server.js` used a **relative** path. The
shell's cwd had reset to the repo root between tool calls, so the substitution rewrote the
**shared main checkout**, leaving it referencing a constant that only existed in the
worktree. The worktree file was never edited at all.

It read as green twice over:
- `node --check` passed on the contaminated file. It parses syntax and never resolves
  identifiers, so a file referencing an undefined constant checks fine and fails only at
  runtime.
- The confirming `grep` found the substitution, in the wrong tree.

The failure surfaced much later, as an unrelated-looking `spawn ENOENT` from a test that
should have picked up the change.

Rules:
1. **Absolute paths for every scripted edit in a worktree** (`perl`, `sed`, `awk`, `mv`,
   `cp`), not just for the editor tool. A relative path is only safe when the same command
   re-establishes cwd.
2. **Assert the shared checkout is clean after any scripted in-place edit**:
   `git -C <worktree> diff --stat` for what you meant to change,
   `git -C <main-checkout> status --short` for what you did not. One command, and it is the
   only check that catches this.
3. **Revert a leak surgically** by inverting the same substitution. `git checkout -- <file>`
   in a shared checkout would also discard another live session's uncommitted work in that
   file.
