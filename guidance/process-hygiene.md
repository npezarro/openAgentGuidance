<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

If you spawn a long-running process (`npm run dev`, a background build, a watch command, a test runner in watch mode), you own it for the duration of your session.

- **Record the PID or process name** when you start something. You'll need it to stop it later.
- **Stop it before session end**, or document it in `context.md` so the next session knows it's running.
- **Don't assume your process manager (e.g. PM2) will manage it.** Only processes declared in `ecosystem.config.cjs` (or equivalent) are managed. Anything you start with `node`, `npm run dev`, or `&` is orphaned when your session ends.

```bash
# Start a dev server and note the PID
npm run dev &
DEV_PID=$!
echo "Dev server running on PID $DEV_PID"

# Later, clean up
kill $DEV_PID
```

## Atomic State Writes

When updating `context.md` or `progress.md`, treat the update as its own operation. Don't leave it as the last step in a chain that might not complete.

- **Update context files early and often**, not just at session end.
- **Commit the context update with the work it describes**, in the same commit.
- If you're about to do something risky (a build, a deploy, a large refactor), update `context.md` *before* the risky step so that if it crashes, the state is captured.

## Temp File Cleanup

- Don't leave temp files in `/tmp`, project directories, or anywhere else.
- If you create scratch files during debugging (`test.js`, `debug.log`, `temp.json`), delete them before committing.
- If a process creates temp files (detached job output, build artifacts), clean them up or document their location.

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

When PM2 restarts a process, the old Node instance may not release its port before the new one starts, causing `EADDRINUSE`, then a crash, then a PM2 restart, repeat.

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
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. This ensures the SQLite WAL is flushed and connections released before exit, preventing `SQLITE_BUSY` or "database is locked" on the next start.
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
   - The build script must `mkdir -p .next/standalone/.next` before `rm -rf .next/standalone/.next/static`; on a fresh clone the directory doesn't exist and `cp` fails silently. Correct form: `next build && mkdir -p .next/standalone/.next && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static`

**Diagnosis:** `pm2 show <process>` with a rapidly increasing restart count plus `EADDRINUSE` in the logs means this pattern.

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

Start with SIGTERM (graceful) and escalate to SIGKILL only after several retries. Use `fuser` when available (util-linux); fall back to `lsof` (macOS, minimal Linux). This is a start.sh-level fix, not a replacement for `kill_timeout`.

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
- The 2s delay gives the OS time to release the port between attempts.
- Intermittent EADDRINUSE can persist even with a long `kill_timeout`, graceful shutdown, and proactive port kill all in place; the app-level retry is what closes the gap.

**Client-side companion: also retry `ECONNREFUSED`.** A worker or client process that starts before its server is fully bound receives `ECONNREFUSED`, not `EADDRINUSE`. Include `ECONNREFUSED` in the retryable error set alongside `EAI_AGAIN`, `ECONNRESET`, and `ETIMEDOUT`. This handles the startup race where server and client launch concurrently (e.g. PM2 starts both in rapid succession).

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

PM2's `cron_restart` with `autorestart: false` does not reliably reawaken a batch script that exits normally after doing its work. The script exits, PM2 marks it "stopped", and on some deployments the cron silently never fires again. A batch job can go dark for weeks with no error and no alert.

**Fix:** For any run-once, batch, or cron-style PM2 process (digest posters, scrapers, daily scripts), use the system crontab calling `pm2 restart <name> --update-env` as the primary scheduler. Keep `cron_restart` in `ecosystem.config.js` only as documentation, not as the sole mechanism.

```cron
0 7 * * * /usr/bin/env pm2 restart my-batch-job --update-env >> $HOME/logs/my-batch-job.cron.log 2>&1
```

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop any dev servers, watch commands, or background tasks you started.
2. **Temp files:** Delete any scratch files you created.
3. **Ports:** Verify you haven't left a rogue server bound to a port.
4. **Git state:** No uncommitted changes related to your task.
5. **Context:** `context.md` reflects what's running and what's not.

## Rule Digest

One line per lesson. Each was learned from a real silent failure.

### Containers and process managers
- **Docker bind mount refresh**: use `docker compose down && docker compose up -d`, not `docker compose restart`, for anything that must pick up updated host files.
- **Docker `exec` always needs `--user`**: when a container has a non-root application user, pass `--user <username>` on every `docker exec`, or files get created root-owned and the app can't touch them.
- **`pm2 restart <name>` does NOT pick up ecosystem config changes**: it reuses the in-memory config. Use `pm2 delete <name> && pm2 start ecosystem.config.js --only <name>` (or `pm2 reload ecosystem.config.js`) after editing the config.
- **PM2 crash loops from DB dependency on startup**: services that connect to Postgres (or any external DB) at module load time loop tightly if the DB isn't ready after a reboot. Connect lazily with retry and backoff instead of at import.
- **PM2 periodic-exit scripts**: for any process that exits on completion, always pair `cron_restart` with `autorestart: false` (and schedule via system crontab as above).
- **`pm2 stop` is not durable**: `pm2 stop <app>` plus `pm2 save` does not permanently stop an app; any deploy path that runs `pm2 start ecosystem...` or `pm2 restart all` brings it back. Use `pm2 delete` and remove it from the ecosystem file.
- **Suspending an autonomous agent: full checklist**: stopping the process alone is not enough. Also `pm2 delete` it, remove it from the ecosystem file, remove its crontab entries and any external schedulers, and record the suspension in `context.md`.

### Bash and cron
- **Stale git lock files**: any automated script that runs git should check for and remove stale `.git/index.lock` (only when no git process is running) before operating.
- **`set -u` with optional parameters**: use `${N:-}` or `${N:-default}` for any positional parameter that may not be passed.
- **`${VAR:-default}` vs `${VAR-default}`**: `:-` substitutes when `VAR` is unset OR empty; `-` only when unset. Pick deliberately.
- **`date +%H` is octal-invalid in arithmetic**: `08` and `09` break `$(( ))`. Use `date +%-H` or `$((10#$h))`.
- **`set -e` kills error handlers before they fire**: in `set -e` / `set -euo pipefail` scripts, capture exit codes inline with `cmd || VAR=$?`.
- **Guard `git stash pop`**: never call it unconditionally in a script; only pop if your own stash was actually created.
- **Remote cron wrappers self-sync**: cron scripts on hosts without a deploy pipeline should `git pull --ff-only` at the start of each run.
- **Cron PATH double trap**: cron runs with a minimal PATH (`/usr/bin:/bin`). Prepend the bin dirs for both `node` and any CLI you call (e.g. `/usr/local/bin`) at the top of every cron-invoked script, or call binaries by absolute path.
- **Cron failure alerting**: unattended scripts fail silently (expired auth can go unnoticed for days). Add an `EXIT` trap that sends an alert via a shared helper when the exit code is non-zero.
- **Alert-once-then-suppress**: monitoring scripts should keep a marker that records *whether an alert was already sent*, not just that a failure occurred, and clear it on recovery.
- **Network calls in shell scripts need timeouts**: `curl`, `ssh`, `openssl s_client`, `dig`, `nc` without timeouts hang forever on a slow host; if that hang holds a shared lock, every later scheduled run is blocked behind it for days.
- **`$HOSTNAME` is always set**: never use `${HOSTNAME:-default}` as a bind-address guard; it never falls through.
- **`pkill -f` / `pgrep -f` matches its own invoking shell**: a pattern that appears in the calling shell's cmdline kills or counts that shell too. Use a bracketed pattern (`[m]y-proc`) or match on exact process name.
- **Follow-mode logs piped to `head` leak forever**: `tail -f` or `pm2 logs` piped into something that exits early leaves the producer running. Use `--lines N --nostream` / non-follow modes, or wrap with `timeout`.
- **Parallel Bash calls race on persisted shell cwd**: when running tool calls in parallel, always `cd` with an absolute path inside each command instead of relying on the previous cwd.
- **Generated config drift**: if a live config (e.g. a crontab) is generated from a registry file, edit the registry and regenerate; reconcile any drift between the live config and the generator before regenerating, or the regeneration silently deletes live entries.

### CLIs and agents
- **`claude -p` vs `claude --print`**: in scripts that pipe stdin to `claude`, use `--print` whenever other flags follow, so a flag value isn't swallowed as the positional prompt.
- **Claude CLI `--model` takes short aliases** (e.g. `opus`, `sonnet`), not full API model IDs.
- **`WebFetch` routes through a remote edge, not your local network**: use `curl` via Bash for private or local URLs.
- **Gemini CLI `-p` treats `@filepath` as text only**: it does not do multimodal (image/video) input in headless mode. Also verify any free tier you depend on is still offered before building on it.
- **Codex CLI gotchas**: keep the CLI updated (stale versions silently break all models); the vision `-i` flag is variadic, so pass the prompt via stdin; `codex exec` echoes the prompt in its output, so tests must not match on prompt text.
- **Custom skill source of truth**: edit skills in their source repo and reinstall, never the live installed copy, or the next sync overwrites your change.
- **Never hand the user long text to copy-paste**: write it to a file or run it yourself instead of giving long commands, URLs, or multi-line text to transcribe.
- **Copied OAuth tokens get revoked**: bootstrapping a second container by copying a token means both share one refresh token; when one rotates it, the other dies. Give each consumer its own login.
- **Gitignore runtime state in autonomous agent repos**: anything the loop itself writes (state files, cursors, logs) belongs in `.gitignore`.
- **Confirm async follow-through, not just dispatch**: any runner that creates a PR, ticket, or artifact for later pickup should, at the START of its next run, reconcile its own prior outputs (merged? stuck? abandoned?) rather than waiting for a janitor to notice.
- **Stale dedup lists**: agents that gate new work on a dedup list built from `git log` or `git branch -r` must `git fetch --prune` first, or they block on, or act on, stale data.
- **"Safe to close, nothing unique lost" is a claim about the whole diff**: before closing a bundled PR, verify each distinct change against main independently, not per-file at a glance.
- **Multi-pass AI generation**: refinement passes lead with meta-commentary unless told otherwise; instruct them explicitly to put any editor notes at the bottom, and strip such notes from both ends of the output.
- **WSL overnight scheduling**: wake timers only fire from sleep, not shutdown. Put the machine to sleep before an overnight run.

### Node.js and services
- **Module-level `process.env` reads bake in defaults before `dotenv.config()` runs (ESM)**: read env vars at call time, or make `import 'dotenv/config'` the very first import in the entrypoint.
- **Node `fetch` (undici) default `headersTimeout` is about 300s**: backends that send headers only after computing the full body get cut off. Raise the timeout via a custom dispatcher or stream the response.
- **`Promise.race` timeout wrappers leave a dangling timer**: `clearTimeout` in a `finally`, or the timer keeps the process alive.
- **`for...of` with `const`**: never assign to the loop variable (it throws and can crash-loop a service); use `let`. Nulling a loop variable "to help GC" is cargo-cult; the reference is released when the block exits.
- **V8 large-object retention in batch functions**: large objects in scope until a function returns may not be collected; scope them per iteration or null them when a long-running function is done with them.
- **Express: `new URLSearchParams(req.query)` drops repeated params**: iterate and `.append()` each value.
- **Express routes: null-check after DB insert and try/catch every handler**: a write-then-read can return null; wrap every async handler; use `!== undefined` rather than `||` for nullable columns so `0`/`''` survive.
- **Background queue saturation**: when a handler spawns fire-and-forget work, track pending count and return HTTP 503 above a cap.
- **Webhook queues: array-based, not promise chains**: a growing `.then()` chain under bursty load leaks memory and loses errors; use an array queue drained by a single worker.
- **External API 429s**: use exponential backoff on 429 plus a fixed inter-request throttle in sequential loops.
- **Health endpoints should check data freshness**: besides DB connectivity, verify background sync jobs wrote recently, or a dead pipeline reports healthy.
- **File-watcher feedback loop**: a service that watches a directory and writes into it must exclude its own output files, or it triggers itself forever.
- **Chokidar `ignored` gets the full path**: match denylist entries as path segments, not substrings, or `/build` also ignores `/rebuild-notes`. Limit watch depth on large trees.
- **Next.js standalone in a git worktree**: the server lands under `.next/standalone/<path-from-repo-root>/`, not `.next/standalone/server.js`; resolve the path rather than hardcoding it.
- **Collapsed `<details>` still mounts its children**: lazy-mount heavy content on first open.
- **Client-side storage**: validate the schema of anything loaded from `localStorage`/`sessionStorage` and fall back to defaults on mismatch.
- **Slug and normalization guards**: `slugify()`-style functions can return `''` or `['']` for empty or whitespace input; return `[]` or reject instead of building an empty path segment.
- **Required fields in user-authored config**: validate required keys with a clear error message instead of raw indexing (`d["type"]` gives a cryptic `KeyError`).
- **Validate email addresses before `smtplib` sends**: a basic sanity check avoids crashing the whole run on one bad address.

### Data and SQLite
- **Wrap every `JSON.parse()` of DB data in try/catch**, especially inside `.map()` over rows and in batch loops that advance a cursor after the loop: one bad row otherwise crashes the request or permanently stalls the pipeline.
- **Per-item failure isolation in batch loops**: catch and log per iteration so one bad record skips itself instead of aborting the whole batch.
- **ID-based cursor pagination for large tables**: use `WHERE id > ? ORDER BY id LIMIT N`, not `LIMIT N OFFSET M`, which gets slower and skips or repeats rows under concurrent writes.
- **SQLite `busy_timeout` alongside WAL**: WAL alone doesn't prevent `SQLITE_BUSY`; set `PRAGMA busy_timeout` (e.g. 5000) too.
- **SQLite `.iterate()` cleanup**: wrap in try/finally so the cursor closes on error.
- **SQLite bind-parameter limit**: `createMany`/bulk inserts hit the per-statement variable limit (about 999 on older builds); chunk them. Validate webhook timestamps before storing.
- **SQLite UPSERT with optional columns**: branch on whether the field was provided and use a separate statement per case, so an absent value doesn't overwrite stored data with null.
- **SQLite corruption auto-detect**: run `PRAGMA quick_check` at startup and auto-restore from the latest backup on failure.
- **Prisma with the LibSQL adapter**: don't also pass `datasourceUrl` in the `PrismaClient` constructor; the adapter owns the connection.
- **Don't use a data column as a state machine without recovery**: if a status column drives processing, a row stuck in an intermediate state (crash mid-job) is invisible to retry logic. Add timestamps and a sweep that resets stale in-progress rows.
