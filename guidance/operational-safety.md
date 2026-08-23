<!-- Load when: self-deploy loops, restart storms, hook loops -->
# Operational Safety

Prevent feedback loops, restart storms, and cascading failures in automated systems.

## Self-Deploy Loop Prevention

**The scenario:** An agent job modifies the service that spawned it, then deploys or restarts that service. The service restarts, recovers the "active" job from persistence, re-attaches to the still-running process, and the cycle repeats. Each restart kills in-flight work and creates cascading failures.

**How it happens:**
1. A service spawns an agent job targeting the service's own repo
2. The agent finishes changes and runs a restart or deploy command against that service
3. The service restarts, loads its persisted job state, finds the job still "active"
4. The service re-attaches to the process (or re-queues the job)
5. The job or a recovered job triggers another restart
6. Repeat indefinitely

**Defenses (layered):**

1. **Hard guard in the deploy tooling:** The `deploy` and `restart` verbs check the persisted job state for active jobs before restarting the service. If jobs are active, the command is refused with an error. This is the primary barrier.

2. **Prompt-level warning in the job executor:** When a job's working directory is inside the service's own repo, a self-restart-guard message is prepended to the prompt telling the agent not to restart the service. This is a soft barrier (the agent can ignore it).

3. **SIGINT handler in the service:** The service refuses SIGINT during startup (30s grace) and while jobs are active. The process manager sends SIGTERM to force shutdown. This prevents cascading SIGINTs from child processes.

**If a loop is already happening:**
1. Kill the stale child processes: `ps aux | grep <agent-binary> | grep -v grep` then `kill <pids>`
2. Clear the persisted jobs: edit the job state file, set `"activeJobs": []`
3. The service will stabilize on next restart with no jobs to recover

**Rule:** Never deploy or restart a service from within a job that service spawned. Make changes, commit, push, and note that a manual restart is needed.

## Restart-Recovery Loop (Externally Triggered)

**The scenario:** A long-running job is in progress. An auto-merger merges a PR and calls the deploy command. The deploy guard sends SIGINT, but the service ignores it (active jobs). The process manager escalates to SIGTERM, force-killing the service. On restart, the service loads its job state, finds the incomplete job, re-queues it, and starts running it. Meanwhile the auto-merger retries the deploy (or another merge triggers it), creating an infinite loop of: deploy, kill, restart, recover job, deploy.

**This is distinct from the self-deploy loop** because the deploy is triggered externally, not by the job itself. The deploy guard does not help because the process manager force-kills after SIGINT is ignored.

**Defenses:**

1. **Recovery attempt limit:** Long-running jobs track `recoveryAttempts` in their persisted state. Each restart increments the counter. After 3 attempts, the job is abandoned instead of re-queued. This breaks the loop even if other defenses fail.

2. **Active-job check in the auto-merger:** Before calling the deploy command, the auto-merger reads the job state and checks for active jobs. If any are active, the deploy is deferred for 60 seconds and retried. This prevents the deploy from killing active jobs in the first place.

3. **Existing deploy guard:** Still in place as a third layer; refuses to restart if active jobs exist. But since the process manager force-kills after SIGINT, this guard only works when the process can actually be signaled gracefully.

**If this loop happens again:**
1. Stop the process; halt the cycle
2. Edit the job state file; set `"activeJobs": []` and `"queue": []`
3. Start the process; clean restart with no recovery
4. Check error logs to identify the root cause

**Prevention rules:**
- Never merge PRs to a service's repo while long-running jobs on that service are active
- If you must deploy during an active job: stop the process, deploy, then start it (the job will be lost, but no loop)

## Restart Storm Detection

A restart storm is when a managed process enters a rapid restart cycle (restarts > 5 in under 5 minutes).

**Signs:**
- The process manager's list shows a high restart count (e.g., 16+) with low uptime (seconds)
- Error logs show repeated startup messages in quick succession
- Recovery messages appearing every few seconds

**Common causes:**
- Self-deploy loop (see above)
- Crash-on-startup bug (bad config, missing env var, syntax error)
- OOM kill cycle (process exceeds its memory-restart limit, restarts, loads same data, OOMs again)
- Dependency failure (database down, required service unavailable)

**Response:**
1. Stop the process to halt the restart cycle
2. Check the last 50 lines of its logs
3. Fix the root cause
4. Start the process to resume

## Bash `pipefail` + `grep -c` Silent Failure

**The scenario:** A script with `set -o pipefail` uses `grep -c 'pattern' || echo "0"` to count matches. When grep finds 0 matches, it outputs `0` AND exits code 1. Pipefail triggers the `|| echo "0"` fallback, producing `"0\n0"`. The variable becomes a two-line string that breaks `$(( ))` arithmetic silently: no error, just wrong values downstream.

**Observed impact:** this exact bug caused a security scanner to silently fail for 13 consecutive days. It was detecting secrets daily but crashing before it could report findings. The state file never updated, so it rescanned the same inputs with the same silent crash every run.

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

Without `pipefail`, `$?` is `tail`'s exit code, and `tail` almost always succeeds. The `&&` therefore fires regardless of what the real command did. This produced a **false "PUSHED" twice in one session**: once when the token lacked `workflow` scope to create `.github/workflows/`, and once when a pre-commit gate had blocked the commit so there was nothing new to push. Both times the operator was told the work was published when it was not.

This is worse than an ordinary bug because the wrong output is a **claim about system state**.

```bash
# RIGHT: capture, test, then report
if out=$(git push -q origin main 2>&1); then echo "PUSHED"; else echo "FAILED: $out"; fi

# ALSO RIGHT: check the real command, not the pipeline
git push -q origin main; rc=$?; [ $rc -eq 0 ] && echo "PUSHED"
```

**Rule:** never end a pipeline with `&& echo "<success>"`. For anything whose success you will report, capture the exit code of the command itself, and verify the outcome against the remote or the target rather than against your own echo. After a push, `git ls-remote origin <branch>` and compare to local `HEAD`: that checks the thing you actually care about.

## Blanket Rename Across Executable Files Is a Destructive Edit

A repo-wide `sed` looks like a rename and behaves like a rewrite. Three failures from a single session, all from the same batch of commands:

- **Delimiter collision.** `sed 's#old#new#'` against content containing `#` (every shell comment) mangled a script into a single corrupted line, prefixing all 95 lines with the replacement text.
- **Syntax destruction.** Replacing a bare word with a multi-word phrase broke a shell `case` pattern, because `some multi word phrase/*` is not a valid glob branch. The file stopped parsing.
- **Prose damage that survives review.** The same replacement rewrote a repo name *inside a path*, so a user-facing error told people to consult a nonsense path with spaces in it. The gate still worked; its instructions were nonsense, and nothing automated flags an absurd string.

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

**The scenario:** A script spawns the agent CLI as a subprocess (Python `subprocess.run`, Node `spawn`/`execSync`, bash pipeline). The parent process already has permissions skipped, but the subprocess is a fresh CLI invocation that does not inherit it. When the agent tries to use tools (web search, fetch, bash), it prompts for permission. With no TTY, the prompt goes to the void and the session silently fails or produces degraded output.

**Observed impact:** a research script spawned the CLI for deep research. The top-level runner had `--dangerously-skip-permissions`, but the subprocess call did not. Every research request's web-search calls were silently blocked, producing reports without web data.

**Rule:** Every headless CLI invocation that runs without a TTY (cron, subprocess, server route, background job) MUST include `--dangerously-skip-permissions`. This includes:
- Python `subprocess.run([CLAUDE_BIN, "-p", "--dangerously-skip-permissions", ...])`
- Node `spawn('claude', ['-p', '--dangerously-skip-permissions', ...])`
- Bash `$CLAUDE_BIN -p --dangerously-skip-permissions`

**Detection:** worth a standing check that scans all repos for agent subprocess calls missing the flag.

**Also required: `--no-chrome`** for headless environments. The CLI may attempt to open a browser (e.g., for OAuth or a dashboard). In headless VMs or daemonized processes, this silently hangs or errors. Add `--no-chrome` alongside `--dangerously-skip-permissions` for all automated invocations:
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

**Observed impact:** a service used `execSync('claude -p --model <model-id>', { input: prompt })`. Every call passed the model flag string as the prompt instead of the real payload.

**Rule:** When combining piped stdin with any extra flags (`--model`, `--output-format`, etc.), always use `claude --print` as the mode flag, not `claude -p`.

### Strip CLAUDE_CODE_* Env Vars From Subprocess Invocations

> **Correction:** this rule was originally written under the belief that inherited `CLAUDE_CODE_*` env vars caused a synthetic-401 incident. **That diagnosis was wrong.** Follow-up isolated testing (full polluted env including `CLAUDE_CODE_EXECPATH`, `CLAUDECODE=1`, and a dead `CLAUDE_CODE_SESSION_ID`) returned `is_error:false`. The true cause of those 401s was the OAuth refresh script being **rate-limited for several consecutive cron cycles**, leaving an expired access token. See "OAuth Refresh Rate-Limiting" below. The env-strip pattern is kept here as **defensive hygiene only**; it is not the fix for the observed incident.

**Defensive scenario:** A long-running daemon that was started (or restarted) from inside an agent session inherits `CLAUDECODE=1` and `CLAUDE_CODE_SESSION_ID` in its env. There is no reproducible failure from this alone, but stripping the vars when spawning a `claude -p` subprocess is cheap insurance against any future CLI behavior change that might treat a nested-session-marker env as special.

**When to apply:** Long-running services (daemons, server routes) where the inherited env is opaque or stale, and where you want subprocess invocations to look like fresh shell calls. Not required for cron jobs that already start with a clean env.

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

**Why a process manager captures these vars:** it captures the full env at daemon start (including any `CLAUDE_CODE_*` vars from the terminal session that ran the restart). The vars persist in the process table for the lifetime of that process slot, even across subsequent restarts, until the manager itself is restarted from a clean environment. Whether the CLI cares about them in subprocess context is a separate question; see the correction above.

**Also strip `NODE_CHANNEL_FD`** when launching non-Node subprocesses from a Node.js parent (e.g., a Python worker called from a Node service). Node.js IPC sets `NODE_CHANNEL_FD` in its own env; child processes that themselves use Node runtimes (such as a media downloader's JS challenge solver) inherit this FD reference and can fail with IPC errors because the FD is already closed or invalid in the new process.

Observed: a Python pipeline ran inside a Node.js parent; a downloader's JS challenge solver inherited `NODE_CHANNEL_FD` and errored with IPC channel failures. Fix: strip it before spawning:

```python
env = kwargs.get("env") or os.environ.copy()
if "NODE_CHANNEL_FD" in env:
    del env["NODE_CHANNEL_FD"]
kwargs["env"] = env
```

### OAuth Refresh Rate-Limiting (the real cause of the synthetic 401s)

**The scenario:** A token-refresh script runs every 3h via cron and calls the OAuth token endpoint with a `refresh_token` grant. The endpoint is **rate-limited**, and under load can return `rate_limit_error` for multiple consecutive cron cycles.

**Observed incident:** four consecutive cycles failed with `rate_limit_error`. The access token expired roughly 7h into the failure window. Every daemon doing `claude -p` during that window got a synthetic 401 with `model: <synthetic>` and `result: "Failed to authenticate. API Error: 401 Invalid authentication credentials"`. The CLI's `--output-format json` returns this as `is_error:false` `subtype:success` (confusingly), so the failure is not visible via standard subprocess exit codes; only by parsing the `result` field for the auth-error string. Eventually a later cycle got through and the token recovered.

**Detection signal:**
- `result` field of `claude -p --output-format json` contains "Failed to authenticate" or "401 Invalid authentication credentials"
- The refresh log shows `ERROR: OAuth refresh failed: rate_limit_error` on consecutive cycles
- Daemons silently fall back to degraded mode

**Mitigations:**
1. **6h refresh threshold** (`REFRESH_THRESHOLD_MS=21600000`); refreshes ~3 cron cycles before expiry instead of 1.
2. **Intra-cycle retry with backoff**; up to 3 attempts per run, backing off 60s/240s on `rate_limit_error` and 30s on other failures.
3. **Consecutive-cycle failure counter**, stored under a cache dir. After 2 or more consecutive failures, post an alert to your notification channel with hours-remaining context. Counter resets on any successful or healthy cycle.

**When the consecutive-failure alert fires:** the alert means the API refresh path is stuck. Do NOT wait for the next cron cycle; trigger the browser-based relogin path. The browser OAuth path is not subject to the API rate limit and will recover the token immediately.

**Why "strip the env vars" was misdiagnosed as the fix:** the env-strip shipped the same morning the OAuth refresh independently recovered; the next observation cycle was clean and the env-strip was assumed causal. Isolated repro the following day showed the env vars alone do not produce 401.

**Layered defense: browser path as safety net.** The cron refresh path and the browser-based relogin path are independent recovery mechanisms. When the OAuth API endpoint is rate-limiting (the cron path fails), the browser-based path completes the login via the web OAuth flow, bypassing the API endpoint entirely. Validated in production: a manual run and a cron cycle both exhausted all retries with `rate_limit_error`; the browser relogin chain sidestepped the rate-limited endpoint; the next cron cycle ran clean with the counter reset to 0.

**Implication:** When debugging a prolonged OAuth failure, check both paths. If the cron log shows persistent `rate_limit_error` and the access token is expired, the recovery path is NOT to wait; it is to trigger the browser relogin, which is not subject to the API rate limit.

### React SPA Hydration Race in Browser-Driven OAuth Scripts

**Symptom:** A browser automation script clicks the OAuth Authorize button. The click reports success but nothing happens: no navigation, no callback. The same script works fine minutes later.

**Why:** React SPAs render the DOM before hydrating (wiring up event listeners). The Authorize button can be visible and selectable during this gap but fires no event when clicked. The window is typically under 2s but is reproducible on freshly-woken browser sessions.

**Observed:** one container's relogin failed with "callback tab not found" while sibling containers running the identical script ten minutes later succeeded. The fix: add `sleep 4` after locating the consent tab, then retry the click once if no callback appears within 25s.

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

**Symptom:** All automated relogins fail on the same night with `callback tab not found`. The browser session IS active (the provider's app shows the account logged in), but clicking Authorize redirects to a re-auth/login URL instead of the OAuth callback.

**Root cause:** the provider enforces a **max auth-age**, the elapsed time since the account last performed a real sign-in, in addition to activity-age, before granting the inference OAuth scopes. A session-keepalive script slides the activity clock but cannot reset the auth-age clock. When auth-age exceeds the threshold, the consent flow forces a full logout regardless of session freshness.

**Differentiator from the hydration race (above):** all containers fail on the same night. The hydration race is a single-container, timing-based event that a retry resolves. Simultaneous failure across all containers is diagnostic of the auth-age pattern.

**Why automation may not self-heal:** after the forced logout, the OAuth grant page lands on a federated-identity button whose popup the browser blocks for extension-synthetic clicks (it requires a real user-activation gesture). The script cannot complete the re-login loop unattended without extra work.

**Recovery (manual path):** sign the account out of and back into the controlling browser. The browser session then satisfies the auth-age check and nightly relogins resume.

**~~No user-facing impact during the failure window~~: FALSIFIED.** This paragraph used to read: *"Containers keep running. Their existing access tokens auto-refresh via the refresh-token OAuth flow. Only the nightly refresh-token rotation is broken, not the live inference path."* That is true for days, not weeks, and it was the load-bearing premise for muting the nightly alert email. A refresh token carries **its own expiry** (`refreshTokenExpiresAt`): **roughly 28 to 30 days, reset only by a successful interactive rotation and NOT extended by ordinary refreshes.** (An earlier version of this note said "hours to a day", which was measuring the tail of an already-dying chain rather than the rule. Every session rotated after the fix read ~30 days out, and each one that died did so ~30 days after its last successful rotation.) That is why breaking rotation did not surface for four weeks: **the fleet had a month of runway and spent all of it silently.** Any session that idles past that window wakes up unable to refresh; the CLI then writes the credential file back with **empty-string** `accessToken`/`refreshToken` and `expiresAt: 0`, and the health endpoint reports `auth: "failed", "OAuth session expired and could not be refreshed"`. Nothing automated can recover that state, because minting a new refresh token requires the interactive login that auth-age is blocking.

Measured after 11 nights of un-repaired auth-age failure: **7 of 9 sessions dead**, each with a blanked credential and a `refreshTokenExpiresAt` in the past. The two survivors were simply the two whose chains never missed a refresh.

**Rule:** treat an auth-age failure as a deadline, not a steady state. Build the alarm for it: a daily monitor that reads `refreshTokenExpiresAt` for the host and every running container, warns under 20 days and pages under 10. That one field measures both how long until a credential is unrecoverable and how long rotation has been failing, and it does not care *why* rotation stopped, so it also catches the quiet skip (a pre-flight that exits 0 when the browser is asleep is right for one night and fatal over a fortnight). Have both relogin scripts close the tabs they open, because a leftover error page from run N is the bug in run N+1: benign on night one and an outage by week two. The alarm that matters is the one on a blank credential, not the nightly relogin email.

**Operational rule:** when an automated relogin fires a final-failure alert, check whether the alert message says the session was logged out at grant time. If it does, trigger a manual browser re-sign-in; do NOT attempt automated recovery, retry loops, or container restarts.

**RESOLVED, and the later failures were NOT auth-age.** The automation was eventually made to clear the wall unattended, and the fleet was restored without any human sign-in. Four separate defects had stacked up, each masked by the one in front of it. In causal order:

1. **The caller's browser key was being overwritten (the real cause).** A commit moved webhook config into `$HOME/.env` and added `set -a; . "$HOME/.env"; set +a` to all three browser-driving scripts. That file also defines the default browser-agent key, and `set -a` plus source lets the **file beat the caller**. Every alternate-profile rotation is invoked as `BROWSER_AGENT_KEY="$BROWSER_AGENT_KEY_ALT" ...`, so from that day each one drove the **default** browser profile: it opened one account's consent URL in a browser signed in as a different account, and the account chooser it reached never contained the expected address (`"clicked": false, "error": "not found"`). Every "the session is logged out" alert described a profile the run never touched. **Rule:** a script that sources an env file after receiving env from its caller must re-assert the caller's values, or the file silently wins.
2. **The chooser popup was invisible to the tab registry.** A browser-extension release added the identity provider's domain to the manifest's `exclude_matches`. The relay's registry is fed by content-script heartbeats, so from that day such a tab could never appear in the tab list, and the entire account-chooser branch was unreachable code. Fixed by adding a verb that queries tabs via the service worker instead.
3. **Origin containment hard-denied the clicks.** Same release. The sanctioned opt-in is an explicit allow-sensitive flag, paired with an origin allowlist so it re-narrows to the one domain.
4. **The popup is a separate WINDOW, so it is never visible.** Focusing a *tab* does not raise its *window*, so the popup's document sits at `visibilityState: "hidden"` and the browser does not deliver CDP Input events to an unrendered page. Twelve consecutive synthetic CDP clicks reported `{"clicked": true}` at the button's real coordinates while the page never moved; one `el.click()` on the same hidden page advanced it instantly. **Rule:** inside a popup window, use JS clicks. Reserve trusted CDP clicks for the one button that needs user activation (the one that calls `window.open`).

**Bringing the second account to parity** surfaced three further traps, all now fixed in the shared library: the identity provider **versions** its consent paths (two profiles got different path versions on the same day, and the matcher knew neither the new version nor any future number), a **stale** tab on that domain hijacks the loop forever (a leftover error-page consent tab with no buttons classified as consent, clicked nothing, every round, while the real wall was never touched again), and an unclassifiable page needs an **exit** (the catch-all state had no clearing branch, so it "settled" the same page twelve times logging nothing but the word). Rules: match provider states by keyword, not by fixed path; snapshot the provider's tab ids at entry and ignore pre-existing ones, since a popup you did not open is not yours to drive; and always log the URL of a page you could not classify. The host script also gained a per-key extension-status pre-flight, a decoded consent-tab match, foregrounding before the Authorize click (it had been clicking a visibility-gated button on a hidden tab), and failure email with the auth-age suppression, and it stopped warning "restart had errors" on every successful run, which was a restart command being called with no arguments because an empty container list is the normal case.

Also fixed: the consent-tab matcher required a literal `oauth/authorize`, but the provider redirects to `/login?...returnTo=%2Foauth%2Fauthorize`, where it is percent-encoded, so losing the race against the redirect produced "consent tab not found - is the browser signed into the right account?" about a tab sitting right there. Match the **decoded** URL. And on one consent path, Cancel and Continue share the same `jsname` attribute: select the provider's primary button by visible label, never by an opaque attribute.

**Two traps that hid this for six weeks:**

1. **A per-key operation gated on a global signal reports on the wrong thing.** The browser relay's tab endpoint is a single un-keyed registry: every API key sees the union of tabs from **both** browser profiles, while *commands* route per key to one profile's extension. So an `ensure <url>` call would match a URL, hand back the **other** profile's tab, and every later read on that id timed out. The keepalive script was therefore reading the wrong profile's tab and certifying its session daily, logging "session appears alive" while the real session aged out, tripped auth-age, and finally logged itself out. Its content check was correct; it was pointed at the wrong browser. The same bug sat in the relogin pre-flight, which gated on a global `connectedClients` count: one awake profile satisfied it while the other extension was absent. Fixed by probing ownership with a keyed `ping` inside `ensure`, and gating on per-key extension status. **Rule:** if a check is per-profile/per-key/per-tenant, its signal must be too, and "I could not read it" is never evidence of health.

2. **Muting an alert by call site means the mute silently moves.** The original suppression keyed on the *post*-Authorize classifier (one exit code, one wall kind). Weeks later the session went from stale to fully signed out, so the identical wall began failing one call site **earlier**, at the pre-Authorize login-wall check with a different exit code, which was not suppressed. Six emails a night resumed with **no code change on either side** (`git log` confirms no commits that day). **Rule:** suppress on the *classified condition*, and make the classification reachable from every path that can produce it; a mute pinned to one exit code is a mute that expires the moment the failure moves.

### Pin the CLI Binary Path via Env Var, Not a Hardcoded Default

The agent CLI binary is not at the same path on every host (`/usr/bin/claude` on one, `/usr/local/bin/claude` on another). A wrong hardcoded fallback causes silent `[Errno 2] No such file or directory` failures that drop all AI processing without any obvious error in service logs.

**Observed impact:** a service had the wrong hardcoded default. All CLI invocations from it failed silently until the path was corrected.

**Rule:** always prefer a `CLAUDE_BIN` env var over hardcoding, so deployments with non-standard paths can override it. Verify the fallback with `command -v claude` on each host.

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

## Rate Limit Detection in Service Wrappers

**The scenario:** A service wraps `claude -p` (e.g., via `spawn` or `execFile`) and reads stdout for the AI response. When the account hits its usage limit, the CLI exits with code 0 but outputs a rate limit message instead of a real response (e.g., "You've hit your limit... resets 3:50pm PT"). The service treats this as a successful result, returning garbage content to the user.

**Observed impact:** a bridge server returned rate limit text as a "completed" generated document. Jobs were marked successful with useless content because the bridge only checked exit code, not output content.

**Fix:** After collecting stdout from any `claude -p` subprocess, check for rate limit patterns before treating the output as valid:

```javascript
const output = stdout.trim();
if (output.match(/you've hit your limit/i) || output.match(/resets \d+:\d+[ap]m/i)) {
  // Return 429 or retry error, NOT success
  return { error: "AI at capacity", status: 429 };
}
```

**Rule:** Any service wrapping an agent CLI must detect rate limit responses and translate them to errors (HTTP 429 or equivalent). Do not rely on exit codes alone; rate limit messages arrive on stdout with exit code 0.

### Detecting it is half the job; the other half is a parking lot, not a retry

Translating the limit to an error stops the garbage, but it hands the user a failed job they have to re-issue by hand. Routing it into an existing retry ladder is worse: a 1/2/4-minute exponential backoff cannot return quota, so the retries are spent against a condition they cannot change and the job fails anyway. Same shape as the restart storm below: the remedy must address the condition.

The working pattern (a `usageLimit` classifier plus a `parkedJobs` store):

1. **Classify at the single choke point** every spawn path funnels through, not at each call site. Prefer the structured signal (`rate_limit_event` with `status: "rejected"` in stream-json) over string matching, and scope it *per job*; a global "over cap" gauge that also flips on `allowed_warning` will park jobs that finished fine.
2. **Match wording as a family, and gate loose patterns on output length.** The CLI says `your limit` / `your session limit` / `your weekly limit` / `usage limit reached|<epoch>`. When it is genuinely out of quota the rejection notice is the *entire* output, so shortness is the tell; that bound is what stops a long agent report which merely *discusses* rate limits from parking itself.
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

**Observed impact:** three autonomous runners plus a verify script all had this bug. Zero failure alerts had ever fired across roughly 1,000 combined runs; a 45-minute run timed out with no log entry, no state write, and a reused run ID the next day; a verify gate passed proven test failures for weeks.

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

**Observed impact:** a health monitor on a 15-minute cron died at its first `vlog` call on every single run for its entire deployed life. Its log showed only `START:` lines; it never completed a check, never posted an alert, and nothing noticed, because the thing that died WAS the alerting layer. Its own cron scheduling was verifiably fine: **a heartbeat at the start of a run proves scheduling, not completion. Freshness checks must key on an end-of-run marker.**

**Fix:** `if [ -n "$VERBOSE" ]; then log "$*"; fi` (an `if` whose condition is false returns 0), or end the function with `|| true` / an explicit `return 0`.

**Rule:** in `set -e` scripts, never end a function body with a bare `[ cond ] && cmd`.

## Cron Output Redirects Into Root-Owned Dirs Die Silently

**The scenario:** a non-root crontab line redirects into `/var/log/`:

```
*/5 * * * * $HOME/bin/watchdog.sh >> /var/log/watchdog.log 2>&1
```

The shell opens the redirect target BEFORE running the command. If the dir is not writable by the cron user and the file does not exist, the open fails and **the command never runs at all**: every occurrence, forever, with no trace beyond an unread cron mail. The trap is asymmetric: if the log file already exists (created earlier when perms allowed, or pre-touched by root), appending works, so some `/var/log` crons keep working while their siblings are dead, which defeats "the other one works, so the pattern is fine" reasoning.

**Observed impact:** `/var/log` was root-owned 755; 9 of 11 user cron entries redirecting there were dead, including both process watchdogs, the uptime monitor, the error aggregator, the restart alerter, a sync job, and a nightly state backup whose last artifact was 4 months old. The 2 survivors had pre-existing log files. One dead cron had been individually "fixed" earlier by pre-creating its log file; the instance was patched, the class was not.

**Rules:**
- Non-root cron output goes to a user-owned dir (`$HOME/logs/cron/`); never redirect cron output into `/var/log` as a non-root user.
- When you find one broken cron redirect, audit the whole crontab for the class: `crontab -l | grep '/var/log'`.
- Every watchdog/monitor needs periodic end-to-end verification: does its log show a run **completing** (not just starting) within the last interval, and can it still deliver its alert? A monitoring stack in which every layer dies silently (observed: host watchdog crons dead, health monitor dead, and process-manager metrics poisoned, simultaneously) is the default failure mode, not the exception.

## Hook Loop Prevention

Auto-posting hooks run on every agent turn. If a hook failure triggers a retry or a new agent session, you get an infinite loop.

**Rules:**
- Hooks must be fire-and-forget. Never retry on failure.
- Hooks must not spawn new agent sessions without recursion guards.
- Hooks must have timeouts (10s max). A hung webhook should not block the session.
- If a hook fails, log the failure and continue. Do not abort the parent session.

### Stop Hook Safety

Stop hooks that invoke the agent CLI need three guards, provided by a shared guard library that every such hook sources:

- an **env var circuit breaker** (a marker exported into child sessions so a re-entrant invocation exits immediately),
- a **PID lockfile** (so two concurrent hooks cannot both run), and
- a **per-hour rate limiter**.

Classify hooks by tier: Tier 1 observation (no side effects), Tier 2 verification (reads state, may write logs), Tier 3 agent-invoking (must source the guard library).

**Observed impact:** a session-scoring Stop hook ran the scorer via the agent CLI on every session exit. The scorer's own session exit re-triggered the hook. Result: 4,888 recursive sessions in one day and 199M tokens, 78% of that week's usage. Fixed by adding an env var guard plus a content pattern match.

## Job Recovery Safety

When a service recovers persisted jobs on startup:
- **PID alive:** Re-attach and monitor for completion. Do not re-execute.
- **PID dead:** Extract partial output, mark as failed, notify the user. Do not re-run automatically.
- **Multi-turn work partially complete:** Re-queue from the last completed turn, not from scratch.

**Never** automatically re-execute a failed job. The failure may have been caused by the job itself (e.g., it deployed the service). Automatic re-execution would repeat the failure.

## Unattended Jobs That Take Irreversible External Actions

A cron job that spends money, sends a message, cancels a subscription, or files something is not a normal cron job: a bug does not just fail, it does the wrong thing to the outside world, and nobody is watching when it happens. Five requirements, all of them cheap:

1. **Gate on identity, not just success.** Before the irreversible step, assert the thing in front of you is the thing you meant: expected item/recipient name, expected quantity. Refuse and report on mismatch. A checkout page that loads fine is not evidence it holds the right cart.
2. **Cap the magnitude.** A hard ceiling (`MAX_TOTAL`) turns a pricing change, a currency bug, or a duplicated line item into a refusal instead of a charge.
3. **Idempotency guard.** Keep a per-period state file (`$HOME/.state/<job>-last-*.json`) recording the period already completed, and check it first. Without this, a manual re-run, a retry, or two overlapping schedules double-execute. This is the single highest-value guard, because retries are otherwise unsafe to add.
4. **A `--dry-run` that stops immediately before the irreversible call** and exercises everything up to it. This is what makes the job testable at all; without it the only test is doing the thing for real.
5. **Report every outcome, including failure.** Silence must never be the success signal. Send to your notification channel on success, failure, AND skip.

**Retry windows: separate transient blockers from real failures.** A job that depends on something ambient (a browser being open, a VPN, the machine being awake) cannot be scheduled at one fixed time and called reliable. Sweep a window instead, but only if the alerting is retry-aware, or an outage becomes a dozen identical emails and the next real alert gets ignored:

- **Transient** (dependency not ready yet, later attempt may clear it): log, stay silent during the window.
- **Real** (failed gate, missing credential, unparseable confirmation): alert immediately; a human is needed and more attempts will not help.
- **Already done** (idempotency guard fired): silent. This is the steady state.
- **Close the window with one `--final` run** that alarms if the period never completed. That single alert is the "we missed it" signal, and it fires once.

**Related:** if the job drives a browser, verify before claiming: parse the confirmation for a real identifier (an order number); never trust that the click "worked".

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

1. **Gather and confirm first**: Build the full list of items to be removed and present it to the user for confirmation before deleting anything. This catches mistakes in date ranges, filters, or account selection.
2. **Restrict to safe content types**: Only auto-generated or temporary content is eligible for bulk deletion (e.g., unlisted short clips, draft posts). Never bulk-delete public, private, or manually curated content.
3. **Filter by metadata**: Apply duration, privacy status, date range, and ownership filters to exclude anything that should not be touched (e.g., skip full-length videos when deleting short clips by filtering to <=90s).

**Why:** Platform deletions are irreversible. A wrong date range or missing filter can wipe out manually curated content. The confirmation step and content-type restriction ensure only disposable items are at risk.

## Verify Before Asserting

Do not claim the user did something (submitted an application, sent an email, published a post) unless you can verify it through an authoritative source. The existence of prep materials, drafts, or related files does NOT confirm the action was completed.

**Why:** an agent asserted the user had applied to a role because prep materials existed in cloud storage. The application was never actually submitted, and incorrect context was passed on to a third party as a result.

**How to verify:**
- **Applications/emails:** Check the mail client for sent confirmations
- **Published posts:** Check the CMS or the live URL
- **Deploys:** Check process status and server logs
- **Git pushes:** Check `git log origin/main` or `gh pr list`
- **Any user action:** Look for the completion artifact, not the preparation artifact

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

**Why:** a fix-applying error handler scanned all managed processes including itself. A dedup window increase (1h to 24h) was also needed to prevent repeated self-triggering within a single incident window.

**Rule:** Any monitoring daemon that enumerates processes must exclude its own process name from health checks.

### Log Artifacts and ANSI Codes in Error Handlers

Three related patterns that cause error handler crash loops or alert floods when reading process-manager log output:

**1. Log format artifacts in IGNORE_PATTERNS**

Process-manager log output contains formatting lines that are not actual errors: separator lines (`---`), the log command echo, and the handler's own prefixed log lines. Without ignore patterns for these, the handler classifies them as errors and alerts/loops on its own output.

Always include these in `IGNORE_PATTERNS` for any log-reading error handler:
```python
IGNORE_PATTERNS = [
    r"\[error-handler\]",  # handler's own log prefix
    r"pm2 logs",           # log command echo
    r"^---$",              # separator lines
]
```

**2. ANSI escape codes break dedup signatures**

Process managers sometimes emit ANSI escape sequences in log lines (color codes, cursor movement). If not stripped before computing the error signature hash, the same underlying error produces different hashes across restarts, causing an alert flood.

Always strip ANSI before pattern matching and dedup:
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
logger.info(f"Fix complete (cost: ${cost:.4f})")
```

## When a Vendor Deprecates a Free Tier, Every Silent Consumer Breaks at Once

A free CLI tier used by shadow runners and fallback paths can be withdrawn without notice, after which every invocation throws a tier-ineligibility error before the first request. The error occurs during user setup, so it cannot be suppressed with flags, model overrides, or working-directory changes: it is account-wide.

**Silent impact on automated runners:** every consumer that shells out to that CLI now errors. The process exits non-zero, but cron wrappers that ignore exit codes never alert. Any "fallback to the other vendor" path in your system is broken too.

**Mitigation:** treat the CLI as unavailable until migrated to a paid key or the replacement product. Fall back to another provider's CLI for shadow runners. Before relying on any such call in automation, probe it first (`<cli> -p "ok?" 2>&1`) and check for the tier error.

**General rule:** any automation whose fallback path depends on a free vendor tier needs a live probe, not an assumption, and its wrapper must check exit codes.

## Shared Poller Resource Gates Must Be Scoped to the Executing Machine

When a poller or executor dispatches jobs to BOTH local and remote workers (e.g., a local run function and a remote-over-SSH variant), any resource gate based on the local machine's resources (RAM, CPU, disk) must NOT fire for remote jobs; those jobs consume zero local resources.

**Observed case:** a multi-worker dispatcher had ONE memory watchdog for all jobs: when the host's `MemAvailable` fell below 100MB, it killed the tracked PID. For remote SSH jobs the tracked PID was only the SSH client on the host; the real work ran on the remote worker using zero host memory. Host memory pressure was killing healthy offloaded sessions. Symptom: the log showed "Memory watchdog: only 93MB available, killing PID" while dispatch counts showed only remote dispatches and zero local ones.

**Fix pattern:** Add a `skipMemoryWatchdog` (or equivalent) flag to the polling function. Set it to `true` for remote-dispatched jobs. Timeout and output-size watchdogs can still apply to remote jobs (they guard a hung SSH or runaway output regardless of location).

**Rule of thumb when adding any resource guard to a shared poller:** Ask "Does this resource live on the machine actually running the session?" If the job is remote, host-local RSS/mem/CPU is irrelevant.

## A Repo's Main Checkout Must Never Be Left on a Merged Feature Branch

**Symptom:** a repo's primary working copy (not a worktree) is checked out on a feature branch whose PR has already been merged. The local branch is stranded and the local default branch silently falls behind the remote, sometimes by several commits, with no error surfaced anywhere.

**Why this is worse than an ordinary stale branch:** SessionStart hooks, `CLAUDE.md` loads, and guidance-file reads for every concurrent session on that machine execute against whatever is checked out in the main checkout. A stranded branch means every other session (interactive or automated) silently reads outdated or divergent guidance. This can originate from **any** session that does a plain `git checkout <branch>` in the main checkout to open a PR (rather than using a worktree) and never switches back after the merge.

**Detection:** In any repo's main checkout, `git branch --show-current` should always equal that repo's default branch except for the brief window a human is actively working on a real feature. If it is not, check whether the current branch's PR is already merged (`gh pr list --head <branch> --state all`); if so, the checkout was simply never returned home.

**Fix:** Verify the current branch is a strict subset of the default branch first (`git diff origin/main HEAD --stat` should be empty or default-only), then `git checkout main && git merge --ff-only origin/main && git branch -d <stale-branch>`. Do not force anything; if the diff is not empty, treat it as in-progress human work (stash/investigate, do not discard).

**Prevention:** any session opening a PR from a main checkout should use a worktree instead: `git -C <repo> worktree add /tmp/<label> -b <branch>`, work there, and leave the main checkout untouched on its default branch throughout.

## Never Inline Single-Quoted Code in `ssh 'block'`

`ssh host 'big block ...'` wraps the whole remote command in single quotes. Any single quote INSIDE the block (e.g. JS `app.get('/path', ...)`, Python `'text/plain'`) terminates the outer quote and silently mangles the code. This has shipped invalid JS to a production server file and crash-looped the service.

**Fix:** write the script/patch to a LOCAL file and `scp` it, then run `ssh host 'python3 /tmp/file.py'`. Always syntax-validate on the remote host (`node --check`, `bash -n`, `python -m py_compile`) BEFORE restarting, and keep a `.bak` to restore.

## Audit the CLI Version on Every Host, and Pin Fan-Out/Search Defaults Before Upgrading

CLI version drift silently keeps already-fixed reliability bugs in play, and headless hosts drift worst because nobody watches their startup banner. In one audit the interactive host was 19 versions behind and a server host 8 behind, so both were still exposed to fixed bugs including: truncated tool outputs retaining the full untruncated result in memory for the rest of the session; stream-json output truncated at exit for slow-reading pipeline consumers (which makes a headless job report success with the tail of its response missing); and quadratic message-normalization stalls in long sessions.

Rules:

1. Check `claude --version` against `npm view @anthropic-ai/claude-code version` on EVERY host that runs the CLI (workstation, servers, containers), not just the interactive one.

2. Pin fan-out and search behavior BEFORE upgrading, because upgrades change defaults underneath you: one release raised the default nested-subagent spawn depth from 1 to 3, and another added a session-wide web-search cap. Set `CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH` and `CLAUDE_CODE_MAX_WEB_SEARCHES_PER_SESSION` explicitly so an upgrade never changes spend or research depth implicitly. Implicit depth-3 nesting can outrun what a usage gate reasons about, since the gate models the fan-out the top-level session controls.

3. Set `fallbackModel` (array, max 3 entries, does NOT merge across settings files) on every host running headless runners. Without it a runner hard-fails when its primary model is unavailable or overloaded: the silent-healer failure class.

4. Verifying a settings change means launching the CLI and getting a reply, not just parsing the JSON. An unsupported or misspelled settings key is accepted silently and does nothing. Corollary: env vars introduced in a version NEWER than the installed CLI are inert until the upgrade lands, so setting them is upgrade-preparation, not an active change.

5. **Containerized installs drift worst, and the host version tells you nothing about them.** Container images that install with an UNPINNED `RUN npm install -g @anthropic-ai/claude-code` freeze whatever was latest at build time and never move again. In one audit, eight live containers sat at three different versions, all far behind their hosts.

   **Match the fix list to how the consumer actually invokes the CLI before calling drift urgent.** A first pass of that audit asserted the containers were exposed to the stream-json exit-truncation bug, the tool-output memory leak, and long-session stalls. Reading the server code refuted all three: the containers spawn `claude -p --allowedTools ...` and accumulate PLAIN stdout (no `--output-format stream-json`), attach NO MCP servers, and run one-shot per request rather than long sessions. Version drift is real, but a fix only matters if the invocation path touches it. Check the spawn arguments, not the version number alone.

   Two consequences that do hold:
   - **Pin the version in the Dockerfile** (`@anthropic-ai/claude-code@<version>`). Unpinned means every rebuild is a silent, unreviewed upgrade that can change defaults (see rule 2), and builds are not reproducible.
   - **Rebuild on a cadence, not on demand.** An unpinned image that is never rebuilt is the worst of both worlds: frozen on an old version AND guaranteed to jump many versions at once whenever it finally is rebuilt. Enumerate with `docker exec <container> claude --version` per container.

### Unpinned Docker Installs Make Rebuilds a Silent No-Op; and `docker exec` Probes as Root and False-Alarms on Auth

Rebuilding a container fleet surfaced two traps that make a rebuild look successful when it did nothing, and make a working container look broken.

1. **An UNPINNED install plus Docker layer cache means `docker compose build` is a silent no-op.** One container rebuilt cleanly and came back on its old version. Its `RUN npm install -g @anthropic-ai/claude-code` line was byte-identical to the previous build, so Docker reused the cached layer and never re-ran npm. The others upgraded ONLY because pinning the version changed that line and busted the cache. So an unpinned image is doubly bad: it freezes at build-day latest AND resists the rebuild you would use to fix it. Either pin the version (preferred, and the cache-bust is a feature) or build with `--no-cache`. Always assert the version INSIDE the container after a rebuild (`docker exec <c> claude --version`); never infer success from a clean build log.

2. **`docker exec <container> claude -p ...` runs as ROOT and reports "Not logged in", even when the service is perfectly authenticated.** Credentials live under the service user's home (e.g. `/home/node/.claude/.credentials.json`), but root's HOME is `/root`, so the CLI finds nothing. This looks exactly like a rebuild wiping credentials and will trigger a false rollback. Probe as the service user instead: `docker exec -u node -e HOME=/home/node <c> claude -p "..."`. Confirm any suspected breakage against an un-rebuilt container as a control before acting.

3. **`auth=pending` on a health endpoint immediately after a rebuild is expected, not a failure.** If the server checks auth on a long interval (e.g. 30 minutes) with the first check roughly 60s after start, wait for the "checked N seconds ago" field to be populated before judging.

Credentials survive a rebuild when they live in a named volume mounted at the service user's `.claude` dir rather than baked into the image, so `docker compose build && up -d` preserves them and no re-OAuth is needed.

### The CLI Sandbox Is Not Usable Inside Docker, or on WSL Alongside Windows Interop

Investigated and closed as not-applicable in one environment; this corrects an earlier recommendation from the same session that called `sandbox.network.strictAllowlist` "the highest-value remaining security item."

**Containers cannot use it.** The sandbox is enforced by bubblewrap, which requires unprivileged user namespaces. Inside the containers `bwrap` fails with `Creating new namespace failed: Operation not permitted`, including the weaker variant that binds the existing `/proc`. The host kernel is NOT the blocker (`/proc/sys/user/max_user_namespaces` reads a large value inside the container); Docker's default seccomp profile blocks `CLONE_NEWUSER`. Enabling it would require running with `--privileged`, `--cap-add SYS_ADMIN`, or `seccomp=unconfined`.

That trade is backwards: it punches a hole in the OUTER isolation boundary in order to add an inner one, on containers whose entire purpose is isolating untrusted public input. **For such containers, the Docker container IS the sandbox.** Do not weaken it to add a nested sandbox. The weaker-nested-sandbox setting does not rescue this: it addresses a container that cannot mount a fresh `/proc`, not one forbidden from creating namespaces at all.

**WSL2 hosts may not be able to use it either, for a different reason.** Under the sandbox on WSL2, sandboxed commands cannot launch Windows binaries or anything under `/mnt/c/`. If your primary working directory lives on the Windows filesystem and Windows interop is routine, enabling the sandbox breaks that wholesale; `docker` is separately documented as sandbox-incompatible.

**Where the real mitigation lives instead.** If the exposure that motivated this was a broad shell permission (e.g. `Bash(curl:*)`) acting on untrusted public input, and the OS-level sandbox is unavailable, the controls that DO apply are: a narrow `--allowedTools` list at the spawn site, account isolation, the container boundary itself, and an output scrubber. Harden those rather than reaching for `strictAllowlist`.

**Verify before reopening:** run `docker exec -u root <container> bwrap --ro-bind / / --dev /dev echo ok`. If it still prints `Operation not permitted`, this conclusion stands.

## A Recovery Action That Cannot Fix the Condition Must Be Gated on Classifying the Condition First

Restart storms come from a health check with fewer states than reality. One auth-refresh watchdog had two: `ok` and "not ok", where "not ok" meant stale bind-mounted credentials and the remedy was recreating the container. Being out of quota also reads as "not ok", so it inherited a remedy that cannot return quota: 1,273 container recreates across six containers' logs, tearing down and rebuilding every 10 minutes for the length of each limit window, plus an alert telling the operator to run a login command for a condition login cannot fix.

The diagnostic that settles it is correlation across independent units. Six containers have six independent credential files, and the recreates fired in lockstep at the same minute on consecutive nights. Independent files do not go stale in the same second; one shared account runs out of quota in the same second. Lockstep failure across units that share exactly one thing points at the shared thing.

Rules:
1. Before wiring an automatic remedy to a failure state, ask which conditions land in that state and whether the remedy addresses each. If it addresses only some, classify first and let the others fall through to a wait.
2. Detect operational strings by wording family, not one literal. The CLI says "your limit", "your session limit", "your weekly limit", and the reset stamp may carry no minutes ("resets 3am (UTC)"). A guard pinned to one literal silently stops matching when the vendor rewords, and the failure is invisible because the wrong branch still runs. Scope loose patterns to short output so real content quoting "limit" is not swallowed.
3. Put the classifier where the condition is observed (the health endpoint), and keep a wording fallback in the consumer, so the fix applies to already-running processes without a rebuild.
4. A recovery loop that re-runs on a fixed interval should record what it observed, not just what it did. Those logs said "auth=failed, recreating container" and never printed the error text, so the misclassification was invisible for months in plain sight.
5. Alert text is part of the fix. An alert naming the wrong remedy trains the operator to distrust the alert.

Applies to any watchdog: process-manager restarts, container recreates, auth refreshers, stale-job requeues.

## A Retry Cap Must Not Be Spent on an Infrastructure Outage

A bounded-retry recovery loop (MAX_ATTEMPTS, cron every N minutes) permanently kills every in-flight job when the dependency is down longer than cap x interval. The attempts are consumed against a dead socket, and once a row is at the cap the recovery SELECTs exclude it forever, so the work stays dead long after the dependency recovers, and nothing ever retries it.

Observed: a dependency fleet was down for about an hour. A consumer's recovery ran every 5 min with MAX_ATTEMPTS=2, so both attempts were spent inside the first ten minutes. The job was dead for 5 hours with a useless error until a human reported it.

The distinction that fixes it: a CONNECTION-level failure (ECONNREFUSED/ENOTFOUND/ECONNRESET/socket hang up) is a statement about the infrastructure, not a verdict on the job. A failure returned BY the dependency (bad response, timeout while it was answering) is a verdict on the job and must still count.

How to apply:
1. Preflight the dependency (GET /health) before the run counts an attempt, resets a status, or posts an alert. During an outage the whole run becomes a silent no-op, which also stops the every-5-minutes alert spam that trains people to ignore it.
2. In the catch, refund the attempt on a connection-level error and restore the row's prior status, so the next run retries it. Bound it with the existing age window (e.g. 24h) rather than the attempt cap.
3. Test the decisive property directly: run N consecutive recovery passes against a CLOSED PORT and assert the row is still retryable afterwards. A single-pass test passes on the broken version too.

## A 429 or 503 From a Dependency Is a Verdict on Its Quota, Not on the Row: Refund the Attempt

A retry-budget fix for the class above refunded the attempt only for CONNECTION-level faults: error codes such as ECONNREFUSED and ECONNRESET plus the strings 'socket hang up' and 'fetch failed'. A service that answers HTTP 429 "temporarily at capacity" is reachable by that test, so the attempt was charged. Both attempts for a row were spent inside a single 5-minute cron tick and the work then dropped out of every recovery query while the account was merely out of quota.

The counterintuitive part worth remembering: making the dependency's rejection FASTER and MORE PRECISE made this worse, not better. An admission gate had been added that detects the quota state up front and rejects in milliseconds with the parsed reset time. Before that, each attempt at least consumed real time and the two retries were spread out; afterwards both were burned instantly against a wall that was going to clear on a known schedule.

General rules:
1. Classify a failed dependency call by WHOSE fault it is, not by whether the socket opened. Connection refused, HTTP 429, HTTP 503 and an explicit quota or rate-limit response are all statements about the dependency's availability. Only an error produced while the dependency was genuinely serving the request is evidence about the row, and only that should spend a retry.
2. If the dependency tells you WHEN it will recover (a reset timestamp in the 429 body or a `Retry-After` header), defer until then instead of merely refunding. Refunding alone means the next tick retries immediately and refunds again, which works but is pure noise.
3. A retry cap plus a fast-failing dependency is a silent work-loss combination. Rows at the cap are excluded by the selecting query, so nothing alerts and the backlog just stops existing.
4. Keep the user-visible escape hatch independent of the internal counter. Give the stored failure message a Retry action whose route resets the row and re-runs WITHOUT consulting the attempt counter, so a human can still recover work the automation has given up on.

## A Watchdog That Kills Out of Band Must Set a Kill Reason, or the Death Reads as Success

A supervisor that terminates a job from outside the code path that reaps it leaves the reaper with only one observable: the process is gone. Absent an explicit reason, "gone" is indistinguishable from "finished", so the system reports a clean completion carrying whatever partial work existed. Observed: a stall watchdog SIGKILLed a job at 6 minutes of silence; the completion poller saw a dead pid with `killReason=null` and resolved normally, so the user saw 21 minutes of tool narration under an ordinary completion footer and no answer.

Two corollaries:
1. A silence-based liveness threshold must exceed the longest legal quiet operation: a single shell tool call may run 600s emitting nothing, so a 300s stall timeout kills healthy work.
2. The explanation must travel on the channel the user actually reads: streaming UIs render the stream, not the returned value, so a notice appended only to the return string is invisible.

## Use the SSH Config Alias, Not a Bare IP

`ssh <ip> "<cmd>"` fails with "Permission denied (publickey)" when `~/.ssh/config` has no `Host` entry matching the bare IP: only named aliases carry the correct user and identity file, so a bare-IP call falls back to the local default user and the wrong key.

This silently broke a restart-storm detector: every ssh call failed, and a `|| echo 0` fallback on the restart-count check made storm detection permanently report 0 restarts regardless of the real count (verified: a known process's dry-run reported 0 / "No storm detected" pre-fix versus its real restart count / "STORM DETECTED" post-fix). Two other command templates in the same tool had the identical bug. This exact failure had already been noted once in a failures log, where an agent worked around it in-session by using the alias, but it was never fixed at the source, so it kept recurring.

**Lesson:** when a documented working command references a host by raw IP, swap it for the configured alias rather than treating a one-off Permission-denied as a transient fluke. Check `~/.ssh/config` for the actual alias before re-deriving the fix each run.

## Storm Detection Must Key on the Crash-Loop Counter, Not the Cumulative Restart Count

Fixing the SSH bug above unmasked a second, more consequential bug in the same script: the `STORM_THRESHOLD=5` check compared against `.pm2_env.restart_time`, the cumulative lifetime restart count, which never resets. Any long-uptime stable production process trivially exceeds 5 (observed: 79, 182, and 233 restarts across three healthy processes, all with `unstable_restarts=0`). A post-fix dry-run proved this concretely: "STORM DETECTED" for a process that was not flapping at all.

The correct field is `.pm2_env.unstable_restarts`, the crash-loop counter: it only counts restarts before `min_uptime` clears, and resets to 0 once the process is stable.

The full fix, and the checklist it generalises to:
- Swap the field at BOTH the pre-rollback storm check and the post-rollback stability check.
- Put a hard allowlist guard INSIDE the script (not just in the calling agent's textual instructions), so a non-dry-run invocation against any non-staging process name is refused before any stop/rollback command runs.
- Normalize the empty-output case: `jq`'s `select()` with no match emits nothing at all, so `// 0` never fires, and under `set -e` an integer test on an empty string errors and can fall through to a false "STORM DETECTED". Normalize to 0 explicitly.
- Verify by re-running every scenario fresh: dry-run against a stable process (no storm), non-dry-run against a non-allowlisted process (refused pre-mutation), and an absent process (normalizes to 0 rather than erroring).

**Lesson:** a script that reads a metrics field by name is only as correct as the field choice. `restart_time` and `unstable_restarts` sound interchangeable but have opposite reset semantics; always verify a restart-count threshold against a known-stable, long-uptime process before trusting it.

## A Script That Reports a Skipped Step as Informational Text Will Have That Step Skipped Indefinitely

A propagation script printed `SKIP guidance (no --guidance-file specified)` when the flag was omitted. It exited 0, the summary line said "propagated to 1 destination(s)", and the skip read as a neutral status note. Five consecutive calls in one session went memory-only, and all five outputs were pasted into reports as evidence of compliance with the rule they had just violated. The tool was not broken; its failure was indistinguishable from its success.

**Rule:** when a script can silently omit the step that is the whole point of calling it, the omission must be louder than the success path: stderr, a visible `SKIPPED` marker in the result summary, and an explicit opt-out flag, so that "I meant to skip it" and "I forgot" are different observable states. A mandatory step that a script can no-op is not mandatory, it is aspirational.

**Corollary for the caller:** read the output of a compliance command before quoting it as proof of compliance.
