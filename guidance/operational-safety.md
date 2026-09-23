<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

Prevent feedback loops, restart storms, silent failures, and cascading failures in automated systems.

## Self-Deploy Loop Prevention

**The scenario:** An agent job modifies the service that spawned it (for example, a chat bot or job dispatcher that runs agent sessions), then deploys or restarts that service. The service restarts, recovers the "active" job from persistence, re-attaches to the still-running process, and the cycle repeats. Each restart kills in-flight work and creates cascading failures.

**How it happens:**
1. The dispatcher spawns an agent job targeting the dispatcher's own repo
2. The agent finishes its changes and runs `pm2 restart <dispatcher>` (or your deploy wrapper)
3. The dispatcher restarts, loads its persisted jobs file, finds the job still "active"
4. It re-attaches to the process (or re-queues the job)
5. The job, or a recovered job, triggers another restart
6. Repeat indefinitely

**Defenses (layered):**

1. **Hard guard in the deploy wrapper:** the `deploy` and `restart` verbs check the persisted jobs file for active jobs before restarting the dispatcher. If jobs are active, refuse with an error. This is the primary barrier.
2. **Prompt-level warning:** when a job's working directory is inside the dispatcher's own repo, prepend a message telling the agent not to restart the dispatcher. This is a soft barrier (the agent can ignore it).
3. **Signal handling:** the dispatcher refuses SIGINT during a startup grace period (around 30s) and while jobs are active; the process manager sends SIGTERM to force shutdown. This prevents cascading SIGINTs from child processes.

**If a loop is already happening:**
1. Kill the stale child processes: `ps aux | grep claude | grep -v grep`, then `kill <pids>`
2. Clear the persisted jobs (set the active-jobs list to empty)
3. The service stabilizes on the next restart with no jobs to recover

**Rule:** never deploy or restart a service from within a job that service spawned. Make changes, commit, push, and note that a manual restart is needed.

## Restart-Recovery Loop (Externally Triggered)

**The scenario:** A long-running job (a multi-turn job, a batch queue) is active. An auto-merger merges a PR and deploys the dispatcher. The dispatcher ignores SIGINT because jobs are active; the process manager escalates to SIGTERM and force-kills it. On restart it finds the incomplete job, re-queues it, and runs it. Meanwhile the auto-merger retries the deploy (or another merge triggers it): deploy, kill, restart, recover, deploy, forever.

This is distinct from the self-deploy loop because the deploy is triggered externally. A "refuse while jobs are active" guard does not help when the process manager force-kills after the graceful signal is ignored.

**Defenses:**
1. **Recovery attempt limit:** track `recoveryAttempts` on each persisted job. Increment on every restart. After 3, abandon the job instead of re-queueing. This breaks the loop even if every other defense fails.
2. **Active-job check in the auto-merger:** before deploying, read the persisted jobs file. If any are active, defer (for example 60 seconds) and retry.
3. **The deploy-wrapper guard** stays as a third layer, but it only works when the process can actually be signalled gracefully.

**If this loop happens:**
1. `pm2 stop <dispatcher>` to halt the cycle
2. Clear both the active-jobs list and the queue in the persisted state
3. `pm2 start <dispatcher>` for a clean restart with no recovery
4. Check error logs for the root cause

**Prevention rules:**
- Never merge PRs to the dispatcher while long-running jobs are active
- If you must deploy during an active job: stop, deploy, start (the job is lost, but there is no loop)

## Restart Storm Detection

A restart storm is a process in a rapid restart cycle (more than 5 restarts in under 5 minutes).

**Signs:**
- `pm2 list` shows a high restart count with uptime in seconds
- Logs show repeated startup messages in quick succession
- Recovery messages every few seconds

**Common causes:**
- Self-deploy loop (above)
- Crash-on-startup bug (bad config, missing env var, syntax error)
- OOM kill cycle (process exceeds `max_memory_restart`, restarts, loads the same data, OOMs again)
- Dependency failure (database down, required service unavailable)

**Response:**
1. `pm2 stop <process>` to halt the cycle
2. `pm2 logs <process> --lines 50 --nostream`
3. Fix the root cause
4. `pm2 start <process>`

**Use the right counter.** PM2's `restart_time` is cumulative for the life of the process and never resets; any long-running stable service will exceed a threshold of 5. Storm detection must key on `.pm2_env.unstable_restarts`, the crash-loop counter that only counts restarts before `min_uptime` clears and resets once the process is stable. Before trusting any restart-count threshold, run it against a known-stable long-uptime process and confirm it reports no storm. Also normalize empty `jq` output (a `select()` with no match emits nothing, so `// 0` never fires) to 0 explicitly, or an integer test under `set -e` can fall through to a false positive.

**Put safety allowlists inside the script,** not only in the instructions of the agent calling it. A remediation script that stops or rolls back processes should refuse, before any mutating command, to act on process names outside its intended scope.

## Bash `pipefail` + `grep -c` Silent Failure

**The scenario:** A script with `set -o pipefail` uses `grep -c 'pattern' || echo "0"`. When grep finds nothing it prints `0` AND exits 1, so the fallback also runs and the variable becomes `"0\n0"`. That silently breaks `$(( ))` arithmetic downstream: no error, just wrong values. This exact bug has kept a security scanner crashing silently, every day for weeks, before it could report what it found.

```bash
# WRONG: produces "0\n0" with pipefail
count=$(grep -c 'pattern' file || echo "0")

# RIGHT: outputs "0" and suppresses exit code 1
count=$(grep -c 'pattern' file || true)
```

**Rule:** in any script using `set -eo pipefail`, never pair `grep` (any flag) with `|| echo`. Use `|| true`.

## A Pipeline Reports the LAST Command's Exit Code, So Never Chain a Success Message Off One

```bash
# WRONG: prints "PUSHED" even when the push fails
git push -q origin main 2>&1 | tail -2 && echo "PUSHED"
```

Without `pipefail`, `$?` is `tail`'s exit code, and `tail` almost always succeeds. This pattern produces false "PUSHED" reports when the token lacks a scope, or when a pre-commit gate blocked the commit and there was nothing to push. The wrong output is a claim about system state, which makes it worse than an ordinary bug.

```bash
# RIGHT: capture, test, then report
if out=$(git push -q origin main 2>&1); then echo "PUSHED"; else echo "FAILED: $out"; fi

# ALSO RIGHT: check the real command, not the pipeline
git push -q origin main; rc=$?; [ $rc -eq 0 ] && echo "PUSHED"
```

**Rule:** never end a pipeline with `&& echo "<success>"`. Capture the exit code of the command itself, and verify against the target rather than your own echo. After a push, run `git ls-remote origin <branch>` and compare to local `HEAD`.

## `set -e` Makes Post-Hoc Exit-Code Capture Dead Code

```bash
set -euo pipefail
timeout 2700 claude -p "$PROMPT" > "$LOG"   # non-zero exit kills the script HERE
EXIT_CODE=$?                                 # never reached on failure
if [ "$EXIT_CODE" -eq 124 ]; then ...        # dead code
```

Under `set -e`, every downstream failure path (timeout logging, alerts, state writes, cost tracking) is unreachable. The same applies to `RESULT=$(cmd)`. A subtle variant: `OUT=$(cmd || true); RC=$?` guarantees `RC` is always 0, silently disabling any gate that reads it. This pattern can leave autonomous runners with zero failure alerts across a thousand runs, and verify gates passing proven test failures for weeks.

**Fix:** capture in the same statement:

```bash
EXIT_CODE=0
timeout 2700 claude -p "$PROMPT" > "$LOG" || EXIT_CODE=$?
```

**Rule:** in any `set -e` script, a command whose failure you intend to handle must be captured with `|| VAR=$?` or run inside an `if`. Never write a bare command followed by `$?`, and never read `$?` after `|| true`. Audit with `grep -n 'EXIT_CODE=\$?\|_EXIT=\$?' <script>`: each hit must be on the same line as the command it measures.

### The complement: `exit $?` is a landmine for any later edit

```bash
some_command
exit $?          # fine today
```

This is correct only while nothing sits between the two lines. The moment anyone adds a log line or metric write in the gap, `$?` reports that command instead, and the branch exits 0 when it meant 1. Nothing warns you; this is how a fail-closed gate silently becomes fail-open.

```bash
some_command
GATE_RC=$?       # capture FIRST: anything below clobbers $?
log_event "$GATE_RC"
exit "$GATE_RC"
```

**Rule:** treat `exit $?` and `return $?` as write-protected. If you add anything to that branch, convert it to a named capture in the same edit. When instrumenting a gate others depend on, prove exit-code parity with the pre-change version by running both copies over every branch in a sandbox; the diff looks purely additive, so inspection misses this.

## `set -e` Kills Functions Ending in a Guarded `&&`

```bash
set -euo pipefail
vlog() {
  [ -n "$VERBOSE" ] && log "$*"   # returns 1 when VERBOSE is unset
}
vlog "checking..."                 # set -e exits the WHOLE script here
```

Inline, `[ cond ] && action` is safe under `set -e`. As the **last command of a function**, it makes the function return 1, and the call site kills the script silently. A health monitor with this bug can die at its first log call on every run for its entire life, showing only `START:` lines, while nothing notices because the thing that died was the alerting layer.

**Fix:** `if [ -n "$VERBOSE" ]; then log "$*"; fi`, or end the function with `|| true` or `return 0`.

**Rules:**
- In `set -e` scripts, never end a function body with a bare `[ cond ] && cmd`.
- A heartbeat at the start of a run proves scheduling, not completion. Freshness checks must key on an end-of-run marker.

## Cron Output Redirects Into Root-Owned Dirs Die Silently

```
*/5 * * * * $HOME/bin/watchdog.sh >> /var/log/watchdog.log 2>&1
```

The shell opens the redirect target BEFORE running the command. If the directory is not writable by the cron user and the file does not exist, **the command never runs at all**, every time, with no trace beyond unread cron mail. The trap is asymmetric: if the log file already exists (pre-created by root), appending works, so some `/var/log` crons keep working while their siblings are dead, which defeats "the other one works, so the pattern is fine" reasoning. Pre-creating one log file patches the instance, not the class.

**Rules:**
- Non-root cron output goes to a user-owned directory (for example `~/logs/cron/`). Never redirect into `/var/log` as a non-root user.
- When you find one broken cron redirect, audit the whole crontab: `crontab -l | grep '/var/log'`.
- Every watchdog needs periodic end-to-end verification: does its log show a run **completing** within the last interval, and can it still deliver its alert? A monitoring stack in which every layer has died silently at once is the default failure mode, not the exception.

## Blanket Rename Across Executable Files Is a Destructive Edit

A repo-wide `sed` looks like a rename and behaves like a rewrite. Three typical failures:

- **Delimiter collision.** `sed 's#old#new#'` against content containing `#` (every shell comment) can mangle a whole script.
- **Syntax destruction.** Replacing a bare word with a multi-word phrase can break a shell `case` glob; the file stops parsing.
- **Prose damage that survives review.** Replacing a name inside a path produces a user-facing error message pointing at a nonsense path. The code still works; nothing automated flags an absurd string.

**Rules:**
1. Never blanket-`sed` executable files. Rename with an explicit list of full paths, or a script that parses the file.
2. Pick a delimiter that cannot appear in the content (`|` for paths, never `#` against shell).
3. Re-run `bash -n` on every touched script immediately after, in the same command.
4. Then read the user-facing strings. A syntax check cannot tell you a message became gibberish.

## Programmatic Edits to a Shared Config Must Preserve Formatting

Rewriting a JSON config with `json.dump(...)` reformats the **whole file**. Without `ensure_ascii=False`, every non-ASCII character is escaped, so a 6-line insertion arrives as a 42-line diff touching entries owned by others, and a secret gate may then block the commit over a pre-existing line you never meant to touch.

**Rules:** pass `ensure_ascii=False` and match the existing indentation; verify with `git diff --stat` that the diff is only your change before staging. Note that `git checkout -- <file>` restores from the **index**, not `HEAD`: after staging a bad rewrite, only `git checkout HEAD -- <file>` reverts it.

## Regenerating From a Source of Truth Deletes Whatever Only Exists Live

When a live artifact (crontab, DNS zone, firewall ruleset, service config) is generated from a checked-in source, the source drifts **behind** the moment anyone edits the live copy. Regenerating then silently deletes their work, and the deletion looks like a normal install. For example, disabling one cron entry by regenerating can also remove credential-rotation jobs someone added live, producing an outage weeks later with no link back to the install.

**Rules:**
1. **Diff against live before installing**, and read the diff for removals, not just your addition.
2. Build a removal guard into the generator so it **refuses** when the output drops entries. A generator that only warns gets `--force`d.
3. When the guard fires, import the live state first, re-apply your change, then install. Never `--force` past it.
4. After installing, count the entries you did not intend to touch and confirm they are still present.

## Headless Claude CLI Invocation

### Permission flag

A script that spawns `claude -p` as a subprocess (Python `subprocess.run`, Node `spawn`, a bash pipeline) does not inherit the parent's `--dangerously-skip-permissions`. When the subprocess tries to use tools (WebSearch, WebFetch, Bash), it prompts for permission; with no TTY the prompt goes nowhere and the session silently fails or produces degraded output (for example, research reports produced with no web data).

**Rule:** every `claude -p` invocation without a TTY (cron, subprocess, server route, background job) MUST include `--dangerously-skip-permissions`:
- Python `subprocess.run([CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...])`
- Node `spawn('claude', ['-p', '--dangerously-skip-permissions', ...])`
- Bash `$CLAUDE_BIN -p --dangerously-skip-permissions`

Also disable any browser-launching behavior in headless environments (for example `--no-chrome` where your CLI version supports it); an attempted browser open on a headless host hangs or fails silently. Consider a periodic scan of your repos for subprocess invocations missing these flags.

### `claude -p` eats the next argument as a prompt string

When piping stdin **and** passing flags like `--model`, use `claude --print`, not `claude -p`. `-p` treats the next argument as the prompt, so the flag becomes the prompt and stdin is ignored.

```bash
# WRONG: -p eats --model as the prompt; stdin is ignored
echo "$prompt" | claude -p --model <model>

# CORRECT
echo "$prompt" | claude --print --model <model>
```

### Strip inherited session env vars (defensive hygiene)

A long-running service started from inside a Claude Code session can inherit `CLAUDECODE=1` and `CLAUDE_CODE_*` vars; PM2 captures the full env at daemon start and keeps it across restarts until PM2 itself restarts from a clean environment. No reproducible failure has been tied to this alone (be careful not to credit it for an unrelated fix that happened to land at the same time), but stripping them is cheap insurance:

```python
clean_env = {k: v for k, v in os.environ.items()
             if not k.startswith("CLAUDE_CODE") and k != "CLAUDECODE"}
subprocess.run([CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...], env=clean_env)
```

```javascript
const clean_env = Object.fromEntries(
  Object.entries(process.env).filter(([k]) => !k.startsWith('CLAUDE_CODE') && k !== 'CLAUDECODE')
);
spawn(CLAUDE_BIN, ['-p', '--dangerously-skip-permissions', ...], { env: clean_env });
```

**Also strip `NODE_CHANNEL_FD`** when launching subprocesses from a Node parent. Children that themselves use a Node runtime (for example a downloader's JS challenge solver) inherit the IPC FD reference and fail with IPC errors.

```python
env = kwargs.get("env") or os.environ.copy()
env.pop("NODE_CHANNEL_FD", None)
kwargs["env"] = env
```

### Binary path

Don't hardcode a guessed install path; a wrong fallback (`/usr/local/bin/claude` vs `/usr/bin/claude`) causes silent `No such file or directory` failures that drop all AI processing. Confirm with `command -v claude` on each host and let an env var override:

```bash
CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude)}"
```

### Auth failures can arrive as "success"

With `--output-format json`, an expired or unrefreshable OAuth token can surface as `is_error:false`, `subtype:success`, with a `result` like `"Failed to authenticate. API Error: 401 ..."`. Exit codes will not show it; parse `result` for the auth-error string.

If you refresh tokens on a cron, the token endpoint can be rate-limited for several consecutive cycles. Mitigations:
1. Refresh well ahead of expiry (several cron cycles, not one).
2. Retry within a run with backoff (longer backoff for rate-limit errors).
3. Keep a consecutive-failure counter in a state file and alert after 2 or more consecutive failures, including hours remaining.
4. Keep an independent recovery path (for example an interactive or browser-based login) that is not subject to the same rate limit, and use it immediately when the alert fires rather than waiting for the next cycle.

## Claude CLI Rate Limit Detection in Service Wrappers

When a user hits their usage limit, the CLI can exit 0 and print the limit message on stdout ("You've hit your limit... resets 3:50pm"). A wrapper that only checks the exit code returns that text as a completed result.

```javascript
const output = stdout.trim();
if (output.match(/you've hit your limit/i) || output.match(/resets \d+:\d+[ap]m/i)) {
  return { error: "AI at capacity", status: 429 };
}
```

**Rule:** any service wrapping the CLI must detect limit responses and translate them into errors (HTTP 429 or equivalent). Do not rely on exit codes alone.

### Detecting it is half the job; the other half is a parking lot, not a retry

Translating the limit into an error hands the user a failed job to re-issue by hand. Routing it into a retry ladder is worse: 1/2/4-minute backoff cannot return quota, so retries are spent and the job fails anyway. The working pattern:

1. **Classify at the single choke point** every spawn path funnels through. Prefer the structured signal (a `rate_limit_event` with `status: "rejected"` in stream-json) over string matching, and scope it per job; a global "over cap" gauge that also flips on warnings will park jobs that finished fine.
2. **Match wording as a family, and gate loose patterns on output length.** The CLI says `your limit`, `your session limit`, `your weekly limit`, `usage limit reached|<epoch>`, and reset stamps may lack minutes ("resets 3am (UTC)"). A genuine rejection is the entire output, so shortness is the tell; that bound stops a long report which merely discusses rate limits from parking itself.
3. **Exclude it from your retryable-error check explicitly.** A `/rate.?limit/i` entry in a retry list is a trap.
4. **Park, notify, and restart on a timer.** Persist the job (it must survive a restart), tell the user *when* it will resume, and re-dispatch after the stated reset plus a buffer. No stated reset means a real wait (an hour), not a fast retry.
5. **Unpark before dispatch**, so a resumed run that hits the wall again re-parks cleanly instead of doubling.
6. **Keep the attempt count outside the parked entry.** The entry is deleted at dispatch, so a re-parked job otherwise restarts at attempt 0 forever. Store the count under a stable identity and clear it once a resume succeeds.
7. **Cap it and say so.** Bound by attempts and age; when you give up, post that you gave up. Silence is indistinguishable from still-waiting.

## Hook Loop Prevention

Auto-posting hooks run on every agent turn. If a hook failure triggers a retry or a new agent session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new agent sessions without recursion guards.
- Hooks must have timeouts (10s max). A hung webhook must not block the session.
- If a hook fails, log and continue. Do not abort the parent session.

### Stop hooks that invoke the model

Classify Stop hooks by what they do: observation only, verification, or **invoking the model**. The last tier is the dangerous one. A Stop hook that runs a scorer via `claude -p` on every session exit will re-trigger itself when the scorer's own session exits; this has produced thousands of recursive sessions in a day and consumed most of a week's usage. Every model-invoking hook needs three guards, ideally from one shared library:
- an **env var circuit breaker** set on the child so the hook no-ops inside its own invocation,
- a **PID lockfile** so only one instance runs,
- a **per-hour rate limiter**.

## Concurrent Sessions in One Checkout

Give each concurrent session its own git worktree rather than sharing one working tree, and use real locks (not conventions) for anything that must run as a singleton. When something keeps "reverting", suspect another session writing the same checkout before suspecting the code.

## A Repo's Main Checkout Must Never Be Left on a Merged Feature Branch

If the primary working copy is left on a feature branch whose PR has merged, local `main` silently falls behind `origin/main`. Every hook, rules file, and guidance read that executes against that checkout now serves stale or divergent content to every other session on the machine.

**Detection:** `git branch --show-current` in a main checkout should equal the default branch except while a human is actively working. If not, check `gh pr list --head <branch> --state all`.

**Fix:** confirm the branch contains nothing beyond origin (`git diff origin/main HEAD --stat` empty), then `git checkout main && git merge --ff-only origin/main && git branch -d <stale-branch>`. If the diff is not empty, treat it as in-progress human work: investigate, don't discard.

**Prevention:** open PRs from a worktree (`git -C <repo> worktree add /tmp/<label> -b <branch>`) and leave the main checkout on its default branch.

## Job Recovery Safety

When a dispatcher recovers persisted jobs on startup:
- **PID alive:** re-attach and monitor. Do not re-execute.
- **PID dead:** extract partial output, mark failed, notify the user. Do not re-run automatically.
- **Multi-turn job partially complete:** re-queue from the last completed turn, not from scratch.

**Never** automatically re-execute a failed job. The failure may have been caused by the job itself (for example, it deployed the dispatcher).

### A boot-only reaper misses jobs stranded inside a still-running process

A reaper that runs only at process start assumes a restart is what strands jobs. But a fire-and-forget `void (async () => ...)()` also dies to an unhandled rejection or an `await` that never settles (a hung child, a fetch with no deadline), with no restart to trigger recovery. Jobs can then sit `pending` for days.

**Fix:** call the reaper from an existing periodic timer. Keep the age cutoff comfortably past the longest legitimate run, and make it a parameter so tests can assert the boundary without sleeping.

**Tell:** rows in a non-terminal state older than any possible runtime, in a process whose uptime predates them.

### A watchdog that kills out of band must set a kill reason

A supervisor that terminates a job outside the code path that reaps it leaves the reaper seeing only "process gone", which is indistinguishable from "finished". The system then reports a clean completion carrying partial work. Two corollaries:
1. A silence-based liveness threshold must exceed the longest legal quiet operation. A single tool call can run 10 minutes with no output, so a 5-minute stall timeout kills healthy work.
2. The explanation must travel on the channel the user actually reads. Streaming UIs render the stream, not the return value.

## Recovery Actions Must Match the Condition

### Classify the condition before applying a remedy that cannot fix it

Restart storms come from a health check with fewer states than reality. A credentials-refresh cron with two states, `ok` and "not ok", where "not ok" meant stale credentials and the remedy was recreating the container: being out of quota also reads "not ok", so it inherited a remedy that cannot return quota, producing well over a thousand container recreates and an alert telling the operator to log in again for a condition login cannot fix.

The diagnostic that settles it is correlation across independent units: several containers with independent credential files failing in lockstep, at the same minute, on consecutive nights. Independent files do not go stale in the same second; one shared account runs out of quota in the same second. Lockstep failure points at the one thing the units share.

**Rules:**
1. Before wiring an automatic remedy to a failure state, list which conditions land in that state and whether the remedy addresses each.
2. Detect operational strings by wording family, not one literal, and scope loose patterns to short output.
3. Put the classifier where the condition is observed (the health endpoint), with a wording fallback in the consumer, so the fix applies to running processes without a rebuild.
4. A recovery loop should log what it **observed**, not just what it did.
5. Alert text is part of the fix. An alert naming the wrong remedy trains the operator to distrust it.

### Gate a destructive remedy on a positive match, never on "not one of the known-benign cases"

If a probe returns ok / known-benign / everything-else and "everything else" triggers a restart, every unfamiliar string becomes a restart. Carving out benign cases one at a time (usage limit, blank credential, transient CLI error) is correct each time and never fixes the structure. For example, a bare `Execution error` (which the CLI also emits for upstream 5xx, network blips, and the caller's own timeout) caused repeated container recreates, one of which destroyed a user's job 25 seconds after it started, while the credentials were valid throughout.

**Rules:**
1. Ask "does this error name the thing a restart fixes?", not "is this one of the harmless errors I know?".
2. An empty or unrecognised error is not evidence for the remedy. Give it its own state.
3. Restarting is not a free diagnostic. Price the remedy: if it kills in-flight work, it cannot be the default.
4. Keep an escalation path: arm a marker on first sight of an unclassified fault, and apply the remedy only once it has persisted past a grace window of a few probe intervals.
5. Log the triggering value, not just the verdict.
6. "No verdict yet" (pending, null, zero timestamp) must never trigger the remedy.
7. Test the flow, not the classifier. Drive the real script against a real endpoint with the destructive call shimmed, and assert whether the remedy was **attempted**.
8. Test-harness caveat: under `set -o pipefail`, a `grep | tail | cut` that matches nothing aborts the suite mid-run, so the negative control reports fewer failures than exist. Use `awk`, which exits 0 on no match.

### A retry cap must not be spent on an infrastructure outage

A bounded-retry recovery loop (MAX_ATTEMPTS, cron every N minutes) permanently kills every in-flight job when a dependency is down longer than cap x interval. Attempts are spent against a dead socket; once a row hits the cap, recovery queries exclude it forever.

A connection-level failure (ECONNREFUSED, ENOTFOUND, ECONNRESET, socket hang up) is a statement about infrastructure, not a verdict on the job. So is HTTP 429, HTTP 503, or an explicit quota response. Only an error produced while the dependency was genuinely serving the request is evidence about the row.

**How to apply:**
1. Preflight the dependency (`GET /health`) before counting an attempt, resetting status, or alerting. During an outage the run becomes a silent no-op, which also stops alert spam.
2. On a dependency-availability error, refund the attempt and restore the row's prior status. Bound it by an age window (for example 24h) instead of the attempt cap.
3. If the dependency says when it will recover (a reset timestamp, `Retry-After`), defer until then rather than just refunding.
4. Beware that making the dependency's rejection faster (an admission gate that rejects in milliseconds) makes this worse: all retries burn instantly against a wall that clears on a known schedule.
5. Keep a user-visible escape hatch (a Retry button that resets the row without consulting the counter).
6. Test the decisive property: run N consecutive recovery passes against a **closed port** and assert the row is still retryable. A single-pass test passes on the broken version too.

### A benign-skip guard on a recurring job needs a consecutive-skip backstop

A job that treats "precondition not ready" as a quiet exit 0 is correct for one run and silently fatal over many. If the precondition stays down for two weeks (a browser profile left closed, a VPN down), every nightly rotation skips quietly and the far-downstream symptom (expired credentials) is the only alarm.

**Rule:** count consecutive skips in a state file and escalate once the streak crosses a small threshold, naming the stuck precondition. Deduplicate across jobs sharing that precondition with a per-key cooldown marker, so you get one alert per cycle, not one per job.

### Credentials with a hard expiry are a deadline, not a steady state

OAuth refresh tokens carry their own expiry (commonly around a month), reset only by a full interactive rotation and **not** extended by ordinary access-token refreshes. If rotation breaks, everything keeps working for weeks, then services die one by one as each refresh token expires, often leaving blanked credential files that nothing automated can recover. Monitor the refresh-token expiry field directly (warn under 20 days, page under 10). That one field measures both time to unrecoverable and how long rotation has been failing, regardless of why.

## Silent-Failure Patterns in Monitoring and Automation

### Muting an alert by call site means the mute silently moves

If you suppress an alert keyed on one exit code or code path, and the same underlying condition later starts failing one step earlier, the alerts resume with no code change anywhere. **Suppress on the classified condition**, and make the classification reachable from every path that can produce it.

### A per-key check gated on a global signal reports on the wrong thing

If a health check is per-profile, per-key, or per-tenant, its signal must be too. A keepalive that looked up "a tab with this URL" in a registry shared across two browser profiles read the wrong profile's session and certified it daily while the intended session aged out. A pre-flight that gated on a global "clients connected" count passed while the specific client it needed was absent. "I could not read it" is never evidence of health.

### A two-signal liveness check is only as strong as its weaker signal

A check that ORs a URL match and a page-content match looks like defense in depth. If the logged-out state renders at the same URL, only the content signal matters, and if its extraction silently returns an empty string on failure, "extraction failed" and "content confirms healthy" produce the same value. The check then reports "alive" every day while the session is dead. **Log or alert on an empty extraction distinctly from a non-matching one.**

### A script that reports a skipped mandatory step as informational text will skip it forever

A script that prints `SKIP <step>` and exits 0 when a flag is omitted, while its summary says "done", makes failure indistinguishable from success. When a script can omit the step that is the point of calling it, the omission must be louder than success: stderr, a visible SKIPPED marker in the summary, and an explicit opt-out flag so "I meant to skip" and "I forgot" are different states. Read a compliance command's output before quoting it as proof.

### A recurring job that notifies only on success makes an outage look like a quiet day

If the inbox gets mail on success and nothing on failure, "the run broke" and "nothing new today" are the same empty inbox, and outages run for days unnoticed.
1. Send on every terminal outcome. The failure notice must say explicitly that nothing was checked, and include bounded error text.
2. Route failure notices through the same delivery/retry machinery as success notices.
3. Give failures their own template; a failed row's content is an error string, not a deliverable.
4. Mark the pre-existing failed backlog as legacy at deploy, or the first run floods the inbox.

### A script that sources an env file can overwrite its caller's values

`set -a; . "$HOME/.env"; set +a` lets the file win over values the caller passed in. If a caller invokes `KEY="$OTHER_KEY" script.sh` and `.env` also defines `KEY`, the script silently runs against the wrong target. **A script that sources an env file after receiving env from its caller must re-assert the caller's values.**

## Unattended Jobs That Take Irreversible External Actions

A cron job that spends money, sends a message, cancels a subscription, or files something does the wrong thing to the outside world when it has a bug, and nobody is watching. Five cheap requirements:

1. **Gate on identity, not just success.** Before the irreversible step, assert the expected item/recipient and quantity. Refuse and report on mismatch. A checkout page that loads is not evidence it holds the right cart.
2. **Cap the magnitude.** A hard ceiling (`MAX_TOTAL`) turns a pricing change, currency bug, or duplicated line into a refusal instead of a charge.
3. **Idempotency guard.** A per-period state file (for example `~/.state/<job>-last-*.json`) recording the period already completed, checked first. Without it, manual re-runs, retries, or overlapping schedules double-execute. This is the single highest-value guard.
4. **A `--dry-run` that stops immediately before the irreversible call** and exercises everything up to it.
5. **Report every outcome, including failure and skip,** to email or your notification channel. Silence must never be the success signal.

**Retry windows: separate transient blockers from real failures.** A job that depends on something ambient (a browser being open, a VPN, a laptop being awake) should sweep a window, with retry-aware alerting:
- **Transient** (dependency not ready): log, stay silent during the window.
- **Real** (failed gate, missing credential, unparseable confirmation): alert immediately.
- **Already done** (idempotency guard fired): silent; this is the steady state.
- **Close the window with one `--final` run** that alarms once if the period never completed.

If the job drives a browser, parse the confirmation for a real identifier (an order number); never trust that the click "worked".

## Irreversible Content Deletion

When bulk-deleting content on external platforms (video hosts, social media, cloud storage):

1. **Gather and confirm first.** Build the full list and present it for confirmation before deleting anything.
2. **Restrict to safe content types.** Only auto-generated or temporary content (for example unlisted auto-generated shorts, drafts) is eligible. Never bulk-delete public, private, or manually curated content.
3. **Filter by metadata.** Duration, privacy status, date range, ownership (for example, only items of 90s or less when deleting shorts).

Platform deletions are irreversible; a wrong filter can wipe curated content.

## Verify Before Asserting

Don't claim the user did something (submitted an application, sent an email, published a post) unless an authoritative source confirms it. Prep materials, drafts, or related files do not confirm the action happened; asserting otherwise can put false context in front of third parties.

- **Applications/emails:** check the sent folder for confirmations
- **Posts:** check the live URL
- **Deploys:** check process status and server logs
- **Git pushes:** `git ls-remote`, `git log origin/main`, or `gh pr list`
- **Any user action:** look for the completion artifact, not the preparation artifact

## Health Monitor Self-Exclusion

A monitor that scans all managed processes, including itself, can loop: it sees its own restart count, "fixes" itself, restarts, raises the count, and repeats.

```python
for proc in processes:
    if proc["name"] == MY_PROCESS_NAME:  # skip self
        continue
```

**Rule:** any monitor iterating `pm2 jlist` must exclude its own process name. Use a dedup window long enough (for example 24h) to prevent re-triggering within one incident.

### Log artifacts and ANSI codes in log-reading error handlers

1. **Ignore process-manager formatting lines and your own output:**
   ```python
   IGNORE_PATTERNS = [
       r"\[error-handler\]",  # handler's own log prefix
       r"pm2 logs",           # command echo
       r"^---$",              # separator lines
   ]
   ```
2. **Strip ANSI escapes before dedup hashing,** or the same error hashes differently across restarts and floods your notification channel:
   ```python
   ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')
   clean_line = ANSI_ESCAPE.sub('', raw_line)
   signature = hashlib.md5(clean_line.encode()).hexdigest()
   ```
3. **Avoid status-keyword prefixes** (`SUCCESS:`, `ERROR:`, `WARN:`) in a monitor's own info messages; a pattern scanner watching logs can re-ingest them as a different class. The log level already carries severity.

## Shared Poller Resource Gates Must Be Scoped to the Executing Machine

When a poller dispatches jobs to both local and remote workers (for example, some over SSH), resource gates based on local RAM/CPU/disk must not fire for remote jobs. For a remote job the tracked local PID is just the SSH client; killing it under local memory pressure kills a healthy remote session.

**Fix:** a `skipMemoryWatchdog` (or equivalent) flag for remote-dispatched jobs. Timeout and output-size watchdogs still apply. **Rule of thumb:** ask "does this resource live on the machine actually running the session?"

## Never Inline Single-Quoted Code in `ssh 'block'`

`ssh host '...'` wraps the remote command in single quotes; any single quote inside (JS `app.get('/path')`, Python `'text/plain'`) terminates it and silently mangles the code. This can ship invalid code to production and crash-loop the service.

**Fix:** write the script or patch to a local file, `scp` it, then `ssh host 'python3 /tmp/file.py'`. Syntax-check on the server (`node --check`, `python3 -m py_compile`) before restarting, and keep a `.bak` to restore.

### Use the SSH config alias, not a bare IP

If `~/.ssh/config` defines the user and identity file under a named alias, `ssh <ip>` falls back to the default user and key and fails with `Permission denied (publickey)`. Combined with a `|| echo 0` fallback, this can make a monitor report "0 restarts" forever. When a documented command uses a raw IP, fix it at the source to use the alias rather than working around it in-session.

## Claude Code Version Drift and Pinning

Version drift silently keeps already-fixed bugs in play, and headless hosts drift worst because nobody watches their startup banner.

1. Check `claude --version` against `npm view @anthropic-ai/claude-code version` on **every** host that runs the CLI (workstations, servers, containers), not only the interactive one.
2. Pin fan-out and search behavior before upgrading, because upgrades change defaults (for example nested subagent depth, per-session search caps). Set the relevant env vars or settings explicitly so an upgrade never changes spend implicitly.
3. Set `fallbackModel` on hosts running headless runners, so an unavailable primary model does not hard-fail them. Note it does not merge across settings files.
4. Verifying a settings change means launching the CLI and getting a reply. Misspelled or unsupported keys are accepted silently, and env vars introduced in a newer version are inert until you upgrade.
5. Before calling drift urgent, match the fix list to how the consumer actually invokes the CLI (output format, MCP servers, one-shot vs long session). A fix only matters if the invocation path touches it.

### Containers

- An **unpinned** `RUN npm install -g @anthropic-ai/claude-code` freezes at build-day latest, and Docker layer caching makes a later `docker compose build` a silent no-op because the line is unchanged. Pin the version (the cache-bust is a feature) or build with `--no-cache`, and rebuild on a cadence.
- After a rebuild, assert the version **inside** the container: `docker exec <c> claude --version`. Never infer success from a clean build log.
- `docker exec <c> claude -p ...` runs as root, whose HOME has no credentials, and reports "Not logged in" even when the service is fine. Probe as the service user: `docker exec -u node -e HOME=/home/node <c> claude -p "..."`. Compare against an un-rebuilt container as a control before rolling back.
- Credentials kept in a named volume survive `docker compose build && up -d`.
- A health endpoint that runs its first auth check some time after start will read "pending" right after a rebuild; wait for the first check before judging.

### The OS-level sandbox inside Docker

The Claude Code network sandbox relies on bubblewrap, which needs unprivileged user namespaces. Docker's default seccomp profile blocks `CLONE_NEWUSER`, so `bwrap` fails with `Operation not permitted` inside containers. Enabling it would require `--privileged`, `SYS_ADMIN`, or `seccomp=unconfined`, which weakens the outer isolation boundary to add an inner one. **For containers that isolate untrusted input, the container is the sandbox;** harden the allowed-tools list, account isolation, and output scrubbing instead. On WSL2, sandboxed commands also cannot launch Windows binaries or anything under `/mnt/c/`, which breaks interop-heavy workflows. Verify before reopening: `docker exec -u root <c> bwrap --ro-bind / / --dev /dev echo ok`.

## Host-Level Failure Modes

### One runaway session can OOM-reboot a WSL2 VM

**Symptom:** every interactive session ends at once, each offering `claude --resume <id>`, and every process-manager service comes back with the same few-minutes uptime. Rule out closeout hooks and a host sleep/reboot first.

**Cause:** a single CLI process grows to double-digit GB and trips the WSL2 VM's global OOM killer at the top of its cgroup tree, which reboots the whole VM. Confirm with `journalctl -b -1 -n 25` (OOM kill followed by reboot) and a history grep for the kernel's out-of-memory line.

**Fix (two layers; either alone leaves a gap):**
1. **Per-session cap:** run each interactive session in a cgroup with a hard ceiling, for example `systemd-run --scope -p MemoryMax=<N>G -p MemorySwapMax=0`, so a runaway session dies alone and can be resumed. If the user systemd manager has no D-Bus session, use the system manager via `sudo -E systemd-run --uid=... --gid=...`. Skip the wrapper for headless jobs.
2. **Aggregate guard:** a watchdog polling available memory every ~15s that, below a threshold, terminates the largest **headless** session first (interactive only if none), before the kernel chooses for you.

### `systemctl --user` can be silently broken on WSL

On some WSL hosts `systemctl --user` always fails with `Failed to connect to bus` even though the user manager is running units. Any cron or self-heal that calls it does nothing but log the error. Bus-free alternative: kill the unit's main process (`pkill -TERM -f <exec-pattern>`) and let `Restart=always` respawn it, or use the system manager with `--uid`. **Run the command once on each host and check for the bus error before trusting it in automation.**

Related: if a reverse-tunnel respawns with `ExitOnForwardFailure=yes`, the server's sshd may hold dead forwarded ports for `ClientAliveInterval x ClientAliveCountMax` (for example 6 minutes at 120 x 3). Lower those (for example 30 x 2) so ports self-reap in about a minute.

### Auto-starting WSL at Windows boot

A Task Scheduler AtStartup task that runs `wsl -d <distro> ...` must run as the **Windows user who owns the distro**, with LogonType S4U (runs before login, no stored password). Running as SYSTEM fails because distros are registered per user, so SYSTEM has no such distro. Use `New-ScheduledTaskPrincipal -UserId '<HOST>\<user>' -LogonType S4U -RunLevel Highest` and an action like `wsl -d <distro> -u <linux-user> -e /bin/true`. A test-fire while logged in is necessary but not sufficient (your registry hive is already loaded); only an actual reboot proves it. Without this, an unattended OS-update reboot leaves services down until someone logs in.

### A desynced PM2 daemon

A long-lived PM2 daemon can desync so `pm2 jlist` looks fine but `pm2 restart`/`reload` fails with `Process <id> not found` for **every** id. Crashed processes then never auto-recover and auto-fix restarts fail. `pm2 install <module>` re-registers a module with a fresh id, but the global desync is only repaired by `pm2 update` or `pm2 kill && pm2 resurrect`, which restarts all services. That is a human action: it cannot be issued from a job dispatched by one of those services, since respawning the daemon kills the process capturing the result. Tag this error string in triage so it says "refresh the daemon", not "restart the process".

## Browser Automation Gotchas

- **SPA hydration race:** a button can be visible before event listeners are attached; the click "succeeds" and does nothing. Wait (around 4s) after the page appears, click, poll for the expected result (up to ~25s), and retry once. Never retry unboundedly; two misses means a different problem, so alert.
- **Popup windows are not visible:** focusing a tab does not raise its window, so a popup's document can sit at `visibilityState: "hidden"`, and trusted CDP input events are not delivered to it (clicks report success; nothing happens). Inside popups use JS `el.click()`; reserve trusted clicks for buttons that need user activation.
- **Match decoded URLs:** redirects percent-encode the target (`returnTo=%2Foauth%2Fauthorize`), so a literal match fails.
- **Match identity-provider pages by keyword, not fixed path:** consent paths are versioned and change.
- **Ignore pre-existing tabs:** snapshot tab ids at entry; a leftover error page from a previous run can otherwise hijack the loop forever. Close the tabs your script opens.
- **Always log the URL of a page you could not classify,** and give the unclassified state an exit.
- **Select buttons by visible label,** not by shared internal attributes that primary and cancel buttons may share.

## Retiring a Repo From an Auto-Discovering Pipeline

If a pipeline auto-discovers repos (for example "any repo with 5 or more commits not in the include or exclude list"), deleting a repo from the include list is undone on the next run. Move it to the exclusion list, in every config copy. Then kill every other recurrence vector: process-manager apps on each host (`pm2 delete` + `pm2 save`), scheduled restarts in ecosystem configs, open PRs an auto-merger would merge, and dependency-bot schedules.

## Postmortem Template

When a feedback loop or restart storm occurs, document it:

```
### Incident: [Short description]
**Date:** YYYY-MM-DD
**Duration:** How long the loop ran before intervention
**Trigger:** What action started the cascade
**Mechanism:** How the loop sustained itself
**Resolution:** How the loop was broken
**Prevention:** What guard was added to prevent recurrence
```

Add the entry to the project's `context.md` under "Known Issues" or "Incident Log" so future sessions are aware.
