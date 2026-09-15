<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

How to prevent feedback loops, restart storms, silent failures and cascading failures in automated systems.

## Self-Deploy Loop Prevention

**The scenario:** An agent job changes the bot or dispatcher that spawned it, then deploys or restarts that bot. The bot comes back up, loads the "active" job from its persistence file, re-attaches to the process that is still running, and the whole thing repeats. Every restart kills work in flight and sets off more failures.

**How it happens:**
1. The bot spawns an agent job that targets the bot's own repo
2. The agent finishes its changes and runs `pm2 restart bot` (or your deploy wrapper)
3. The bot restarts, loads its persisted jobs file and finds the job still "active"
4. The bot re-attaches to the process or re-queues the job
5. That job, or the recovered copy, triggers another restart
6. This repeats with no end

**Defenses (layered):**

1. **Hard guard in the deploy/restart wrapper:** before `deploy` or `restart` touches the bot, it reads the persisted jobs file. If any jobs are active, it refuses and prints an error. This is the main barrier.
2. **Prompt-level warning in the executor:** if a job's working directory is inside the bot's repo, prepend a self-restart guard to the prompt telling the agent not to restart the bot. This barrier is soft because the agent can ignore it.
3. **Signal handling in the bot:** ignore SIGINT during a startup grace period (for example 30s) and while jobs are active. The process manager can still force shutdown with SIGTERM. This stops SIGINTs from child processes from cascading.

**If a loop is already running:**
1. Kill the stale child processes: `ps aux | grep claude | grep -v grep`, then `kill <pids>`
2. Clear the persisted jobs by setting `"activeJobs": []` in the jobs file
3. The bot settles on its next restart because it has no jobs to recover

**Rule:** a job must never deploy or restart the service that spawned it. Make the changes, commit, push, and note that someone needs to restart it by hand.

## Restart-Recovery Loop (Long-Running Jobs)

**The scenario:** A long multi-turn job is running. An auto-merger merges a PR and calls deploy. The deploy guard sends SIGINT, which the bot ignores because jobs are active. The process manager escalates to SIGTERM and kills the bot. On restart the bot finds the unfinished job, re-queues it and starts it again. Meanwhile the auto-merger retries the deploy, or another merge triggers one, and the cycle runs forever: deploy, kill, restart, recover, deploy.

**How this differs from the self-deploy loop:** something outside the job triggers the deploy. The wrapper guard doesn't help, because the process manager force-kills the bot once SIGINT is ignored.

**Defenses:**
1. **Recovery attempt limit:** long jobs keep a `recoveryAttempts` count in their persisted state, and each restart adds one. After 3 attempts the job is abandoned, not re-queued. This breaks the loop even when every other defense fails.
2. **Active-job check in the auto-merger:** before it deploys, the merger reads the jobs file. If jobs are active, it waits 60 seconds and tries again, so the deploy never kills active jobs in the first place.
3. **The wrapper guard:** keep it as a third layer. It only works when the process can be signaled gracefully.

**If the loop happens again:**
1. `pm2 stop bot` to halt the cycle
2. Set `"activeJobs": []` and `"queue": []` in the jobs file
3. `pm2 start bot` for a clean restart with nothing to recover
4. Read the error logs to find the root cause

**Prevention rules:**
- Don't merge PRs to the bot's repo while long jobs (multi-turn jobs, batch queues) are active
- If you must deploy during an active job: `pm2 stop bot`, deploy, then `pm2 start bot`. The job is lost, but you avoid a loop.

## Restart Storm Detection

A restart storm is a process stuck in a rapid restart cycle: more than 5 restarts in under 5 minutes.

**Signs:**
- `pm2 list` shows a high restart count with uptime measured in seconds
- Logs repeat the startup banner every few seconds
- Recovery messages show up every few seconds

**Common causes:**
- A self-deploy loop (see above)
- A crash-on-startup bug (bad config, missing env var, syntax error)
- An OOM kill cycle: the process passes `max_memory_restart`, restarts, loads the same data and runs out of memory again
- A failed dependency (database down, required service unavailable)

**Response:**
1. `pm2 stop <process>` to halt the cycle
2. Read the logs: `pm2 logs <process> --lines 50 --nostream`
3. Fix the root cause
4. `pm2 start <process>` to resume

**Use the right PM2 counter.** `.pm2_env.restart_time` counts restarts over the process's whole life and never resets, so any stable process that has been up a long time will pass a threshold like 5. `.pm2_env.unstable_restarts` is PM2's crash-loop counter: it only counts restarts that happen before `min_uptime` clears, and it goes back to 0 once the process is stable. Base storm detection on `unstable_restarts`. Before you trust a restart threshold, test it against a process you know has been stable for a long time. Also, `jq` with a `select()` that matches nothing prints nothing, so `// 0` never applies. Turn empty output into `0` explicitly, or a `set -e` integer test will crash and fall through to a false positive.

## Bash `pipefail` + `grep -c` Silent Failure

**The scenario:** A script with `set -o pipefail` counts matches with `grep -c 'pattern' || echo "0"`. When nothing matches, grep prints `0` **and** exits with code 1. The `|| echo "0"` then runs too, so the result is `"0\n0"`. That two-line string breaks `$(( ))` arithmetic without any error; the numbers downstream are just wrong.

**Lesson:** this bug can keep a security scanner broken for weeks. It finds problems every run, then crashes before it can report them, and its state file never updates, so the next run repeats the same silent crash.

```bash
# WRONG: produces "0\n0" with pipefail
count=$(grep -c 'pattern' file || echo "0")

# RIGHT: outputs "0" and suppresses exit code 1
count=$(grep -c 'pattern' file || true)
```

**Rule:** in any script using `set -eo pipefail`, never pair `grep` (with any flag) with `|| echo`. Use `|| true` to swallow the non-zero exit code.

## A Pipeline Reports the LAST Command's Exit Code, So Never Chain a Success Message Off One

```bash
# WRONG: prints "PUSHED" even when the push fails.
git push -q origin main 2>&1 | tail -2 && echo "PUSHED"
```

Without `pipefail`, `$?` is `tail`'s exit code, and `tail` nearly always succeeds. So the `&&` fires whatever the real command did. This pattern has reported pushes that never happened: once when the token lacked the scope needed to create workflow files, and once when a pre-commit gate had blocked the commit and there was nothing to push.

That is worse than an ordinary bug, because the wrong output is a claim about the state of a system.

```bash
# RIGHT: capture, test, then report
if out=$(git push -q origin main 2>&1); then echo "PUSHED"; else echo "FAILED: $out"; fi

# ALSO RIGHT: check the real command, not the pipeline
git push -q origin main; rc=$?; [ $rc -eq 0 ] && echo "PUSHED"
```

**Rule:** never end a pipeline with `&& echo "<success>"`. If you're going to report whether something succeeded, capture the exit code of that command itself. Then check the result against the remote or the target, not against your own echo. After a push, run `git ls-remote origin <branch>` and compare it with your local `HEAD`.

## Blanket Rename Across Executable Files Is a Destructive Edit

A repo-wide `sed` looks like a rename but acts like a rewrite. Three ways it goes wrong:

- **Delimiter collision.** `sed 's#old#new#'` run over content that contains `#` (every shell comment) can collapse a script into one corrupted line.
- **Broken syntax.** Replacing a bare word with a multi-word phrase can break a shell `case` pattern, because a phrase with spaces followed by `/*` isn't a valid glob branch. The file stops parsing.
- **Prose damage that gets past review.** A replacement can rewrite a name *inside a path*, so a user-facing error points at a path that doesn't exist. The script still works, but its instructions are nonsense, and no automated check flags an absurd string.

**Rules:**
1. Never blanket-`sed` executable files. Rename with an explicit list of full paths, or with a script that parses the file.
2. Pick a delimiter that can't appear in the content (`|` for paths; never `#` on shell scripts).
3. **Run `bash -n` on every touched script right away, in the same command.**
4. Then read the user-facing strings. A syntax check can't tell you a message has turned into gibberish.

## Programmatic Edits to a Shared Config Must Preserve Formatting

Rewriting a JSON config with `json.dump(...)` reformats the **whole file**. Without `ensure_ascii=False`, every non-ASCII character gets escaped, so a 6-line insertion can become a 42-line diff that touches entries owned by other people. A secret scanner can then block the commit over an existing line you never meant to change.

**Rules:** pass `ensure_ascii=False` and match the file's existing indentation. Then **check that the diff contains only your change** before staging (`git diff --stat` should show a plausible line count). If the diff is bigger than your edit, the tool reformatted the file, and you're about to commit other people's content. Note that `git checkout -- <file>` restores from the **index**, not `HEAD`. Once a bad rewrite is staged, only `git checkout HEAD -- <file>` reverts it.

## Regenerating From a Source of Truth Deletes Whatever Only Exists Live

When a live artifact (crontab, DNS zone, firewall ruleset, service config) is generated from a checked-in source file, the source falls **behind** as soon as anyone edits the live copy directly. Regenerating then quietly deletes their work, and the deletion looks like a normal install.

Typical case: you disable one cron entry by regenerating the crontab, and that also removes credential-rotation jobs someone added live without recording them. Weeks later the credentials expire, and nothing links the outage back to your install.

**Rules:**
1. **Always diff against the live copy before installing.** Read the diff for removals; don't just skim it for your addition.
2. Build a removal guard into the generator, so it **refuses** when the output would drop entries. A generator that only warns will get `--force`d.
3. When the guard fires, **import the live state first**, then re-apply your change, then install. Never use `--force` to get past it; the guard is doing its job.
4. After installing, check that the entries you didn't mean to touch are still there. Count them.

## Headless Claude CLI Invocations

**The scenario:** A script spawns `claude -p` as a subprocess (Python `subprocess.run`, Node `spawn`/`execSync`, a bash pipeline). The parent may have `--dangerously-skip-permissions`, but the subprocess is a fresh CLI invocation and doesn't inherit it. When Claude tries to use a tool (WebSearch, WebFetch, Bash), it asks for permission. With no TTY, nobody sees the prompt, and the session fails silently or returns degraded output, such as research reports with no web data.

**Rule:** every `claude -p` invocation without a TTY (cron, subprocess, server route, background job) MUST include `--dangerously-skip-permissions`:
- Python `subprocess.run([CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...])`
- Node `spawn('claude', ['-p', '--dangerously-skip-permissions', ...])`
- Bash `$CLAUDE_BIN -p --dangerously-skip-permissions`

**Detection:** a periodic health check can scan all repos for Claude subprocess calls that are missing the flag.

**Also add `--no-chrome` in headless environments.** The CLI may try to open a browser. On headless servers or under a process manager that hangs or fails silently. Add `--no-chrome` next to `--dangerously-skip-permissions` in every automated invocation.

### Gotcha: Use `--print`, Not `-p`, When Combining Piped Stdin With Other Flags

When piping a prompt on stdin and passing flags such as `--model`, use `claude --print`. Some usages have seen `-p` take the next argument as a literal prompt string, so `claude -p --model <model>` sent `"--model <model>"` as the prompt and ignored stdin. Every eval call then scored the flag string instead of the real data.

```bash
# RISKY: -p may eat --model as the prompt; stdin is ignored
echo "$prompt" | claude -p --model <model>

# CORRECT: --print enables stdin pass-through; --model is parsed as a flag
echo "$prompt" | claude --print --model <model>
```

**Rule:** when you pipe stdin and also pass flags (`--model`, `--output-format`, etc.), use `claude --print` as the mode flag.

### Strip CLAUDE_CODE_* Env Vars From Subprocess Invocations (Defensive Hygiene)

A long-running service started or restarted from inside a Claude Code session inherits `CLAUDECODE=1` and `CLAUDE_CODE_SESSION_ID`. PM2 captures the full environment when it starts a process, and those vars stay with the process slot across later restarts until PM2 itself restarts from a clean environment. Isolated testing has **not** shown these vars cause failures. An auth failure once blamed on them turned out to be an expired token (see below). Strip them anyway; it's cheap insurance.

```python
# Python
clean_env = {k: v for k, v in os.environ.items()
             if not k.startswith("CLAUDE_CODE") and k != "CLAUDECODE"}
result = subprocess.run([CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...], env=clean_env)
```

```javascript
// Node
const clean_env = Object.fromEntries(
  Object.entries(process.env).filter(([k]) => !k.startsWith('CLAUDE_CODE') && k !== 'CLAUDECODE')
);
const child = spawn(CLAUDE_BIN, ['-p', '--dangerously-skip-permissions', ...], { env: clean_env });
```

**Lesson on misdiagnosis:** if a fix ships at about the same time a problem clears up on its own, reproduce the failure in isolation before crediting the fix.

**Also strip `NODE_CHANNEL_FD`** when a Node.js parent launches subprocesses. Node IPC sets it, and any grandchild that runs a Node runtime (for example a downloader's JS challenge solver) inherits a stale FD reference and fails with IPC channel errors.

```python
env = kwargs.get("env") or os.environ.copy()
env.pop("NODE_CHANNEL_FD", None)
kwargs["env"] = env
```

### OAuth Token Refresh Rate-Limiting

**The scenario:** A cron job refreshes the CLI's OAuth access token with a `refresh_token` grant. The token endpoint is rate-limited and can return `rate_limit_error` for several cron cycles in a row. The access token expires partway through, and every daemon calling `claude -p` gets a synthetic 401. With `--output-format json`, the CLI can report this as `is_error:false`, `subtype:success`, with `result: "Failed to authenticate. API Error: 401 ..."`. Exit codes don't show the failure; only parsing `result` does.

**Detection signals:**
- The `result` field contains "Failed to authenticate" or "401 Invalid authentication credentials"
- The refresh log shows `rate_limit_error` on consecutive cycles
- Daemons quietly drop into degraded fallback modes

**Mitigations:**
1. **Refresh early:** use a threshold of several cron cycles (for example 6h) before expiry, not one.
2. **Retry within a cycle with backoff:** up to 3 attempts, backing off longer on `rate_limit_error` (60s, then 240s) than on other failures (30s).
3. **Count consecutive failed cycles:** persist the count and alert after 2 or more, including how many hours the token has left. Reset it on success.
4. **Keep an independent recovery path.** A browser-based interactive login doesn't go through the rate-limited API endpoint. When the refresh path is stuck and the token is expiring, trigger the browser login right away instead of waiting for the next cron cycle.

### React SPA Hydration Race in Browser-Automation OAuth Scripts

**Symptom:** A browser-automation script clicks an OAuth Authorize button. The click reports success but nothing happens: no navigation, no callback. The same script works a few minutes later.

**Why:** React SPAs render the DOM before hydration wires up event listeners. The button can be visible and selectable in that gap while its click does nothing. The gap is usually under 2s but shows up reliably on browser sessions that have just woken.

```bash
# After confirming the consent tab exists:
sleep 4  # Let React hydrate before clicking
browser-cli click "#authorize-button"

# Poll for callback (up to ~25s)
for i in $(seq 1 5); do
  sleep 5
  # check if callback tab appeared ...
done

# If no callback after 25s, retry once
if [ "$callback_found" != "1" ]; then
  sleep 4
  browser-cli click "#authorize-button"
fi
```

**Rule:** never retry a consent button without limit. If two attempts both produce no callback, send an alert to your notification channel. The cause is something other than a hydration race (rate limit, broken page, wrong selector).

### Auth-Age Enforcement and Refresh-Token Expiry

**Symptom:** Every automated account relogin fails on the same night. The browser session looks active, but clicking Authorize redirects to a reauth/login page instead of the OAuth callback.

**Root cause:** the identity provider enforces a **maximum auth-age**, meaning time since the account last really signed in, separately from activity age. A keepalive that refreshes activity doesn't reset the auth-age clock. Once auth-age passes the limit, the consent flow forces a logout. Automation often can't finish the re-login because a "Continue with Google"-style popup needs a real user gesture.

**Differentiator:** a hydration race hits one account at a time and a retry fixes it. All accounts failing at once points to auth-age.

**Recovery:** a one-time manual step: sign the account out of the controlling browser and back in. Don't run automated retry loops or restart containers.

**Treat an auth-age failure as a deadline, not a steady state.** Refresh tokens can have **their own expiry**, reset only by a successful interactive rotation and not extended by ordinary refreshes. Roughly 30 days has been observed. Existing access tokens keep refreshing for a while, which is exactly why a broken rotation can go unnoticed for weeks. Past the refresh token's expiry, the CLI can write the credential file back with empty `accessToken`/`refreshToken` and `expiresAt: 0`. Nothing automated can recover that. Monitor the refresh-token expiry field for every credential daily: warn under 20 days, page under 10. That one field catches both how close a credential is to unrecoverable and how long rotation has been failing, whatever the reason.

**Lessons from debugging a browser-driven relogin chain (each defect hid the next):**
1. **A script that sources an env file after receiving env from its caller must re-assert the caller's values.** `set -a; . "$HOME/.env"; set +a` lets the file win. A caller passing `BROWSER_KEY="$ALT_KEY"` silently got the default profile, so every "alt session logged out" alert was about a browser the run never touched.
2. **Tab registries fed by content scripts can't see pages the extension excludes.** If sensitive origins are excluded from content scripts, query tabs through the extension's service worker.
3. **A popup is a separate window.** Focusing a tab doesn't raise its window, so the popup stays `visibilityState: "hidden"`, and trusted input events are never delivered to an unrendered page, even when the click API reports success. Inside popup windows, use JS `el.click()`. Save trusted clicks for buttons that need user activation (anything that calls `window.open`).
4. **Providers version their consent paths.** Match page states by keyword, not by fixed path.
5. **Stale tabs from earlier runs take over later runs.** Snapshot the tab ids at entry and ignore any that already existed; a popup you didn't open isn't yours to drive. Close the tabs you open. Junk left by run N becomes the bug in run N+1.
6. **Give an unclassifiable page an exit, and always log its URL.**
7. **Match the decoded URL.** A redirect such as `/login?returnTo=%2Foauth%2Fauthorize` percent-encodes the path you're looking for.
8. **Choose buttons by visible label, not by an internal attribute that Cancel and Continue share.**
9. **A per-key operation gated on a global signal reports on the wrong thing.** If a tab registry is shared across profiles but commands route per key, an "ensure tab" call can return another profile's tab. A keepalive can then certify the wrong session every day while the right one ages out. If a check is per profile, per key or per tenant, its signal must be too, and "I couldn't read it" is never evidence of health.
10. **A mute attached to a call site moves when the failure moves.** If you suppress an alert by exit code, the same condition surfacing one step earlier with a different code starts alerting again (or stays silent, if the mute is broad). Suppress based on the *classified condition*, and make that classification available on every path that can produce it.

### Claude CLI Binary Path

A hardcoded fallback path that doesn't match where the CLI is actually installed (for example `/usr/local/bin/claude` when it lives at `/usr/bin/claude`) causes `[Errno 2] No such file or directory`. That silently drops all AI processing, with nothing obvious in the service logs.

**Rule:** find the real path on each host with `command -v claude`, always let a `CLAUDE_BIN` env var override it, and use the verified path as the fallback:

```python
claude_bin = os.environ.get("CLAUDE_BIN", "/usr/bin/claude")
```

```javascript
const CLAUDE_BIN = process.env.CLAUDE_BIN || '/usr/bin/claude';
```

```bash
CLAUDE_BIN="${CLAUDE_BIN:-/usr/bin/claude}"
```

## Claude CLI Rate Limit Detection in Service Wrappers

**The scenario:** A service wraps `claude -p` and reads stdout for the response. When the account hits its usage limit, the CLI can exit 0 while printing a limit message ("You've hit your limit... resets 3:50pm PT"). The service treats that as success and returns it to the user as a "completed" deliverable.

```javascript
const output = stdout.trim();
if (output.match(/you've hit your limit/i) || output.match(/resets \d+:\d+[ap]m/i)) {
  return { error: "AI at capacity", status: 429 };
}
```

**Rule:** any service wrapping the Claude CLI must detect limit responses and turn them into errors (HTTP 429 or equivalent). Exit codes alone aren't enough.

### Detection is half the job; the other half is a parking lot, not a retry

Turning the limit into an error stops the garbage output, but it leaves the user with a failed job to re-submit by hand. Routing it into an existing retry ladder is worse: exponential backoff over 1, 2 and 4 minutes can't bring back quota, so every retry is spent against a condition it can't change.

The pattern that works:
1. **Classify at the single choke point** that every spawn path goes through. Prefer the structured signal (a `rate_limit_event` with `status: "rejected"` in stream-json) over string matching, and scope it *per job*. A global "over cap" gauge that also flips on warnings will park jobs that finished fine.
2. **Match a family of wordings, and only apply loose patterns to short output.** Wording varies: `your limit`, `your session limit`, `your weekly limit`, `usage limit reached|<epoch>`. A real out-of-quota rejection is the *entire* output, so shortness is the tell. That length bound keeps a long report that merely *mentions* rate limits from being parked.
3. **Explicitly exclude it from `isRetryableError()`.** A `/rate.?limit/i` entry in a retry list is a trap here.
4. **Park, notify, and resume on a timer.** Persist the job so it survives a restart. Tell the user *when* it will resume, not that it failed. Re-dispatch after the stated reset plus a buffer; the reset time runs on the server's clock. If no reset time is given, wait a real interval (an hour), not a fast retry.
5. **Unpark before dispatching**, so a resumed run that hits the limit again re-parks cleanly instead of being doubled.
6. **Keep the attempt count outside the parked entry.** The entry is deleted at dispatch, so a count stored on it is lost and the job never reaches its cap. Store the count under a stable identity (source + message id) and clear it once a resume succeeds.
7. **Cap it, and say so when you give up.** Bound it by attempts and by age. Silence looks the same as still waiting.

## `set -e` Makes Post-Hoc Exit-Code Capture Dead Code

```bash
set -euo pipefail
timeout 2700 claude -p "$PROMPT" > "$LOG"   # non-zero exit kills the script HERE
EXIT_CODE=$?                                 # never reached on failure
if [ "$EXIT_CODE" -eq 124 ]; then ...        # dead code
```

Under `set -e`, a non-zero exit ends the script before `EXIT_CODE=$?` runs, so every failure path after it (timeout logging, alerts, state writes, cost tracking) is unreachable. Command substitution behaves the same way. A subtler variant: `OUT=$(cmd || true); RC=$?` always gives `RC=0`, which quietly disables whatever gate reads it.

**Lesson:** this bug can sit in every runner script of an autonomous pipeline for months. Across about a thousand runs, zero failure alerts fire, timeouts leave no log entry, and a verify gate passes test runs that actually failed.

```bash
EXIT_CODE=0
timeout 2700 claude -p "$PROMPT" > "$LOG" || EXIT_CODE=$?
```

**Rule:** in any `set -e` script, a command whose failure you plan to handle must capture its exit code with `|| VAR=$?`, or run inside an `if`. Never put a bare command followed by `$?`, and never read `$?` after `|| true`. Audit with `grep -n 'EXIT_CODE=\$?\|_EXIT=\$?' <script>`: every hit must be on the same line as the command it measures.

### The complement: `exit $?` is a landmine for any later edit

```bash
some_command
exit $?          # fine today
```

This is only correct while nothing sits between the two lines. Once someone adds a log line, metric write or cleanup call in between, `$?` reports *that* command, and the branch exits 0 when it should exit 1. The script still runs and prints the same output; only the exit code, the one thing callers branch on, is wrong. This is how a gate that should fail closed quietly starts failing open.

```bash
some_command
GATE_RC=$?       # capture FIRST: anything below clobbers $?
log_event "$GATE_RC"
exit "$GATE_RC"
```

**Rule:** treat `exit $?` and `return $?` as write-protected. If you need to add anything to that branch, switch to a named capture in the same edit. When you instrument a gate other systems depend on, prove the exit codes match the pre-change version: run both copies through every branch in a sandbox and assert the codes are equal. The diff looks purely additive, which is why reading it misses this.

## `set -e` Kills Functions Ending in a Guarded `&&`

```bash
set -euo pipefail
vlog() {
  [ -n "$VERBOSE" ] && log "$*"   # returns 1 when VERBOSE is unset
}
vlog "checking..."                 # set -e exits the WHOLE script here
```

Written inline, `[ cond ] && action` is safe under `set -e`. As the **last command of a function**, though, it makes the function return 1, the call becomes a failing command, and `set -e` kills the script at the first call. Nothing is printed.

**Lesson:** a health monitor with this bug can die at its first log call on every run for its whole life. Its log shows only start lines, and nobody notices, because the part that died *is* the alerting. **A heartbeat at the start of a run proves the schedule works, not that the run finished. Freshness checks must look for an end-of-run marker.**

**Fix:** `if [ -n "$VERBOSE" ]; then log "$*"; fi`, or end the function with `|| true` or `return 0`.

**Rule:** in `set -e` scripts, never end a function body with a bare `[ cond ] && cmd`.

## Cron Output Redirects Into Root-Owned Dirs Die Silently

```
*/5 * * * * $HOME/bin/watchdog.sh >> /var/log/watchdog.log 2>&1
```

The shell opens the redirect target BEFORE running the command. If the cron user can't write to the directory and the file doesn't exist yet, the open fails and **the command never runs**, on every occurrence, leaving no trace except unread cron mail. It's also asymmetric: if the log file already exists, appending works. So some `/var/log` crons keep running while their siblings are dead, which defeats "the other one works, so the pattern is fine."

**Lesson:** a single crontab can hold a whole monitoring stack (watchdogs, uptime monitors, error aggregators, backups) in which most entries have never run. Pre-creating one log file fixes that entry and leaves the rest of the class broken.

**Rules:**
- Send non-root cron output to a user-owned directory (for example `~/logs/cron/`). A non-root user should never redirect cron output into `/var/log`.
- When you find one broken redirect, audit the whole crontab for the same class: `crontab -l | grep '/var/log'`.
- Verify every watchdog end to end on a schedule: does its log show a run **completing** (not just starting) within the last interval, and can it still deliver its alert? A monitoring stack where every layer has died silently is the default failure mode, not the exception.

## Hook Loop Prevention

Auto-posting hooks (blog, chat notifications) run on every agent turn. If a hook failure triggers a retry or a new agent session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new agent sessions without recursion guards.
- Hooks must have timeouts (10s max). A hung webhook must not block the session.
- If a hook fails, log it and continue. Don't abort the parent session.

### Stop Hook Safety

Sort Stop hooks into three tiers: **Tier 1** only observes (logging, posting), **Tier 2** verifies (runs checks, can block), and **Tier 3** invokes Claude. Every Tier 3 hook needs all three guards, ideally from one shared library that every hook sources:
1. **An env var circuit breaker.** Set a marker variable in the child invocation, and have the hook exit immediately when it sees that marker.
2. **A PID lockfile**, so only one instance runs at a time.
3. **A per-hour rate limiter**, which caps total invocations even when the other guards fail.

**Lesson:** a Stop hook that ran a session scorer (`claude -p` with a small model) on every session exit re-triggered itself when the scorer's own session exited. It produced thousands of recursive sessions in one day and used most of a week's token budget.

## Concurrent Sessions in One Checkout

Give each session its own git worktree instead of sharing a checkout (`git worktree add /tmp/<label> -b <branch>`). Protect singleton resources (one-at-a-time jobs, shared state files) with real locks, not conventions. If something keeps reverting, first check whether another session is writing to the same tree.

## Job Recovery Safety

When a service recovers persisted jobs on startup:
- **PID alive:** re-attach and monitor until it completes. Don't re-execute.
- **PID dead:** extract any partial output, mark the job failed and notify the user. Don't re-run it automatically.
- **Multi-turn job partially complete:** re-queue from the last completed turn, not from scratch.

**Never** re-execute a failed job automatically. The job itself may have caused the failure (for example by deploying the service), and re-running it repeats the failure.

## Unattended Jobs That Take Irreversible External Actions

A cron job that spends money, sends a message, cancels a subscription or files something isn't a normal cron job. A bug doesn't just fail; it does the wrong thing to the outside world while nobody is watching. Five requirements, all cheap:

1. **Gate on identity, not just success.** Before the irreversible step, confirm that what's in front of you is what you meant: expected item or recipient name, expected quantity. Refuse and report on a mismatch. A checkout page loading fine doesn't prove it holds the right cart.
2. **Cap the size.** A hard ceiling (`MAX_TOTAL`) turns a price change, currency bug or duplicated line item into a refusal instead of a charge.
3. **Idempotency guard.** Keep a per-period state file (for example `~/.state/<job>-last-*.json`) recording which period is done, and check it first. Without it, a manual re-run, a retry or two overlapping schedules will execute twice. This guard is worth the most, because without it retries aren't safe to add.
4. **A `--dry-run` that stops right before the irreversible call** and exercises everything up to it. Without that, the only way to test the job is to do the thing for real.
5. **Report every outcome, including failure and skip,** to email or your notification channel. Silence must never be the success signal.

**Retry windows: separate temporary blockers from real failures.** A job that depends on something ambient (a browser being open, a VPN, a laptop being awake) isn't reliable at one fixed time. Run it repeatedly across a window instead, but only if the alerting knows about retries:
- **Transient** (dependency not ready, a later attempt may succeed): log it and stay silent during the window.
- **Real** (failed gate, missing credential, unparseable confirmation): alert immediately. A human is needed, and more attempts won't help.
- **Already done** (idempotency guard fired): stay silent. This is the normal state.
- **End the window with one `--final` run** that alarms if the period never completed. That single alert is the "we missed it" signal, and it fires once.

If the job drives a browser, parse the confirmation for a real identifier (an order number). Never trust that the click "worked".

## Postmortem Template

When a feedback loop or restart storm happens, write it up:

```
### Incident: [Short description]
**Date:** YYYY-MM-DD
**Duration:** How long the loop ran before intervention
**Trigger:** What action started the cascade
**Mechanism:** How the loop sustained itself
**Resolution:** How the loop was broken
**Prevention:** What guard was added to prevent recurrence
```

Add the entry to the project's `context.md` under "Known Issues" or "Incident Log" so future sessions know about it.

## Irreversible Content Deletion

When bulk-deleting content on external platforms (video platforms, social media, cloud storage):

1. **Build the list and confirm first.** Show the user the full list of items to be removed before deleting anything. This catches wrong date ranges, filters or accounts.
2. **Only delete safe content types.** Only auto-generated or temporary content is eligible for bulk deletion (for example unlisted auto-generated shorts, draft posts). Never bulk-delete public, private or hand-curated content.
3. **Filter by metadata.** Apply duration, privacy status, date range and ownership filters to exclude anything that shouldn't be touched (for example, only items of 90 seconds or less when deleting shorts).

**Why:** platform deletions can't be undone. One wrong filter can wipe out curated content.

## Verify Before Asserting

Don't claim the user did something (submitted an application, sent an email, published a post) unless an authoritative source confirms it. Prep materials, drafts or related files do NOT prove the action happened. An agent that treats prep materials as proof of submission can pass wrong context to third parties.

**How to verify:**
- **Applications/emails:** look in the sent mail for confirmations
- **Blog posts:** check the live URL
- **Deploys:** check process manager status and server logs
- **Git pushes:** `git log origin/main` or `gh pr list`
- **Any user action:** look for the artifact that proves completion, not the one from preparation

## Health Monitor Self-Exclusion

**A health monitor or watchdog that scans processes must always skip its own process.** Otherwise it can attack itself: it sees its own high restart count, tries to fix it, restarts itself, raises the count, and tries again.

```python
for proc in processes:
    if proc["name"] == MY_PROCESS_NAME:  # skip self
        continue
    # ... health checks
```

Also use a dedup window long enough (for example 24h, not 1h) that one incident can't re-trigger the monitor over and over.

**Rule:** any monitoring daemon that iterates over `pm2 jlist` must leave its own process name out of its health checks.

### PM2 Log Artifacts and ANSI Codes in Error Handlers

**1. Ignore PM2 log formatting artifacts.** PM2 output includes separator lines, the `pm2 logs` command echo, and the handler's own prefixed lines. Without ignore patterns, the handler treats these as errors and alerts or loops on its own output.

```python
IGNORE_PATTERNS = [
    r"\[error-handler\]",  # handler's own log prefix
    r"pm2 logs",           # pm2 command echo
    r"^---$",              # PM2 separator lines
]
```

**2. Strip ANSI escape codes before computing dedup signatures.** If you don't, the same error hashes differently across restarts and floods your notification channel.

```python
import re
ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')

def _strip_ansi(text: str) -> str:
    return ANSI_ESCAPE.sub('', text)

clean_line = _strip_ansi(raw_line)
signature = hashlib.md5(clean_line.encode()).hexdigest()
```

**3. Don't use status-keyword prefixes in a monitor's info logs.** Prefixes like `SUCCESS:`, `ERROR:` or `WARN:` in normal lines can match pattern scanners watching that output and feed back into the alert pipeline.

```python
# BAD
logger.info(f"SUCCESS: fix complete (cost: ${cost:.4f})")
# GOOD: the log level already communicates severity
logger.info(f"Fix complete (cost: ${cost:.4f})")
```

## Third-Party AI CLI Tier Deprecations Fail Every Consumer at Once

A free or individual-tier auth path for a third-party AI CLI can be retired account-wide. It fails during setup, before the first request, and no flag, model choice or working-directory change gets around it. Every automation that shells out to that CLI starts exiting non-zero, and cron wrappers that ignore exit codes never alert. Fallback paths that relied on that CLI break at the same moment.

**Rule:** before relying on a third-party CLI in automation, probe it (`<cli> -p "ok?" 2>&1`) and look for tier or eligibility errors. Treat any CLI whose probe fails as unavailable, and route shadow or fallback work to a provider whose probe passes.

## Shared Poller Resource Gates Must Be Scoped to the Executing Machine

When a poller sends jobs to both local and remote workers (for example, local spawns plus SSH to another machine), any gate based on local resources (RAM, CPU, disk) must NOT apply to remote jobs, because they use no local resources.

**Lesson:** a memory watchdog that killed the tracked PID when local available memory was low was killing healthy remote sessions. For a remote job, the tracked PID was only the local SSH client. The telltale sign: watchdog kill messages while the dispatch counts showed only remote dispatches.

**Fix:** add a `skipMemoryWatchdog` flag (or equivalent) to the polling function and set it for remote jobs. Timeout and output-size watchdogs still apply to remote jobs, since they guard against a hung SSH connection or runaway output wherever the job runs.

**Rule of thumb:** before adding a resource guard to a shared poller, ask: "Does this resource live on the machine actually running the session?"

## A Repo's Main Checkout Must Never Be Left on a Merged Feature Branch

**Symptom:** a repo's main working copy (not a worktree) is on a feature branch whose PR has already merged. Local `main` falls behind `origin/main` with no error anywhere.

**Why it's worse than an ordinary stale branch:** SessionStart hooks, CLAUDE.md loads and guidance reads for every other session on the machine run against whatever that checkout has checked out. A stranded branch means every session quietly reads outdated rules.

**Detection:** `git branch --show-current` in a main checkout should equal the default branch, except while a human is actively working. If it doesn't, check whether the branch's PR has merged: `gh pr list --head <branch> --state all`.

**Fix:** first confirm the current branch contains nothing that isn't already in `origin/<default>` (`git diff origin/main HEAD --stat` should be empty), then `git checkout main && git merge --ff-only origin/main && git branch -d <stale-branch>`. Force nothing. If the diff isn't empty, treat it as in-progress human work: stash and investigate, don't discard.

**Prevention:** open PRs from a worktree (`git -C <repo> worktree add /tmp/<label> -b <branch>`) and keep the main checkout on its default branch the whole time.

## Never Inline Single-Quoted Code in `ssh 'block'`

`ssh host 'big block ...'` wraps the whole remote command in single quotes. Any single quote INSIDE the block (JS `app.get('/path', ...)`, Python `'text/plain'`) ends the outer quote and silently mangles the code. That can ship invalid code to production and put the service in a crash loop.

**Fix:** write the script or patch to a LOCAL file, `scp` it over, then run `ssh host 'python3 /tmp/file.py'`. Always syntax-check on the server (`node --check`, `python3 -m py_compile`) BEFORE restarting, and keep a `.bak` to restore.

## Bare-IP SSH Can Fail Where the Config Alias Works

`ssh <ip> "<cmd>"` fails with "Permission denied (publickey)" when `~/.ssh/config` has no `Host` entry matching the bare IP. Only the named alias carries the right user and identity file. Combined with a `|| echo 0` fallback, this can make a restart-storm detector report 0 restarts forever, whatever the real count.

**Rule:** when a documented command refers to a host by raw IP, replace it with the configured SSH alias at the source. Don't treat one "Permission denied" as a transient fluke and work around it in the session, or it will keep coming back.

## Keep Claude Code Current on Every Host and Pin Defaults Before Upgrading

Version drift quietly keeps already-fixed reliability bugs alive (memory growth from large tool outputs, truncated stream-json at exit for slow readers, stalls in long sessions). Headless hosts drift the most because nobody sees their startup banner.

**Rules:**
1. Compare `claude --version` with `npm view @anthropic-ai/claude-code version` on EVERY host that runs claude (workstation, servers, containers), not just the interactive one.
2. **Pin fan-out and search behavior before upgrading**, because upgrades change defaults under you (nested subagent spawn depth, per-session web search caps). Set `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` explicitly so an upgrade never silently changes spend or research depth. Deeper implicit nesting can go beyond what a usage gate accounts for.
3. **Set `fallbackModel`** (an array of at most 3 entries, not merged across settings files) on every host running headless runners. Without it, a runner fails hard when its primary model is unavailable or overloaded.
4. **Verifying a settings change means launching the CLI and getting a reply,** not just parsing the JSON. An unsupported or misspelled key is accepted silently and does nothing. Env vars added in a version newer than the installed CLI stay inert until you upgrade.
5. **Containers drift the most, and the host's version tells you nothing about them.** An unpinned `RUN npm install -g @anthropic-ai/claude-code` freezes each image at whatever was latest on build day. Check each one: `docker exec <container> claude --version`.
   - **Before calling drift urgent, check the fix list against how the consumer actually invokes claude.** A stream-json fix doesn't matter to a consumer reading plain stdout; an MCP fix doesn't matter if no MCP servers are attached; a long-session fix doesn't matter for one-shot calls. Read the spawn arguments, not just the version number.
   - **Pin the version in the Dockerfile** (`@anthropic-ai/claude-code@<version>`). Unpinned means every rebuild is an unreviewed upgrade and builds aren't reproducible.
   - **Rebuild on a schedule, not on demand.** An image that's never rebuilt is frozen on an old version and guaranteed to jump many versions at once when it finally is.

### Unpinned Docker installs make rebuilds a silent no-op; `docker exec` runs as root and false-alarms on auth

1. **An unpinned install plus Docker's layer cache makes `docker compose build` a no-op.** If the `RUN npm install` line hasn't changed, Docker reuses the cached layer and never runs npm. Pin the version (the cache-bust is a feature) or build with `--no-cache`. After a rebuild, always check the version INSIDE the container; never infer success from a clean build log.
2. **`docker exec <container> claude -p ...` runs as root and can say "Not logged in" when the service is fully authenticated.** The credentials sit under the service user's home and root's HOME is `/root`. This looks exactly like a rebuild wiped the credentials and invites a needless rollback. Probe as the service user: `docker exec -u node -e HOME=/home/node <c> claude -p "..."`. Before acting on suspected breakage, compare with an un-rebuilt container as a control.
3. **A pending auth status right after a rebuild is expected.** Wait for the service's first periodic auth check to report before judging.

Credentials kept in a named volume survive `docker compose build && up -d`; no re-auth is needed.

### The Claude Code network sandbox is not usable inside Docker containers or on WSL2 for Windows-interop workflows

- **In Docker:** the sandbox relies on bubblewrap, which needs unprivileged user namespaces. Docker's default seccomp profile blocks `CLONE_NEWUSER`, so `bwrap` fails with `Creating new namespace failed: Operation not permitted`, even when the host kernel allows user namespaces. Enabling it would mean `--privileged`, `--cap-add SYS_ADMIN` or `seccomp=unconfined`. That trade is backwards: it weakens the OUTER isolation boundary to add an inner one, on containers meant to isolate untrusted input. **For such containers, the container IS the sandbox.** `enableWeakerNestedSandbox` doesn't help here, because it addresses containers that can't mount a fresh `/proc`, not ones forbidden from creating namespaces.
- **On WSL2:** sandboxed commands can't launch Windows binaries or anything under `/mnt/c/`. If your work depends on Windows interop, enabling the sandbox breaks it wholesale. `docker` is also documented as incompatible with the sandbox.
- **Put the effort into mitigations that do apply:** a narrow `--allowedTools` list, account isolation, the container boundary itself, and output scrubbing.
- **Check before revisiting:** `docker exec -u root <container> bwrap --ro-bind / / --dev /dev echo ok`. If it still says `Operation not permitted`, this conclusion stands.

## A Recovery Action That Can't Fix the Condition Must Be Gated on Classifying the Condition First

Restart storms come from a health check that has fewer states than reality does. If "not ok" means "stale credentials, recreate the container", then being out of quota also reads as "not ok" and gets a remedy that can't bring quota back. The result: containers torn down every 10 minutes for the whole limit window, plus an alert telling the operator to re-login for a problem login can't fix.

**Diagnostic:** correlate across independent units. Independent credential files don't go stale in the same second, but one shared account runs out of quota in the same second. When units that share exactly one thing fail in lockstep, look at that shared thing.

**Rules:**
1. Before wiring an automatic remedy to a failure state, ask which conditions land in that state and whether the remedy fixes each one. If it fixes only some, classify first and let the rest fall through to a wait.
2. Detect operational strings by families of wording, not a single literal ("your limit", "your session limit", "your weekly limit"; reset stamps may have no minutes, as in "resets 3am (UTC)"). A guard pinned to one literal stops matching when the vendor rewords, and the wrong branch keeps running unnoticed. Only apply loose patterns to short output.
3. Put the classifier where the condition is observed (the health endpoint), and keep a wording-based fallback in the consumer so already-running processes get the fix without a rebuild.
4. A recovery loop should log what it observed, not just what it did. "auth=failed, recreating container" with no error text hides a misclassification in plain sight for months.
5. Alert text is part of the fix. An alert that names the wrong remedy teaches the operator to ignore alerts.

## A Destructive Remedy Must Be Gated on a Positive Match, Never on "Not One of the Known-Benign Cases"

The shape: a probe returns ok, known-benign, or everything else, and "everything else" is wired to a DESTRUCTIVE remedy (such as `docker compose down && up` every 10 minutes). Each fix carves out one more benign condition: usage limit, blank credential file, transient CLI error. Every carve-out is right, and none of them fixes the structure. The default branch is the expensive, destructive answer, so every unfamiliar string becomes a restart. A bare "Execution error" (which the CLI also emits for upstream 5xx errors, network blips and caller timeouts) can recreate a healthy container mid-job and kill a live user request, while the credentials were valid the whole time.

**Rules:**
1. Gate a destructive remedy on a POSITIVE match for the condition it actually repairs. Ask "does this error name the thing a restart fixes?", not "is this one of the errors I know is harmless?"
2. An empty or unrecognised error is NOT evidence for the remedy. Give the unclassified case its own state.
3. Restarting isn't a free diagnostic. Count what the remedy costs before making it the default; if it kills work in flight, every restart is a chance to destroy a live job.
4. Keep an escalation path. An unidentifiable fault is still a fault: set a marker the first time you see it, and apply the remedy anyway once it has lasted past a grace window of a few probe intervals.
5. Log WHAT the detector reacted to, not just its verdict.
6. "No verdict yet" (pending, null, zero timestamp) must never trigger the remedy. That restarts a component that just started and resets the same delayed probe.
7. Test the whole flow, not just the classifier. A guard that exists and is correct but can't be reached looks the same as a working one under grep and in a unit test. Run the real script against a real endpoint with the destructive call stubbed out, and assert whether the remedy was ATTEMPTED.
8. Harness caveat: under `set -o pipefail`, a `grep | tail | cut` that matches nothing aborts the test suite partway through, so the negative control reports FEWER failures than exist. That error runs in exactly the direction that creates false confidence. Use awk, which exits 0 when nothing matches.

## A Retry Cap Must Not Be Spent on an Infrastructure Outage

A bounded-retry recovery loop (MAX_ATTEMPTS, run by cron every N minutes) permanently kills every in-flight job when the dependency is down longer than cap × interval. The attempts get used up against a dead socket. Once a row reaches the cap, the recovery query excludes it for good, so the work stays dead long after the dependency comes back.

**The key distinction:** a CONNECTION-level failure (ECONNREFUSED, ENOTFOUND, ECONNRESET, socket hang up) says something about the infrastructure, not the job. A failure the dependency returns while actually serving the request is a verdict on the job and should still count.

**How to apply:**
1. **Preflight the dependency** (GET /health) before a run counts an attempt, resets a status or sends an alert. During an outage the run becomes a silent no-op, which also stops alerts every 5 minutes that teach people to ignore them.
2. **Refund the attempt on a connection-level error** and restore the row's previous status. Bound retries with an age window (for example 24h) instead of the attempt cap.
3. **Test the property that matters:** run N consecutive recovery passes against a CLOSED PORT and assert the row can still be retried afterwards. A single-pass test passes on the broken version too.

### A 429 or 503 is a verdict on the dependency's quota, not on the row

A refund rule that only covers connection-level faults still charges attempts when a reachable service answers HTTP 429 "temporarily at capacity". A counterintuitive twist: making the dependency reject **faster and more precisely** (an admission gate that returns in milliseconds with the reset time) makes this worse, because every retry burns out instantly against a limit that was going to clear on a known schedule.

**Rules:**
1. Classify a failed call by WHOSE fault it is, not by whether the socket opened. Connection refused, HTTP 429, HTTP 503 and explicit quota or rate-limit responses are all about the dependency's availability. Only an error produced while the dependency was really serving the request should use up a retry.
2. If the dependency says WHEN it will recover (a reset timestamp or `Retry-After`), wait until then instead of just refunding. Otherwise the next tick retries at once and refunds again, which is pure noise.
3. A retry cap plus a dependency that fails fast means work gets lost silently: rows at the cap drop out of the query, nothing alerts, and the backlog quietly disappears.
4. Keep a user-facing escape hatch that doesn't depend on the counter (for example a Retry button whose route resets the row without checking the attempt count).

## A Watchdog That Kills Out of Band Must Set a Kill Reason, or the Death Reads as Success

A supervisor that kills a job from outside the code that reaps it leaves the reaper with one observation: the process is gone. Without an explicit reason, "gone" looks like "finished", so the system reports a clean completion containing whatever partial work existed. A user can then see many minutes of tool narration under a normal completion footer, with no answer.

**Corollaries:**
1. A silence-based liveness threshold must be longer than the longest legitimate quiet stretch. A single shell tool call may run 600s without output, so a 300s stall timeout kills healthy work.
2. The explanation must go out on the channel the user actually reads. Streaming UIs show the stream, not the return value, so a notice added only to the returned string is invisible.

## A Two-Signal Liveness Check Is Only as Strong as Its Weaker Signal

A session keepalive can report "session appears alive" every day for more than a week while the session is logged out. Downstream, each service depending on that session degrades separately as its own token expires, and no single alert points at the cause.

**The mechanism:** the check ORed two signals, a URL pattern match and a page-content phrase match. The site showed its logged-out state at the *same URL* as its logged-in state, so the URL signal could never fire for this failure. That left only the content match, and its extraction silently returned an empty string on failure (error suppression). An empty extraction and a real non-match produce the same `false`, so the OR quietly shrank to "URL only".

**Rule:** when a health check ORs several signals for robustness, you must also detect when one signal's *input* goes missing, not just when it fails to match. Log or alert on an empty extraction separately from a non-match. A check that can silently lower its own confidence has to say so, or its redundancy disappears exactly when you need it.

## A Recurring Job That Notifies Only on Success Makes an Outage Look Like a Quiet Day

If a daily job emails on completion and sends nothing on failure, "the run broke" and "the run found nothing new" both arrive as an empty inbox. An outage can then last days, noticed only when someone remembers the missing messages.

**Rule:** for any recurring job whose output reaches a human, notify on EVERY final outcome, so that a missing message is itself the alarm:
1. The failure notice must say plainly that nothing was checked ("This is a failure notice, not an empty result"), or readers take it as a zero-result run. Include the error text, bounded in length.
2. Send the failure notice through the SAME delivery-tracking and retry machinery as the success notice. Otherwise the message most worth delivering is the one with no retry behind it.
3. A failed row's stored content is an error string, not a deliverable. Give it its own template instead of reusing "your material is ready".
4. Suppress the historical backlog at deploy (mark existing failed rows `legacy`), or the first cron tick floods the inbox with notices about one already-known outage.

## A Boot-Only Reaper Misses Jobs Stranded Inside a Still-Running Process

A reaper that runs once, at startup, assumes a restart is what strands a fire-and-forget job. But a `void (async () => ...)()` promise also dies from an unhandled rejection or an `await` that never settles (a hung child process, a fetch with no deadline), and no restart happens. Jobs can then sit `pending` for days in a process that has been up the whole time.

**Fix:** call the reaper from a periodic timer that already exists, so a stranded job's lifetime is bounded whatever stranded it. Set the age cutoff well beyond the longest legitimate run, and make it a parameter so a test can check the boundary without sleeping.

**Diagnostic tell:** rows stuck in a non-final state, older than any possible run time, in a process that was started before they were created. Compare process uptime with the row's `created_at` before assuming the reaper is missing. It may be deployed and simply never run again.

## A Script That Reports a Skipped Step as Informational Text Gets That Step Skipped Forever

If a script prints `SKIP <step> (no --flag specified)`, exits 0, and its summary says "done", the skip reads as a neutral status note. Callers will leave out the flag again and again, then paste the output as evidence they followed the very rule they broke.

**Rule:** when a script can silently skip the step that is the whole reason to call it, the skip must be louder than success: print to stderr, show a visible SKIPPED marker in the summary, and require an explicit opt-out flag, so "I meant to skip it" and "I forgot" leave different traces. A mandatory step that a script can turn into a no-op isn't really mandatory. **For the caller:** read a compliance command's output before quoting it as proof you complied.

## A Single Claude Code Session on WSL2 Can OOM-Reboot the Whole VM

**Symptom:** every interactive Claude Code session ends at once with no warning, each offering `claude --resume <id>`, and every PM2 service comes back with the same few minutes of uptime. That matching uptime is what tells this apart from an unrelated client crash. Before assuming the cause, rule out closeout hooks and host sleep or reboot (check the host OS's power-event log).

**Root cause:** one Claude Code process grows to tens of GB of RSS (worse with a large-context model) and trips the WSL2 VM's global OOM killer at the top of its cgroup tree (`/init.scope`). Because that scope is above everything else, the whole VM reboots, not just the offending process. If the WSL memory cap is below host RAM, a runaway session hits that ceiling.

**Diagnose:** `journalctl -b -1 -n 25` shows the OOM kill followed immediately by a reboot. Grep the full history for the kernel's out-of-memory line to see whether it keeps happening.

**Fix (two independent layers; either alone leaves a gap):**
1. **Per-session cap:** run each interactive session in a cgroup with a hard memory ceiling (`systemd-run --scope -p MemoryMax=<N>G -p MemorySwapMax=0`), so a runaway session is killed alone and can be resumed. Gotcha: the user-mode systemd manager may not work without a user D-Bus session (see below). Use the **system** manager through passwordless sudo, with `--uid`/`--gid` to drop back to your user, and `sudo -E` so the CLI still finds its config. Skip the wrapper for headless invocations.
2. **Aggregate guard:** a lightweight watchdog checks available memory every ~15s. Below a threshold, it kills the largest **headless** Claude process first, and an interactive one only if no headless one exists, before the kernel's OOM killer picks for you. This is what makes several concurrent sessions safe, because the per-session cap bounds only one session, not their total.

Neither layer requires switching to a smaller-context model. If the watchdog also governs remote-dispatched work, apply the resource-gate scoping rule above.

## WSL Start-at-Boot Scheduled Task Must Run as the Distro-Owning User via S4U, Not SYSTEM

To start a WSL distro automatically at Windows boot (so services recover without anyone logging in), use a Task Scheduler task with an AtStartup trigger that runs as the Windows user who owns the distro, with LogonType S4U (runs before login, no stored password). Running it as `NT AUTHORITY\SYSTEM` fails: distros are registered per Windows user (under HKCU), so SYSTEM has no distro, and `wsl -d <distro> ...` returns LastTaskResult `0xFFFFFFFF`.

```powershell
New-ScheduledTaskPrincipal -UserId '<HOST>\<windows-user>' -LogonType S4U -RunLevel Highest
```

Use `wsl -d <distro> -u <linux-user> -e /bin/true` as the action. The Windows and Linux usernames may be different. Only an actual reboot proves it works: a test run while you're logged in already has HKCU loaded, so LastTaskResult `0x0` is necessary but not sufficient. Automatic OS updates reboot hosts overnight, and without this task WSL services stay down until someone logs in.

## `systemctl --user` May Be Permanently Broken on WSL; Keep Automation Bus-Free

On some WSL hosts, `systemctl --user` always fails with `Failed to connect to bus: No such file or directory`: `/run/user/<uid>/bus` is missing, even though the user systemd manager is running and supervising units with linger enabled. Any cron or automation that calls `systemctl --user restart|start|stop` there is silently broken; it logs the bus error and does nothing. A self-heal that "restarts" a tunnel this way never works, and dead forwarded ports stay dead.

**Bus-free fix:** to restart a supervised user unit, kill its main process and let `Restart=always` bring it back (the manager's own restart logic doesn't need D-Bus), for example `pkill -TERM -f <exec-pattern>`. For new scoped processes, use the system manager (`sudo systemd-run --uid`). Never use `systemctl --user` in headless or cron contexts without first running it once on that host and checking for the bus error.

**Related:** with reverse SSH forwards and `ExitOnForwardFailure=yes`, the server's `sshd` can hold dropped forwarded ports for `ClientAliveInterval × ClientAliveCountMax` (for example 120s × 3 = 6 min), which blocks rebinding. Lower those values (for example to 30 and 2) in a drop-in under `/etc/ssh/sshd_config.d/` so ports free themselves in about 60s.

## Retiring a Repo From an Auto-Discovering Pipeline

If an autonomous pipeline auto-discovers repos (for example, any git repo under a root with at least N commits that isn't listed or excluded) and appends them to its list, deleting a repo from the list gets undone on the next run. To retire it permanently, move it to the pipeline's **exclusion list**, in every config variant that runs.

Then shut down every other recurring source of activity for that repo: process manager entries on every host (`pm2 delete <name> && pm2 save` on each), `cron_restart` in ecosystem configs, open PRs (an auto-merger will merge them), and `.github/dependabot.yml` (weekly scheduled PRs). The ongoing churn often comes from the pipeline, not the repo's own runtime.
