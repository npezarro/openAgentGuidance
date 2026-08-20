<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

Prevent feedback loops, restart storms, and cascading failures in automated systems.

## Self-Deploy Loop Prevention

**The scenario:** An agent job modifies the service that spawned it, then deploys or restarts that service. The service restarts, recovers the "active" job from persistence, re-attaches to the still-running process, and the cycle repeats. Each restart kills in-flight work and creates cascading failures.

**How it happens:**
1. A long-running service spawns an agent job targeting the service's own repo
2. The agent finishes changes and runs `restart <service>` or a deploy script
3. The service restarts, loads its job-state file, finds the job still "active"
4. It re-attaches to the process (or re-queues the job)
5. The job or a recovered job triggers another restart
6. Repeat indefinitely

**Defenses (layered):**

1. **Hard guard in the deploy script:** The `deploy` and `restart` verbs check the job-state file for active jobs before restarting the service. If jobs are active, the command is refused with an error. This is the primary barrier.

2. **Prompt-level warning in the job executor:** When a job's working directory is inside the service's own repo, prepend a self-restart guard message to the prompt telling the agent not to restart the service. This is a soft barrier (the agent can ignore it).

3. **SIGINT handler in the service:** The service refuses SIGINT during startup (30s grace) and while jobs are active. The process manager sends SIGTERM to force shutdown. This prevents cascading SIGINTs from child processes.

**If a loop is already happening:**
1. Kill the stale child processes: `ps aux | grep <agent-bin> | grep -v grep` then `kill <pids>`
2. Clear the persisted jobs: edit the job-state file, set `"activeJobs": []`
3. The service will stabilize on next restart with no jobs to recover

**Rule:** Never deploy or restart a service from within a job that service spawned. Make changes, commit, push, and note that a manual restart is needed.

## Restart-Recovery Loop (Externally Triggered)

**The scenario:** A long-running job is in flight. An auto-merger merges a PR and calls the deploy script. The deploy guard sends SIGINT, but the service ignores it (active jobs). The process manager escalates to SIGTERM, force-killing it. On restart, the service loads its job-state file, finds the incomplete job, re-queues it, and starts running it. Meanwhile the auto-merger retries the deploy (or another merge triggers it), creating an infinite loop of: deploy, kill, restart, recover job, deploy.

**This is distinct from the self-deploy loop** because the deploy is triggered externally, not by the job itself. The deploy-script guard doesn't help because the process manager force-kills after SIGINT is ignored.

**Defenses:**

1. **Recovery attempt limit:** Long-running jobs track `recoveryAttempts` in their persisted state. Each restart increments the counter. After 3 attempts, the job is abandoned instead of re-queued. This breaks the loop even if other defenses fail.

2. **Active-job check in the auto-merger:** Before calling the deploy script, the auto-merger reads the job-state file and checks for active jobs. If any are active, the deploy is deferred for 60 seconds and retried. This prevents the deploy from killing active jobs in the first place.

3. **Deploy-script guard:** Still in place as a third layer, refusing to restart if active jobs exist. But since the process manager force-kills after SIGINT, this guard only works when the process can actually be signaled gracefully.

**If this loop happens again:**
1. Stop the process, halting the cycle
2. Edit the job-state file: set `"activeJobs": []` and `"queue": []`
3. Start the process again for a clean restart with no recovery
4. Check error logs to identify the root cause

**Prevention rules:**
- Never merge PRs to a service's repo while long-running jobs are active on it
- If you must deploy during an active job: stop the process, deploy, then start it (the job will be lost, but no loop)

## Restart Storm Detection

A restart storm is when a supervised process enters a rapid restart cycle (restarts > 5 in under 5 minutes).

**Signs:**
- The process manager's list shows a high restart count (16+) with low uptime (seconds)
- Error logs show repeated startup messages in quick succession
- Recovery messages appearing every few seconds

**Common causes:**
- Self-deploy loop (see above)
- Crash-on-startup bug (bad config, missing env var, syntax error)
- OOM kill cycle (process exceeds its memory-restart limit, restarts, loads same data, OOMs again)
- Dependency failure (database down, required service unavailable)

**Response:**
1. Stop the process to halt the restart cycle
2. Check logs (last 50 lines, non-streaming)
3. Fix the root cause
4. Start the process to resume

**Read the right field.** A process manager typically exposes two restart counters with opposite reset semantics: a cumulative lifetime count that never resets, and a crash-loop counter that resets once the process clears its minimum-uptime threshold. Storm detection must key on the crash-loop counter. Keying on the cumulative one flags every long-uptime stable process as a storm (a healthy service can trivially sit at 80, 180, or 230 lifetime restarts with a crash-loop count of 0). They sound interchangeable; they are not. Always validate a restart threshold against a known-stable, long-uptime process before trusting it. Also normalize the empty case: if the query returns no rows at all (process absent), a `// 0` default never fires, and under `set -e` the resulting integer test can fall through to a false positive.

**Put destructive guards inside the script, not in the calling instructions.** A storm handler that stops and rolls back a process must refuse, before any mutating command, to act on anything outside an explicit allowlist of names. Textual instructions to the caller are not a guard.

## Bash `pipefail` + `grep -c` Silent Failure

**The scenario:** A script with `set -o pipefail` uses `grep -c 'pattern' || echo "0"` to count matches. When grep finds 0 matches, it outputs `0` AND exits code 1. Pipefail triggers the `|| echo "0"` fallback, producing `"0\n0"`. The variable becomes a two-line string that breaks `$(( ))` arithmetic silently: no error, just wrong values downstream.

Encountered directly: this bug made a scheduled security scanner fail silently for 13 consecutive days. It was detecting secrets daily but crashing before it could report findings. The state file never updated, so it rescanned the same targets with the same silent crash every run.

**Fix:** Use `grep -c 'pattern' || true` instead. `grep -c` already outputs `0` on no match; it just needs the exit code suppressed, not a fallback echo.

```bash
# WRONG — produces "0\n0" with pipefail
count=$(grep -c 'pattern' file || echo "0")

# RIGHT — outputs "0" and suppresses exit code 1
count=$(grep -c 'pattern' file || true)
```

**Rule:** In any bash script using `set -eo pipefail`, never pair `grep` (any flag) with `|| echo`. Use `|| true` to suppress the non-zero exit code.

## A Pipeline Reports the LAST Command's Exit Code, So Never Chain a Success Message Off One

**The scenario:** You run a command, pipe it somewhere to trim the output, and chain a confirmation:

```bash
# WRONG — prints "PUSHED" even when the push fails.
git push -q origin main 2>&1 | tail -2 && echo "PUSHED"
```

Without `pipefail`, `$?` is `tail`'s exit code, and `tail` almost always succeeds. The `&&` therefore fires regardless of what the real command did. This produced a false "PUSHED" twice in one session: once when the token lacked `workflow` scope to create `.github/workflows/`, and once when a pre-commit gate had blocked the commit so there was nothing new to push. Both times the operator was told the work was published when it was not.

This is worse than an ordinary bug because the wrong output is a **claim about system state**.

```bash
# RIGHT — capture, test, then report
if out=$(git push -q origin main 2>&1); then echo "PUSHED"; else echo "FAILED: $out"; fi

# ALSO RIGHT — check the real command, not the pipeline
git push -q origin main; rc=$?; [ $rc -eq 0 ] && echo "PUSHED"
```

**Rule:** never end a pipeline with `&& echo "<success>"`. For anything whose success you will report, capture the exit code of the command itself, and verify the outcome against the remote or the target rather than against your own echo. After a push, `git ls-remote origin <branch>` and compare to local `HEAD`: that checks the thing you actually care about.

## Blanket Rename Across Executable Files Is a Destructive Edit

A repo-wide `sed` looks like a rename and behaves like a rewrite. Three failures from a single session, all from the same batch of commands:

- **Delimiter collision.** `sed 's#old#new#'` against content containing `#` (every shell comment) mangled a script into a single corrupted line, prefixing all 95 lines with the replacement text.
- **Syntax destruction.** Replacing a bare word with a multi-word phrase broke a shell `case` pattern, because a branch containing spaces is not a valid glob branch. The file stopped parsing.
- **Prose damage that survives review.** The same replacement rewrote a repo name *inside a path*, so a user-facing error told people to consult a path with spaces in the middle of it. The gate still worked; its instructions were nonsense, and nothing automated flags an absurd string.

**Rules:**
1. Never blanket-`sed` executable files. Rename with an explicit list of full paths, or a script that parses the file.
2. Pick a delimiter that cannot appear in the content (`|` for paths, never `#` against shell).
3. **Re-run `bash -n` on every touched script immediately after**, in the same command. Two of the three failures above were caught only because a syntax check followed.
4. Then read the user-facing strings. A syntax check cannot tell you a message became gibberish.

## Programmatic Edits to a Shared Config Must Preserve Formatting

Rewriting a JSON config with `json.dump(...)` reformats the **whole file**. Without `ensure_ascii=False`, every non-ASCII character is escaped, so an intended 6-line insertion arrived as a 42-line diff touching entries owned by other sessions. A secret gate then blocked the commit over a pre-existing line the edit never meant to touch.

**Rules:** pass `ensure_ascii=False` and match the file's existing indentation; then **verify the diff is only your change** (`git diff --stat` should show a plausible line count) before staging. If the diff is larger than your edit, the tool reformatted and you are now committing other people's content. And note that `git checkout -- <file>` restores from the **index**, not `HEAD`: after staging a bad rewrite, only `git checkout HEAD -- <file>` actually reverts it.

## Regenerating From a Source of Truth Deletes Whatever Only Exists Live

When a live artifact (a crontab, a DNS zone, a firewall ruleset, a service config) is generated from a checked-in source file, the source drifts **behind** the moment anyone edits the live copy directly. Regenerating then silently deletes their work, and the deletion looks like a normal install.

Encountered directly: disabling one cron entry would also have removed two credential-rotation jobs a concurrent session had added live but never recorded in the registry. Those rotations are what keep credentials from expiring, so the result would have been a silent outage weeks later, with no link back to the install that caused it.

**Rules:**
1. **Diff against live before installing**, always, and read the diff for removals rather than skimming it for your addition.
2. Build the removal guard into the generator, so it **refuses** when the rendered output drops entries. A generator that only warns gets `--force`d.
3. When the guard fires, **import the live state first**, then re-apply your change, then install. Never reach for `--force` to get past it: that is the guard working.
4. After installing, verify the entries you did not intend to touch are still present. Count them.

## Headless Agent CLI: Permission Flag Requirement

**The scenario:** A script spawns `claude -p` as a subprocess (Python `subprocess.run`, Node `spawn`/`execSync`, bash pipeline). The parent process already has `--dangerously-skip-permissions`, but the subprocess is a fresh CLI invocation that doesn't inherit it. When the agent tries to use tools (WebSearch, WebFetch, Bash), it prompts for permission. With no TTY, the prompt goes to the void and the session silently fails or produces degraded output.

Encountered directly: a research collector spawned the CLI for deep research. The top-level runner had `--dangerously-skip-permissions`, but the subprocess call didn't. Every WebSearch call was silently blocked, producing reports with no web data.

**Rule:** Every `claude -p` invocation that runs without a TTY (cron, subprocess, server route, background job) MUST include `--dangerously-skip-permissions`:
- Python `subprocess.run([CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...])`
- Node `spawn('claude', ['-p', '--dangerously-skip-permissions', ...])`
- Bash `$CLAUDE_BIN -p --dangerously-skip-permissions`

Worth scanning for automatically: a health monitor can grep every repo for agent-CLI subprocess calls missing the flag.

**Also required: `--no-chrome`** for headless environments. The CLI may attempt to open a browser (for OAuth or a dashboard). In headless VMs or supervised processes, this silently hangs or errors. Add `--no-chrome` alongside `--dangerously-skip-permissions` for all automated invocations:
- `claude --print --no-chrome -p "..."`
- `$CLAUDE_BIN -p --dangerously-skip-permissions --no-chrome`

### Gotcha: `claude -p` Eats the Next Argument as a Prompt String

When calling the CLI with piped stdin **and** additional flags like `--model`, use `claude --print`, **not** `claude -p`. The `-p` flag is positional: it treats the **next CLI argument** as a literal prompt string, so `claude -p --model <model-id>` passes `"--model <model-id>"` as the prompt and ignores stdin entirely.

```bash
# WRONG — -p eats --model as the prompt; stdin is ignored
echo "$prompt" | claude -p --model <model-id>

# CORRECT — --print enables stdin pass-through; --model is parsed as a flag
echo "$prompt" | claude --print --model <model-id>
```

Encountered directly: a scoring script used `execSync('claude -p --model <model-id>', { input: prompt })`. Every eval call passed the model flag string as the prompt instead of the real data.

**Rule:** When combining piped stdin with any extra flags (`--model`, `--output-format`), always use `claude --print` as the mode flag, not `claude -p`.

### Strip CLAUDE_CODE_* Env Vars From Subprocess Invocations

This is **defensive hygiene only**, not a fix for any observed failure. An earlier version of this rule attributed a synthetic-401 incident to inherited `CLAUDE_CODE_*` env vars; isolated testing with a fully polluted env refuted that. The real cause was an expired access token from a rate-limited OAuth refresh (see below). The pattern is kept because it is cheap insurance.

**Defensive scenario:** A long-running daemon that was started from inside an agent session inherits `CLAUDECODE=1` and `CLAUDE_CODE_SESSION_ID` in its env. There is no reproducible failure from this alone, but stripping the vars when spawning a `claude -p` subprocess guards against any future CLI behavior change that treats a nested-session marker as special.

**When to apply:** Long-running services (daemons, server routes) where the inherited env is opaque or stale. Not required for cron jobs that already start with a clean env.

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

**Why a process manager captures these vars:** It captures the full env at daemon start, including any `CLAUDE_CODE_*` vars from the terminal session that ran the restart. The vars persist in the process table for the lifetime of that process slot, even across subsequent restarts, until the manager itself is restarted from a clean environment.

**Also strip `NODE_CHANNEL_FD`** when launching non-Node subprocesses from a Node.js parent (for example, a Python worker called from a Node service). Node.js IPC sets `NODE_CHANNEL_FD` in its own env; child processes that themselves use Node runtimes (such as a media downloader's JS challenge solver) inherit this FD reference and can fail with IPC errors because the FD is already closed or invalid in the new process.

```python
env = kwargs.get("env") or os.environ.copy()
if "NODE_CHANNEL_FD" in env:
    del env["NODE_CHANNEL_FD"]
kwargs["env"] = env
```

### OAuth Refresh Rate-Limiting

**The scenario:** A cron job refreshes an OAuth access token every few hours using a `refresh_token` grant. The token endpoint is **rate-limited**, and under load can return `rate_limit_error` for multiple consecutive cron cycles.

Encountered directly: four consecutive refresh cycles failed with `rate_limit_error`. The access token expired about 7 hours into the failure window. Every daemon doing `claude -p` during that window got a synthetic 401 with `result: "Failed to authenticate. API Error: 401 Invalid authentication credentials"`. The CLI's `--output-format json` returns this as `is_error:false` `subtype:success` (confusingly), so the failure is **not visible via subprocess exit codes**: only by parsing the `result` field for the auth-error string. Eventually a later cycle got through and the token recovered.

**Detection signal:**
- `result` field of `claude -p --output-format json` contains "Failed to authenticate" or "401 Invalid authentication credentials"
- The refresh log shows `rate_limit_error` on consecutive cycles
- Daemons silently fall back to degraded mode

**Mitigations for the refresh script:**
1. **Refresh well before expiry.** Use a threshold of roughly 3 cron cycles of headroom, not 1.
2. **Intra-cycle retry with backoff.** Up to 3 attempts per run; back off longer for `rate_limit_error` (60s, 240s) than for other failures (30s).
3. **Consecutive-cycle failure counter.** Store it in a state dir. After 2 or more consecutive failures, alert on your notification channel with hours-remaining context. Reset the counter on any healthy cycle.

**When the consecutive-failure alert fires:** the API refresh path is stuck. Do NOT wait for the next cron cycle: trigger the browser-based re-login path. The browser OAuth flow is not subject to the API rate limit and will recover the token immediately.

**Layered defense: the browser path is the safety net.** The cron refresh path and the browser-based re-login path are independent recovery mechanisms. When the token endpoint is rate-limiting, the browser flow completes the login via the web OAuth flow, bypassing the API endpoint entirely. Validated in production: a manual run and a cron run both exhausted all retries with `rate_limit_error`; the browser re-login chain sidestepped the rate-limited endpoint; the following cron cycle ran clean with the counter reset to 0.

**Implication:** When debugging a prolonged OAuth failure, check both paths. If the log shows persistent `rate_limit_error` and the access token is expired, the recovery path is NOT to wait; it is to trigger the browser re-login.

### React SPA Hydration Race in Browser-Driven OAuth Scripts

**Symptom:** A browser-automation script clicks the OAuth Authorize button. The click reports success but nothing happens: no navigation, no callback. The same script works fine minutes later.

**Why:** React SPAs render the DOM before hydrating (wiring up event listeners). The Authorize button can be visible and selectable during this gap but fires no event when clicked. The window is typically under 2s but is reproducible on freshly-woken browser sessions.

Encountered directly: one automated re-login failed with "callback tab not found" while two sibling runs 10 and 20 minutes later succeeded with the same script. The fix: add a short wait after locating the consent tab, then retry the click once if no callback appears within 25s.

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

**Rule:** Never do unbounded retries on a consent button. If two attempts both produce no callback, escalate an alert: the problem is something other than a hydration race (rate limit, broken page, wrong selector).

### Auth-Age Enforcement: All Sessions Fail Simultaneously

**Symptom:** Every automated re-login across a fleet of containers fails on the same night with `callback tab not found`. The browser session IS active (the app shows the account logged in), but clicking Authorize redirects to a re-auth/logout URL instead of the OAuth callback.

**Root cause:** The identity provider enforces a **max auth-age**, the elapsed time since the account last performed a real sign-in, in addition to activity-age, before granting OAuth scopes. A session-keepalive script slides the activity clock but cannot reset the auth-age clock. When auth-age exceeds the threshold, the consent flow forces a full logout regardless of session freshness.

**Differentiator from the hydration race above:** all containers fail on the same night. The hydration race is a single-unit, timing-based event that a retry resolves. Simultaneous failure across all units is diagnostic of the auth-age pattern.

**Why automation may not self-heal:** after the forced logout, the grant page can land on a federated-login button whose popup the browser blocks for extension-synthetic clicks (it requires a real user-activation gesture).

**A refresh token has its own expiry, and that is the real deadline.** An earlier version of this note claimed there was "no user-facing impact during the failure window" because existing access tokens keep auto-refreshing. That is true for days, not weeks, and it was the load-bearing premise for muting the nightly alert. The refresh token carries a separate `refreshTokenExpiresAt`, on the order of **weeks**, reset only by a successful interactive rotation and **not** extended by ordinary refreshes. That is why breaking rotation did not surface for a month: the fleet had weeks of runway and spent all of it silently. Any unit that idles past that window wakes up unable to refresh; the CLI then writes the credential file back with **empty-string** tokens and `expiresAt: 0`, and the health endpoint reports an expired session that could not be refreshed. Nothing automated can recover that state, because minting a new refresh token requires the interactive login that auth-age is blocking.

Measured after eleven nights of un-repaired auth-age failure: 7 of 9 units dead, each with a blanked credential and a `refreshTokenExpiresAt` in the past, each dying roughly one refresh-token lifetime after its last successful rotation. The two survivors were simply the ones whose chains never missed a refresh.

**Rule:** treat an auth-age failure as a **deadline, not a steady state**. Build the alarm on the credential's own expiry field: a daily job that reads `refreshTokenExpiresAt` for the host and every running unit, warning under 20 days and paging under 10. That one field measures both how long until a credential is unrecoverable and how long rotation has been failing, and it does not care *why* rotation stopped, so it also catches the quiet skip (a pre-flight that exits 0 when the browser is asleep is right for one night and fatal over a fortnight). The alarm that matters is the blank-credential page, not the nightly re-login email.

**Also: have the automation close the tabs it opens.** Leftover pages from run N are the bug in run N+1; a stale error page in the browser hijacked a later run's tab matching entirely.

**Operational rule:** When an automated re-login fires a final-failure alert, check whether the alert says the session was logged out at grant time. If so, do a manual interactive sign-in. Do NOT attempt automated recovery, retry loops, or container restarts for that condition.

**Resolution: four stacked defects, each masked by the one in front of it.** The wall was eventually cleared unattended. In causal order, all four are generalizable:

1. **A script that sources an env file after receiving env from its caller lets the file win.** Moving webhooks into a dotenv file added `set -a; . "$HOME/.env"; set +a` to browser-driving scripts. That file also defined the browser API key for the *primary* profile, and `set -a` plus source overrides the caller's value. Every alt-profile rotation, invoked as `KEY="$ALT_KEY" script`, silently drove the **primary** profile instead: it opened an alt-account consent URL in a browser signed in as the other account, so the account chooser never contained the expected address. Every "the session is logged out" alert described a profile the run never touched. **Rule:** re-assert caller-provided env after sourcing a file, or the file wins.
2. **An extension `exclude_matches` entry made the target tab invisible to the tab registry.** The registry is fed by content-script heartbeats, so an excluded origin can never appear in a tab listing, and the entire account-chooser branch became unreachable code. Fixed with a listing verb backed by the browser's own tab-query API rather than by heartbeats.
3. **Origin containment hard-denied the clicks.** The sanctioned opt-in flag, paired with an allowlist re-narrowed to the single origin needed.
4. **A popup is a separate WINDOW, so it is never "visible".** Focusing a *tab* does not raise its *window*, so the popup document sits at `visibilityState: "hidden"` and the browser does not deliver synthetic input events to an unrendered page. Twelve consecutive coordinate-based clicks reported success at the button's real coordinates while the page never moved; one JS `el.click()` on the same hidden page advanced it instantly. **Rule:** inside a popup window, use JS clicks. Reserve trusted coordinate clicks for the one button that genuinely needs user activation (a button that calls `window.open`).

**Three further traps surfaced when bringing a second profile to parity:**
- **Providers version their consent paths.** Two profiles hit different consent URL versions on the same day, and a matcher pinned to fixed paths knew neither. Match by keyword, not by path.
- **A stale tab hijacks the loop forever.** A leftover error page on the same origin classified as "consent", clicked nothing, every round, while the real wall was never touched again. Snapshot the relevant tab ids at entry and ignore pre-existing ones: a popup you did not open is not yours to drive.
- **An unclassifiable page needs an exit.** A catch-all state with no clearing branch "settled" the same page twelve times, logging nothing but a category name. Always log the URL of a page you could not classify.

Also: a consent-tab matcher that required a literal `oauth/authorize` failed whenever the app redirected to `/login?...returnTo=%2Foauth%2Fauthorize`, where it is percent-encoded, producing "consent tab not found" about a tab sitting right there. **Match the decoded URL.** And where Cancel and Continue share the same generated attribute, select the primary button by visible label, never by that attribute.

**Two traps that hid all of this for six weeks:**

1. **A per-key operation gated on a global signal reports on the wrong thing.** The tab-listing endpoint was a single un-keyed registry (every API key saw the union of tabs from both browser profiles) while *commands* routed per key to one profile. So an "ensure this URL is open" call would match a URL, hand back the **other** profile's tab, and every later read on that id timed out. The keepalive script was therefore reading the wrong profile's tab and certifying its session daily, logging "session appears alive" while the real session aged out and finally logged itself out. Its content check was correct; it was pointed at the wrong browser. The same bug sat in the pre-flight, which gated on a *global* connected-clients count: one awake browser satisfied it while the target extension was absent. Fixed by probing ownership with a keyed ping, and gating on per-key status. **Rule:** if a check is per-profile/per-key/per-tenant, its signal must be too, and "I could not read it" is never evidence of health.

2. **Muting an alert by call site means the mute silently moves.** A suppression keyed on the *post*-Authorize classifier (one exit code, one wall kind). When the session went from stale to fully signed out, the identical wall began failing one call site **earlier**, at the pre-Authorize check with a different exit code, which was not suppressed. The alert flood resumed with **no code change on either side**. **Rule:** suppress on the *classified condition*, and make that classification reachable from every path that can produce it; a mute pinned to one exit code expires the moment the failure moves.

### Pin the Agent CLI Binary Path Explicitly

A wrong hardcoded fallback path for the agent CLI causes silent `[Errno 2] No such file or directory` failures that drop all AI processing with no obvious error in service logs. Installation prefixes differ between hosts (`/usr/bin` vs `/usr/local/bin`).

**Rule:** always prefer an env var over hardcoding, and verify the actual path on each host with `command -v claude` before choosing the fallback:

```python
claude_bin = os.environ.get("CLAUDE_BIN", "/usr/bin/claude")
```

```javascript
const CLAUDE_BIN = process.env.CLAUDE_BIN || '/usr/bin/claude';
```

```bash
CLAUDE_BIN="${CLAUDE_BIN:-/usr/bin/claude}"
```

## Rate Limit Detection in Service Wrappers

**The scenario:** A service wraps `claude -p` (via `spawn` or `execFile`) and reads stdout for the response. When the account hits its usage limit, the CLI exits with code 0 but outputs a rate-limit message instead of a real response. The service treats this as a successful result, returning garbage content to the user.

Encountered directly: a service returned rate-limit text as a "completed" generated document. Jobs were marked successful with useless content because the wrapper only checked the exit code, not the output.

**Fix:** After collecting stdout from any `claude -p` subprocess, check for rate-limit patterns before treating the output as valid:

```javascript
const output = stdout.trim();
if (output.match(/you've hit your limit/i) || output.match(/resets \d+:\d+[ap]m/i)) {
  // Return 429 or retry error, NOT success
  return { error: "AI at capacity", status: 429 };
}
```

**Rule:** Any service wrapping an agent CLI must detect rate-limit responses and translate them to errors (HTTP 429 or equivalent). Do not rely on exit codes alone; rate-limit messages arrive on stdout with exit code 0.

### Detecting it is half the job: the other half is a parking lot, not a retry

Translating the limit to an error stops the garbage, but it hands the user a failed job they must re-issue by hand. Routing it into an existing retry ladder is worse: a 1/2/4-minute exponential backoff cannot return quota, so the retries are spent against a condition they cannot change and the job fails anyway. Same shape as the restart storm above: the remedy must address the condition.

The working pattern (a `usageLimit` classifier plus a `parkedJobs` store):

1. **Classify at the single choke point** every spawn path funnels through, not at each call site. Prefer the structured signal (a rate-limit event with `status: "rejected"` in stream-json) over string matching, and scope it *per job*: a global "over cap" gauge that also flips on a warning event will park jobs that finished fine.
2. **Match wording as a family, and gate loose patterns on output length.** The CLI says `your limit` / `your session limit` / `your weekly limit` / `usage limit reached`. When it is genuinely out of quota the rejection notice is the *entire* output, so shortness is the tell; that bound is what stops a long agent report that merely *discusses* rate limits from parking itself.
3. **Exclude it from `isRetryableError()` explicitly.** A `/rate.?limit/i` entry in a retry list is a trap here.
4. **Park, notify, and restart on a timer.** Persist the job (it must survive a process restart), tell the user *when* it will resume rather than that it failed, and re-dispatch after the stated reset plus a buffer: the reset boundary is the server's clock, not yours. No stated reset means a real wait (an hour), not a fast retry.
5. **Unpark before dispatch**, so a resumed run that hits the wall again re-parks cleanly instead of doubling.
6. **Keep the attempt count outside the parked entry.** The entry is deleted at dispatch, so a job that re-parks reads no history off it, restarts at attempt 0 forever, and never reaches the cap. Memoize the count under a stable identity (source plus message id) and clear it once a resume goes through.
7. **Cap it and say so.** Bound by attempts and by age, and when you give up, post that you gave up. Silence is indistinguishable from still-waiting.

## `set -e` Makes Post-Hoc Exit-Code Capture Dead Code

**The scenario:** A runner script uses `set -euo pipefail`, invokes a fallible command as a bare statement, then tries to handle failure afterwards:

```bash
set -euo pipefail
timeout 2700 claude -p "$PROMPT" > "$LOG"   # non-zero exit kills the script HERE
EXIT_CODE=$?                                 # never reached on failure
if [ "$EXIT_CODE" -eq 124 ]; then ...        # dead code
```

Under `set -e`, any non-zero exit terminates the script before `EXIT_CODE=$?` runs. Every downstream failure path (timeout logging, alerts, state writes, cost tracking) is unreachable. The same applies to command substitution: `RESULT=$(claude ...)` exits the script before the failure branch. A subtle variant: `OUT=$(cmd || true); RC=$?` — the `|| true` guarantees `RC` is always 0, silently disabling the gate that reads it.

Encountered directly: three autonomous runners plus a verify script all had this bug. Zero failure alerts had ever fired across roughly 1,000 combined runs; a 45-minute run timed out with no log entry, no state write, and a reused run ID the next day; a verify gate passed proven test failures for weeks.

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

Encountered directly: a health monitor on a 15-minute cron died at its first verbose-log call on every single run for its entire deployed life. Its log showed only `START:` lines. It never completed a check, never posted an alert, and nothing noticed, because the thing that died WAS the alerting layer. Its cron scheduling was verifiably fine: **a heartbeat at the start of a run proves scheduling, not completion. Freshness checks must key on an end-of-run marker.**

**Fix:** `if [ -n "$VERBOSE" ]; then log "$*"; fi` (an `if` whose condition is false returns 0), or end the function with `|| true` / an explicit `return 0`.

**Rule:** in `set -e` scripts, never end a function body with a bare `[ cond ] && cmd`.

## Cron Output Redirects Into Root-Owned Dirs Die Silently

**The scenario:** a non-root crontab line redirects into `/var/log/`:

```
*/5 * * * * $HOME/bin/watchdog.sh >> /var/log/watchdog.log 2>&1
```

The shell opens the redirect target BEFORE running the command. If the dir is not writable by the cron user and the file doesn't exist, the open fails and **the command never runs at all**: every occurrence, forever, with no trace beyond an unread cron mail. The trap is asymmetric: if the log file already exists (created earlier when perms allowed, or pre-touched by root), appending works, so some `/var/log` crons keep working while their siblings are dead, which defeats "the other one works, so the pattern is fine" reasoning.

Encountered directly: `/var/log` was root-owned 755 and 9 of 11 user cron entries redirecting there were dead: both process-manager watchdogs, the uptime monitor, the error aggregator, the restart alerter, a guidance sync, a daily restart, a database guardian (never ran once), and a state backup (last artifact 4 months old). The 2 survivors had pre-existing log files. One dead cron had been individually "fixed" earlier by pre-creating its log file: the instance was patched, the class was not.

**Rules:**
- Non-root cron output goes to a user-owned dir (`$HOME/logs/cron/`); never redirect cron output into `/var/log` as a non-root user.
- When you find one broken cron redirect, audit the whole crontab for the class: `crontab -l | grep '/var/log'`.
- Every watchdog/monitor needs periodic end-to-end verification: does its log show a run **completing** (not just starting) within the last interval, and can it still deliver its alert? A monitoring stack in which every layer dies silently is the default failure mode, not the exception.

## Hook Loop Prevention

Auto-posting hooks run on every agent turn. If a hook failure triggers a retry or a new session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new agent sessions without recursion guards.
- Hooks must have timeouts (10s max). A hung webhook should not block the session.
- If a hook fails, log the failure and continue. Do not abort the parent session.

### Stop Hook Safety

Classify Stop hooks into tiers: Tier 1 observation (read-only), Tier 2 verification (runs checks), Tier 3 agent-invoking. Every Tier 3 hook must go through a shared guard providing an env var circuit breaker, a PID lockfile, and a per-hour rate limiter.

Encountered directly: a Stop hook ran a session scorer via the agent CLI on every session exit. The scorer's own session exit re-triggered the hook. Result: 4,888 recursive sessions in one day, 199M tokens (78% of that week's usage). Fixed with an env var guard plus a content pattern match, then standardized into a shared guard library.

## Concurrent Sessions in One Checkout

Two distinct problems, often confused:

- **Shared tree:** two sessions editing the same working copy stomp each other. Fix: a worktree per session (`git worktree add`), never two sessions in one checkout.
- **Singletons:** two sessions running the same one-at-a-time operation (an installer, a migration, a deploy). Fix: a real lock (`flock` on a lockfile), not a convention.

If something you wrote keeps reverting, check for a second session in the same tree before debugging your own code.

## Job Recovery Safety

When a service recovers persisted jobs on startup:
- **PID alive:** Re-attach and monitor for completion. Do not re-execute.
- **PID dead:** Extract partial output, mark as failed, notify the user. Do not re-run automatically.
- **Partially complete multi-turn job:** Re-queue from the last completed turn, not from scratch.

**Never** automatically re-execute a failed job. The failure may have been caused by the job itself (for example, it restarted its own host service). Automatic re-execution would repeat the failure.

## Unattended Jobs That Take Irreversible External Actions

A cron job that spends money, sends a message, cancels a subscription, or files something is not a normal cron job: a bug does not just fail, it does the wrong thing to the outside world, and nobody is watching when it happens. Five requirements, all of them cheap:

1. **Gate on identity, not just success.** Before the irreversible step, assert the thing in front of you is the thing you meant: expected item/recipient name, expected quantity. Refuse and report on mismatch. A checkout page that loads fine is not evidence it holds the right cart.
2. **Cap the magnitude.** A hard ceiling (`MAX_TOTAL`) turns a pricing change, a currency bug, or a duplicated line item into a refusal instead of a charge.
3. **Idempotency guard.** Keep a per-period state file (`$HOME/.state/<job>-last-*.json`) recording the period already completed, and check it first. Without this, a manual re-run, a retry, or two overlapping schedules double-execute. This is the single highest-value guard, because retries are otherwise unsafe to add.
4. **A `--dry-run` that stops immediately before the irreversible call** and exercises everything up to it. This is what makes the job testable at all; without it the only test is doing the thing for real.
5. **Report every outcome, including failure.** Silence must never be the success signal. Alert on success, failure, AND skip.

**Retry windows: separate transient blockers from real failures.** A job that depends on something ambient (a browser being open, a VPN, the machine being awake) cannot be scheduled at one fixed time and called reliable. Sweep a window instead, but only if the alerting is retry-aware, or an outage becomes a dozen identical alerts and the next real one gets ignored:

- **Transient** (dependency not ready yet, later attempt may clear it): log, stay silent during the window.
- **Real** (failed gate, missing credential, unparseable confirmation): alert immediately; a human is needed and more attempts will not help.
- **Already done** (idempotency guard fired): silent. This is the steady state.
- **Close the window with one `--final` run** that alarms if the period never completed. That single alert is the "we missed it" signal, and it fires once.

If the job drives a browser, it also inherits the verify-before-claiming rule: parse the confirmation for a real identifier (an order number), never trust that the click "worked".

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
2. **Restrict to safe content types.** Only auto-generated or temporary content is eligible for bulk deletion (unlisted uploads, draft posts). Never bulk-delete public, private, or manually curated content.
3. **Filter by metadata.** Apply duration, privacy status, date range, and ownership filters to exclude anything that shouldn't be touched (for example, skip full-length videos when deleting short-form clips by filtering to <=90s).

**Why:** Platform deletions are irreversible. A wrong date range or missing filter can wipe out manually curated content.

## Verify Before Asserting

Don't claim the user did something (submitted an application, sent an email, published a post) unless you can verify it through an authoritative source. The existence of prep materials, drafts, or related files does NOT confirm the action was completed.

**Why:** an agent asserted the user had applied to a role because prep materials existed in cloud storage. The application was never submitted, and incorrect context was passed on to a third party as a result.

**How to verify:**
- **Applications/emails:** check the sent folder for confirmations
- **Published posts:** check the CMS or the live URL
- **Deploys:** check process status and server logs
- **Git pushes:** check `git log origin/main` or `gh pr list`
- **Any user action:** look for the completion artifact, not the preparation artifact

## Health Monitor Self-Exclusion

**When writing a health monitor or watchdog that scans supervised processes, always skip the monitor's own process.**

If a health monitor watches all processes, including itself, it can trigger auto-immune loops: the monitor detects its own high restart count, attempts to fix it, restarts itself, which increments the restart count, which triggers another fix attempt.

```python
for proc in processes:
    if proc["name"] == SELF_PROCESS_NAME:  # skip self
        continue
    # ... health checks
```

Encountered directly: an error-handling daemon scanned every supervised process including itself. Widening its dedup window (1h to 24h) was also needed to prevent repeated self-triggering within a single incident window.

**Rule:** Any monitoring daemon that enumerates processes must exclude its own process name from health checks.

### Process-Manager Log Artifacts and ANSI Codes in Error Handlers

Two related patterns that cause error-handler crash loops or alert floods when reading process-manager log output:

**1. Log format artifacts belong in IGNORE_PATTERNS**

Process-manager log output contains formatting lines that are not actual errors: separator lines (`---`), the log command echo, and the handler's own prefixed log lines. Without ignore patterns for these, the handler classifies them as errors and alerts/loops on its own output.

```python
IGNORE_PATTERNS = [
    r"\[error-handler\]",  # handler's own log prefix
    r"pm2 logs",           # log command echo
    r"^---$",              # separator lines
]
```

**2. ANSI escape codes break dedup signatures**

Process managers sometimes emit ANSI escape sequences in log lines (color codes, cursor movement). If not stripped before computing the error signature hash, the same underlying error produces different hashes across restarts, causing an alert flood.

```python
import re
ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')

def _strip_ansi(text: str) -> str:
    return ANSI_ESCAPE.sub('', text)

clean_line = _strip_ansi(raw_line)
signature = hashlib.md5(clean_line.encode()).hexdigest()
```

**3. Log message prefixes that mis-trigger monitoring**

Avoid structured-looking prefixes like `SUCCESS:`, `ERROR:`, or `WARN:` in info/success log messages of a monitoring daemon. If the daemon (or a downstream watcher) pattern-matches on its own log output, a `SUCCESS:` prefix in a normal info line can look like a different error class and re-enter the alert pipeline.

```python
# BAD — "SUCCESS:" could be caught by a pattern scanner watching for status keywords
logger.info(f"SUCCESS: fix complete (cost: ${cost:.4f})")

# GOOD — plain message; log level already communicates severity
logger.info(f"fix complete (cost: ${cost:.4f})")
```

## When a Vendor CLI's Free Tier Is Withdrawn, Every Silent Consumer Breaks at Once

A free-tier auth mode for a third-party model CLI can be discontinued account-wide with no warning, after which every invocation throws a tier-ineligibility error before the first request. Such an error occurs during client setup, so no flag (`--model`, a trust bypass, a different cwd) suppresses it.

**Silent impact on automated runners:** every consumer that shells out to that CLI now errors. The process exits non-zero, but cron wrappers that ignore exit codes never alert. Any "fallback to the other vendor" path built on it is broken too, which is worse: the fallback is exactly what nobody tests.

**Mitigation:** treat the CLI as unavailable until migrated to a paid key or the successor product. Before relying on any such call in automation, probe it: `<cli> -p "ok?" 2>&1` and check for the tier error.

**General rule:** any automation whose fallback path depends on a *free* tier of a third-party service should probe that path on a schedule, not assume it. A fallback you never exercise is a fallback you do not have.

## Shared Poller Resource Gates Must Be Scoped to the Executing Machine

When a poller or executor dispatches jobs to BOTH local and remote workers (locally, and via SSH to another host), any resource gate based on the local machine's resources (RAM, CPU, disk) must NOT fire for remote jobs: those jobs consume zero local resources.

Encountered directly: a multi-worker dispatcher had ONE memory watchdog for all jobs: when local `MemAvailable < 100MB`, it killed the tracked PID. For remote SSH jobs the tracked PID was only the SSH client, while the real work ran on the remote worker using zero local memory. Local memory pressure was killing healthy offloaded sessions. The symptom was a log line reading "Memory watchdog: only 93MB available, killing process PID" while dispatch counts showed only remote dispatches and zero local ones.

**Fix pattern:** add a `skipMemoryWatchdog` (or equivalent) flag to the polling function. Set it to `true` for remote-dispatched jobs. Timeout and output-size watchdogs can still apply to remote jobs (they guard a hung SSH or runaway output regardless of location).

**Rule of thumb when adding any resource guard to a shared poller:** ask "does this resource live on the machine actually running the session?" If the job is remote, local RSS/mem/CPU is irrelevant.

## A Repo's Main Checkout Must Never Be Left on a Merged Feature Branch

**Symptom:** the primary working copy of a repo (not a worktree) is checked out on a feature branch whose PR has already been merged. The local branch is stranded and local `main` silently falls behind `origin/main`, sometimes by several commits, with no error surfaced anywhere.

**Why this is worse than an ordinary stale branch:** session-start hooks, instruction-file loads, and guidance reads for every concurrent session on that machine execute against whatever is checked out in the main checkout. A stranded branch means every other session (interactive or automated) silently reads outdated or divergent guidance. Any session that does a plain `git checkout <branch>` in the main checkout to open a PR, rather than using a worktree, and never switches back after the merge, causes this.

**Detection:** in any repo's main checkout, `git branch --show-current` should always equal that repo's default branch except for the brief window someone is actively working on a real feature. If it isn't, check whether the current branch's PR is already merged (`gh pr list --head <branch> --state all`): if so, the checkout was simply never returned home.

**Fix:** verify the current branch is a strict subset of the default first (`git diff origin/main HEAD --stat` should be empty or default-only), then:

```bash
git checkout main && git merge --ff-only origin/main && git branch -d <stale-branch>
```

Do not force anything. If the diff isn't empty, treat it as in-progress human work: stash and investigate, don't discard.

**Prevention:** any session opening a PR from a main checkout should use a worktree instead: `git -C <repo> worktree add /tmp/<label> -b <branch>`, work there, and leave the main checkout untouched on its default branch throughout.

## Never Inline Single-Quoted Code in `ssh 'block'`

`ssh host 'big block ...'` wraps the whole remote command in single quotes. Any single quote INSIDE the block (JS `app.get('/path', ...)`, Python `'text/plain'`) terminates the outer quote and silently mangles the code. This has shipped invalid JS to a production server file and crash-looped the service.

**Fix:** write the script or patch to a LOCAL file and `scp` it, then run `ssh host 'python3 /tmp/file.py'`. Always syntax-validate on the remote host (`node --check`, `bash -n`, `python -m py_compile`) BEFORE restarting, and keep a `.bak` to restore.

### Use the SSH Config Alias, Never a Bare IP

`ssh <ip> "<cmd>"` fails with "Permission denied (publickey)" whenever `~/.ssh/config` has no `Host` entry matching the bare IP: only named aliases carry the correct user and identity file, so a bare-IP call falls back to the local default user and the wrong key.

This silently broke a restart-storm detector: every ssh call failed, and a `|| echo 0` fallback on the restart-count check made storm detection permanently report 0 restarts regardless of the real count. The same failure had been noted once before in a failure log, worked around in-session by using the alias, and never fixed at the source, so it kept recurring.

**Rule:** when a documented working command references a host by raw IP, swap it for the configured alias rather than treating a one-off Permission-denied as a transient fluke. Check `~/.ssh/config` for the actual alias before re-deriving the fix each run.

## Audit Agent CLI Versions on Every Host, and Pin Fan-Out Defaults Before Upgrading

Version drift silently keeps already-fixed reliability bugs in play, and headless hosts drift worst because nobody watches their startup banner. A single audit found the interactive workstation 19 versions behind and a server host 8 behind, both still exposed to fixed bugs including retained memory from truncated tool outputs, truncated stream-json output at exit for slow-reading consumers, and quadratic message-normalization stalls in long sessions.

1. **Check `claude --version` against `npm view @anthropic-ai/claude-code version` on EVERY host that runs the CLI** (workstation, server, containers), not just the interactive one.

2. **Pin fan-out and search behavior BEFORE upgrading**, because upgrades change defaults underneath you: one release raised the default nested-subagent spawn depth from 1 to 3, and another added a session-wide web-search cap. Set `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` explicitly so an upgrade never changes spend or research depth implicitly. Implicit depth-3 nesting can outrun what a usage gate reasons about, since the gate models only the fan-out the top-level session controls.

3. **Set `fallbackModel`** (array, max 3 entries, does NOT merge across settings files) on every host running headless runners. Without it, a runner hard-fails when its primary model is unavailable or overloaded.

4. **Verifying a settings change means launching the CLI and getting a reply**, not just parsing the JSON. An unsupported or misspelled settings key is accepted silently and does nothing. Corollary: env vars introduced in a version NEWER than the installed CLI are inert until the upgrade lands, so setting them is upgrade-preparation, not an active change.

5. **Containerized installs drift worst, and the host version tells you nothing about them.** An unpinned `RUN npm install -g @anthropic-ai/claude-code` in a Dockerfile freezes whatever was latest at build time and never moves again. One audit found eight live containers spread across three versions, all far behind their hosts.

   **Match the fix list to how the consumer actually invokes the CLI before calling drift urgent.** The first pass of that audit asserted the containers were exposed to three specific bugs. Reading the server code refuted all three: the containers spawned `claude -p --allowedTools ...` accumulating PLAIN stdout (no `--output-format stream-json`), attached NO MCP servers, and ran one-shot per request rather than long sessions. Version drift is real, but a fix only matters if the invocation path touches it. **Check the spawn arguments, not the version number alone.**

   Two consequences that do hold:
   - **Pin the version in the Dockerfile** (`@anthropic-ai/claude-code@<version>`). Unpinned means every rebuild is a silent, unreviewed upgrade that can change defaults, and builds are not reproducible.
   - **Rebuild on a cadence, not on demand.** An unpinned image that is never rebuilt is the worst of both worlds: frozen on an old version AND guaranteed to jump many versions at once whenever it finally is rebuilt. Enumerate with `docker exec <container> claude --version` per container.

### Unpinned Installs Make Rebuilds a Silent No-Op; `docker exec` Probes as Root and False-Alarms on Auth

Rebuilding a fleet of containers to a current version surfaced two traps that make a rebuild look successful when it did nothing, and make a working container look broken.

1. **An UNPINNED install plus Docker layer cache means `docker compose build` is a silent no-op.** One container rebuilt cleanly and came back on its original, months-old version. Its `RUN npm install -g @anthropic-ai/claude-code` line was byte-identical to the previous build, so Docker reused the cached layer and never re-ran npm. The others upgraded ONLY because pinning the version changed that line and busted the cache. So an unpinned image is doubly bad: it freezes at build-day latest AND resists the rebuild you would use to fix it. Either pin the version (preferred, and the cache-bust is a feature) or build with `--no-cache`. Always assert the version INSIDE the container after a rebuild (`docker exec <c> claude --version`); never infer success from a clean build log.

2. **`docker exec <container> claude -p ...` runs as ROOT and reports "Not logged in", even when the service is perfectly authenticated.** Credentials live under the service user's home (`/home/node/.claude/.credentials.json`), but root's HOME is `/root`, so the CLI finds nothing. This looks exactly like a rebuild wiping credentials and will trigger a false rollback. Probe as the service user instead:

   ```bash
   docker exec -u node -e HOME=/home/node <container> claude -p "..."
   ```

   Confirm any suspected breakage against an un-rebuilt container as a control before acting.

3. **A pending auth status immediately after a rebuild is expected, not a failure.** If the server checks auth on a long interval (30 min) with the first check about 60s after start, wait for the "checked N seconds ago" field to be populated before judging.

Credentials survive a rebuild when they live in a named volume mounted at the service user's config dir, not in the image, so `docker compose build && up -d` preserves them and no re-OAuth is needed.

## The Agent Sandbox Is Not Usable Inside Docker or Under WSL2

Investigated and CLOSED as not-applicable, correcting an earlier recommendation that called strict network allowlisting "the highest-value remaining security item."

**Containers cannot use it.** The sandbox is enforced by bubblewrap, which requires unprivileged user namespaces. Inside a container `bwrap` fails with `Creating new namespace failed: Operation not permitted`, including the weaker variant that binds the existing `/proc`. The host kernel is NOT the blocker (`/proc/sys/user/max_user_namespaces` reads a large number inside the container); Docker's default seccomp profile blocks `CLONE_NEWUSER`. Enabling it would require running with `--privileged`, `--cap-add SYS_ADMIN`, or `seccomp=unconfined`.

That trade is backwards: it punches a hole in the OUTER isolation boundary in order to add an inner one, on containers whose entire purpose is isolating untrusted public input. **For a container, the container IS the sandbox.** Do not weaken it to add a nested sandbox. The weaker-nested-sandbox option does not rescue this: it addresses a container that cannot mount a fresh `/proc`, not one forbidden from creating namespaces at all.

**WSL2 cannot use it either, for a different reason.** Under WSL2, sandboxed commands cannot launch Windows binaries or anything under `/mnt/c/`. If your working directory lives on the Windows filesystem and Windows interop is routine, enabling the sandbox breaks that wholesale. Docker is separately documented as sandbox-incompatible.

**Where the real mitigation lives instead.** The exposure that motivated this was broad shell access acting on untrusted public input. Since the OS-level sandbox is unavailable, the controls that DO apply are: a narrow `--allowedTools` list, account isolation, the container boundary itself, and an output scrubber. Harden those.

**Verify before reopening:** run `docker exec -u root <container> bwrap --ro-bind / / --dev /dev echo ok`. If it still prints `Operation not permitted`, this conclusion stands.

## A Recovery Action That Cannot Fix the Condition Must Be Gated on Classifying the Condition First

Restart storms come from a health check with fewer states than reality. An auth-refresh watchdog had two: `ok` and "not ok", where "not ok" meant stale credentials and the remedy was recreating the container. Being out of quota also reads as "not ok", so it inherited a remedy that cannot return quota: 1,273 container recreates across six containers, tearing down and rebuilding every 10 minutes for the length of each limit window, plus an alert telling the operator to run a login command for a condition login cannot fix.

The diagnostic that settles it is **correlation across independent units.** Six containers have six independent credential files, and the recreates fired in lockstep at the same minute on consecutive nights. Independent files do not go stale in the same second; one shared account runs out of quota in the same second. **Lockstep failure across units that share exactly one thing points at the shared thing.**

**Rules:**
1. Before wiring an automatic remedy to a failure state, ask which conditions land in that state and whether the remedy addresses each. If it addresses only some, classify first and let the others fall through to a wait.
2. Detect operational strings by wording family, not one literal. A guard pinned to one literal silently stops matching when the vendor rewords, and the failure is invisible because the wrong branch still runs. Scope loose patterns to short output so real content quoting "limit" is not swallowed.
3. Put the classifier where the condition is observed (the health endpoint), and keep a wording fallback in the consumer, so the fix applies to already-running processes without a rebuild.
4. A recovery loop that re-runs on a fixed interval should record what it observed, not just what it did. These logs said "auth=failed, recreating container" and never printed the error text, so the misclassification was invisible for months in plain sight.
5. Alert text is part of the fix. An alert naming the wrong remedy trains the operator to distrust the alert.

Applies to any watchdog: process restarts, container recreates, auth refreshers, stale-job requeues.

## A Retry Cap Must Not Be Spent on an Infrastructure Outage

A bounded-retry recovery loop (`MAX_ATTEMPTS`, cron every N minutes) permanently kills every in-flight job when the dependency is down longer than cap x interval. The attempts are consumed against a dead socket, and once a row is at the cap the recovery queries exclude it forever, so the work stays dead long after the dependency recovers and nothing ever retries it.

Encountered directly: a dependency fleet was down for about an hour. Recovery ran every 5 minutes with `MAX_ATTEMPTS=2`, so both attempts were spent inside the first ten minutes of the outage. A job stayed dead for 5 hours with a useless error until a human reported it.

The distinction that fixes it: a CONNECTION-level failure (`ECONNREFUSED`/`ENOTFOUND`/`ECONNRESET`/socket hang up) is a statement about the infrastructure, not a verdict on the job. A failure returned BY the dependency (bad response, timeout while it was answering) is a verdict on the job and must still count.

**How to apply:**
1. **Preflight the dependency** (`GET /health`) before the run counts an attempt, resets a status, or posts an alert. During an outage the whole run becomes a silent no-op, which also stops the every-5-minutes alert spam that trains people to ignore it.
2. **In the catch, refund the attempt** on a connection-level error and restore the row's prior status, so the next run retries it. Bound it with an age window (24h) rather than the attempt cap.
3. **Test the decisive property directly:** run N consecutive recovery passes against a CLOSED PORT and assert the row is still retryable afterwards. A single-pass test passes on the broken version too.

### A 429 or 503 Is a Verdict on the Dependency's Quota, Not on the Row

Observed after shipping the fix above: it refunded the attempt only for CONNECTION-level faults, matching error codes such as `ECONNREFUSED` and `ECONNRESET` plus the strings `socket hang up` and `fetch failed`. A service that answers HTTP 429 "temporarily at capacity" is reachable by that test, so the attempt was charged. Both attempts for the row were spent inside a single 5-minute cron tick and the work then dropped out of every recovery query while the account was merely out of quota.

The counterintuitive part worth remembering: making the dependency's rejection **faster and more precise made this worse, not better.** An admission gate had been added that detects the quota state up front and rejects in milliseconds with the parsed reset time. Before that, each attempt at least consumed real time and the two retries were spread out; afterwards both were burned instantly against a wall that was going to clear on a known schedule.

**General rules:**
1. Classify a failed dependency call by WHOSE fault it is, not by whether the socket opened. Connection refused, HTTP 429, HTTP 503, and an explicit quota or rate-limit response are all statements about the dependency's availability. Only an error produced while the dependency was genuinely serving the request is evidence about the row, and only that should spend a retry.
2. If the dependency tells you WHEN it will recover (a reset timestamp in the 429 body or a `Retry-After` header), defer until then instead of merely refunding. Refunding alone means the next tick retries immediately and refunds again, which works but is pure noise.
3. A retry cap plus a fast-failing dependency is a silent work-loss combination. Rows at the cap are excluded by the selecting query, so nothing alerts and the backlog just stops existing.
4. Keep the user-visible escape hatch independent of the internal counter. A stored failure message that renders with a Retry button whose route resets the row and re-runs WITHOUT consulting the attempt counter lets a human recover work the automation gave up on.

## A Watchdog That Kills Out of Band Must Set a Kill Reason, or the Death Reads as Success

A supervisor that terminates a job from outside the code path that reaps it leaves the reaper with only one observable: the process is gone. Absent an explicit reason, "gone" is indistinguishable from "finished", so the system reports a clean completion carrying whatever partial work existed.

Encountered directly: a stall watchdog SIGKILLed a job at 6 minutes of silence; the completion poller saw a dead pid with `killReason=null` and resolved normally, so the user saw 21 minutes of tool narration under an ordinary completion footer and no answer.

Two corollaries:
1. **A silence-based liveness threshold must exceed the longest legal quiet operation.** A single shell tool call may run 600s emitting nothing, so a 300s stall timeout kills healthy work.
2. **The explanation must travel on the channel the user actually reads.** Streaming UIs render the stream, not the returned value, so a notice appended only to the return string is invisible.
