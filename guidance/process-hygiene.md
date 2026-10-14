<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

If you spawn a long-running process (`npm run dev`, a background build, a watch command, a test runner in watch mode), you own it for the duration of your session.

- **Record the PID or process name** when you start something. You'll need it to stop it later.
- **Stop it before session end** or document it in `context.md` so the next session knows it's running.
- **Don't assume your process manager will manage it.** Only processes declared in its config (e.g. PM2's `ecosystem.config.cjs`) are managed. Anything you start with `node`, `npm run dev`, or `&` is orphaned when your session ends.

```bash
# Start a dev server, note the PID
npm run dev &
DEV_PID=$!
echo "Dev server running on PID $DEV_PID"

# Later, clean up
kill $DEV_PID
```

## Atomic State Writes

When updating `context.md` or `progress.md`, treat the update as its own operation; don't leave it as the last step in a chain that might not complete.

- **Update context files early and often**, not just at session end
- **Commit the context update with the work it describes**, in the same commit
- If you're about to do something risky (a build, a deploy, a large refactor), update `context.md` *before* the risky step so that if it crashes, the state is captured

## Temp File Cleanup

- Don't leave temp files in `/tmp`, project directories, or anywhere else
- If you create scratch files during debugging (`test.js`, `debug.log`, `temp.json`), delete them before committing
- If a process creates temp files (detached job output, build artifacts), clean them up or document their location

## Port and Process Conflicts

Before starting any server or service:

```bash
# Is the port already in use?
ss -tlnp | grep <port>

# Is a previous instance still running?
ps aux | grep <process-name>
pm2 list
```

Don't blindly start a service on a port that's occupied. Either stop the existing process (if it's yours) or use a different port. If the existing process belongs to another session, coordinate; don't kill it.

### PM2 Restart EADDRINUSE Crash Loop

When PM2 restarts a process, the old Node instance may not release its port before the new one starts, causing `EADDRINUSE` → crash → PM2 restart → repeat.

**Three-layer fix:**

1. **`kill_timeout` and `listen_timeout` in ecosystem.config:**
   ```js
   { kill_timeout: 3000, listen_timeout: 3000 }
   ```
2. **Graceful shutdown handler in server code:** handle both SIGINT and SIGTERM, close DB connections inside the `server.close()` callback, add a force-exit fallback, and register global error handlers:
   ```js
   function shutdown() {
     server.close(() => {
       // Close DB BEFORE process.exit(): flushes WAL, releases locks
       if (db && typeof db.close === 'function') db.close();
       process.exit(0);
     });
     // Force exit if graceful shutdown takes too long
     setTimeout(() => process.exit(1), 5000);
   }
   process.on('SIGINT', shutdown);
   process.on('SIGTERM', shutdown);
   process.on('unhandledRejection', (reason) => console.error('Unhandled Rejection:', reason));
   process.on('uncaughtException', (err) => { console.error('Uncaught Exception:', err); setTimeout(() => process.exit(1), 100); });
   ```
   - SIGINT handles Ctrl-C in dev, SIGTERM handles PM2 restart. Both are needed.
   - Close DB (and any other resource) inside the `server.close()` callback, not after it. This ensures the SQLite WAL is flushed and connections released before the process exits, preventing SQLITE_BUSY or "database is locked" on the next start.
   - The force-exit prevents PM2 from hanging on keep-alive connections that never drain.
   - `unhandledRejection`/`uncaughtException` log before exiting; without these, PM2 sees a silent crash with no diagnostic output.
3. **Use a `start.sh` wrapper for Next.js standalone.** `next start` as the PM2 script loses process tracking. A wrapper lets PM2 signal the actual node process:
   ```bash
   #!/bin/bash
   set -e
   set -a
   if [ -f "$(dirname "$0")/.env" ]; then source "$(dirname "$0")/.env"; fi
   set +a
   # Check for both server.js AND static assets: server.js can exist from a partial build
   if [ ! -f "$(dirname "$0")/.next/standalone/server.js" ] || [ ! -d "$(dirname "$0")/.next/standalone/.next/static" ]; then
     npm run build
   fi
   exec node "$(dirname "$0")/.next/standalone/server.js"
   ```
   - The build script must use `mkdir -p .next/standalone/.next` before `rm -rf .next/standalone/.next/static`; on a fresh clone the directory doesn't exist and `cp` will fail silently. Correct form: `next build && mkdir -p .next/standalone/.next && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static`

**Diagnosis:** `pm2 show <process>` with a rapidly increasing restart count plus `EADDRINUSE` in logs = this pattern.

**Belt-and-suspenders: proactive port cleanup in start.sh.** When `kill_timeout` alone isn't enough (e.g. a previous process crashed without releasing the socket), add a `kill_port()` function at the top of `start.sh` that clears the port before launching:

```bash
kill_port() {
  local sig=$1
  if command -v fuser >/dev/null 2>&1; then
    fuser -k -$sig "${PORT}/tcp" >/dev/null 2>&1 || true
  elif command -v lsof >/dev/null 2>&1; then
    lsof -ti :"${PORT}" | xargs kill -$sig >/dev/null 2>&1 || true
  fi
}

kill_port TERM
# Wait up to 50s for port to be free; escalate to SIGKILL at attempt 5
for i in {1..5}; do
  ss -tulpn 2>/dev/null | grep -q ":${PORT} " || break
  [ $i -eq 5 ] && kill_port 9
  sleep 10
done
```

Start with SIGTERM (graceful), escalate to SIGKILL only after several retries. Use `fuser` when available (util-linux); fall back to `lsof` (macOS / minimal Linux). This is a start.sh-level fix, not a replacement for ecosystem.config `kill_timeout`.

**App-level retry loop in `server.listen()`.** When the above layers still aren't enough (the OS hasn't released the socket despite kill_timeout plus a proactive kill), wrap `app.listen()` in a retry loop instead of exiting immediately:

```js
function startServer(retries = 5) {
  const srv = app.listen(PORT, () => {
    console.log(`Listening on port ${PORT}`);
    if (process.send) process.send('ready');
  });
  srv.on('error', (err) => {
    if (err.code === 'EADDRINUSE' && retries > 0) {
      console.warn(`Port ${PORT} in use, retrying in 2s... (${retries} left)`);
      setTimeout(() => { srv.close(); startServer(retries - 1); }, 2000);
    } else {
      console.error('Server error:', err);
      process.exit(1);
    }
  });
  return srv;
}
const server = startServer();
```

- Only retry on `EADDRINUSE`; hard-exit on all other errors.
- A 2s delay gives the OS time to release the port between attempts.
- In practice, intermittent EADDRINUSE can persist even with a long `kill_timeout`, graceful shutdown, and a proactive port kill all in place; the app-level retry is what finally eliminates the crash loop.

**Client-side companion: also retry `ECONNREFUSED`.** A worker or client process that starts before its server is fully bound receives `ECONNREFUSED` instead of `EADDRINUSE`. Include `ECONNREFUSED` in the retryable error set alongside network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). This handles the startup race where server and client launch concurrently (e.g. PM2 starts both in rapid succession).

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

PM2's `cron_restart` + `autorestart: false` does not reliably reawaken a batch script that exits normally after doing its work. The script exits, PM2 marks it "stopped", and on some deployments the cron silently never fires again. A scheduled job can go offline for days this way with no error and no alert; it just stops producing output.

**Fix:** For any run-once/batch/cron-style PM2 process (digest posters, scrapers, daily scripts), use system crontab calling `pm2 restart <name> --update-env` as the primary scheduler. Keep `cron_restart` in `ecosystem.config.js` only as documentation, not as the sole mechanism.

```cron
0 7 * * * /usr/bin/env pm2 restart my-batch-job --update-env >> $HOME/logs/my-batch-job-cron.log 2>&1
```

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop any dev servers, watch commands, or background tasks you started
2. **Temp files:** Delete any scratch files you created
3. **Ports:** Verify you haven't left a rogue server bound to a port
4. **Git state:** No uncommitted changes related to your task
5. **Context:** `context.md` reflects what's running and what's not

## Rule Digest

One line per lesson. Each is a rule learned from a real silent failure.

- **Docker Bind Mount Refresh**: Use `docker compose down && docker compose up -d` instead of `docker compose restart` for any operation that requires the container to pick up updated host files.
- **Docker `exec` Always Needs `--user`**: When running `docker exec` against a container that has a non-root application user (e.g. `node`), **always pass `--user <username>`** on every exec call.
- **Long Text Transfer**: Never give the user long commands, URLs, or multi-line text to copy-paste manually.
- **Stale Git Lock Files**: Any automated script that runs git commands should check for and remove stale lock files before operating.
- **Stale Branch Dedup Lists**: Automated agents that gate new work on a dedup list built from `git log` or `git branch -r` can block or act on stale data; fetch before building the list.
- **Bash `set -u` with Optional Parameters**: Use `${N:-}` (empty default) or `${N:-default}` for any positional parameter that may not be passed.
- **Bash `${VAR:-default}` vs `${VAR-default}`: Empty Counts as Unset**: `${VAR:-default}` substitutes the default if `VAR` is **unset OR empty**; use `${VAR-default}` when an empty value is meaningful.
- **Python `smtplib`: Validate Email Addresses Before Sending**: Always guard `smtplib` send calls with a basic address sanity check.
- **`pm2 restart <name>` Does NOT Pick Up Ecosystem Config Changes**: `pm2 restart <name>` restarts the process using its **in-memory config**, ignoring changes to `ecosystem.config.js`. Use `pm2 delete <name> && pm2 start ecosystem.config.js --only <name>` (or `pm2 startOrReload`) after editing the config.
- **PM2 Crash Loops from DB Dependency on Startup**: Services that connect to Postgres (or any external DB) at module load time can enter a tight PM2 restart loop if the DB isn't ready on first boot or after a reboot. Connect with retry/backoff instead of at import time.
- **Bash `date +%H` Produces Octal-Invalid Strings in Arithmetic**: `date +%H` emits zero-padded hours (`08`, `09`), which bash arithmetic treats as invalid octal. Use `10#$(date +%H)` or `date +%-H`.
- **Agent web-fetch tools route through the provider's edge, not your local network**: Use `curl` via the shell instead for private/local URLs.
- **Generated crontabs: edit the source, not the output**: If your crontab is generated from a registry file, edits made directly to the crontab are lost on the next regeneration. Change the registry and regenerate.
- **Bash `set -e` Kills Error Handlers Before They Fire**: In any `set -e` or `set -euo pipefail` script, capture exit codes inline with `cmd || VAR=$?`.
- **Bash `git stash pop` Must Be Guarded**: Never call `git stash pop` unconditionally in a script; only pop if the earlier stash actually created an entry.
- **PM2 Periodic-Exit Scripts Must Use `autorestart: false` with `cron_restart`**: For any PM2 process that exits on completion (data push scripts, sync jobs, batch processors), always pair `cron_restart` with `autorestart: false` (and back it with system crontab, per above).
- **Cron Wrappers on Remote Machines: Self-Sync via `git pull --ff-only`**: Cron scripts running on isolated machines (a second PC, Raspberry Pi, or any host without an automatic deploy pipeline) should `git pull --ff-only` at the start of each run.
- **`claude -p` vs `claude --print`: Positional Argument Trap**: In any script or cron job that pipes stdin to `claude`, use `--print` (not `-p`) whenever other flags follow.
- **ID-Based Cursor Iteration for Large Dataset Processing**: When a script processes all rows from a large DB table in batches, use **ID-based cursor pagination** (`WHERE id > ? ORDER BY id LIMIT N`) instead of `LIMIT N OFFSET M`.
- **Resilient DB JSON Parsing: Wrap Every `JSON.parse()` in try/catch**: When reading rows that store serialized JSON (metadata columns, config blobs, event payloads), wrap every `JSON.parse()` call in a `try/catch`.
- **Confirm Async Follow-Through, Not Just Dispatch**: Any runner that creates a PR/ticket/artifact for later pickup should, at the START of its next run, reconcile its own prior outputs rather than waiting for a downstream janitor to notice.
- **Gemini CLI `-p` does NOT support multimodal (video/image) input**: In headless mode, `@filepath` references are treated as **text only**.
- **Chokidar file-watcher: denylist segment vs. substring matching**: Chokidar's `ignored` function receives the **full file path**; match path segments, not substrings, or you will ignore unrelated files whose path happens to contain the word.
- **Bash `$HOSTNAME` is always set**: never use `${HOSTNAME:-default}` as a bind-address guard; the default never applies.
- **SQLite `.iterate()` Cleanup and File-Watcher Depth Limiting**: Always wrap `.iterate()` in try/finally so the cursor is closed even on error; set a `depth` limit on recursive watchers.
- **Background Queue Saturation Guards for Webhook Handlers**: When a route handler spawns fire-and-forget background work, track pending task count and return HTTP 503 when a cap is exceeded.
- **SQLite `createMany` Variable Limit and Webhook Timestamp Validation**: SQLite limits bind parameters per statement (~999 for older builds, up to 32766 in recent ones); chunk bulk inserts. Validate webhook timestamps before trusting them.
- **Express API Routes: Null-Check After DB Insert and Full try-catch Audit**: A DB write followed by a read can return null; wrap every route handler in try-catch; for nullable columns use `!== undefined` instead of `||` so falsy-but-valid values survive.
- **Claude CLI `--model` Alias vs. SDK Model ID**: The Claude CLI's `--model` flag takes **short aliases**, not API model IDs.
- **Health Endpoint: Data Pipeline Freshness Gate**: A `/health` endpoint should check not only DB connectivity but whether background sync jobs have recently written.
- **V8 Object Nullification in Batch Processing Functions**: V8 does not always garbage-collect large objects that remain in scope until a function returns; release large intermediates (or split into smaller functions) inside long batch functions.
- **File-Watcher Feedback Loop: Exclude Files the Service Writes To**: Any service that watches a directory AND writes to a file inside it must explicitly exclude its own output files from the watcher.
- **`Promise.race` Timeout Wrapper Leaves a Dangling Timer**: The naive form leaves the `setTimeout` running after the main promise resolves; `clearTimeout` in a `finally`.
- **Defensive JSON Parsing in Batch/Summarization Loops**: When a loop advances a cursor or timestamp **after** the loop, a bare `JSON.parse` throw on one bad row permanently stalls the pipeline.
- **SQLite `busy_timeout` Alongside WAL Mode**: WAL reduces write-write contention but does not prevent `SQLITE_BUSY` under concurrent requests; also set `PRAGMA busy_timeout`.
- **A JSON-File Index Mutated by Read-Modify-Write Needs an In-Process Lock AND Atomic tmp+rename Writes**: An unserialized "read index.json, modify, write back" loses writes under concurrency and can corrupt the file; a bare "if missing, write `[]`" init is a third, independent race.
- **Cross-Host Job Handoff: a Failed Push Needs a Pending Marker, Not Just a Pull Guard**: A primary/fallback job wrapper that pulls shared state, runs, then pushes must treat push failure as its own case: mark the file pending and re-push before the next pull, or a successful local run gets overwritten by stale remote state. Pair with a cross-host mutual-exclusion lock (not just a heartbeat heuristic) so both hosts can't run the same job at once; sort multi-file lock acquisition to avoid deadlock.
- **PrismaClient + LibSQL Adapter: Don't Pass `datasourceUrl` in the Constructor**: The adapter already owns the database connection.
- **Bash Monitoring Scripts: Alert-Once-Then-Suppress via Marker State**: The marker must encode *whether an alert was already sent*, not just that a failure occurred. For a condition that stays broken indefinitely, hash the failure's own content instead of a bare boolean, so a *different* problem arriving mid-suppression still alerts.
- **External API 429 Handling: Exponential Backoff + Inter-Request Throttle**: When calling an external REST API in a sequential loop, use both: backoff on 429 and a fixed delay between requests.
- **Express: `URLSearchParams(req.query)` Doesn't Handle Repeated Query Params**: Iterate explicitly and call `.append()` for each value.
- **OAuth Bootstrap: Copied Token Gets Revoked on Source Rotation**: Copying a token from one container to bootstrap another makes them share a refresh token; when one rotates it, the other is revoked. Give each consumer its own login.
- **SQLite UPSERT with Optional Columns: Branch by Presence to Avoid Null Overwrite**: Branch on whether the optional field was provided, and use a separate prepared statement for each case.
- **SQLite Corruption Auto-Detect and Restore**: Run `PRAGMA quick_check` at startup and auto-restore from backup when corruption is detected (power loss, OOM kills mid-write, disk I/O errors).
- **Multi-Pass AI Content Generation: Editor Commentary Placement**: A refinement pass leads with meta-commentary unless told not to; instruct it to put editor notes at the bottom, and have the narration-stripping step remove both leading narration and a trailing editor-notes section (only when that heading is the last one in the document).
- **Webhook Queue: Array-Based Queue Over Promise Chains**: For bursty events processed sequentially with I/O, use an explicit array queue with a single drain loop instead of an ever-growing promise chain.
- **Multi-Phase AI Research Pipeline with Disqualification Gates**: Structure research/recommendation prompts as sequential phases that narrow candidates and deepen research, with explicit disqualification gates between phases.
- **`for…of` Loop: Don't Assign to `const` Loop Variable**: It throws and can cause a crash loop; use `let`. Nulling a loop variable to "help GC" is cargo-cult code.
- **Slug Guard: Always Return `[]` on Empty Derived Slug**: When converting a string to a slug for a URL path segment, guard against returning an empty string.
- **Shell Script Network Calls: Always Set Timeouts**: Unattended scripts calling `curl`, `ssh`, `openssl s_client`, `dig`, `nc`, etc. without timeouts hang indefinitely on a slow host, and if the hang holds a shared lock it silently blocks every scheduled run behind it (for days).
- **Client-Side Storage Schema Validation**: Validate the schema of `localStorage`/`sessionStorage` data on load; fall back to defaults on mismatch.
- **Required-Field Validation in User-Authored Config/YAML Parsers**: Never access required keys via raw dict indexing (`d["type"]` → cryptic `KeyError`); validate and report the missing field by name.
- **Autonomous Agent Repos: Gitignore Runtime State Files**: Gitignore all runtime state written by the autonomous loop itself.
- **Bare `JSON.parse` Inside `.map()` Over DB Rows Is a Crash Vector**: One bad row kills the whole response; parse defensively.
- **String Normalization Output Guard (slugify, sanitize, etc.)**: Normalizers can return `''` or `['']` for empty/whitespace input; check the output before using it.
- **Free CLI tiers get deprecated: verify before depending on one**: Check that a free AI CLI tier still exists before building a job on it.
- **Codex CLI Gotchas**: Keep the CLI up to date (stale versions silently break all models); the vision `-i` flag is variadic, so pass the prompt via stdin; `codex exec` echoes the prompt in output, so don't grep output for strings that appear in the prompt.
- **WSL Overnight Scheduling: Wake Timer Requires Sleep, Not Shutdown**: Before an overnight run, put the machine to sleep instead of shutting it down.
- **Custom Skill Source-of-Truth: Repo Before Live Copy**: Edit skills in their source repo, then sync to the live location; edits to the live copy get overwritten.
- **Cron PATH Double Trap: claude + node**: Prepend both bin dirs at the top of any cron-invoked script.
- **Per-Item Failure Isolation in Batch Loops**: An unguarded throw on one bad item aborts the **entire** batch; wrap each iteration.
- **PM2 Stop Is Not Durable Against Deploy-Path Restarts**: `pm2 stop <app>` + `pm2 save` does NOT permanently stop an app; a later deploy or `pm2 start ecosystem` brings it back. Remove it from the ecosystem config.
- **Cron Script Failure Alerting: EXIT Trap + Shared Alert Helper**: Silent failures in unattended cron scripts are the top cause of auth expiry going unnoticed for days; trap EXIT and alert on non-zero.
- **Suspending an Autonomous Agent: Full Checklist**: Stopping the process alone is not enough; also remove it from the process-manager config, disable its cron entries, and stop any webhook or trigger that restarts it.
- **Cron jobs that invoke `claude` must use an absolute binary path**: Cron's minimal PATH (`/usr/bin:/bin`) excludes `/usr/local/bin`.
- **Parallel Bash calls race on persisted shell cwd**: always `cd` with an absolute path explicitly.
- **Follow-mode log commands piped into head leak a shell process forever**: e.g. `pm2 logs | head` or `tail -f | head`; use non-follow flags (`--nostream`, `tail -n`).
- **A data column used as a state machine makes failures invisible to recovery**: model failure states explicitly so recovery can find them.
- **A generator that claims to be the source of truth for a live config is a loaded gun once it drifts**: diff generated output against the live config before installing.
- **A Next.js standalone build in a git worktree nests the server under `.next/standalone/<path-from-repo-root>`**: don't hardcode `.next/standalone/server.js` in worktrees.
- **A collapsed `<details>` still mounts and parses all its children**: lazy-mount heavy content.
- **Module-Level `process.env` Read Bakes In the Default Before `dotenv.config()` Runs (ES Modules)**: Read env vars at call time, or make `import 'dotenv/config'` the very first import in the entrypoint.
- **Node.js `fetch` (undici) Default `headersTimeout` Cuts Slow Non-Streaming Backends**: The ~300s default severs the socket when a peer sends headers only after computing the whole body; raise it with a custom dispatcher.
- **pkill/pgrep -f pattern also matches the shell whose own cmdline contains the pattern**: use a bracket trick (`pgrep -f '[m]y-proc'`) or exclude `$$`.
- **A PR closed as "safe to close, nothing unique lost" is a claim about the WHOLE bundled diff**: verify each distinct change against main independently before trusting or making that closure.
- **Parallel backgrounded shell jobs (`cmd &` + `wait`) silently drop output under resource pressure, even when the batch reports exit 0**: cap heavy build/test fan-out to 2-3 concurrent jobs, or give each job its own backgrounded tool call; verify a log file exists AND is non-empty before trusting its absence of errors.
- **An "overdue job" check that derives its grace period from the job's own first run row never fires for a job with zero rows**: a job that never ran has no baseline and gets read as "too new" forever. Persist the watcher's own baseline (when it started watching each job) independently of the job's run history. Indeterminate is not healthy.
