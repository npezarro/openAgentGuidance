<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

If you spawn a long-running process (`npm run dev`, a background build, a watch command, a test runner in watch mode), you own it for the duration of your session.

- **Record the PID or process name** when you start something. You'll need it to stop it later.
- **Stop it before session end**, or document it in `context.md` so the next session knows it's running.
- **Don't assume your process manager will manage it.** Only processes in `ecosystem.config.cjs` (or equivalent) are managed. Anything you start with `node`, `npm run dev`, or `&` is orphaned when your session ends.

```bash
# Start a dev server, note the PID
npm run dev &
DEV_PID=$!
echo "Dev server running on PID $DEV_PID"

# Later, clean up
kill $DEV_PID
```

## Atomic State Writes

When updating `context.md` or `progress.md`, treat the update as its own operation. Don't leave it as the last step in a chain that might not complete.

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

When PM2 restarts a process, the old Node instance may not release its port before the new one starts, causing `EADDRINUSE`, then a crash, then a PM2 restart, and repeat.

**Three-layer fix:**

1. **`kill_timeout` and `listen_timeout` in ecosystem.config:**
   ```js
   { kill_timeout: 3000, listen_timeout: 3000 }
   ```
2. **Graceful shutdown handler in server code.** Handle both SIGINT and SIGTERM, close DB connections inside the `server.close()` callback, add a force-exit fallback, and register global error handlers:
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
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. This ensures the SQLite WAL is flushed and connections are released before the process exits, preventing `SQLITE_BUSY` or "database is locked" on the next start.
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

**Diagnosis:** `pm2 show <process>` with a rapidly increasing restart count plus `EADDRINUSE` in the logs means this pattern.

**Belt-and-suspenders: proactive port cleanup in start.sh.** When `kill_timeout` alone isn't enough (e.g., a previous process crashed without releasing the socket), add a `kill_port()` function at the top of `start.sh` that clears the port before launching:

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

Start with SIGTERM (graceful), and escalate to SIGKILL only after several retries. Use `fuser` when available (util-linux); fall back to `lsof` (macOS or minimal Linux). This is a start.sh-level fix, not a replacement for the ecosystem.config `kill_timeout`.

**App-level retry loop in `server.listen()`.** When the above layers still aren't enough (the OS hasn't released the socket despite `kill_timeout`, graceful shutdown, and a proactive kill), wrap `app.listen()` in a retry loop instead of exiting immediately:

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
- The 2s delay gives the OS time to release the port between attempts.
- An app-level retry has eliminated intermittent crash loops even where all the other layers were already in place.

**Client-side companion: also retry `ECONNREFUSED`.** A worker or client process that starts before its server is fully bound gets `ECONNREFUSED`, not `EADDRINUSE`. Include `ECONNREFUSED` in the retryable error set alongside network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). This handles the startup race where server and client launch concurrently (e.g., PM2 starts both in rapid succession).

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

PM2's `cron_restart` with `autorestart: false` does not reliably reawaken a batch script that exits normally after doing its work. The script exits, PM2 marks it "stopped", and on some deployments the cron silently never fires again. A job can go dark for days with no error and no alert.

**Fix:** For any run-once, batch, or cron-style PM2 process (digest posters, scrapers, daily scripts), use the system crontab calling `pm2 restart <name> --update-env` as the primary scheduler. Keep `cron_restart` in `ecosystem.config.js` only as documentation, not as the sole mechanism.

```cron
0 7 * * * /usr/bin/env pm2 restart my-batch-job --update-env >> $HOME/logs/my-batch-job.cron.log 2>&1
```

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop any dev servers, watch commands, or background tasks you started
2. **Temp files:** Delete any scratch files you created
3. **Ports:** Verify you haven't left a rogue server bound to a port
4. **Git state:** No uncommitted changes related to your task
5. **Context:** `context.md` reflects what's running and what's not

## Rule Digest

One line per lesson. Each is a rule learned from a real silent failure.

- **Docker bind mount refresh**: Use `docker compose down && docker compose up -d` instead of `docker compose restart` for anything that needs the container to pick up updated host files.
- **Docker `exec` always needs `--user`**: When a container runs a non-root application user (e.g. `node`), pass `--user <username>` on every `docker exec`, or files get created as root and the app can't touch them.
- **PM2 lifecycle traps**: Several PM2 behaviors around restarts, stops and monitoring each cause silent failures; when a PM2 service misbehaves around restarts, check config reload, durability of stop, crash loops and cron behavior (all below).
- **Long text transfer**: Never give the user long commands, URLs, or multi-line text to copy-paste manually; write it to a file or host it and hand over a short command.
- **Stale git lock files**: Any automated script that runs git commands should check for and remove stale `.git/*.lock` files (with no live git process) before operating.
- **Stale branch dedup lists**: Automated agents that gate new work on a dedup list built from `git log` or `git branch -r` can block or act on stale data; fetch and prune first.
- **Bash `set -u` with optional parameters**: Use `${N:-}` (empty default) or `${N:-default}` for any positional parameter that may not be passed.
- **Bash `${VAR:-default}` vs `${VAR-default}`**: `${VAR:-default}` substitutes the default if `VAR` is unset OR empty; use `${VAR-default}` if an explicit empty value must be preserved.
- **Python `smtplib`: validate addresses before sending**: Guard every send with a basic address sanity check.
- **`pm2 restart <name>` does NOT pick up ecosystem config changes**: It reuses the in-memory config. Use `pm2 delete <name> && pm2 start ecosystem.config.js --only <name>` (or `pm2 reload ecosystem.config.js`).
- **PM2 crash loops from DB dependency on startup**: Services that connect to Postgres (or any external DB) at module load can tight-loop on boot if the DB isn't ready; connect lazily with retry and backoff.
- **Bash `date +%H` is octal-invalid in arithmetic**: `08` and `09` break `$(( ))`; use `$((10#$(date +%H)))` or `date +%-H`.
- **`WebFetch`-style tools route through a remote edge, not your local network**: Use `curl` from the shell for private or local URLs.
- **Generated crontabs**: If your crontab is generated from a registry file, edit the registry and regenerate; hand edits to the live crontab are overwritten and drift.
- **Bash `set -e` kills error handlers before they fire**: In `set -e` or `set -euo pipefail` scripts, capture exit codes inline with `cmd || VAR=$?`.
- **Bash `git stash pop` must be guarded**: Never call `git stash pop` unconditionally in a script; only pop if the stash step actually created an entry.
- **PM2 periodic-exit scripts use `autorestart: false` with `cron_restart`**: For any process that exits on completion, pair `cron_restart` with `autorestart: false`, or it restarts in a tight loop (and back it with system cron, see above).
- **Cron wrappers on remote machines self-sync**: Scripts running on hosts without a deploy pipeline should `git pull --ff-only` at the start of each run.
- **`claude -p` vs `claude --print` positional trap**: In scripts that pipe stdin to `claude`, use `--print` (not `-p`) whenever other flags follow.
- **ID-based cursor iteration for large datasets**: Paginate with `WHERE id > ? ORDER BY id LIMIT N`, not `LIMIT N OFFSET M`.
- **Resilient DB JSON parsing**: Wrap every `JSON.parse()` of a stored JSON column in `try/catch`.
- **Confirm async follow-through, not just dispatch**: Any runner that creates a PR, ticket, or artifact for later pickup should, at the START of its next run, reconcile its own prior outputs rather than trusting a downstream janitor.
- **Gemini CLI `-p` does NOT support multimodal input**: In headless mode `@filepath` references to video or images are treated as text only.
- **Chokidar denylist: segment vs substring matching**: The `ignored` function receives the full path; match path segments, not substrings, or you'll ignore far more (or less) than intended.
- **Bash `$HOSTNAME` is always set**: Never use `${HOSTNAME:-default}` as a bind-address guard; it never falls through.
- **SQLite `.iterate()` cleanup and watcher depth limiting**: Wrap `.iterate()` in `try/finally` so the cursor always closes, and set a `depth` limit on file watchers.
- **Background queue saturation guards for webhook handlers**: Track pending fire-and-forget tasks and return HTTP 503 when a cap is exceeded.
- **SQLite `createMany` variable limit and webhook timestamp validation**: SQLite limits bind parameters per statement (about 999 on older builds, up to 32766 on recent ones); chunk bulk inserts, and reject webhooks with stale or missing timestamps.
- **Express API routes: null-check after insert, try/catch everywhere**: A DB read right after a write can return null; wrap every route handler in `try/catch`; guard nullable columns with `!== undefined` rather than `||`.
- **Claude CLI `--model` alias vs SDK model ID**: The CLI's `--model` flag takes short aliases, not API model IDs; verify the model that actually served the request, not the flag you passed.
- **Health endpoint: data pipeline freshness gate**: `/health` should check not only DB connectivity but whether background sync jobs have written recently.
- **V8 object nullification in batch functions**: Large objects in scope until a function returns may not be collected; scope them tightly (smaller helper functions) in long batch runs.
- **File-watcher feedback loop**: A service that watches a directory and writes into it must explicitly exclude its own output files.
- **`Promise.race` timeout leaves a dangling timer**: `clearTimeout` in a `finally` once the race settles.
- **Defensive JSON parsing in batch/summarization loops**: If the cursor advances only after the loop, one bare `JSON.parse` failure stalls the pipeline forever; parse per item inside `try/catch`.
- **SQLite `busy_timeout` alongside WAL**: WAL alone doesn't prevent `SQLITE_BUSY`; also set `PRAGMA busy_timeout = 5000` (or similar).
- **PrismaClient with the LibSQL adapter**: Don't pass `datasourceUrl` in the constructor; the adapter owns the connection.
- **Bash monitoring: alert-once-then-suppress via marker state**: The marker must encode whether an alert was already sent, not just that a failure occurred; clear it on recovery.
- **External API 429 handling**: Use exponential backoff on 429 plus a fixed inter-request throttle in sequential loops.
- **Express: `URLSearchParams(req.query)` drops repeated params**: Iterate explicitly and `.append()` each value.
- **OAuth bootstrap: a copied token gets revoked on source rotation**: Copying a refresh token from one container to another makes them share it; when either rotates, the other is revoked. Authenticate each consumer independently.
- **SQLite UPSERT with optional columns**: Branch on whether the optional field was provided and use a separate prepared statement per case, so an absent value doesn't overwrite existing data with null.
- **SQLite corruption auto-detect and restore**: Run `PRAGMA quick_check` at startup and auto-restore from backup when it fails (power loss, OOM kills mid-write, and disk errors all cause corruption).
- **Multi-pass AI generation: editor commentary placement**: A refinement pass leads with meta-commentary unless told not to; instruct it explicitly to put any editor notes at the bottom.
- **Strip narration from both ends**: When post-processing model output, remove trailing editor notes as well as leading narration, gated on the notes heading being the last heading in the document.
- **Webhook queue: array-based queue over promise chains**: For bursty events processed sequentially with I/O, use an explicit array queue and a single worker loop instead of an ever-growing promise chain.
- **Multi-phase AI research pipeline with disqualification gates**: Structure research/recommendation agents as sequential phases that narrow candidates and apply hard disqualifiers before deepening research.
- **`for...of`: don't assign to a `const` loop variable**: It throws and can crash-loop a service; use `let`. Nulling a loop variable "to help GC" is cargo-cult code.
- **Slug guard**: When converting a string to a slug for a URL path segment, return `[]` (or reject) when the derived slug is empty.
- **Shell script network calls: always set timeouts**: Unattended scripts must use `curl --max-time` and `ssh -o ConnectTimeout=...`, or a slow host hangs them indefinitely.
- **Client-side storage schema validation**: Validate the shape of anything loaded from `localStorage`/`sessionStorage` and fall back to defaults on mismatch.
- **Required-field validation in user-authored config parsers**: Never access required keys by raw indexing (`d["type"]` gives a cryptic `KeyError`); validate and emit a message naming the file and missing field.
- **Autonomous agent repos: gitignore runtime state files**: Anything the loop writes at runtime must be gitignored.
- **Bare `JSON.parse` inside `.map()` over DB rows is a crash vector**: One bad row kills the whole response; parse per row with a guard.
- **String normalization output guard**: `slugify()`-style functions can return `''` or `['']` for empty or whitespace input; check the output, not just the input.
- **Verify free tiers before depending on them**: CLI free tiers get deprecated; confirm the tier is still live before building on it.
- **Codex CLI gotchas**: Keep the CLI up to date (stale versions silently break all models); the vision `-i` flag is variadic, so pass the prompt via stdin; `codex exec` echoes the prompt in its output, so don't assert on substrings of it in tests.
- **WSL overnight scheduling**: A wake timer requires sleep, not shutdown; put the machine to sleep before an overnight run.
- **Custom skill source of truth**: Keep skills in a repo and edit there first, then sync to the live copy; edits to the live copy get overwritten.
- **Cron PATH double trap**: Prepend both the `claude` and `node` bin directories at the top of any cron-invoked script.
- **Per-item failure isolation in batch loops**: Wrap each iteration in `try/catch` so one bad record doesn't abort the whole batch; log and count failures.
- **PM2 stop is not durable against deploy-path restarts**: `pm2 stop` plus `pm2 save` does not keep an app stopped if a deploy script restarts it; remove it from the ecosystem file or `pm2 delete` it.
- **Cron script failure alerting**: Add an EXIT trap that sends an alert (via a shared helper) on non-zero exit; silent cron failures are the top cause of auth expiry going unnoticed for days.
- **Suspending an autonomous agent: full checklist**: Stopping the process is not enough; also remove it from the ecosystem file, disable its cron entries and any deploy-path restarts, and record the suspension in `context.md`.
- **Cron jobs that invoke `claude` must use an absolute binary path**: Cron's minimal PATH (`/usr/bin:/bin`) doesn't include `/usr/local/bin`.
- **Parallel Bash calls race on persisted shell cwd**: Always `cd` with an absolute path explicitly, or use absolute paths throughout.
- **Follow-mode log commands piped into `head` leak a process forever**: `pm2 logs`/`tail -f` piped into something that exits early keeps running; use a non-follow flag (`--nostream`, `tail -n`) or wrap in `timeout`.
- **A data column used as a state machine makes failures invisible to recovery**: If a status column has no explicit failed state and timestamp, stuck rows are never retried; model failure states explicitly.
- **A generator that claims to be the source of truth for a live config is dangerous once it drifts**: Diff the generated output against the live config before installing, and refuse to overwrite on unexplained differences.
- **Next.js standalone build in a git worktree**: The server nests under `.next/standalone/<path-from-repo-root>`; don't hardcode `.next/standalone/server.js` in worktree builds.
- **A collapsed `<details>` still mounts and parses all its children**: Lazy-mount heavy content on open.
- **Module-level `process.env` reads bake in defaults before `dotenv.config()` runs (ES modules)**: Read env vars at call time, or load dotenv first via `import 'dotenv/config'` as the very first import in the entrypoint.
- **Node `fetch` (undici) default `headersTimeout` cuts slow non-streaming backends**: The default is about 300 seconds; for backends that send headers only after computing the whole body, pass a custom dispatcher with a longer `headersTimeout`, or stream.
- **`pkill`/`pgrep -f` also match the shell whose command line contains the pattern**: Use a pattern that can't match itself (e.g. `pgrep -f '[m]y-server'`) or match by PID file.
