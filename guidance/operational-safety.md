<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

Prevent feedback loops, restart storms, and cascading failures in automated systems.

## Self-Deploy Loop Prevention

**The scenario:** An agent job modifies the service that spawned it, then deploys or restarts that service. The service restarts, recovers the "active" job from persistence, re-attaches to the still-running process, and the cycle repeats. Each restart kills in-flight work and creates cascading failures.

**How it happens:**
1. A service spawns an agent job targeting the service's own repo
2. The agent finishes changes and runs `pm2 restart <service>` or an equivalent deploy command
3. The service restarts, loads its job state file, finds the job still "active"
4. The service re-attaches to the process (or re-queues the job)
5. The job, or a recovered job, triggers another restart
6. Repeat indefinitely

**Defenses (layered):**

1. **Hard guard in the deploy script:** The `deploy` and `restart` verbs check the job state file for active jobs before restarting the service. If jobs are active, the command is refused with an error. This is the primary barrier.

2. **Prompt-level warning in the job executor:** When a job's working directory is inside the service's own repo, prepend a self-restart guard message to the prompt telling the agent not to restart the service. This is a soft barrier (the agent can ignore it).

3. **SIGINT handler in the service entry point:** The service refuses SIGINT during startup (30s grace) and while jobs are active. The process manager sends SIGTERM to force shutdown. This prevents cascading SIGINTs from child processes.

**If a loop is already happening:**
1. Kill the stale child processes: `ps aux | grep claude | grep -v grep` then `kill <pids>`
2. Clear the persisted jobs: edit the job state file, set `"activeJobs": []`
3. The service will stabilize on next restart with no jobs to recover

**Rule:** Never deploy or restart a service from within a job that service spawned. Make changes, commit, push, and note that a manual restart is needed.

## Restart-Recovery Loop (Long-Running Jobs)

**The scenario:** A long-running job is in flight. An auto-merger merges a PR and calls the deploy script. The deploy guard sends SIGINT, but the service ignores it (active jobs). The process manager escalates to SIGTERM, force-killing the service. On restart, the service loads its job state, finds the incomplete job, re-queues it, and starts running it. Meanwhile the auto-merger retries the deploy (or another merge triggers it), creating an infinite loop of: deploy → kill → restart → recover job → deploy.

**This is distinct from the self-deploy loop** because the deploy is triggered externally, not by the job itself. The deploy-script guard doesn't help, because the process manager force-kills after SIGINT is ignored.

**Defenses:**

1. **Recovery attempt limit:** Long-running jobs track `recoveryAttempts` in their persisted state. Each restart increments the counter. After 3 attempts, the job is abandoned instead of re-queued. This breaks the loop even if other defenses fail.

2. **Active-job check in the auto-merger:** Before calling the deploy script, the auto-merger reads the job state file and checks for active jobs. If any are active, the deploy is deferred for 60 seconds and retried. This prevents the deploy from killing active jobs in the first place.

3. **Existing deploy-script guard:** Still in place as a third layer, refusing to restart if active jobs exist. But since the process manager force-kills after SIGINT, this guard only works when the service process can actually be signaled gracefully.

**If this loop happens:**
1. `pm2 stop <service>` — halt the cycle
2. Edit the job state file — set `"activeJobs": []` and `"queue": []`
3. `pm2 start <service>` — clean restart with no recovery
4. Check error logs to identify the root cause

**Prevention rules:**
- Never merge PRs to a service's repo while long-running jobs are active on it
- If you must deploy during an active job: stop the service, deploy, then start it (the job will be lost, but no loop)

## Restart Storm Detection

A restart storm is when a managed process enters a rapid restart cycle (restarts > 5 in under 5 minutes).

**Signs:**
- `pm2 list` shows high restart count (e.g., 16+) with low uptime (seconds)
- Error logs show repeated startup messages in quick succession
- Recovery messages appearing every few seconds

**Common causes:**
- Self-deploy loop (see above)
- Crash-on-startup bug (bad config, missing env var, syntax error)
- OOM kill cycle (process exceeds `max_memory_restart` limit, restarts, loads same data, OOMs again)
- Dependency failure (database down, required service unavailable)

**Response:**
1. `pm2 stop <process>` to halt the restart cycle
2. Check logs: `pm2 logs <process> --lines 50 --nostream`
3. Fix the root cause
4. `pm2 start <process>` to resume

## Bash `pipefail` + `grep -c` Silent Failure

**The scenario:** A script with `set -o pipefail` uses `grep -c 'pattern' || echo "0"` to count matches. When grep finds 0 matches, it outputs `0` AND exits code 1. Pipefail triggers the `|| echo "0"` fallback, producing `"0\n0"`. The variable becomes a two-line string that breaks `$(( ))` arithmetic silently: no error, just wrong values downstream.

**Incident lesson:** This exact bug once made a daily security scanner fail silently for nearly two weeks. It was detecting secrets in public repos every run but crashing before it could report findings. The state file never updated, so it rescanned the same repos with the same silent crash every time.

**Fix:** Use `grep -c 'pattern' || true` instead. `grep -c` already outputs `0` on no match; it just needs the exit code suppressed, not a fallback echo.

```bash
# WRONG — produces "0\n0" with pipefail
count=$(grep -c 'pattern' file || echo "0")

# RIGHT — outputs "0" and suppresses exit code 1
count=$(grep -c 'pattern' file || true)
```

**Rule:** In any bash script using `set -eo pipefail`, never pair `grep` (any flag) with `|| echo`. Use `|| true` to suppress the non-zero exit code.

## Headless Claude CLI: Permission Flag Requirement

**The scenario:** A script spawns `claude -p` as a subprocess (Python `subprocess.run`, Node `spawn`/`execSync`, bash pipeline). The parent process already has `--dangerously-skip-permissions`, but the subprocess is a fresh CLI invocation that doesn't inherit it. When Claude tries to use tools (WebSearch, WebFetch, Bash, etc.), it prompts for permission. With no TTY, the prompt goes to the void and the session silently fails or produces degraded output.

**Incident lesson:** A research script spawned Claude for deep research. The top-level entry point had `--dangerously-skip-permissions`, but the nested subprocess call didn't. Every research request's WebSearch calls were silently blocked, producing reports without web data.

**Rule:** Every `claude -p` invocation that runs without a TTY (cron, subprocess, server route, background job) MUST include `--dangerously-skip-permissions`. This includes:
- Python `subprocess.run([CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...])`
- Node `spawn('claude', ['-p', '--dangerously-skip-permissions', ...])`
- Bash `$CLAUDE_BIN -p --dangerously-skip-permissions`

**Detection:** Have a health monitor scan all repos for Claude subprocess calls missing the flag.

**Also required: `--no-chrome`** for headless environments. The CLI may attempt to open a browser (for OAuth or a dashboard). In headless VMs or process-manager-supervised processes, this silently hangs or errors. Add `--no-chrome` alongside `--dangerously-skip-permissions` for all automated invocations:
- `claude --print --no-chrome -p "..."`
- `$CLAUDE_BIN -p --dangerously-skip-permissions --no-chrome`

An incident of this class: a worker piped prompts to `claude --print -p -` without `--no-chrome`; on the headless host, browser operations were attempted and failed silently.

### Gotcha: `claude -p` Eats the Next Argument as a Prompt String

When calling the CLI with piped stdin **and** additional flags like `--model`, use `claude --print`, **not** `claude -p`. The `-p` flag is positional: it treats the **next CLI argument** as a literal prompt string, so `claude -p --model <model-id>` passes `"--model <model-id>"` as the prompt and ignores stdin entirely.

```bash
# WRONG — -p eats --model as the prompt; stdin is ignored
echo "$prompt" | claude -p --model <model-id>

# CORRECT — --print enables stdin pass-through; --model is parsed as a flag
echo "$prompt" | claude --print --model <model-id>
```

**Incident lesson:** A scoring script used `execSync('claude -p --model <model-id>', { input: prompt })`. Every eval call passed the model flag string as the prompt instead of the real data.

**Rule:** When combining piped stdin with any extra flags (`--model`, `--output-format`, etc.), always use `claude --print` as the mode flag, not `claude -p`.

### Strip CLAUDE_CODE_* Env Vars From Subprocess Invocations

> **Correction:** This rule was originally written under the belief that inherited `CLAUDE_CODE_*` env vars caused a synthetic-401 incident. **That diagnosis was wrong.** Follow-up isolated testing (full polluted env including `CLAUDE_CODE_EXECPATH`, `CLAUDECODE=1`, and a dead `CLAUDE_CODE_SESSION_ID`) returned `is_error:false`. The true cause of those 401s was an OAuth refresh script being **rate-limited for several consecutive cron cycles**, leaving an expired access token. See "OAuth Refresh Rate-Limiting" below. The env-strip pattern is kept here as **defensive hygiene only**; it is not the fix for that failure class.

**Defensive scenario:** A long-running daemon that was started (or restarted) from inside a Claude Code session inherits `CLAUDECODE=1` and `CLAUDE_CODE_SESSION_ID` in its env. There is no reproducible failure from this alone, but stripping the vars when spawning a `claude -p` subprocess is cheap insurance against any future CLI behavior change that might treat a nested-session-marker env as special.

**When to apply:** Long-running services (daemons, server routes) where the inherited env is opaque or stale, and where you want subprocess `claude -p` invocations to look like fresh shell calls. Not required for cron jobs that already start with a clean env.

**Pattern:** Strip `CLAUDE_CODE_*` and `CLAUDECODE` from the subprocess environment:

```python
# Python
clean_env = {k: v for k, v in os.environ.items()
             if not k.startswith("CLAUDE_CODE") and k != "CLAUDECODE"}

result = subprocess.run(
    [CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...],
    env=clean_env,
    ...
)
```

```javascript
// Node
const clean_env = Object.fromEntries(
  Object.entries(process.env).filter(([k]) => !k.startsWith('CLAUDE_CODE') && k !== 'CLAUDECODE')
);
const child = spawn(CLAUDE_BIN, ['-p', '--dangerously-skip-permissions', ...], { env: clean_env });
```

**Why a process manager captures these vars:** Process managers capture the full env at daemon start (including any `CLAUDE_CODE_*` vars from the terminal session that ran the restart). The vars persist in the process table for the lifetime of that process slot, even across subsequent restarts, until the manager itself is restarted from a clean environment.

**Also strip `NODE_CHANNEL_FD`** when launching non-Node subprocesses from a Node.js parent (for example, a Python worker called from a Node service). Node.js IPC sets `NODE_CHANNEL_FD` in its own env; child processes that themselves use Node runtimes (such as a media downloader's JS challenge solver) inherit this FD reference and can fail with IPC errors because the FD is already closed or invalid in the new process.

```python
env = kwargs.get("env") or os.environ.copy()
if "NODE_CHANNEL_FD" in env:
    del env["NODE_CHANNEL_FD"]
kwargs["env"] = env
```

### OAuth Refresh Rate-Limiting

**The scenario:** A token refresh script runs every 3h via cron and calls the OAuth token endpoint with a `refresh_token` grant. The endpoint is **rate-limited**, and under load can return `rate_limit_error` for multiple consecutive cron cycles.

**Incident lesson:** Four consecutive cycles failed with `rate_limit_error`. The access token expired ~7h into the failure window. Every daemon doing `claude -p` during that window got a synthetic 401 with `model: <synthetic>` and `result: "Failed to authenticate. API Error: 401 Invalid authentication credentials"`. The CLI's `--output-format json` returns this as `is_error:false` `subtype:success` (confusingly), so the failure is not visible via standard subprocess exit codes, only by parsing the `result` field for the auth-error string. Eventually a later cycle got through and the token recovered.

**Detection signal:**
- `result` field of `claude -p --output-format json` contains "Failed to authenticate" or "401 Invalid authentication credentials"
- The refresh log shows `ERROR: OAuth refresh failed: rate_limit_error` on consecutive cycles
- Daemons silently fall back to degraded mode

**Mitigations to build into a refresh script:**
1. **Refresh well before expiry** (e.g. a 6h threshold), so a failure has ~3 cron cycles of slack instead of one.
2. **Intra-cycle retry with backoff** — up to 3 attempts per run; back off longer on `rate_limit_error` (60s/240s) than on other failures (30s).
3. **Consecutive-cycle failure counter** stored in a cache dir. After 2 or more consecutive failures, post an alert to your notification channel with hours-remaining context. Reset the counter on any successful or healthy cycle.

**When the consecutive-failure alert fires:** The alert means the API refresh path is stuck. Do NOT wait for the next cron cycle; trigger the browser-based re-login path. The browser OAuth path is not subject to the API rate limit and will recover the token immediately.

**Why "strip the env vars" was misdiagnosed as the fix:** The original 401 investigation happened to ship the env-strip a couple of hours before the OAuth refresh independently recovered; the next observation cycle was clean and the env-strip was assumed causal. Isolated repro (full polluted env) later showed the env vars alone do not produce 401.

**Layered defense: browser path as safety net.** The cron refresh path and the browser-based re-login path are independent recovery mechanisms. When the OAuth API endpoint is rate-limiting (the cron path fails), the browser-based path completes the login via the web OAuth flow, bypassing the API endpoint entirely. Observed in sequence: a manual run and the next cron cycle both exhausted all retries with `rate_limit_error`; the browser re-login chain ran the login through browser automation, sidestepping the rate-limited endpoint; the following cron cycle ran clean with the counter reset to 0.

**Implication:** When debugging a prolonged OAuth failure, check both paths. If the cron log shows persistent `rate_limit_error` and the access token is expired, the recovery path is NOT to wait; it is to trigger the browser-based re-login, which is not subject to the API rate limit.

### React SPA Hydration Race in Browser-Automated OAuth Scripts

**Symptom:** A browser-automation script clicks the OAuth Authorize button. The click reports success but nothing happens: no navigation, no callback. The same script works fine minutes later.

**Why:** React SPAs render the DOM before hydrating (wiring up event listeners). The Authorize button can be visible and selectable during this gap but fires no event when clicked. The window is typically under 2s but is reproducible on freshly-woken browser sessions.

**Incident lesson:** One container's re-login failed with "callback tab not found" while sibling containers running the identical script minutes later succeeded. The fix: add `sleep 4` after locating the consent tab, then retry the click once if no callback appears within 25s.

**Pattern for OAuth automation scripts:**
```bash
# After opening the consent/authorize URL and confirming the tab exists:
sleep 4  # Let React hydrate before clicking

# Click Authorize
browser-cli click "#authorize-button" ...

# Poll for callback (up to ~25s)
for i in $(seq 1 5); do
  sleep 5
  # check if callback tab appeared ...
done

# If no callback after 25s, retry once
if [ "$callback_found" != "1" ]; then
  sleep 4
  browser-cli click "#authorize-button" ...
fi
```

**Rule:** Never do unbounded retries on a consent button. If two attempts both produce no callback, escalate an alert; the problem is something other than a hydration race (rate limit, broken page, wrong selector).

### Auth-Age Enforcement: All Sessions Fail Simultaneously

**Symptom:** All automated re-logins fail on the same night with "callback tab not found". The browser session IS active (the account appears logged in), but clicking Authorize redirects to a login/reauth URL instead of the OAuth callback.

**Root cause:** The identity provider enforces a **max auth-age** (elapsed time since the account last performed a real sign-in) in addition to activity-age, before granting OAuth scopes. A session-keepalive script slides the activity clock but cannot reset the auth-age clock. When auth-age exceeds the threshold, the consent flow forces a full logout regardless of session freshness.

**Differentiator from the hydration race (above):** every container fails on the same night. The hydration race is a single-container, timing-based event that a retry resolves. Simultaneous failure across all containers is diagnostic of the auth-age pattern.

**Why automation may not self-heal:** after the forced logout, the OAuth grant page lands on a federated-identity button whose popup the browser blocks for extension-synthetic clicks (it requires a real user-activation gesture). Without special handling the script cannot complete the re-login loop unattended.

**Recovery:** a one-time manual action: sign the account out of and back into the controlling browser profile. The browser session then satisfies the auth-age check and nightly re-logins resume.

**The dangerous part: a refresh token has its own expiry.** It is tempting to conclude there is no user-facing impact during the failure window, because containers keep running and their access tokens auto-refresh. That is true for days, not weeks. A refresh token carries its own `refreshTokenExpiresAt` (observed: roughly 28-30 days), reset only by a successful interactive rotation and NOT extended by ordinary refreshes. That is why a rotation break in one month may not surface until the next: the fleet has weeks of runway and spends all of it silently. Any session that idles past that window wakes up unable to refresh; the CLI then writes the credential file back with **empty-string** `accessToken`/`refreshToken` and `expiresAt: 0`, and the health endpoint reports auth failed with "OAuth session expired and could not be refreshed". Nothing automated can recover that state, because minting a new refresh token requires the interactive login that auth-age is blocking. Measured after 11 nights of un-repaired auth-age failure: 7 of 9 sessions dead, each with a blanked credential and a `refreshTokenExpiresAt` in the past, and each died roughly 30 days after its own last successful rotation. The two survivors were simply the two whose chains never missed a refresh.

**Rule:** treat an auth-age failure as a deadline, not a steady state. Build the alarm that measures it: a daily job that reads `refreshTokenExpiresAt` for the host and every running container, warns under 20 days and pages under 10. That one field measures both how long until a credential is unrecoverable and how long rotation has been failing, and it does not care *why* rotation stopped, so it also catches the quiet skip (a pre-flight that exits 0 when the browser is asleep is right for one night and fatal over a fortnight). Also make every automation close the tabs it opens: leftover pages from run N become the bug in run N+1, benign on night one and an outage by week two. The alarm that matters is the one on a blank credential, not the nightly relogin email.

**Operational rule:** when an automated re-login fires a final-failure alert, check whether the alert message says the session was logged out at grant time. If it does, trigger a manual browser re-sign-in; do NOT attempt automated recovery, retry loops, or container restarts.

**Resolution notes, and the trap of assuming auth-age is always the cause.** A later fleet-wide failure of the same shape turned out NOT to be auth-age. Four separate defects had stacked up, each masked by the one in front of it:

1. **The caller's browser key was being overwritten.** A commit moved secrets into an env file and added `set -a; . "$HOME/.env"; set +a` to the browser-driving scripts. That file also defined the default browser profile key, and `set -a` plus source lets the **file beat the caller**. Every alternate-profile rotation was invoked as `KEY="$ALT_KEY" ...`, so from that day each one drove the **default** profile: it opened an alternate-account consent URL in a browser signed in as a different account, and the account chooser it reached never contained the expected address. Every "the session is logged out" alert described a profile the run never touched. **Rule:** a script that sources an env file after receiving env from its caller must re-assert the caller's values, or the file silently wins.
2. **The chooser popup was invisible to the tab registry.** A browser-extension release added the identity provider's domain to the manifest's `exclude_matches`. The registry was fed by content-script heartbeats, so from that day such a tab could never appear in the tab listing, and the entire account-chooser branch was unreachable code. Fixed by adding a listing verb backed by the extension service worker rather than content scripts.
3. **Origin containment hard-denied the clicks.** Same release. The sanctioned opt-in is an explicit "allow sensitive origins" flag, paired with an allowlist so it re-narrows to the single needed domain.
4. **The popup is a separate WINDOW, so it is never visible.** Focusing a *tab* does not raise its *window*, so the popup's document sits at `visibilityState: "hidden"` and the browser does not deliver synthetic input events to an unrendered page. Twelve consecutive debugger-protocol clicks reported success at the button's real coordinates while the page never moved; one `el.click()` on the same hidden page advanced it instantly. **Rule:** inside a popup window, use JS clicks. Reserve trusted protocol-level clicks for the one button that genuinely needs user activation (a button that calls `window.open`).

Bringing a second profile to parity surfaced three further traps, all worth encoding in any shared library:

- The identity provider **versions** its consent paths (two profiles hit different path versions on the same day, and a matcher pinned to a fixed path knew neither, nor any future one). Match provider states by keyword, not by fixed path.
- A **stale** consent tab hijacks the loop forever: a leftover error page with no buttons classified as consent, clicked nothing, every round, while the real wall was never touched again. Snapshot the provider's tab ids at entry and ignore pre-existing ones; a popup you did not open is not yours to drive.
- An unclassifiable page needs an **exit**: an "other" branch with no clearing action re-settles the same page every round, logging nothing but the word. Always log the URL of a page you could not classify.

Also fixed in the same pass: the consent-tab matcher required a literal `oauth/authorize`, but the site redirects to `/login?...returnTo=%2Foauth%2Fauthorize`, where it is percent-encoded, so losing the race against the redirect produced "consent tab not found" about a tab sitting right there. Match the **decoded** URL. And on one consent variant, Cancel and Continue share the same `jsname` attribute: select the primary button by visible label, never by an opaque attribute.

**Two traps that hid this for weeks:**

1. **A per-key operation gated on a global signal reports on the wrong thing.** The browser-automation service exposed a single un-keyed tab registry: every API key saw the union of tabs from **both** browser profiles, while *commands* routed per key to one profile's extension. So an "ensure this URL is open" call would match a URL, hand back the **other** profile's tab, and every later read on that id timed out. The session-keepalive script was therefore reading the wrong profile's tab and certifying its session daily, logging "session appears alive" while the target session aged out, tripped auth-age, and finally logged itself out. Its content check was correct; it was pointed at the wrong browser. The same bug sat in the relogin pre-flight, which gated on a global `connectedClients` count: one awake profile satisfied it while the other extension was absent. Fixed by probing ownership with a keyed ping, and gating on a per-key extension-status check. **Rule:** if a check is per-profile/per-key/per-tenant, its signal must be too, and "I could not read it" is never evidence of health.

2. **Muting an alert by call site means the mute silently moves.** A suppression keyed on the *post*-Authorize classifier (one exit code, one wall kind). Weeks later the session went from stale to fully signed out, so the identical wall began failing one call site **earlier** (the pre-Authorize check, a different exit code) which was not suppressed. Six alerts a night resumed with **no code change on either side**. **Rule:** suppress on the *classified condition*, and make the classification reachable from every path that can produce it; a mute pinned to one exit code is a mute that expires the moment the failure moves.

### Verify the CLI Binary Path Rather Than Assuming It

A wrong hardcoded fallback path for the CLI binary causes silent `[Errno 2] No such file or directory` failures that drop all AI processing without any obvious error in service logs. On one host the binary lived at `/usr/bin/claude`, not the assumed `/usr/local/bin/claude`, and every invocation from an error handler failed silently.

**Rule:** Resolve the path with `command -v claude` on each host and prefer a `CLAUDE_BIN` env var over hardcoding, so deployments with non-standard paths can override it:

```python
# Python
claude_bin = os.environ.get("CLAUDE_BIN", "/usr/bin/claude")
```

```javascript
// Node
const CLAUDE_BIN = process.env.CLAUDE_BIN || '/usr/bin/claude';
```

```bash
# Bash
CLAUDE_BIN="${CLAUDE_BIN:-/usr/bin/claude}"
```

## Claude CLI Rate Limit Detection in Service Wrappers

**The scenario:** A service wraps `claude -p` (via `spawn` or `execFile`) and reads stdout for the AI response. When the account hits its usage limit, the CLI exits with code 0 but outputs a rate limit message instead of a real response (e.g., "You've hit your limit... resets 3:50pm PT"). The service treats this as a successful result, returning garbage content to the user.

**Incident lesson:** A service returned rate limit text as a "completed" generated document. Jobs were marked successful with useless content because the wrapper only checked exit code, not output content.

**Fix:** After collecting stdout from any `claude -p` subprocess, check for rate limit patterns before treating the output as valid:

```javascript
const output = stdout.trim();
if (output.match(/you've hit your limit/i) || output.match(/resets \d+:\d+[ap]m/i)) {
  // Return 429 or retry error, NOT success
  return { error: "AI at capacity", status: 429 };
}
```

**Rule:** Any service wrapping the CLI must detect rate limit responses and translate them to errors (HTTP 429 or equivalent). Do not rely on exit codes alone; rate limit messages arrive on stdout with exit code 0. Match by wording family, not one literal string (see the classification rules further down).

## `set -e` Makes Post-Hoc Exit-Code Capture Dead Code

**The scenario:** A runner script uses `set -euo pipefail`, invokes a fallible command as a bare statement, then tries to handle failure afterwards:

```bash
set -euo pipefail
timeout 2700 claude -p "$PROMPT" > "$LOG"   # non-zero exit kills the script HERE
EXIT_CODE=$?                                 # never reached on failure
if [ "$EXIT_CODE" -eq 124 ]; then ...        # dead code
```

Under `set -e`, any non-zero exit terminates the script before `EXIT_CODE=$?` runs. Every downstream failure path (timeout logging, alerts, state writes, cost tracking) is unreachable. The same applies to command substitution: `RESULT=$(claude ...)` exits the script before the failure branch. A subtle variant: `OUT=$(cmd || true); RC=$?` — the `|| true` guarantees `RC` is always 0, silently disabling the gate that reads it.

**Incident lesson:** three separate autonomous runners plus a verification script all had this bug. Zero failure alerts had ever fired across roughly a thousand combined runs; a 45-minute run timed out with no log entry, no state write, and a reused run ID the next day; the verify gate passed proven test failures for weeks.

**Fix:** capture the exit code in the same statement so `set -e` never sees the failure:

```bash
EXIT_CODE=0
timeout 2700 claude -p "$PROMPT" > "$LOG" || EXIT_CODE=$?
```

**Rule:** In any `set -e` script, a command whose failure you intend to handle must have its exit captured via `|| VAR=$?` (or run inside an `if`). Never write a bare command followed by `$?`, and never read `$?` after `|| true`. Audit: `grep -n 'EXIT_CODE=\$?\|_EXIT=\$?' <script>` — each hit must be on the same line as the command it measures.

### The complement: `exit $?` is a landmine for any later edit

The rule above is about `set -e`. This one bites with or without it. A script that ends a branch with

```bash
some_command
exit $?          # fine today
```

is correct only while nothing sits between the two lines. The moment anyone adds a log line, a metric write, or a cleanup call in that gap, `$?` reports *that* command instead, and the branch starts exiting 0 when it meant to exit 1. Nothing warns you: the script still runs, still prints the same output, and only the exit code, the one thing callers branch on, is now wrong.

This is exactly how a fail-closed gate silently becomes fail-open.

**Fix:** capture into a named variable immediately, then exit on the variable. The name also documents that the value is load-bearing:

```bash
some_command
GATE_RC=$?       # capture FIRST: anything below clobbers $?
log_event "$GATE_RC"
exit "$GATE_RC"
```

**Rule:** treat `exit $?` and `return $?` as write-protected. If you need to add anything to that branch, convert it to a named capture in the same edit. When instrumenting a gate that other systems depend on, prove exit-code parity with the pre-change version rather than reasoning about it: run both copies over every branch in a sandbox and assert the codes match. Inspection is what misses this, because the diff looks purely additive.

## `set -e` Kills Functions Ending in a Guarded `&&`

**The scenario:** a helper function's last command is `[ condition ] && action`:

```bash
set -euo pipefail
vlog() {
  [ -n "$VERBOSE" ] && log "$*"   # returns 1 when VERBOSE is unset
}
vlog "checking..."                 # set -e exits the WHOLE script here
```

Inline, `[ cond ] && action` is safe under `set -e` (the failing test is on the left of `&&`). But as the **last command of a function**, the function's return status becomes 1, the function call itself is now a failing simple command, and `set -e` kills the script at the first call site. The failure is completely silent: no error output, exit before any later logging.

**Incident lesson:** a health monitor on a 15-minute cron died at its first `vlog` call on every single run for its entire deployed life. Its log showed only `START:` lines; it never completed a check, never posted an alert, and nothing noticed, because the thing that died WAS the alerting layer. Its own cron scheduling was verifiably fine: **a heartbeat at the start of a run proves scheduling, not completion. Freshness checks must key on an end-of-run marker.**

**Fix:** `if [ -n "$VERBOSE" ]; then log "$*"; fi` (an `if` whose condition is false returns 0), or end the function with `|| true` / an explicit `return 0`.

**Rule:** in `set -e` scripts, never end a function body with a bare `[ cond ] && cmd`.

## Cron Output Redirects Into Root-Owned Dirs Die Silently

**The scenario:** a non-root crontab line redirects into `/var/log/`:

```
*/5 * * * * $HOME/bin/watchdog.sh >> /var/log/watchdog.log 2>&1
```

The shell opens the redirect target BEFORE running the command. If the dir is not writable by the cron user and the file doesn't exist, the open fails and **the command never runs at all**: every occurrence, forever, with no trace beyond an unread cron mail. The trap is asymmetric: if the log file already exists (created earlier when perms allowed, or pre-touched by root), appending works, so some `/var/log` crons keep working while their siblings are dead, which defeats "the other one works, so the pattern is fine" reasoning.

**Incident lesson:** `/var/log` on a host was root-owned 755; 9 of 11 user cron entries redirecting there were dead: both process watchdogs, the uptime monitor, the error aggregator, the restart alerter, a config sync, a daily restart, a database guardian (never ran once), and a state backup (last artifact 4 months old). The 2 survivors had pre-existing log files. One dead cron had been individually "fixed" earlier by pre-creating its log file: the instance was patched, the class was not.

**Rules:**
- Non-root cron output goes to a user-owned dir (e.g. `~/logs/cron/`); never redirect cron output into `/var/log` as a non-root user.
- When you find one broken cron redirect, audit the whole crontab for the class: `crontab -l | grep '/var/log'`.
- Every watchdog/monitor needs periodic end-to-end verification: does its log show a run **completing** (not just starting) within the last interval, and can it still deliver its alert? A monitoring stack in which every layer dies silently (watchdog crons dead, health monitor dead, process-metric collection poisoned, simultaneously) is the default failure mode, not the exception.

## Hook Loop Prevention

Auto-posting hooks (publishing, notifications) run on every agent turn. If a hook failure triggers a retry or a new session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new agent sessions without recursion guards.
- Hooks must have timeouts (10s max). A hung webhook should not block the session.
- If a hook fails, log the failure and continue. Do not abort the parent session.

### Stop Hook Safety

Classify Stop hooks by tier and guard accordingly:
- **Tier 1 (observation):** reads state, writes a log. No guard needed beyond a timeout.
- **Tier 2 (verification):** runs tests or checks. Needs a PID lockfile so concurrent sessions don't stampede.
- **Tier 3 (invokes an agent):** must source a shared guard providing an env-var circuit breaker (set in the child's env so a nested session skips the hook), a PID lockfile, and a per-hour rate limiter.

**Incident lesson:** a Stop hook ran a session scorer via `claude -p` on every session exit. The scorer's own session exit re-triggered the hook. Result: nearly 5,000 recursive sessions in one day, consuming the large majority of that week's token usage. Fixed with an env-var guard plus a content pattern match, then standardized into a shared guard library.

## Concurrent Sessions in One Checkout

Two distinct problems, two distinct fixes:

- **Shared working tree:** two sessions editing the same checkout clobber each other's branches and staged state. Use a worktree per session: `git -C <repo> worktree add /tmp/<label> -b <branch>`.
- **Singleton resources:** a shared state file, a lock-free queue, or a single process slot needs a real lock (flock or a PID lockfile), not a convention.

When something keeps reverting, diagnose in this order: is another session in the same tree; is a hook or automation rewriting the file; is a stale process holding the old content.

## Job Recovery Safety

When a service recovers persisted jobs on startup:
- **PID alive:** Re-attach and monitor for completion. Do not re-execute.
- **PID dead:** Extract partial output, mark as failed, notify. Do not re-run automatically.
- **Partially complete multi-step job:** Re-queue from the last completed step, not from scratch.

**Never** automatically re-execute a failed job. The failure may have been caused by the job itself (for example, it deployed the service). Automatic re-execution would repeat the failure.

## Unattended Jobs That Take Irreversible External Actions

A cron job that spends money, sends a message, cancels a subscription, or files something is not a normal cron job: a bug does not just fail, it does the wrong thing to the outside world, and nobody is watching when it happens. Five requirements, all of them cheap:

1. **Gate on identity, not just success.** Before the irreversible step, assert the thing in front of you is the thing you meant: expected item/recipient name, expected quantity. Refuse and report on mismatch. A checkout page that loads fine is not evidence it holds the right cart.
2. **Cap the magnitude.** A hard ceiling (`MAX_TOTAL`) turns a pricing change, a currency bug, or a duplicated line item into a refusal instead of a charge.
3. **Idempotency guard.** Keep a per-period state file (`~/.state/<job>-last-*.json`) recording the period already completed, and check it first. Without this, a manual re-run, a retry, or two overlapping schedules double-execute. This is the single highest-value guard, because retries are otherwise unsafe to add.
4. **A `--dry-run` that stops immediately before the irreversible call** and exercises everything up to it. This is what makes the job testable at all; without it the only test is doing the thing for real.
5. **Report every outcome, including failure.** Silence must never be the success signal. Route success, failure, AND skip through your alerting path.

**Retry windows: separate transient blockers from real failures.** A job that depends on something ambient (a browser being open, a VPN, a machine being awake) cannot be scheduled at one fixed time and called reliable. Sweep a window instead, but only if the alerting is retry-aware, or an outage becomes a dozen identical alerts and the next real one gets ignored:

- **Transient** (dependency not ready yet, later attempt may clear it): log, stay silent during the window.
- **Real** (failed gate, missing credential, unparseable confirmation): alert immediately; a human is needed and more attempts will not help.
- **Already done** (idempotency guard fired): silent. This is the steady state.
- **Close the window with one `--final` run** that alarms if the period never completed. That single alert is the "we missed it" signal, and it fires once.

**Related:** if the job drives a browser, it also inherits the verify-before-claiming rule: parse the confirmation for a real identifier (an order number), never trust that the click "worked".

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

Add the entry to the project's context file under a "Known Issues" or "Incident Log" section so future sessions are aware.

## Irreversible Content Deletion

When bulk-deleting content on external platforms (video hosts, social media, cloud storage), apply strict safeguards:

1. **Gather and confirm first** — Build the full list of items to be removed and present it for confirmation before deleting anything. This catches mistakes in date ranges, filters, or account selection.
2. **Restrict to safe content types** — Only auto-generated or temporary content is eligible for bulk deletion (e.g., unlisted short clips, draft posts). Never bulk-delete public, private, or manually curated content.
3. **Filter by metadata** — Apply duration, privacy status, date range, and ownership filters to exclude anything that shouldn't be touched (e.g., skip full-length videos when deleting shorts by filtering to <= 90s).

**Why:** Platform deletions are irreversible. A wrong date range or missing filter can wipe out manually curated content. The confirmation step and content-type restriction ensure only disposable items are at risk.

## Verify Before Asserting

Don't claim someone did something (submitted an application, sent an email, published a post) unless you can verify it through an authoritative source. The existence of prep materials, drafts, or related files does NOT confirm the action was completed.

**Why:** An agent asserted an application had been submitted because prep materials existed in cloud storage. It never was. That led to incorrect context being shared with a third party.

**How to verify:**
- **Applications/emails:** check the sent folder for confirmations
- **Published posts:** check the live URL
- **Deploys:** check process status and server logs
- **Git pushes:** check `git log origin/main` or `gh pr list`
- **Any action:** look for the completion artifact, not the preparation artifact

## Health Monitor Self-Exclusion

**When writing a health monitor or watchdog that scans managed processes, always skip the monitor's own process.**

If a health monitor watches all processes, including itself, it can trigger auto-immune loops: the monitor detects its own high restart count, attempts to fix it, restarts itself, which increments the restart count, which triggers another fix attempt.

**Pattern:**
```python
for proc in processes:
    name = proc["name"]
    if name == SELF_PROCESS_NAME:  # skip self
        continue
    # ... health checks
```

**Incident lesson:** a fix-applying health daemon scanned all managed processes including itself. Its dedup window also had to be widened (1h to 24h) to stop repeated self-triggering within a single incident window.

**Rule:** Any monitoring daemon that enumerates processes must exclude its own process name from health checks.

### Log Artifacts and ANSI Codes in Error Handlers

Three related patterns that cause error-handler crash loops or alert floods when reading process-manager log output:

**1. Log format artifacts in IGNORE_PATTERNS**

Process manager log output contains formatting lines that are not actual errors: separator lines, the command echo, and the handler's own prefixed log lines. Without ignore patterns for these, the handler classifies them as errors and alerts/loops on its own output.

```python
IGNORE_PATTERNS = [
    r"\[error-handler\]",  # handler's own log prefix
    r"pm2 logs",           # log command echo
    r"^---$",              # separator lines
]
```

**2. ANSI escape codes break dedup signatures**

Log lines may carry ANSI escape sequences (color codes, cursor movement). If not stripped before computing the error signature hash, the same underlying error produces different hashes across restarts, causing an alert flood.

```python
import re
ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')

def _strip_ansi(text: str) -> str:
    return ANSI_ESCAPE.sub('', text)

# In your log-reading loop:
clean_line = _strip_ansi(raw_line)
signature = hashlib.md5(clean_line.encode()).hexdigest()
```

**3. Log message prefixes that mis-trigger monitoring**

Avoid structured-looking prefixes like `SUCCESS:`, `ERROR:`, or `WARN:` in info/success log messages of a monitoring daemon. If the daemon (or a downstream watcher) pattern-matches on its own log output, a `SUCCESS:` prefix in a normal info line can look like a different error class and re-enter the alert pipeline.

```python
# BAD — "SUCCESS:" could be caught by a scanner watching for status keywords
logger.info(f"SUCCESS: fix complete (cost: ${cost:.4f})")

# GOOD — plain message; log level already communicates severity
logger.info(f"fix complete (cost: ${cost:.4f})")
```

## When a Vendor CLI's Free Tier Is Withdrawn

A free tier can be discontinued with no deprecation window, and the CLI then throws an ineligible-tier error inside its user setup, before the first request. Such an error cannot be suppressed with flags or cwd changes; it is account-wide.

**Silent impact on automated runners:** every consumer that shells out to that CLI now errors, but cron wrappers that ignore exit codes never alert. Audit anything that calls it: shadow runners, PR generators, offload tasks, and any fallback path that quietly depends on it.

**Mitigation:** treat the CLI as unavailable until migrated to a paid key or successor product. Fall back to a different provider or a second CLI. Before relying on any such call in automation, probe with a trivial prompt (`<cli> -p "ok?" 2>&1`) and check for the tier error.

## Shared Poller Resource Gates Must Be Scoped to the Executing Machine

When a poller or executor dispatches jobs to BOTH local and remote workers (e.g. a local run function and a remote-over-SSH variant), any resource gate based on the local machine's resources (RAM, CPU, disk) must NOT fire for remote jobs; those jobs consume zero local resources.

**Case:** a multi-worker dispatcher had ONE memory watchdog for all jobs: when the host's `MemAvailable < 100MB`, it killed the tracked PID. For remote SSH jobs the tracked PID was only the SSH client on the host; the real work ran on the remote worker using zero host memory. Host memory pressure was killing healthy offloaded sessions. Symptom: the log showed "Memory watchdog: only 93MB available — killing process PID" while dispatch counts showed only remote dispatches and zero local ones.

**Fix pattern:** Add a `skipMemoryWatchdog` (or equivalent) flag to the polling function. Set it to `true` for remote-dispatched jobs. Timeout and output-size watchdogs can still apply to remote jobs (they guard a hung SSH connection or runaway output regardless of location).

**Rule of thumb when adding any resource guard to a shared poller:** ask "does this resource live on the machine actually running the session?" If the job is remote, local RSS/mem/CPU is irrelevant.

## A Repo's Main Checkout Must Never Be Left on a Merged Feature Branch

**Symptom:** a repo's primary working copy (not a worktree) is checked out on a feature branch whose PR has already been merged. The local branch is stranded and local `main` silently falls behind `origin/main`, sometimes by several commits, with no error surfaced anywhere.

**Why this is worse than an ordinary stale branch:** SessionStart hooks, CLAUDE.md loads, and guidance-file reads for every concurrent session on that machine execute against whatever is checked out in the main checkout. A stranded branch means every other session (interactive or automated) silently reads outdated or divergent guidance. The failure can originate from **any** session that does a plain `git checkout <branch>` in the main checkout to open a PR (rather than using a worktree) and never switches back after the merge.

**Detection:** In any repo's main checkout, `git branch --show-current` should always equal that repo's default branch except for the brief window someone is actively working on a real feature. If it isn't, check whether the current branch's PR is already merged (`gh pr list --head <branch> --state all`); if so, the checkout was simply never returned home.

**Fix:** verify the current branch is a strict subset of `origin/<default>` first (`git diff origin/main HEAD --stat` should be empty or default-only), then `git checkout main && git merge --ff-only origin/main && git branch -d <stale-branch>`. Do not force anything; if the diff isn't empty, treat it as in-progress human work (stash and investigate, don't discard).

**Prevention:** any session opening a PR from a main checkout should instead do `git -C <repo> worktree add /tmp/<label> -b <branch>`, work there, and leave the main checkout untouched on its default branch throughout.

## Never Inline Single-Quoted Code in `ssh 'block'`

`ssh host 'big block ...'` wraps the whole remote command in single quotes. Any single quote INSIDE the block (JS `app.get('/path', ...)`, Python `'text/plain'`) terminates the outer quote and silently mangles the code. This has shipped invalid JS to a production server and crash-looped the service.

**Fix:** write the script or patch to a LOCAL file and `scp` it, then run `ssh host 'python3 /tmp/file.py'`. Always syntax-validate on the remote host (`node --check`, `python3 -m py_compile`) BEFORE restarting, and keep a `.bak` to restore.

## Audit the CLI Version on Every Host, and Pin Fan-Out Defaults Before Upgrading

Version drift silently keeps already-fixed reliability bugs in play, and headless hosts drift worst because nobody watches their startup banner. A real audit found an interactive host 19 releases behind and a server host 8 behind, both still exposed to fixed bugs in intermediate versions (an MCP truncated-output memory retention bug, a stream-json output truncation at exit for slow-reading consumers, and quadratic message-normalization stalls in long sessions).

Rules:

1. Check `claude --version` against `npm view @anthropic-ai/claude-code version` on EVERY host that runs the CLI (workstation, servers, containers), not just the interactive one.

2. Pin fan-out and search behavior BEFORE upgrading, because upgrades change defaults underneath you (one release raised default nested-subagent spawn depth from 1 to 3; another added a session-wide web-search cap). Set `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` explicitly so an upgrade never changes spend or research depth implicitly. Implicit deep nesting can outrun what a usage gate reasons about, since the gate models the fan-out the top-level session controls.

3. Set `fallbackModel` (array, max 3 entries; does NOT merge across settings files) on every host running headless runners. Without it a runner hard-fails when its primary model is unavailable or overloaded: the silent-healer failure class.

4. Verifying a settings change means launching the CLI and getting a reply, not just parsing the JSON. An unsupported or misspelled settings key is accepted silently and does nothing. Corollary: env vars introduced in a version NEWER than the installed CLI are inert until the upgrade lands, so setting them is upgrade-preparation, not an active change.

5. **Containerized installs drift worst, and the host version tells you nothing about them.** Container images built with an UNPINNED `RUN npm install -g @anthropic-ai/claude-code` freeze whatever was latest at build time and never move again. One audit found eight live containers spread across three old versions while the hosts were on two different, newer ones.

   **Match the fix list to how the consumer actually invokes the CLI before calling drift urgent.** The first pass of that audit asserted the containers were exposed to three specific fixed bugs. Reading the server code refuted all three: the containers spawn `claude -p --allowedTools ...` and accumulate PLAIN stdout (no `--output-format stream-json`), attach NO MCP servers, and run one-shot per request rather than long sessions. Version drift is real, but a fix only matters if the invocation path touches it. Check the spawn arguments, not the version number alone.

   Two consequences that do hold:
   - **Pin the version in the Dockerfile** (`@anthropic-ai/claude-code@<version>`). Unpinned means every rebuild is a silent, unreviewed upgrade that can change defaults (see rule 2), and builds are not reproducible.
   - **Rebuild on a cadence, not on demand.** An unpinned image that is never rebuilt is the worst of both worlds: frozen on an old version AND guaranteed to jump many versions at once whenever it finally is rebuilt. Enumerate with `docker exec <container> claude --version` per container.

### Unpinned Docker Installs Make Rebuilds a Silent No-Op; `docker exec` Probes as Root and False-Alarms on Auth

Rebuilding a fleet of containers surfaced two traps that make a rebuild look successful when it did nothing, and make a working container look broken.

1. **An UNPINNED install plus Docker layer cache means `docker compose build` is a silent no-op.** One container rebuilt cleanly and came back on its old version. Its `RUN npm install -g @anthropic-ai/claude-code` line was byte-identical to the previous build, so Docker reused the cached layer and never re-ran npm. The others upgraded ONLY because pinning the version changed that line and busted the cache. So an unpinned image is doubly bad: it freezes at build-day latest AND resists the rebuild you would use to fix it. Either pin the version (preferred, and the cache-bust is a feature) or build with `--no-cache`. Always assert the version INSIDE the container after a rebuild (`docker exec <c> claude --version`); never infer success from a clean build log.

2. **`docker exec <container> claude -p ...` runs as ROOT and reports "Not logged in", even when the service is perfectly authenticated.** Credentials live under the service user's home (e.g. `/home/node/.claude/.credentials.json`), but root's HOME is `/root`, so the CLI finds nothing. This looks exactly like a rebuild wiping credentials and will trigger a false rollback. Probe as the service user instead: `docker exec -u node -e HOME=/home/node <c> claude -p "..."`. Confirm any suspected breakage against an un-rebuilt container as a control before acting.

3. **An `auth=pending` health reading immediately after a rebuild is expected, not a failure.** If the server checks auth on a long interval (e.g. every 30 minutes) with the first check a minute after start, wait for the "checked N seconds ago" field to be populated before judging.

Credentials survive a rebuild when they live in a named volume mounted over the config dir rather than in the image, so build-and-up preserves them and no re-OAuth is needed.

### The OS Sandbox Is Not Usable Inside Docker or on WSL2

Investigated and CLOSED as not-applicable; this corrects an earlier recommendation that called a strict network allowlist "the highest-value remaining security item."

**Containers cannot use it.** The CLI sandbox is enforced by bubblewrap, which requires unprivileged user namespaces. Inside a container `bwrap` fails with `Creating new namespace failed: Operation not permitted`, including the weaker variant that binds the existing `/proc`. The host kernel is not the blocker (`/proc/sys/user/max_user_namespaces` reads a large positive number inside the container); Docker's default seccomp profile blocks `CLONE_NEWUSER`. Enabling it would require running with `--privileged`, `--cap-add SYS_ADMIN`, or `seccomp=unconfined`.

That trade is backwards: it punches a hole in the OUTER isolation boundary in order to add an inner one, on containers whose entire purpose is isolating untrusted public input. **For such containers, the Docker container IS the sandbox.** Do not weaken it to add a nested sandbox. A "weaker nested sandbox" option does not rescue this: it addresses a container that cannot mount a fresh `/proc`, not one forbidden from creating namespaces at all.

**WSL2 hosts cannot use it either, for a different reason.** On WSL2, sandboxed commands cannot launch Windows binaries or anything under `/mnt/c/`. If your primary working directory is a Windows path and Windows interop is routine, enabling the sandbox breaks that wholesale; Docker is separately sandbox-incompatible.

**Where the real mitigation lives instead.** If the exposure that motivated this was a broad `Bash(curl:*)` permission on untrusted public input, and the OS-level sandbox is unavailable, the controls that DO apply are: a narrow `--allowedTools` list, account isolation, the container boundary itself, and an output scrubber. Harden those.

**Verify before reopening:** run `docker exec -u root <container> bwrap --ro-bind / / --dev /dev echo ok`. If it still prints `Operation not permitted`, this conclusion stands.

## A Recovery Action That Cannot Fix the Condition Must Be Gated on Classifying the Condition First

Restart storms come from a health check with fewer states than reality. One auth-refresh watchdog had two: `ok` and "not ok", where "not ok" meant stale bind-mounted credentials and the remedy was recreating the container. Being out of quota also reads as "not ok", so it inherited a remedy that cannot return quota: 1,273 container recreates across six service logs, tearing down and rebuilding every 10 minutes for the length of each limit window, plus an alert telling the operator to run a login command for a condition login cannot fix.

The diagnostic that settles it is correlation across independent units. Six services have six independent credential files, and the recreates fired in lockstep at the same minute on consecutive nights. Independent files do not go stale in the same second; one shared account runs out of quota in the same second. Lockstep failure across units that share exactly one thing points at the shared thing.

Rules:
1. Before wiring an automatic remedy to a failure state, ask which conditions land in that state and whether the remedy addresses each. If it addresses only some, classify first and let the others fall through to a wait.
2. Detect operational strings by wording family, not one literal. A vendor may say "your limit", "your session limit", "your weekly limit", and a reset stamp may carry no minutes ("resets 3am (UTC)"). A guard pinned to one literal silently stops matching when the wording changes, and the failure is invisible because the wrong branch still runs. Scope loose patterns to short output so real content quoting "limit" is not swallowed.
3. Put the classifier where the condition is observed (the health endpoint), and keep a wording fallback in the consumer, so the fix applies to already-running processes without a rebuild.
4. A recovery loop that re-runs on a fixed interval should record what it observed, not just what it did. Those logs said "auth=failed, recreating container" and never printed the error text, so the misclassification was invisible for months in plain sight.
5. Alert text is part of the fix. An alert naming the wrong remedy trains the operator to distrust the alert.

Applies to any watchdog: process restarts, container recreates, auth refreshers, stale-job requeues.

## A Retry Cap Must Not Be Spent on an Infrastructure Outage

A bounded-retry recovery loop (MAX_ATTEMPTS, cron every N minutes) permanently kills every in-flight job when the dependency is down longer than cap x interval. The attempts are consumed against a dead socket, and once a row is at the cap the recovery SELECTs exclude it forever, so the work stays dead long after the dependency recovers, and nothing ever retries it.

Observed: a dependency fleet was down about an hour; the consumer's recovery ran every 5 minutes with MAX_ATTEMPTS=2, so both attempts were spent inside the first ten minutes. A queued job stayed dead for 5 hours with a useless error until a human reported it.

The distinction that fixes it: a CONNECTION-level failure (ECONNREFUSED/ENOTFOUND/ECONNRESET/socket hang up) is a statement about the infrastructure, not a verdict on the job. A failure returned BY the dependency (bad response, timeout while it was answering) is a verdict on the job and must still count.

How to apply:
1. Preflight the dependency (GET /health) before the run counts an attempt, resets a status, or posts an alert. During an outage the whole run becomes a silent no-op, which also stops the every-5-minutes alert spam that trains people to ignore it.
2. In the catch, refund the attempt on a connection-level error and restore the row's prior status, so the next run retries it. Bound it with an age window (e.g. 24h) rather than the attempt cap.
3. Test the decisive property directly: run N consecutive recovery passes against a CLOSED PORT and assert the row is still retryable afterwards. A single-pass test passes on the broken version too.

## A 429 or 503 From a Dependency Is a Verdict on Its Quota, Not on the Row

A retry-budget fix for the class above refunded the attempt only for CONNECTION-level faults: error codes such as ECONNREFUSED and ECONNRESET plus the strings 'socket hang up' and 'fetch failed'. A service that answers HTTP 429 "temporarily at capacity" is reachable by that test, so the attempt was charged. Both attempts for a row were spent inside a single 5-minute cron tick, and the work then dropped out of every recovery query while the account was merely out of quota.

The counterintuitive part worth remembering: making the dependency's rejection FASTER and MORE PRECISE made this worse, not better. An admission gate had been added that detects the quota state up front and rejects in milliseconds with the parsed reset time. Before that, each attempt at least consumed real time and the two retries were spread out; afterwards both were burned instantly against a wall that was going to clear on a known schedule.

General rules:
1. Classify a failed dependency call by WHOSE fault it is, not by whether the socket opened. Connection refused, HTTP 429, HTTP 503, and an explicit quota or rate-limit response are all statements about the dependency's availability. Only an error produced while the dependency was genuinely serving the request is evidence about the row, and only that should spend a retry.
2. If the dependency tells you WHEN it will recover (a reset timestamp in the 429 body or a `Retry-After` header), defer until then instead of merely refunding. Refunding alone means the next tick retries immediately and refunds again, which works but is pure noise.
3. A retry cap plus a fast-failing dependency is a silent work-loss combination. Rows at the cap are excluded by the selecting query, so nothing alerts and the backlog just stops existing.
4. Keep the user-visible escape hatch independent of the internal counter. A stored failure message that renders with a Retry button whose route resets the row and re-runs WITHOUT consulting the attempt counter lets a human recover work the automation gave up on.

## A Watchdog That Kills Out of Band Must Set a Kill Reason

A supervisor that terminates a job from outside the code path that reaps it leaves the reaper with only one observable: the process is gone. Absent an explicit reason, "gone" is indistinguishable from "finished", so the system reports a clean completion carrying whatever partial work existed. In one case a stall watchdog SIGKILLed a job at 6 minutes of silence; the completion poller saw a dead pid with `killReason=null` and resolved normally, so the thread showed 21 minutes of tool narration under an ordinary completion footer and no answer.

Two corollaries:
1. A silence-based liveness threshold must exceed the longest legal quiet operation. A single shell tool call may run 600s emitting nothing, so a 300s stall timeout kills healthy work.
2. The explanation must travel on the channel the user actually reads. Streaming UIs render the stream, not the returned value, so a notice appended only to the return string is invisible.

## Bare-IP SSH Fails When the Key and User Live in an SSH Config Alias

`ssh <ip> "<cmd>"` fails with "Permission denied (publickey)" when `~/.ssh/config` has no `Host` entry matching the bare IP: only the named alias carries the correct user and identity file, so a bare-IP call falls back to the local default user and the wrong key.

This silently broke a restart-storm detector: every ssh call failed, and a `|| echo 0` fallback on the restart-count check made storm detection permanently report 0 restarts regardless of the real count (verified: a known process's dry run reported 0 / "no storm" before the fix vs its real restart count / "STORM DETECTED" after). The identical bug sat in two more commands in the same toolchain. It had even been noted once before in a failures log, where an agent worked around it in-session by using the alias, but never fixed it at the source, so it kept recurring.

**Lesson:** when a documented working command references a host by raw IP, swap it for the configured alias rather than treating a one-off Permission-denied as a transient fluke. Check `~/.ssh/config` for the actual alias before re-deriving the fix each run. And fix the class at the source: an in-session workaround that isn't committed guarantees the next run hits the same wall.

## Restart Detection Must Key on the Crash-Loop Counter, Not the Cumulative One

Fixing the SSH bug above unmasked a second, more consequential bug in the same script: the storm check compared `STORM_THRESHOLD=5` against `.pm2_env.restart_time`, the **cumulative lifetime** restart count, which never resets. Any long-uptime stable production process trivially exceeds 5 (observed: 79, 182, and 233 restarts on processes with `unstable_restarts=0`, i.e. genuinely stable). A post-fix dry run reported "STORM DETECTED" for a process that was not flapping at all.

The correct field is `.pm2_env.unstable_restarts`, the crash-loop counter: it only counts restarts before `min_uptime` clears, and resets to 0 once the process is stable.

The same fix pass added three things worth copying:
- Swap the field at **both** the pre-rollback storm check and the post-rollback stability check.
- Put the target allowlist **inside the script**, not just in the calling agent's textual instructions, so a non-dry-run invocation against any non-staging process name is refused before any stop/rollback command runs.
- Normalize the empty-output case: `jq`'s `select()` with no match emits nothing at all, so `// 0` never fires, and under `set -e` an integer test on an empty string errors and can fall through to a false positive. Normalize to 0 explicitly.

**Lesson:** a script that reads a metric field by name is only as correct as the field choice. `restart_time` and `unstable_restarts` sound interchangeable but have opposite reset semantics. Always verify a restart-count threshold against a known-stable, long-uptime process before trusting it.
