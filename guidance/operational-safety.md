<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

Prevent feedback loops, restart storms, and cascading failures in automated systems.

## Self-Deploy Loop Prevention

**The scenario:** An agent job modifies the bot or service that spawned it, then deploys or restarts that service. The service restarts, recovers the "active" job from persistence, re-attaches to the still-running process, and the cycle repeats. Each restart kills in-flight work and creates cascading failures.

**How it happens:**
1. A bot spawns an agent job targeting the bot's own repo
2. The agent finishes changes and runs `pm2 restart bot` (or the equivalent deploy script)
3. The bot restarts, loads its persisted job state, finds the job still "active"
4. The bot re-attaches to the process (or re-queues the job)
5. The job, or a recovered job, triggers another restart
6. Repeat indefinitely

**Defenses (layered):**

1. **Hard guard in the deploy script:** The `deploy` and `restart` verbs check the persisted job state for active jobs before restarting the bot. If jobs are active, the command is refused with an error. This is the primary barrier.

2. **Prompt-level warning in the executor:** When a job's working directory is inside the bot's own repo, prepend a self-restart guard message to the prompt telling the agent not to restart the bot. This is a soft barrier (the agent can ignore it).

3. **SIGINT handler in the service:** The bot refuses SIGINT during startup (30s grace) and while jobs are active. The process manager sends SIGTERM to force shutdown. This prevents cascading SIGINTs from child processes.

**If a loop is already happening:**
1. Kill the stale child processes: `ps aux | grep claude | grep -v grep`, then `kill <pids>`
2. Clear the persisted jobs: edit the job state file, set `"activeJobs": []`
3. The bot will stabilize on next restart with no jobs to recover

**Rule:** Never deploy or restart a service from within a job that service spawned. Make changes, commit, push, and note that a manual restart is needed.

## Restart-Recovery Loop (Externally Triggered)

**The scenario:** A long-running job is in progress. An auto-merger merges a PR and calls the deploy script. The deploy guard sends SIGINT, but the service ignores it (active jobs). The process manager escalates to SIGTERM, force-killing the service. On restart, it loads its job state, finds the incomplete job, re-queues it, and starts running it. Meanwhile the auto-merger retries the deploy (or another merge triggers it), creating an infinite loop of: deploy, kill, restart, recover job, deploy.

**This is distinct from the self-deploy loop** because the deploy is triggered externally, not by the job itself. The deploy-script guard does not help, because the process manager force-kills after SIGINT is ignored.

**Defenses:**

1. **Recovery attempt limit:** Long-running jobs track `recoveryAttempts` in their persisted state. Each restart increments the counter. After 3 attempts, the job is abandoned instead of re-queued. This breaks the loop even if other defenses fail.

2. **Active-job check in the auto-merger:** Before calling the deploy script, the auto-merger reads the job state and checks for active jobs. If any are active, the deploy is deferred for 60 seconds and retried. This prevents the deploy from killing active jobs in the first place.

3. **Existing deploy-script guard:** Still in place as a third layer; refuses to restart if active jobs exist. But since the process manager force-kills after SIGINT, this guard only works when the process can actually be signaled gracefully.

**If this loop happens again:**
1. `pm2 stop <service>`: halt the cycle
2. Edit the job state file: set `"activeJobs": []` and `"queue": []`
3. `pm2 start <service>`: clean restart with no recovery
4. Check error logs to identify the root cause

**Prevention rules:**
- Never merge PRs to a service's repo while long-running jobs are active on that service
- If you must deploy during an active job: `pm2 stop <service>`, deploy, then `pm2 start <service>` (the job will be lost, but no loop)

## Restart Storm Detection

A restart storm is when a managed process enters a rapid restart cycle (restarts > 5 in under 5 minutes).

**Signs:**
- `pm2 list` shows high restart count (e.g. 16+) with low uptime (seconds)
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

**Field-choice trap:** a storm check that reads a process-manager field by name is only as correct as the field choice. In PM2, `restart_time` is the cumulative lifetime restart count and never resets, so any long-uptime stable process trivially exceeds a threshold of 5. The crash-loop counter is `unstable_restarts`, which only counts restarts before `min_uptime` clears and resets to 0 once the process is stable. Always verify a restart-count threshold against a known-stable long-uptime process before trusting it. Related: `jq`'s `select()` emits nothing at all when no match, so `// 0` never fires; normalize the empty-output case explicitly or a `set -e` integer test will fall through to a false positive.

## Bash `pipefail` + `grep -c` Silent Failure

**The scenario:** A script with `set -o pipefail` uses `grep -c 'pattern' || echo "0"` to count matches. When grep finds 0 matches, it outputs `0` AND exits code 1. Pipefail triggers the `|| echo "0"` fallback, producing `"0\n0"`. The variable becomes a two-line string that breaks `$(( ))` arithmetic silently: no error, just wrong values downstream.

Seen in the wild: this exact bug made a security scanner silently fail for 13 consecutive days. It was detecting secrets daily but crashing before it could report findings. The state file never updated, so it rescanned the same repos with the same silent crash every run.

**Fix:** Use `grep -c 'pattern' || true` instead. `grep -c` already outputs `0` on no match; it just needs the exit code suppressed, not a fallback echo.

```bash
# WRONG: produces "0\n0" with pipefail
count=$(grep -c 'pattern' file || echo "0")

# RIGHT: outputs "0" and suppresses exit code 1
count=$(grep -c 'pattern' file || true)
```

**Rule:** In any bash script using `set -eo pipefail`, never pair `grep` (any flag) with `|| echo`. Use `|| true` to suppress the non-zero exit code.

## A Pipeline Reports the LAST Command's Exit Code, So Never Chain a Success Message Off One

**The scenario:** You run a command, pipe it somewhere to trim the output, and chain a confirmation:

```bash
# WRONG: prints "PUSHED" even when the push fails.
git push -q origin main 2>&1 | tail -2 && echo "PUSHED"
```

Without `pipefail`, `$?` is `tail`'s exit code, and `tail` almost always succeeds. The `&&` therefore fires regardless of what the real command did. This has produced a false "PUSHED" twice in one session: once when the token lacked `workflow` scope to create `.github/workflows/`, and once when a pre-commit gate had blocked the commit so there was nothing new to push. Both times the operator was told the work was published when it was not.

This is worse than an ordinary bug, because the wrong output is a **claim about system state**.

```bash
# RIGHT: capture, test, then report
if out=$(git push -q origin main 2>&1); then echo "PUSHED"; else echo "FAILED: $out"; fi

# ALSO RIGHT: check the real command, not the pipeline
git push -q origin main; rc=$?; [ $rc -eq 0 ] && echo "PUSHED"
```

**Rule:** never end a pipeline with `&& echo "<success>"`. For anything whose success you will report, capture the exit code of the command itself, and verify the outcome against the remote or the target rather than against your own echo. After a push, run `git ls-remote origin <branch>` and compare to local `HEAD`: that checks the thing you actually care about.

## Blanket Rename Across Executable Files Is a Destructive Edit

A repo-wide `sed` looks like a rename and behaves like a rewrite. Three failures from a single session, all from the same batch of commands:

- **Delimiter collision.** `sed 's#old#new#'` against content containing `#` (every shell comment) mangled a script into a single corrupted line, prefixing all 95 lines with the replacement text.
- **Syntax destruction.** Replacing a bare word with a multi-word phrase broke a shell `case` pattern, because `some multi word phrase/*` is not a valid glob branch. The file stopped parsing.
- **Prose damage that survives review.** The same replacement rewrote a repo name *inside a path*, so a user-facing error told people to consult a nonsense path. The gate still worked; its instructions were gibberish, and nothing automated flags an absurd string.

**Rules:**
1. Never blanket-`sed` executable files. Rename with an explicit list of full paths, or a script that parses the file.
2. Pick a delimiter that cannot appear in the content (`|` for paths, never `#` against shell).
3. **Re-run `bash -n` on every touched script immediately after**, in the same command. Two of the three failures above were caught only because a syntax check followed.
4. Then read the user-facing strings. A syntax check cannot tell you a message became gibberish.

## Programmatic Edits to a Shared Config Must Preserve Formatting

Rewriting a JSON config with `json.dump(...)` reformats the **whole file**. Without `ensure_ascii=False`, every non-ASCII character is escaped, so an intended 6-line insertion arrives as a 42-line diff touching entries owned by other sessions. A secret gate then blocks the commit over a pre-existing line the edit never meant to touch.

**Rules:** pass `ensure_ascii=False` and match the file's existing indentation; then **verify the diff is only your change** (`git diff --stat` should show a plausible line count) before staging. If the diff is larger than your edit, the tool reformatted and you are now committing other people's content. And note that `git checkout -- <file>` restores from the **index**, not `HEAD`: after staging a bad rewrite, only `git checkout HEAD -- <file>` actually reverts it.

## Regenerating From a Source of Truth Deletes Whatever Only Exists Live

When a live artifact (a crontab, a DNS zone, a firewall ruleset, a service config) is generated from a checked-in source file, the source drifts **behind** the moment anyone edits the live copy directly. Regenerating then silently deletes their work, and the deletion looks like a normal install.

Encountered directly: disabling one cron entry would also have removed two credential-rotation jobs a concurrent session had added live but never recorded in the registry. Those rotations are what keep credentials from expiring, so the result would have been a silent outage weeks later, with no link back to the install that caused it.

**Rules:**
1. **Diff against live before installing**, always, and read the diff for removals rather than skimming it for your addition.
2. Build the removal guard into the generator, so it **refuses** when the rendered output drops entries. A generator that only warns gets `--force`d.
3. When the guard fires, **import the live state first**, then re-apply your change, then install. Never reach for `--force` to get past it: that is the guard working.
4. After installing, verify the entries you did not intend to touch are still present. Count them.

## Headless Claude CLI: Permission Flag Requirement

**The scenario:** A script spawns `claude -p` as a subprocess (Python `subprocess.run`, Node `spawn`/`execSync`, bash pipeline). The parent process already has `--dangerously-skip-permissions`, but the subprocess is a fresh CLI invocation that does not inherit it. When the CLI tries to use tools (WebSearch, WebFetch, Bash), it prompts for permission. With no TTY, the prompt goes to the void and the session silently fails or produces degraded output.

Seen in the wild: a research collector spawned the CLI for deep research. The top-level runner had `--dangerously-skip-permissions`, but the subprocess call did not. Every WebSearch call was silently blocked, producing reports with no web data.

**Rule:** Every `claude -p` invocation that runs without a TTY (cron, subprocess, server route, background job) MUST include `--dangerously-skip-permissions`:
- Python: `subprocess.run([CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...])`
- Node: `spawn('claude', ['-p', '--dangerously-skip-permissions', ...])`
- Bash: `$CLAUDE_BIN -p --dangerously-skip-permissions`

**Detection:** worth a repo-wide scan for CLI subprocess calls missing the flag.

**Also required: `--no-chrome`** for headless environments. The CLI may attempt to open a browser (for OAuth or a dashboard). In headless VMs or process-manager-supervised processes, this silently hangs or errors. Add `--no-chrome` alongside `--dangerously-skip-permissions` for all automated invocations:
- `claude --print --no-chrome -p "..."`
- `$CLAUDE_BIN -p --dangerously-skip-permissions --no-chrome`

### Gotcha: `claude -p` Eats the Next Argument as a Prompt String

When calling the CLI with piped stdin **and** additional flags like `--model`, use `claude --print`, **not** `claude -p`. The `-p` flag is positional: it treats the **next CLI argument** as a literal prompt string, so `claude -p --model <model-id>` passes `"--model <model-id>"` as the prompt and ignores stdin entirely.

```bash
# WRONG: -p eats --model as the prompt; stdin is ignored
echo "$prompt" | claude -p --model <model-id>

# CORRECT: --print enables stdin pass-through; --model is parsed as a flag
echo "$prompt" | claude --print --model <model-id>
```

Seen in the wild: a service used `execSync('claude -p --model <model-id>', { input: prompt })`. Every eval call passed the model flag string as the prompt instead of the real data.

**Rule:** When combining piped stdin with any extra flags (`--model`, `--output-format`), always use `claude --print` as the mode flag, not `claude -p`.

### Strip CLAUDE_CODE_* Env Vars From Subprocess Invocations

> **Note on scope:** this pattern is **defensive hygiene only**. It was once believed to be the fix for a synthetic-401 incident; isolated testing with a fully polluted env (including `CLAUDE_CODE_EXECPATH`, `CLAUDECODE=1`, and a dead `CLAUDE_CODE_SESSION_ID`) returned no error. The real cause of those 401s was an OAuth refresh being rate-limited for several consecutive cron cycles, leaving an expired access token. See "OAuth Refresh Rate-Limiting" below.

**Defensive scenario:** A long-running service that was started (or restarted) from inside a Claude Code session inherits `CLAUDECODE=1` and `CLAUDE_CODE_SESSION_ID` in its env. There is no reproducible failure from this alone, but stripping the vars when spawning a `claude -p` subprocess is cheap insurance against a future CLI behavior change that might treat a nested-session-marker env as special.

**When to apply:** Long-running services (supervised daemons, server routes) where the inherited env is opaque or stale. Not required for cron jobs that already start with a clean env.

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

**Why a process manager captures these vars:** PM2 (and similar) capture the full env at daemon start, including any `CLAUDE_CODE_*` vars from the terminal session that ran `pm2 restart`. The vars persist in the process table for the lifetime of that process slot, even across subsequent restarts, until the daemon itself is restarted from a clean environment.

**Also strip `NODE_CHANNEL_FD`** when launching non-Node subprocesses from a Node.js parent (for example, a Python worker called from a Node service). Node.js IPC sets `NODE_CHANNEL_FD` in its own env; child processes that themselves use Node runtimes (such as a media downloader's JS challenge solver) inherit this FD reference and can fail with IPC errors because the FD is already closed or invalid in the new process.

```python
env = kwargs.get("env") or os.environ.copy()
if "NODE_CHANNEL_FD" in env:
    del env["NODE_CHANNEL_FD"]
kwargs["env"] = env
```

### OAuth Refresh Rate-Limiting

**The scenario:** a token-refresh script runs on a fixed cron interval and calls the OAuth token endpoint with a `refresh_token` grant. The endpoint is **rate-limited**, and under load can return `rate_limit_error` for multiple consecutive cron cycles.

Seen in the wild: four consecutive 3-hourly cycles failed with `rate_limit_error`. The access token expired about 7 hours into the failure window. Every daemon doing `claude -p` during that window got a synthetic 401 with `model: <synthetic>` and `result: "Failed to authenticate. API Error: 401 Invalid authentication credentials"`. The CLI's `--output-format json` returns this as `is_error:false` `subtype:success` (confusingly), so the failure is not visible via subprocess exit codes, only by parsing the `result` field for the auth-error string.

**Detection signal:**
- The `result` field of `claude -p --output-format json` contains "Failed to authenticate" or "401 Invalid authentication credentials"
- The refresh log shows `ERROR: OAuth refresh failed: rate_limit_error` on consecutive cycles
- Daemons silently fall back to degraded mode

**Mitigations to build into the refresh script:**
1. **A refresh threshold of several cycles' margin** (for a 3-hourly cron, refresh at 6h remaining) so it refreshes about 3 cycles before expiry instead of 1.
2. **Intra-cycle retry with backoff:** up to 3 attempts per run; back off longer on `rate_limit_error` (60s, then 240s) than on other failures (30s).
3. **Consecutive-cycle failure counter** stored in a cache dir. After 2 or more consecutive failures, alert on your notification channel with hours-remaining context. Reset the counter on any successful or healthy cycle.

**When the consecutive-failure alert fires:** the API refresh path is stuck. Do NOT wait for the next cron cycle: trigger the browser-based re-login path. The browser OAuth flow is not subject to the API rate limit and will recover the token immediately.

**Layered defense, browser path as safety net:** the cron refresh path and the browser-based re-login path are independent recovery mechanisms. When the OAuth API endpoint is rate-limiting, the browser path completes `claude auth login` via the web OAuth flow, bypassing the API endpoint entirely. Observed in sequence: a manual run and the next cron cycle both exhausted all retries with `rate_limit_error`; the browser re-login chain an hour later sidestepped the rate-limited endpoint; the following cron cycle ran clean with the counter reset to 0.

**Implication:** When debugging a prolonged OAuth failure, check both paths. If the cron log shows persistent `rate_limit_error` and the access token is expired, the recovery path is NOT to wait.

### React SPA Hydration Race in Browser-Driven OAuth Scripts

**Symptom:** A browser-automation script clicks the OAuth Authorize button. The click reports success but nothing happens: no navigation, no callback. The same script works fine minutes later.

**Why:** React SPAs render the DOM before hydrating (wiring up event listeners). The Authorize button can be visible and selectable during this gap but fires no event when clicked. The window is typically under 2s but is reproducible on freshly-woken browser sessions.

Seen in the wild: one container's relogin failed with "callback tab not found" while two sibling containers running the identical script minutes later succeeded. The fix: add `sleep 4` after locating the consent tab, then retry the click once if no callback appears within 25s.

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

**Rule:** Never do unbounded retries on a consent button. If two attempts both produce no callback, escalate to your notification channel; the problem is something other than a hydration race (rate limit, broken page, wrong selector).

### Auth-Age Enforcement: All Sessions Fail Simultaneously

**Symptom:** All automated relogins fail on the same night with `callback tab not found`. The browser session IS active (the provider's app shows the account logged in), but clicking Authorize redirects to a re-auth/login URL instead of the OAuth callback.

**Root cause:** The provider enforces a **max auth-age**, the elapsed time since the account last performed a real sign-in, in addition to activity-age, before granting OAuth scopes. A session-keepalive script slides the activity clock but cannot reset the auth-age clock. When auth-age exceeds the threshold, the consent flow forces a full logout regardless of session freshness.

**Differentiator from the hydration race above:** all containers fail on the same night. The hydration race is a single-container, timing-based event that a retry resolves. Simultaneous failure across units is diagnostic of the auth-age pattern.

**Why automation may not self-heal:** after the forced logout, the OAuth grant page can land on a federated "Continue with <provider>" button whose popup the browser blocks for extension-synthetic clicks (it requires a real user-activation gesture).

**A refresh token carries its own expiry.** This is the load-bearing fact. `refreshTokenExpiresAt` is roughly 28 to 30 days out, reset only by a successful **interactive** rotation and NOT extended by ordinary refreshes. So a broken rotation does not surface for weeks: the fleet has about four weeks of runway and spends all of it silently. Any credential that idles past that window wakes up unable to refresh; the CLI then writes the credential file back with **empty-string** `accessToken`/`refreshToken` and `expiresAt: 0`, and the health endpoint reports `auth: "failed", "OAuth session expired and could not be refreshed"`. Nothing automated can recover that state, because minting a new refresh token requires the interactive login that auth-age is blocking.

Measured after 11 nights of un-repaired auth-age failure: 7 of 9 containers dead, each with a blanked credential and a `refreshTokenExpiresAt` in the past. Each died roughly 30 days after its last successful rotation. The two survivors were the two whose chains never missed a refresh.

**Rule:** treat an auth-age failure as a deadline, not a steady state. Build the alarm that actually measures it: a daily job that reads `refreshTokenExpiresAt` for the host and every running container, warns under 20 days and pages under 10. That one field measures both how long until a credential is unrecoverable and how long rotation has been failing, and it does not care *why* rotation stopped, so it also catches the quiet skip (a pre-flight that exits 0 when the browser is asleep is right for one night and fatal over a fortnight). Have relogin scripts close the tabs they open, because leftover debris from run N is the bug in run N+1. The alarm that matters is the blank-credential page, not the nightly relogin email.

**Lessons from untangling this class (all generalizable):**

1. **A script that sources an env file after receiving env from its caller must re-assert the caller's values, or the file silently wins.** Moving secrets into a shared env file plus `set -a; . "$HOME/.env"; set +a` let the file beat the per-invocation override. Every alternate-profile rotation was invoked as `KEY="$KEY_ALT" ...` and, from that day, drove the **default** profile instead: it opened one account's consent URL in a browser signed in as a different account, and the chooser it reached never contained the expected address. Every "the session is logged out" alert described a profile the run never touched.

2. **A per-key operation gated on a global signal reports on the wrong thing.** A browser-automation service exposed a single un-keyed tab registry (every API key saw the union of tabs from both profiles) while *commands* routed per key to one profile. So `ensure <url>` matched a URL, handed back the **other** profile's tab, and every later read on that id timed out. The keepalive script was therefore reading the wrong profile's tab and certifying its session daily, logging "session appears alive" while the real session aged out and logged itself out. Its content check was correct; it was pointed at the wrong browser. Same bug in the relogin pre-flight, which gated on a global `connectedClients` count: one awake profile satisfied it while the other extension was absent. Fix: probe ownership with a keyed ping, and gate on a per-key status. **Rule:** if a check is per-profile, per-key or per-tenant, its signal must be too, and "I could not read it" is never evidence of health.

3. **Muting an alert by call site means the mute silently moves.** A suppression keyed on the *post*-Authorize classifier (one exit code, one wall kind). When the session went from stale to fully signed out, the identical wall began failing one call site **earlier**, at the pre-Authorize check with a different exit code, which was not suppressed. Six emails a night resumed with **no code change on either side**. **Rule:** suppress on the *classified condition*, and make the classification reachable from every path that can produce it; a mute pinned to one exit code expires the moment the failure moves.

4. **A popup is a separate WINDOW, so it is never "visible."** Focusing a *tab* does not raise its *window*, so the popup's document sits at `visibilityState: "hidden"` and the browser does not deliver CDP input events to an unrendered page. Twelve consecutive synthetic clicks reported success at the button's real coordinates while the page never moved; one `el.click()` on the same hidden page advanced it instantly. **Rule:** inside a popup window, use JS clicks. Reserve trusted CDP clicks for the one button that genuinely needs user activation (the one that calls `window.open`).

5. **Extension manifest `exclude_matches` can make a page invisible to a tab registry.** If the registry is fed by content-script heartbeats, an excluded origin can never appear in a tab listing, and the entire branch that handles it becomes unreachable code. Query tabs via the browser API from the service worker instead.

6. **Match provider states by keyword, not by fixed path.** Providers *version* their consent paths (two profiles hit different path versions on the same day, and the matcher knew neither the new one nor any future number). Also match the **decoded** URL: a login redirect can carry the target percent-encoded in a `returnTo` parameter, so a matcher requiring a literal `oauth/authorize` reports "consent tab not found" about a tab sitting right there.

7. **A stale tab hijacks the loop forever.** A leftover error-page consent tab with no buttons classified as "consent," clicked nothing, every round, while the real wall was never touched again. Snapshot the relevant tab ids at entry and ignore pre-existing ones: a popup you did not open is not yours to drive.

8. **An unclassifiable page needs an exit, and its URL must be logged.** A catch-all state with no clearing branch "settles" the same page a dozen times, logging nothing but the word. Always log the URL of a page you could not classify.

9. **Select a button by visible label, not by an obfuscated attribute.** On some consent pages Cancel and Continue share the same generated `jsname`.

10. **Do not warn on the normal case.** A script warned "restart had errors" on every successful run, because the restart command was being called with no arguments and an empty list is the normal case.

### Claude CLI Binary Path

The CLI binary may be at `/usr/bin/claude` rather than `/usr/local/bin/claude`. Using the wrong fallback path causes silent `[Errno 2] No such file or directory` failures that drop all AI processing with no obvious error in service logs.

**Rule:** Always prefer a `CLAUDE_BIN` env var over hardcoding, and verify the fallback with `which claude` on each host:

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

**The scenario:** A service wraps `claude -p` (via `spawn` or `execFile`) and reads stdout for the AI response. When the account hits its usage limit, the CLI exits with code 0 but outputs a rate limit message instead of a real response (for example, "You've hit your limit... resets 3:50pm PT"). The service treats this as a successful result, returning garbage content to the user.

Seen in the wild: a service returned rate limit text as a "completed" buying guide. Jobs were marked successful with useless content because the wrapper only checked the exit code, not the output content.

**Fix:** After collecting stdout from any `claude -p` subprocess, check for rate limit patterns before treating the output as valid:

```javascript
const output = stdout.trim();
if (output.match(/you've hit your limit/i) || output.match(/resets \d+:\d+[ap]m/i)) {
  // Return 429 or retry error, NOT success
  return { error: "AI at capacity", status: 429 };
}
```

**Rule:** Any service wrapping the CLI must detect rate limit responses and translate them to errors (HTTP 429 or equivalent). Do not rely on exit codes alone; rate limit messages arrive on stdout with exit code 0.

### Detecting it is half the job; the other half is a parking lot, not a retry

Translating the limit to an error stops the garbage, but it hands the user a failed job they have to re-issue by hand. Routing it into an existing retry ladder is worse: a 1/2/4-minute exponential backoff cannot return quota, so the retries are spent against a condition they cannot change and the job fails anyway. Same shape as the restart-storm rule below: the remedy must address the condition.

The working pattern (a `usageLimit` classifier plus a `parkedJobs` store):

1. **Classify at the single choke point** every spawn path funnels through, not at each call site. Prefer the structured signal (`rate_limit_event` with `status: "rejected"` in stream-json) over string matching, and scope it *per job*: a global "over cap" gauge that also flips on `allowed_warning` will park jobs that finished fine.
2. **Match wording as a family, and gate loose patterns on output length.** The CLI says `your limit` / `your session limit` / `your weekly limit` / `Claude AI usage limit reached|<epoch>`. When it is genuinely out of quota the rejection notice is the *entire* output, so shortness is the tell; that bound is what stops a long agent report which merely *discusses* rate limits from parking itself.
3. **Exclude it from `isRetryableError()` explicitly.** A `/rate.?limit/i` entry in a retry list is a trap here.
4. **Park, notify, and restart on a timer.** Persist the job (it must survive a process restart), tell the user *when* it will resume rather than that it failed, and re-dispatch after the stated reset plus a buffer; the reset boundary is the server's clock, not yours. No stated reset means a real wait (an hour), not a fast retry.
5. **Unpark before dispatch**, so a resumed run that hits the wall again re-parks cleanly instead of doubling.
6. **Keep the attempt count outside the parked entry.** The entry is deleted at dispatch, so a job that re-parks reads no history off it, restarts at attempt 0 forever, and never reaches the cap. Memoise the count under a stable identity (source plus message id) and clear it once a resume goes through.
7. **Cap it and say so.** Bound by attempts and by age, and when you give up, post that you gave up. Silence is indistinguishable from still-waiting.

## `set -e` Makes Post-Hoc Exit-Code Capture Dead Code

**The scenario:** A runner script uses `set -euo pipefail`, invokes a fallible command as a bare statement, then tries to handle failure afterwards:

```bash
set -euo pipefail
timeout 2700 claude -p "$PROMPT" > "$LOG"   # non-zero exit kills the script HERE
EXIT_CODE=$?                                 # never reached on failure
if [ "$EXIT_CODE" -eq 124 ]; then ...        # dead code
```

Under `set -e`, any non-zero exit terminates the script before `EXIT_CODE=$?` runs. Every downstream failure path (timeout logging, alerts, state writes, cost tracking) is unreachable. The same applies to command substitution: `RESULT=$(claude ...)` exits the script before the failure branch. A subtle variant: `OUT=$(cmd || true); RC=$?`, the `|| true` guarantees `RC` is always 0, silently disabling the gate that reads it.

Seen in the wild: three autonomous runners plus a verify script all had this bug. Zero failure alerts had ever fired across roughly 1,000 combined runs; a 45-minute run timed out with no log entry, no state write, and a reused run ID the next day; the verify gate passed proven test failures for weeks.

**Fix:** capture the exit code in the same statement so `set -e` never sees the failure:

```bash
EXIT_CODE=0
timeout 2700 claude -p "$PROMPT" > "$LOG" || EXIT_CODE=$?
```

**Rule:** In any `set -e` script, a command whose failure you intend to handle must have its exit captured via `|| VAR=$?` (or run inside an `if`). Never write a bare command followed by `$?`, and never read `$?` after `|| true`. Audit: `grep -n 'EXIT_CODE=\$?\|_EXIT=\$?' <script>`, each hit must be on the same line as the command it measures.

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

Seen in the wild: a health monitor on a 15-minute cron died at its first `vlog` call on every single run for its entire deployed life. Its log showed only `START:` lines. It never completed a check, never posted an alert, and nothing noticed, because the thing that died WAS the alerting layer. Its own cron scheduling was verifiably fine: **a heartbeat at the start of a run proves scheduling, not completion. Freshness checks must key on an end-of-run marker.**

**Fix:** `if [ -n "$VERBOSE" ]; then log "$*"; fi` (an `if` whose condition is false returns 0), or end the function with `|| true` or an explicit `return 0`.

**Rule:** in `set -e` scripts, never end a function body with a bare `[ cond ] && cmd`.

## Cron Output Redirects Into Root-Owned Dirs Die Silently

**The scenario:** a non-root crontab line redirects into `/var/log/`:

```
*/5 * * * * $HOME/bin/watchdog.sh >> /var/log/watchdog.log 2>&1
```

The shell opens the redirect target BEFORE running the command. If the dir is not writable by the cron user and the file does not exist, the open fails and **the command never runs at all**: every occurrence, forever, with no trace beyond an unread cron mail. The trap is asymmetric: if the log file already exists (created earlier when perms allowed, or pre-touched by root), appending works, so some `/var/log` crons keep working while their siblings are dead, which defeats "the other one works, so the pattern is fine" reasoning.

Seen in the wild: `/var/log` was root-owned 755 and 9 of 11 user cron entries redirecting there were dead, including both process watchdogs, the uptime monitor, the error aggregator, the restart alerter, a sync job, a daily restart, a database guardian that never ran once, and a state backup whose last artifact was 4 months old. The 2 survivors had pre-existing log files. One dead cron had been individually "fixed" earlier by pre-creating its log file: the instance was patched, the class was not.

**Rules:**
- Non-root cron output goes to a user-owned dir (`$HOME/logs/cron/`); never redirect cron output into `/var/log` as a non-root user.
- When you find one broken cron redirect, audit the whole crontab for the class: `crontab -l | grep '/var/log'`.
- Every watchdog or monitor needs periodic end-to-end verification: does its log show a run **completing** (not just starting) within the last interval, and can it still deliver its alert? A monitoring stack in which every layer dies silently is the default failure mode, not the exception.

## Hook Loop Prevention

Auto-posting hooks run on every agent turn. If a hook failure triggers a retry or a new session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new agent sessions without recursion guards.
- Hooks must have timeouts (10s max). A hung webhook should not block the session.
- If a hook fails, log the failure and continue. Do not abort the parent session.

### Stop Hook Safety

Classify Stop hooks in tiers: Tier 1 observation (log only), Tier 2 verification (read state, no model calls), Tier 3 model-invoking. All Tier 3 hooks need a shared guard providing an env var circuit breaker, a PID lockfile, and a per-hour rate limiter.

Seen in the wild: a Stop hook ran a session scorer (`claude -p --model haiku`) on every session exit. The scorer's own session exit re-triggered the hook. Result: 4,888 recursive sessions in one day and 199M tokens, 78% of the week's usage. Fixed with an env var guard plus a content pattern match, then standardized into a shared guard library.

## Concurrent Sessions in One Checkout

Two distinct problems, two distinct remedies:

- **Shared tree:** two sessions editing the same checkout clobber each other and strand branches. Use a worktree per session: `git -C <repo> worktree add /tmp/<label> -b <branch>`.
- **Singletons:** anything that must run once (a daemon, a migration, an installer) needs a real lock, not a check-then-act. Use a PID lockfile or `flock`.

When something keeps reverting, check in this order: is another session writing the same file, is the branch the one you think it is, and is there a background job re-generating the file.

Note the meta-lesson: this topic once grew three separate homes in one afternoon, written by three sessions that could not see each other, which is the problem itself in miniature.

## Job Recovery Safety

When a service recovers persisted jobs on startup:
- **PID alive:** Re-attach and monitor for completion. Do not re-execute.
- **PID dead:** Extract partial output, mark as failed, notify the user. Do not re-run automatically.
- **Partially complete multi-turn job:** Re-queue from the last completed turn, not from scratch.

**Never** automatically re-execute a failed job. The failure may have been caused by the job itself (for example, it deployed the service). Automatic re-execution would repeat the failure.

## Unattended Jobs That Take Irreversible External Actions

A cron job that spends money, sends a message, cancels a subscription, or files something is not a normal cron job: a bug does not just fail, it does the wrong thing to the outside world, and nobody is watching when it happens. Five requirements, all of them cheap:

1. **Gate on identity, not just success.** Before the irreversible step, assert the thing in front of you is the thing you meant: expected item/recipient name, expected quantity. Refuse and report on mismatch. A checkout page that loads fine is not evidence it holds the right cart.
2. **Cap the magnitude.** A hard ceiling (`MAX_TOTAL`) turns a pricing change, a currency bug, or a duplicated line item into a refusal instead of a charge.
3. **Idempotency guard.** Keep a per-period state file (`$HOME/.state/<job>-last-*.json`) recording the period already completed, and check it first. Without this, a manual re-run, a retry, or two overlapping schedules double-execute. This is the single highest-value guard, because retries are otherwise unsafe to add.
4. **A `--dry-run` that stops immediately before the irreversible call** and exercises everything up to it. This is what makes the job testable at all; without it the only test is doing the thing for real.
5. **Report every outcome, including failure.** Silence must never be the success signal. Alert on success, failure, AND skip.

**Retry windows: separate transient blockers from real failures.** A job that depends on something ambient (the browser being open, a VPN, the laptop being awake) cannot be scheduled at one fixed time and called reliable. Sweep a window instead, but only if the alerting is retry-aware, or an outage becomes a dozen identical emails and the next real alert gets ignored:

- **Transient** (dependency not ready yet, a later attempt may clear it): log, stay silent during the window.
- **Real** (failed gate, missing credential, unparseable confirmation): alert immediately; a human is needed and more attempts will not help.
- **Already done** (idempotency guard fired): silent. This is the steady state.
- **Close the window with one `--final` run** that alarms if the period never completed. That single alert is the "we missed it" signal, and it fires once.

**Related:** if the job drives a browser, parse the confirmation for a real identifier (an order number) before claiming success. Never trust that the click "worked".

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

Add the entry to the project's `context.md` under a "Known Issues" or "Incident Log" section so future sessions are aware.

## Irreversible Content Deletion

When bulk-deleting content on external platforms (video hosts, social media, cloud storage), apply strict safeguards:

1. **Gather and confirm first.** Build the full list of items to be removed and present it to the user for confirmation before deleting anything. This catches mistakes in date ranges, filters, or account selection.
2. **Restrict to safe content types.** Only auto-generated or temporary content is eligible for bulk deletion (unlisted short clips, draft posts). Never bulk-delete public, private, or manually curated content.
3. **Filter by metadata.** Apply duration, privacy status, date range, and ownership filters to exclude anything that should not be touched (for example, skip full-length videos when deleting shorts by filtering to <=90s).

**Why:** Platform deletions are irreversible. A wrong date range or missing filter can wipe out manually curated content.

## Verify Before Asserting

Do not claim the user did something (submitted an application, sent an email, published a post) unless you can verify it through an authoritative source. The existence of prep materials, drafts, or related files does NOT confirm the action was completed.

**Why:** an agent asserted the user had applied to a role because prep materials existed in cloud storage. The application was never submitted, and incorrect context was passed on to a third party as a result.

**How to verify:**
- **Applications/emails:** check the mailbox for sent confirmations
- **Published posts:** check the live URL
- **Deploys:** check process status and server logs
- **Git pushes:** check `git log origin/main` or `gh pr list`
- **Any user action:** look for the completion artifact, not the preparation artifact

## Health Monitor Self-Exclusion

**When writing a health monitor or watchdog that scans supervised processes, always skip the monitor's own process.**

If a health monitor watches all processes, including itself, it can trigger auto-immune loops: the monitor detects its own high restart count, attempts to fix it, restarts itself, which increments the restart count, which triggers another fix attempt.

```python
for proc in processes:
    name = proc["name"]
    if name == MY_PROCESS_NAME:  # skip self
        continue
    # ... health checks
```

Seen in the wild: a fix-handler scanned all managed processes including itself. Widening its dedup window (1h to 24h) was also needed to prevent repeated self-triggering within a single incident window.

**Rule:** Any monitoring daemon that calls `pm2 jlist` (or equivalent) and iterates over processes must exclude its own process name from health checks.

### Process-Manager Log Artifacts and ANSI Codes in Error Handlers

Three related patterns that cause error-handler crash loops or alert floods when reading process-manager log output:

**1. Log format artifacts in IGNORE_PATTERNS**

Process-manager log output contains formatting lines that are not actual errors: separator lines (`---`), the log command echo, and the handler's own prefixed log lines. Without ignore patterns for these, the handler classifies them as errors and alerts or loops on its own output.

```python
IGNORE_PATTERNS = [
    r"\[error-handler\]",  # handler's own log prefix
    r"pm2 logs",           # log command echo
    r"^---$",              # separator lines
]
```

**2. ANSI escape codes break dedup signatures**

Process managers sometimes emit ANSI escape sequences in log lines (color codes, cursor movement). If not stripped before computing the error signature hash, the same underlying error produces different hashes across restarts, and you get an alert flood.

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
# BAD: "SUCCESS:" could be caught by a pattern scanner watching for status keywords
logger.info(f"SUCCESS: fix complete (cost: ${cost:.4f})")

# GOOD: plain message; log level already communicates severity
logger.info(f"fix complete (cost: ${cost:.4f})")
```

## Shared Poller Resource Gates Must Be Scoped to the Executing Machine

When a poller or executor dispatches jobs to BOTH local and remote workers (a local run function and a remote-over-SSH one), any resource gate based on the local machine's resources (RAM, CPU, disk) must NOT fire for remote jobs: those jobs consume zero local resources.

Seen in the wild: a multi-worker dispatcher had ONE memory watchdog for all jobs. When local `MemAvailable < 100MB`, it killed the tracked PID. For remote SSH jobs the tracked PID was only the SSH client; the real work ran on the remote worker using zero local memory. Local memory pressure was killing healthy offloaded sessions. Symptom: the log showed "Memory watchdog: only 93MB available, killing process PID" while dispatch counts showed only remote dispatches and zero local ones.

**Fix pattern:** Add a `skipMemoryWatchdog` (or equivalent) flag to the polling function. Set it to `true` for remote-dispatched jobs. Timeout and output-size watchdogs can still apply to remote jobs (they guard a hung SSH connection or runaway output regardless of location).

**Rule of thumb when adding any resource guard to a shared poller:** ask "does this resource live on the machine actually running the session?" If the job is remote, local RSS/mem/CPU is irrelevant.

## A Repo's Main Checkout Must Never Be Left on a Merged Feature Branch

**Symptom:** the primary working copy (not a worktree) is checked out on a feature branch whose PR has already been merged. The local branch is stranded and local `main` (or `production`) silently falls behind `origin`, sometimes by several commits, with no error surfaced anywhere.

**Why this is worse than an ordinary stale branch:** SessionStart hooks, CLAUDE.md loads, and guidance-file reads for every concurrent session on that machine execute against whatever is checked out in the main checkout. A stranded branch means every other session (interactive or automated) silently reads outdated or divergent guidance. The failure can originate from **any** session that does a plain `git checkout <branch>` in the main checkout to open a PR (rather than using a worktree) and never switches back after the merge.

**Detection:** in any repo's main checkout, `git branch --show-current` should always equal that repo's default branch, except for the brief window a human is actively working on a real feature. If it is not, check whether the current branch's PR is already merged (`gh pr list --head <branch> --state all`); if so, the checkout was simply never returned home.

**Fix:** verify the current branch is a strict subset of `origin/<default>` first (`git diff origin/main HEAD --stat` should be empty or default-only), then `git checkout main && git merge --ff-only origin/main && git branch -d <stale-branch>`. Do not force anything. If the diff is not empty, treat it as in-progress human work: stash or investigate, do not discard.

**Prevention:** any session opening a PR from a main checkout should use `git -C <repo> worktree add /tmp/<label> -b <branch>`, work there, and leave the main checkout untouched on its default branch throughout.

## Never Inline Single-Quoted Code in `ssh 'block'`

`ssh host 'big block ...'` wraps the whole remote command in single quotes. Any single quote INSIDE the block (JS `app.get('/path', ...)`, Python `'text/plain'`) terminates the outer quote and silently mangles the code. This has shipped invalid JS to a production server file and crash-looped the service.

**Fix:** write the script or patch to a LOCAL file and `scp` it, then run `ssh host 'python3 /tmp/file.py'`. Always syntax-validate on the remote host (`node --check`, `bash -n`, `python -m py_compile`) BEFORE restarting, and keep a `.bak` to restore.

### Reference a Host by Its SSH Config Alias, Not a Bare IP

`ssh <ip> "<cmd>"` fails with "Permission denied (publickey)" when `~/.ssh/config` has no `Host` entry matching the bare IP: only named aliases carry the correct user and identity file, so a bare-IP call falls back to the local default user and the wrong key.

Seen in the wild: this silently broke a restart-storm detector. Every ssh call failed, and a `|| echo 0` fallback on the restart-count check made storm detection permanently report 0 restarts regardless of the real count. The same failure had already been noted once in a failure log (an agent worked around it in-session by using the alias) but was never fixed at the source, so it kept recurring.

**Rule:** when a documented working command references a host by raw IP, swap it for the configured alias rather than treating a one-off Permission-denied as a transient fluke. Check `~/.ssh/config` for the actual alias before re-deriving the fix each run. And note the compounding failure: a `|| echo 0` fallback on a broken command converts a hard error into a permanently wrong reading.

## Audit the CLI Version on Every Host, and Pin Fan-Out Defaults Before Upgrading

CLI version drift silently keeps already-fixed reliability bugs in play, and headless hosts drift worst because nobody watches their startup banner. In one audit, the interactive host was 19 versions behind and a server host 8 behind, leaving both exposed to fixed bugs (a truncated-tool-output memory leak, stream-json output truncated at exit for slow-reading consumers, and quadratic message-normalization stalls in long sessions).

Rules:

1. Check `claude --version` against `npm view @anthropic-ai/claude-code version` on EVERY host that runs the CLI (workstation, servers, containers), not just the interactive one.

2. Pin fan-out and search behavior BEFORE upgrading, because upgrades change defaults underneath you: one release raised the default nested-subagent spawn depth from 1 to 3; another added a session-wide 200-call WebSearch cap. Set `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` explicitly so an upgrade never changes spend or research depth implicitly. Implicit depth-3 nesting can outrun what a usage gate reasons about, since the gate models the fan-out the top-level session controls.

3. Set `fallbackModel` (array, max 3 entries, does NOT merge across settings files) on every host running headless runners. Without it, a runner hard-fails when its primary model is unavailable or overloaded.

4. Verifying a settings change means launching the CLI and getting a reply, not just parsing the JSON. An unsupported or misspelled settings key is accepted silently and does nothing. Corollary: env vars introduced in a version NEWER than the installed CLI are inert until the upgrade lands, so setting them is upgrade-preparation, not an active change.

5. **Containerized installs drift worst, and the host version tells you nothing about them.** An unpinned `RUN npm install -g @anthropic-ai/claude-code` freezes each image at whatever was latest at build time and never moves again. In one audit, eight live containers sat three to six minor versions behind their hosts.

   **Match the fix list to how the consumer actually invokes the CLI before calling drift urgent.** The first pass of that audit asserted the containers were exposed to three specific fixed bugs. Reading the server code refuted all three: the containers spawn `claude -p` and accumulate PLAIN stdout (no `--output-format stream-json`), attach NO MCP servers, and run one-shot per request rather than long sessions. Version drift is real, but a fix only matters if the invocation path touches it. Check the spawn arguments, not the version number alone.

   Two consequences that do hold:
   - **Pin the version in the Dockerfile** (`@anthropic-ai/claude-code@<version>`). Unpinned means every rebuild is a silent, unreviewed upgrade that can change defaults (see rule 2), and builds are not reproducible.
   - **Rebuild on a cadence, not on demand.** An unpinned image that is never rebuilt is the worst of both worlds: frozen on an old version AND guaranteed to jump many versions at once whenever it finally is rebuilt. Enumerate with `docker exec <container> claude --version` per container.

### Unpinned Docker Installs Make Rebuilds a Silent No-Op; `docker exec` Probes as Root and False-Alarms on Auth

Rebuilding a container fleet surfaced two traps that make a rebuild look successful when it did nothing, and make a working service look broken.

1. **An UNPINNED install plus Docker layer cache means `docker compose build` is a silent no-op.** One container rebuilt cleanly and came back on its old version. Its `RUN npm install -g @anthropic-ai/claude-code` line was byte-identical to the previous build, so Docker reused the cached layer and never re-ran npm. The others upgraded ONLY because pinning the version changed that line and busted the cache. An unpinned image is doubly bad: it freezes at build-day latest AND resists the rebuild you would use to fix it. Either pin the version (preferred, and the cache-bust is a feature) or build with `--no-cache`. Always assert the version INSIDE the container after a rebuild (`docker exec <c> claude --version`); never infer success from a clean build log.

2. **`docker exec <container> claude -p ...` runs as ROOT and reports "Not logged in", even when the service is perfectly authenticated.** Credentials live under the service user's home (e.g. `/home/node/.claude/.credentials.json`), but root's HOME is `/root`, so the CLI finds nothing. This looks exactly like a rebuild wiping credentials and will trigger a false rollback. Probe as the service user instead: `docker exec -u node -e HOME=/home/node <c> claude -p "..."`. Confirm any suspected breakage against an un-rebuilt container as a control before acting.

3. **`auth=pending` on a health endpoint immediately after a rebuild is expected, not a failure.** If the auth check runs on a long interval (say 30 minutes) with the first check about 60s after start, wait for the "checked N seconds ago" field to be populated before judging.

Credentials survive a rebuild when they live in a named volume mounted at the service user's `.claude` dir rather than in the image, so `docker compose build && up -d` preserves them and no re-OAuth is needed.

## The CLI Sandbox Is Not Usable Inside Docker or on WSL2

Investigated and CLOSED as not-applicable in both environments. This corrects an intuition that a network strict-allowlist sandbox is a high-value hardening step for containerized agents.

**Containers cannot use it.** The sandbox is enforced by bubblewrap, which requires unprivileged user namespaces. Inside a container, `bwrap` fails with `Creating new namespace failed: Operation not permitted`, including the weaker variant that binds the existing `/proc`. The host kernel is not the blocker (`/proc/sys/user/max_user_namespaces` reads fine inside the container); Docker's default seccomp profile blocks `CLONE_NEWUSER`. Enabling it would require running with `--privileged`, `--cap-add SYS_ADMIN`, or `seccomp=unconfined`.

That trade is backwards: it punches a hole in the OUTER isolation boundary in order to add an inner one, on containers whose entire purpose is isolating untrusted public input. **For a container, the container IS the sandbox.** Do not weaken it to add a nested sandbox. A "weaker nested sandbox" option does not rescue this: it addresses a container that cannot mount a fresh `/proc`, not one forbidden from creating namespaces at all.

**WSL2 cannot use it either, for a different reason.** On WSL2, sandboxed commands cannot launch Windows binaries or anything under `/mnt/c/`. If your primary working directory is on the Windows filesystem and Windows interop is routine, enabling the sandbox breaks that wholesale. `docker` is separately documented as sandbox-incompatible.

**Where the real mitigation lives instead.** If the exposure that motivated this was a broad `Bash(curl:*)` permission on untrusted public input, and the OS-level sandbox is unavailable, the controls that DO apply are: a narrow `--allowedTools` list, account isolation, the container boundary itself, and an output scrubber. Harden those.

**Verify before reopening:** run `docker exec -u root <container> bwrap --ro-bind / / --dev /dev echo ok`. If it still prints `Operation not permitted`, this conclusion stands.

## A Recovery Action That Cannot Fix the Condition Must Be Gated on Classifying the Condition First

Restart storms come from a health check with fewer states than reality. An auth-refresh watchdog had two: `ok` and "not ok", where "not ok" meant stale credentials and the remedy was recreating the container. Being out of quota also reads as "not ok", so it inherited a remedy that cannot return quota: 1,273 container recreates across six services, tearing down and rebuilding every 10 minutes for the length of each limit window, plus an alert telling the operator to run a login command for a condition login cannot fix.

The diagnostic that settles it is correlation across independent units. Six services have six independent credential files, and the recreates fired in lockstep at the same minute on consecutive nights. Independent files do not go stale in the same second; one shared account runs out of quota in the same second. **Lockstep failure across units that share exactly one thing points at the shared thing.**

Rules:
1. Before wiring an automatic remedy to a failure state, ask which conditions land in that state and whether the remedy addresses each. If it addresses only some, classify first and let the others fall through to a wait.
2. Detect operational strings by wording family, not one literal. The CLI says "your limit", "your session limit", "your weekly limit", and the reset stamp may carry no minutes ("resets 3am (UTC)"). A guard pinned to one literal silently stops matching when the vendor rewords, and the failure is invisible because the wrong branch still runs. Scope loose patterns to short output so real content quoting "limit" is not swallowed.
3. Put the classifier where the condition is observed (the health endpoint), and keep a wording fallback in the consumer, so the fix applies to already-running processes without a rebuild.
4. A recovery loop that re-runs on a fixed interval should record what it observed, not just what it did. These logs said "auth=failed, recreating container" and never printed the error text, so the misclassification was invisible for months in plain sight.
5. Alert text is part of the fix. An alert naming the wrong remedy trains the operator to distrust the alert.

Applies to any watchdog: process restarts, container recreates, auth refreshers, stale-job requeues.

### A Destructive Remedy Must Be Gated on a Positive Match, Never on "Not One of the Known-Benign Cases"

Third instance of one bug in a single auth-refresh cron, each fixed by carving one more benign condition out of a catch-all, until the catch-all itself was recognised as the defect.

The shape: a health probe returns ok / known-benign / everything-else, and "everything else" is wired to a DESTRUCTIVE remedy (here `docker compose down && up` every 10 minutes). Fixes went: a usage limit is not bad credentials (1,273 recreates), then a blank credential file is not bad credentials, then a transient CLI error is not bad credentials. Each carve-out was correct and none addressed the structure. The classifier's default branch was "the expensive, destructive answer", so every unfamiliar string became a restart.

Measured cost: `claude -p` returned the bare string `Execution error` (which that CLI also emits for upstream 5xx, network blips, and the caller's own spawn timeout). The cron recreated the container three times in 30 minutes. One teardown destroyed a user's research job 25 seconds after it started; the user saw a failure and "the service was temporarily unreachable". The credentials were valid the whole time, proven by the recovery re-run succeeding on the same volume minutes later, and by the state self-clearing with no successful recreate in between. 362 recreates were logged for that one service.

Rules:

1. Gate a destructive remedy on a POSITIVE match for the condition it actually repairs, not on the absence of the benign cases you have met so far. Ask "does this error name the thing a restart fixes?", not "is this one of the errors I know to be harmless?". The first question has a stable answer; the second grows a new bug every time the dependency invents a message.
2. An empty or unrecognised error is NOT evidence for the remedy. Inferring "credentials are broken" from silence is how the catch-all begins. Give the unclassified case its own state.
3. Restarting is not a free diagnostic. Price the remedy before making it the default: this one kills in-flight work, so every one of 362 recreates was a window in which a live user job could die. "Restart when unsure" is only defensible when a restart costs nothing, and it usually does not.
4. Keep an escalation path, or the fix trades a restart storm for a component that never recovers. An unnameable fault is still a fault: arm a marker on first sight and apply the remedy anyway once it has persisted past a grace window sized to a few of the probe's own intervals.
5. A drift detector that does not log WHAT it reacted to cannot be audited. 362 recreates logged "auth=failed, recreating container" and nothing else, which is exactly why this ran unexamined for weeks. Record the triggering value, not just the verdict.
6. "No verdict yet" is not a failing verdict. A probe that has not reported (pending, null, zero-timestamp) must never trigger the remedy: doing so restarts a component that just started and re-arms the same delayed probe.
7. Test the flow, not the classifier. A guard that is present, correct, and unreachable looks identical to a working one under grep and under a unit test of the helper. Drive the real script against a real endpoint with the destructive call shimmed, and assert on whether the remedy was ATTEMPTED.
8. Harness caveat found while writing those tests: under `set -o pipefail`, a `grep | tail | cut` that matches nothing aborts the suite mid-run. The negative control then reports FEWER failures than exist, a test harness silently truncating in the exact direction that manufactures confidence. Use `awk`, which exits 0 on no match.

## A Retry Cap Must Not Be Spent on an Infrastructure Outage

A bounded-retry recovery loop (MAX_ATTEMPTS, cron every N minutes) permanently kills every in-flight job when the dependency is down longer than cap x interval. The attempts are consumed against a dead socket, and once a row is at the cap the recovery SELECTs exclude it forever, so the work stays dead long after the dependency recovers, and nothing ever retries it.

Seen in the wild: a dependency fleet was down about an hour. Recovery ran every 5 minutes with `MAX_ATTEMPTS=2`, so both attempts were spent inside the first ten minutes of the outage. One user's job was dead for 5 hours with a useless error until a human reported it.

The distinction that fixes it: a CONNECTION-level failure (ECONNREFUSED / ENOTFOUND / ECONNRESET / socket hang up) is a statement about the infrastructure, not a verdict on the job. A failure returned BY the dependency (bad response, timeout while it was answering) is a verdict on the job and must still count.

How to apply:
1. Preflight the dependency (`GET /health`) before the run counts an attempt, resets a status, or posts an alert. During an outage the whole run becomes a silent no-op, which also stops the every-5-minutes alert spam that trains people to ignore it.
2. In the catch, refund the attempt on a connection-level error and restore the row's prior status, so the next run retries it. Bound it with an age window (24h) rather than the attempt cap.
3. Test the decisive property directly: run N consecutive recovery passes against a CLOSED PORT and assert the row is still retryable afterwards. A single-pass test passes on the broken version too.

### A 429 or 503 From a Dependency Is a Verdict on Its Quota, Not on the Row: Refund the Attempt

The retry-budget fix above refunds the attempt only for CONNECTION-level faults: error codes such as ECONNREFUSED and ECONNRESET plus the strings `socket hang up` and `fetch failed`. A service that answers HTTP 429 "temporarily at capacity" is reachable by that test, so the attempt gets charged. Both attempts for a row were spent inside a single 5-minute cron tick, and the work then dropped out of every recovery query while the account was merely out of quota.

The counterintuitive part worth remembering: making the dependency's rejection FASTER and MORE PRECISE made this worse, not better. An admission gate had been added that detects the quota state up front and rejects in milliseconds with the parsed reset time. Before that, each attempt at least consumed real time and the two retries were spread out; afterwards both were burned instantly against a wall that was going to clear on a known schedule.

Rules:
1. Classify a failed dependency call by WHOSE fault it is, not by whether the socket opened. Connection refused, HTTP 429, HTTP 503 and an explicit quota or rate-limit response are all statements about the dependency's availability. Only an error produced while the dependency was genuinely serving the request is evidence about the row, and only that should spend a retry.
2. If the dependency tells you WHEN it will recover (a reset timestamp in the 429 body or a `Retry-After` header), defer until then instead of merely refunding. Refunding alone means the next tick retries immediately and refunds again, which works but is pure noise.
3. A retry cap plus a fast-failing dependency is a silent work-loss combination. Rows at the cap are excluded by the selecting query, so nothing alerts and the backlog just stops existing.
4. Keep the user-visible escape hatch independent of the internal counter. A stored failure message that renders with a Retry button whose route resets the row and re-runs WITHOUT consulting the attempt counter lets a human recover work the automation had given up on.

## A Watchdog That Kills Out of Band Must Set a Kill Reason, or the Death Reads as Success

A supervisor that terminates a job from outside the code path that reaps it leaves the reaper with only one observable: the process is gone. Absent an explicit reason, "gone" is indistinguishable from "finished", so the system reports a clean completion carrying whatever partial work existed.

Seen in the wild: a stall watchdog SIGKILLed a job at 6 minutes of silence; the completion poller saw a dead pid with `killReason=null` and resolved normally, so the user got 21 minutes of tool narration under an ordinary completion footer and no answer.

Two corollaries:
1. A silence-based liveness threshold must exceed the longest legal quiet operation. A single Bash tool call may run 600s emitting nothing, so a 300s stall timeout kills healthy work.
2. The explanation must travel on the channel the user actually reads. Streaming UIs render the stream, not the returned value, so a notice appended only to the return string is invisible.

## A Two-Signal Liveness Check Is Only as Strong as Its Weaker Signal

A daily session-liveness keepalive reported "session appears alive" every single day for 11+ consecutive nights while the session was actually logged out. Nothing alerted: the check's own log line stayed uniformly positive throughout. Downstream, every service depending on that session to mint fresh OAuth refresh tokens degraded independently as its own token separately expired; by the time anyone looked, most dependent services were silently dead, with no single alert pointing at the root cause.

The check already combined two detection signals for robustness, a URL-pattern match and a page-content phrase match, which reads as defense in depth. But the two signals were ORed (`url_says_login OR content_says_login`), not independently verified. The page in question renders its logged-out state at the *same URL* as its logged-in state, so the URL signal structurally could never fire for this failure mode. That left the content-phrase match as the only signal that mattered, and its extraction path silently returned an empty string on failure (wrapped in error suppression). An empty extraction and a genuinely-non-matching extraction produce the identical downstream value (`false`), so the OR condition degraded to "URL only" with nothing in the check's own output to distinguish "content confirms this is not a login wall" from "content extraction returned nothing."

**Rule:** when a liveness or health check ORs multiple detection signals together for robustness, that structure only delivers the robustness it implies if you can also detect when one signal's *input* went missing, not just when the signal itself fails to match. Log or alert on an empty extraction distinctly from a non-matching one. A check that can silently downgrade its own confidence needs to say so, or the redundancy it was built for evaporates exactly when you need it, invisibly.

## A Recurring Job That Reports Only on Success Makes an Outage Indistinguishable From a Quiet Day

A daily discovery job sent mail on completion and nothing at all on failure (the chat channel got a `[FAILED]` post; the inbox got nothing). So "the run broke" and "the run found nothing new" arrived as the same event: an empty inbox. A dependency outage ran four full days before anyone noticed, and it was discovered by remembering the absence, not by being told.

**Rule:** for any recurring job whose output reaches a human, send on EVERY terminal outcome, so that a missing message is itself the alarm:
1. The failure notice must say explicitly that nothing was checked ("This is a failure notice, not an empty result: no items were checked"), or the reader interprets it as a zero-result run. Include the bounded error text; a vague "something went wrong" makes an outage take days to surface.
2. Route the failure notice through the SAME delivery-tracking and retry machinery as the success notice, or the message most worth delivering is the one with no retry behind it.
3. A failed row's stored content is an error string, not a deliverable. Give it its own template rather than reusing the "your material is ready" one.
4. Suppress the historical backlog at deploy (mark pre-existing failed rows `legacy`), or the first cron tick floods the inbox with notices for a single already-known outage.

## A Boot-Only Reaper Misses Jobs Stranded Inside a Still-Running Process

An orphan-job reaper ran once per process, at first DB open, on the theory that a restart is what strands a fire-and-forget job. It was deployed and correct, and it still let three production runs rot: rows sat in `status='pending'` for up to four days because the process that would have reaped them had been up continuously and never restarted.

A restart is only ONE way a job is orphaned. A `void (async () => ...)()` promise also dies to an unhandled rejection or an `await` that never settles (a hung child process, a fetch with no deadline), with no restart to trigger recovery.

**Fix:** call the reaper from a periodic timer that already exists, so a stranded job's lifetime is bounded regardless of cause. Keep the age cutoff comfortably past the longest legitimate run and make it a parameter so a test can assert the boundary without sleeping.

**Diagnostic tell:** rows in a non-terminal state whose age exceeds any possible runtime, in a process whose uptime predates them. Check process uptime against the row's `created_at` before assuming the reaper is absent; it may be present, deployed, and simply never re-fired.

## A Script That Reports a Skipped Step as Informational Text Will Have That Step Skipped Indefinitely

A propagation script printed `SKIP guidance (no --guidance-file specified)` when the flag was omitted. It exited 0, the summary line said "propagated to 1 destination(s)", and the skip read as a neutral status note. Five consecutive calls in one session went memory-only, and all five outputs were pasted into reports as evidence of compliance with the rule they had just violated. The tool was not broken; its failure was indistinguishable from its success.

**Rule:** when a script can silently omit the step that is the whole point of calling it, the omission must be louder than the success path: stderr, a visible `SKIPPED` marker in the result summary, and an explicit opt-out flag so that "I meant to skip it" and "I forgot" are different observable states. A mandatory step that a script can no-op is not mandatory, it is aspirational.

**Corollary for the caller:** read the output of a compliance command before quoting it as proof of compliance.

## A Single Agent Session on WSL2 Can OOM-Reboot the Whole VM

**Symptom:** interactive sessions all end at once with no warning, each offering `claude --resume <id>`. This looks like a client-side crash or an exit hook firing, but check both before assuming either: exit hooks typically only post or score, and a host-OS sleep or reboot can be ruled out independently via the OS's own uptime and power-event log.

**Root cause:** a single CLI process (identifiable by process title) grows to double-digit-GB RSS, worsened by a large-context model, and trips the WSL2 VM's own global OOM killer at the top of its cgroup tree (`/init.scope`). Because that scope sits above every other process in the VM, killing it reboots the whole VM rather than just the offending process, taking down every other session and every supervised service simultaneously; they all come back with matching few-minutes uptime, which is the tell that distinguishes this from an unrelated crash. A WSL memory cap set below the host's total RAM means a runaway session hits that ceiling instead of the host absorbing it.

**Diagnose:** the previous boot's tail (`journalctl -b -1 -n 25` or equivalent) shows the OOM kill immediately followed by a reboot message; a full-history grep for the kernel's out-of-memory kill line confirms whether this is a one-off or a recurring pattern before you spend time on a fix.

**Fix (two independent layers; either alone leaves a gap):**
1. **Per-session cap:** run each interactive session inside a cgroup with a hard memory ceiling (`systemd-run --scope -p MemoryMax=<N>G -p MemorySwapMax=0`) so a single runaway session is killed alone, recoverable with the CLI's own resume flag, instead of the whole VM going down. Gotcha: the user-mode systemd manager can be unusable on a box with no active user D-Bus session even when linger is enabled; use the **system** manager via passwordless sudo with `--uid`/`--gid` to drop back to the invoking user, and preserve the environment (`sudo -E`) so the tool's config and home directory are still found. Skip the wrapper for non-interactive or headless invocations (a scripted job should not die mid-way for exceeding an interactive-only budget).
2. **Aggregate guard:** run a lightweight watchdog that polls available memory every ~15s and, once it drops below a threshold, terminates the largest **headless** CLI process first (falling back to interactive only if none exists) before the kernel's own OOM killer has to choose for you. This is what makes running several concurrent sessions safe at all: the per-session cap only bounds one session at a time, not their sum.

Neither layer requires downgrading to a smaller-context model; they make a memory-hungry default safe instead of forcing a capability tradeoff. Sibling failure mode, same root cause: a bare memory watchdog with no scoping still needs the "Shared Poller Resource Gates" rule above if it ever governs both local and remote-dispatched work.

## A WSL Start-at-Boot Scheduled Task Must Run as the Distro-Owning User via S4U, Not SYSTEM

To auto-start a WSL distro at Windows boot (so supervised services recover without a login), a Task Scheduler task with an AtStartup trigger MUST run as the Windows user who owns the distro, using LogonType S4U (runs before login, no stored password). Running it as `NT AUTHORITY\SYSTEM` FAILS: WSL distros are registered per-Windows-user (under `HKCU\...\Lxss`), so SYSTEM has no distro registered and `wsl -d <Distro> ...` returns `LastTaskResult 0xFFFFFFFF`.

**Fix:** `New-ScheduledTaskPrincipal -UserId '<HOST>\<windows-user>' -LogonType S4U -RunLevel Highest`. Note the Windows user may differ from the Linux user; use `wsl -d <Distro> -u <linux-user> -e /bin/true` as the action.

**Definitive proof requires an actual reboot** (a test-fire while logged in has `HKCU` already mounted); `LastTaskResult 0x0` on test-fire is necessary but not sufficient.

Related: an automatic OS update can reboot the host and, with nothing set to auto-start WSL, leave everything down for hours until someone logs in. Check the OS event log for a planned-restart event before attributing an outage to the OOM pattern above.

## `systemctl --user` May Be Permanently Broken on a WSL Host; Make Automation Bus-Free

On a WSL host with no user D-Bus session, `systemctl --user` ALWAYS fails with `Failed to connect to bus: No such file or directory`: `/run/user/<uid>/bus` and `/run/user/<uid>/systemd/private` are absent, even though the `systemd --user` manager IS running and supervising units with linger enabled. So any cron or automation that calls `systemctl --user restart|start|stop` is SILENTLY broken there: it logs the bus error and does nothing.

Seen in the wild: a tunnel self-heal script restarted a reverse-tunnel via `systemctl --user restart <unit>`, which never worked, so dead reverse-forward ports stayed dead for minutes on every drop and dependent jobs got cut off.

**Bus-free fix pattern:** to restart a supervised user unit, kill its main process and let `Restart=always` respawn it (the manager's internal restart logic needs no D-Bus): `pkill -TERM -f <exec-pattern>`.

Same root cause as the OOM-guard note that `systemd-run --user` does not work on such a box: use the SYSTEM manager (`sudo systemd-run --uid`) or process-kill plus `Restart=always`, never `systemctl --user` in headless or cron contexts. **Verify a `systemctl --user` call actually works on a given host before trusting it:** run it once and check for the bus error.

Related tuning if you rely on SSH reverse tunnels: a remote `sshd` can hold dropped reverse-forward ports for several minutes (`ClientAliveInterval 120` x `ClientAliveCountMax 3`), blocking rebind when the client uses `ExitOnForwardFailure=yes`. Lowering to 30/2 in a drop-in config lets ports self-reap in about 60s.

## Sunsetting a Repo From an Auto-Discovery Pipeline Needs an Exclusion, Not a Deletion

An automation runner that auto-discovers any git repo under a root directory with more than N commits, and appends any repo not in its configured lists back into the active list, will undo a plain deletion within a day. To retire a repo from such a pipeline permanently, MOVE it into the protected/excluded list (the only real exclusion mechanism), in every copy of the config.

The recurring vectors for a retired service repo are plural; kill all of them:
- Supervised processes on EVERY host (`pm2 delete` plus `pm2 save` on each)
- Ecosystem config `cron_restart` entries
- Open PRs (an auto-merger will merge them)
- `.github/dependabot.yml` (weekly scheduled PRs)

Diagnostic note from the case that produced this: the churn was the discovery pipeline generating daily PRs, not the service runtime, which had already been stopped.

## A Long-Lived Process-Manager Daemon Can Desync So `restart` Fails for EVERY Process

A PM2 God daemon that had been up for months desynced: `pm2 jlist` and `pm2 describe` report processes fine, but `pm2 restart` and `pm2 reload` FAIL with `[PM2][ERROR] Process <id> not found` for ALL ids, including a freshly created one.

This is the root cause of two symptoms at once: an error monitor's auto-fix `pm2 restart <name>` fails and escalates a deep investigation, and a crashed process never auto-recovers (a module crashed on an uncaught error in its own log sweep and sat `stopped` because the daemon could not respawn its orphaned id).

**Recovery ladder:**
- `pm2 install <module>` re-registers a MODULE with a fresh id (works for modules).
- The GLOBAL desync is only repaired by refreshing the daemon itself (`pm2 update`, or `pm2 kill && pm2 resurrect`), which restarts ALL managed services. That makes it a **human action**: it cannot be issued from a job dispatched BY one of those managed services, because respawning the daemon kills the process capturing the result.

Also note: a committed fix to a supervised service does nothing until that service is restarted to load it, and the desync blocks that restart too.

Same gate as the usage-limit and auth restart-storm findings above: before wiring or retrying a remedy, ask whether it addresses the CONDITION. Harden the classifier so a module is recognized as a module (match both the module flag and the name prefix) and so `Process <id> not found` is tagged as a daemon desync, making the triage say "refresh the daemon" rather than "restart the process".
