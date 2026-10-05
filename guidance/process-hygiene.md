<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

If you start a long-running process (`npm run dev`, a background build, a watch command, a test runner in watch mode), you own it for the rest of your session.

- **Record the PID or process name** when you start it, because you need it to stop the process later.
- **Stop it before the session ends**, or note it in `context.md` so the next session knows it is running.
- **Don't assume PM2 (or any process manager) manages it.** It only manages processes listed in `ecosystem.config.cjs` or the equivalent. Anything you start with `node`, `npm run dev`, or `&` is orphaned when your session ends.

```bash
# Start a dev server and note the PID
npm run dev &
DEV_PID=$!
echo "Dev server running on PID $DEV_PID"

# Later, clean up
kill $DEV_PID
```

## Atomic State Writes

Treat an update to `context.md` or `progress.md` as its own operation. Don't leave it as the last step of a chain that might not finish.

- **Update context files early and often**, not only at session end.
- **Commit the context update with the work it describes**, in the same commit.
- Before a risky step (a build, a deploy, a large refactor), **update `context.md` first**. If the step crashes, the state is already recorded.

## Temp File Cleanup

- Don't leave temp files in `/tmp`, in project directories, or anywhere else.
- Delete scratch files you made while debugging (`test.js`, `debug.log`, `temp.json`) before you commit.
- If a process creates temp files (detached job output, build artifacts), clean them up or write down where they are.

## Port and Process Conflicts

Before you start any server or service:

```bash
# Is the port already in use?
ss -tlnp | grep <port>

# Is a previous instance still running?
ps aux | grep <process-name>
pm2 list
```

Don't start a service on a port that is already taken. If the process on it is yours, stop it. If not, use a different port. If it belongs to another session, coordinate with that session and don't kill it.

### PM2 Restart EADDRINUSE Crash Loop

When PM2 restarts a process, the old Node instance may still hold its port when the new one starts. The result is a loop: `EADDRINUSE`, crash, PM2 restart, repeat.

**Diagnosis:** `pm2 show <process>` shows a restart count that keeps climbing, and the logs contain `EADDRINUSE`.

**Three-layer fix:**

1. **Set `kill_timeout` and `listen_timeout` in the ecosystem config:**
   ```js
   { kill_timeout: 3000, listen_timeout: 3000 }
   ```
2. **Add a graceful shutdown handler to the server code.** Handle both SIGINT and SIGTERM, close DB connections inside the `server.close()` callback, add a force-exit fallback, and register global error handlers:
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
   - SIGINT covers Ctrl-C in development. SIGTERM covers a PM2 restart. You need both.
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. That flushes the SQLite WAL and releases connections before the process exits, so the next start doesn't hit `SQLITE_BUSY` or "database is locked".
   - The force-exit keeps PM2 from hanging on keep-alive connections that never drain.
   - Without the `unhandledRejection`/`uncaughtException` handlers, PM2 sees a silent crash with nothing in the logs.
3. **Use a `start.sh` wrapper for Next.js standalone.** If PM2 runs `next start` directly, it loses track of the real process. A wrapper lets PM2 signal the actual node process:
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
   - The build script must run `mkdir -p .next/standalone/.next` before `rm -rf .next/standalone/.next/static`. On a fresh clone that directory doesn't exist, and `cp` fails silently. The correct form is: `next build && mkdir -p .next/standalone/.next && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static`

**Extra layer: clear the port in start.sh before launch.** `kill_timeout` isn't always enough. For example, a previous process may have crashed without releasing its socket. For that case, add a `kill_port()` function at the top of `start.sh`:

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

Send SIGTERM first so the process can exit cleanly. Escalate to SIGKILL only after several retries. Use `fuser` when it is installed (util-linux) and fall back to `lsof` (macOS, minimal Linux). This works alongside `kill_timeout` in the ecosystem config. It does not replace it.

**App-level retry loop around `server.listen()`.** Even with `kill_timeout`, graceful shutdown, and the start.sh port cleanup, `EADDRINUSE` can still show up now and then. Instead of exiting right away, wrap `app.listen()` in a retry loop:

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

- Retry only on `EADDRINUSE`. Exit hard on every other error.
- The 2s delay gives the OS time to release the port between attempts.

**Client side: also retry `ECONNREFUSED`.** A worker or client that starts before its server has bound the port gets `ECONNREFUSED`, not `EADDRINUSE`. Treat `ECONNREFUSED` as retryable, along with the usual network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). This covers the startup race when the server and client launch together, for example when PM2 starts both back to back.

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

`cron_restart` with `autorestart: false` does not reliably wake up a batch script that exits normally after doing its work. The script exits, PM2 marks it "stopped", and on some setups the cron never fires again. Nothing errors and nothing alerts: the job simply stops running, and this can go unnoticed for days.

**Fix:** For any run-once, batch, or cron-style PM2 process (digest posters, scrapers, daily scripts), make the system crontab the primary scheduler and have it run `pm2 restart <name> --update-env`:

```cron
0 7 * * * pm2 restart my-batch-job --update-env >> /var/log/my-batch-job.cron.log 2>&1
```

You can keep `cron_restart` in `ecosystem.config.js` as documentation, but don't rely on it as the only trigger.

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop every dev server, watch command, and background task you started.
2. **Temp files:** Delete every scratch file you created.
3. **Ports:** Check that you haven't left a stray server bound to a port.
4. **Git state:** No uncommitted changes related to your task.
5. **Context:** `context.md` says what is running and what isn't.

## Rule Digest

One line per lesson, each learned from a real failure.

- **Docker bind mount refresh**: When a container must pick up updated host files, run `docker compose down && docker compose up -d`. `docker compose restart` isn't enough.
- **Docker `exec` always needs `--user`**: If the container has a non-root application user (for example `node`), pass `--user <username>` on every `docker exec` call.
- **Long text transfer**: Never ask the user to copy-paste long commands, URLs, or multi-line text by hand.
- **Stale git lock files**: Any automated script that runs git should check for stale lock files and remove them before it starts.
- **Stale branch dedup lists**: An agent that skips work based on a dedup list built from `git log` or `git branch -r` may be reading stale data. Refresh the list (fetch) before trusting it.
- **Bash `set -u` with optional parameters**: For any positional parameter that might not be passed, use `${N:-}` (empty default) or `${N:-default}`.
- **Bash `${VAR:-default}` vs `${VAR-default}`**: `${VAR:-default}` uses the default when `VAR` is **unset or empty**. `${VAR-default}` uses it only when `VAR` is unset.
- **Python `smtplib`: validate addresses before sending**: Run a basic sanity check on the address before every `smtplib` send call.
- **`pm2 restart <name>` does NOT pick up ecosystem config changes**: It restarts from the in-memory config. To apply edits, run `pm2 delete <name> && pm2 start ecosystem.config.js --only <name>`, or use `pm2 reload ecosystem.config.js --update-env`.
- **PM2 crash loops from a DB dependency at startup**: A service that connects to Postgres (or any external DB) when its module loads can crash-loop if the DB isn't ready on first boot or after a reboot. Retry the connection with backoff instead of exiting.
- **Bash `date +%H` breaks arithmetic**: It prints zero-padded hours (`08`, `09`), which Bash reads as invalid octal. Use `10#$(date +%H)` or `date +%-H`.
- **`WebFetch` runs on a remote edge, not on your machine**: For private or local URLs, use `curl` in Bash.
- **Bash `set -e` kills error handlers before they run**: In `set -e` or `set -euo pipefail` scripts, capture exit codes inline with `cmd || VAR=$?`.
- **Guard `git stash pop` in scripts**: Never call it unconditionally. Pop only if the script actually created a stash.
- **PM2 periodic-exit scripts need `autorestart: false` with `cron_restart`**: Any PM2 process that exits when it finishes (data push, sync jobs, batch processors) must pair `cron_restart` with `autorestart: false`. Also see the crontab fix above.
- **Cron wrappers on remote machines update themselves**: A cron script on a host with no deploy pipeline should run `git pull --ff-only` at the start of each run.
- **`claude -p` vs `claude --print` positional trap**: In scripts that pipe stdin to `claude`, use `--print` (not `-p`) whenever other flags follow it.
- **ID-based cursor pagination for large tables**: For batch work over a large table, page with `WHERE id > :last ORDER BY id LIMIT N`, not `LIMIT N OFFSET M`.
- **Wrap every `JSON.parse()` of DB data in try/catch**: Serialized JSON columns (metadata, config blobs, event payloads) will sometimes hold bad data.
- **Confirm the async work actually happened, not just that you dispatched it**: A runner that creates a PR, ticket, or artifact for someone to pick up later should check the state of its own previous outputs at the START of its next run.
- **Gemini CLI `-p` does NOT support multimodal input**: In headless mode, `@filepath` references are read as text only.
- **Chokidar `ignored` gets the full path**: Match whole path segments, not substrings, or a deny pattern will match unrelated directories.
- **Bash `$HOSTNAME` is always set**: Never use `${HOSTNAME:-default}` to guard a bind address.
- **SQLite `.iterate()` cleanup and watcher depth**: Wrap `.iterate()` in try/finally so the cursor is closed even on error, and set a depth limit on file watchers.
- **Saturation guard for webhook background queues**: If a route handler starts fire-and-forget background work, count the pending tasks and return HTTP 503 once a cap is exceeded.
- **SQLite bind-parameter limit in `createMany`**: SQLite caps bind parameters per statement (about 999 in older builds, up to 32766 in newer ones), so split bulk inserts into chunks. Also validate webhook timestamps.
- **Express routes: null-check after DB insert, try/catch everywhere**: A read right after a write can return null. Every route handler needs a try/catch. For nullable columns, check `!== undefined` rather than using `||`.
- **Claude CLI `--model` takes aliases, not API model IDs**: Use short aliases with the CLI.
- **Health endpoint checks data freshness**: `/health` should also check that background sync jobs wrote data recently, not only that the DB connection works.
- **Null out large objects in batch functions**: V8 may not garbage-collect large objects that stay in scope until the function returns, even after you stop using them.
- **File-watcher feedback loop**: A service that watches a directory and also writes inside it must exclude its own output files from the watch.
- **A `Promise.race` timeout leaves a timer running**: Clear the `setTimeout` when the main promise settles.
- **Defensive JSON parsing in batch loops that advance a cursor**: One bare `JSON.parse` failure before the cursor moves stalls the pipeline permanently. Skip and log the bad row instead.
- **SQLite `busy_timeout` alongside WAL**: WAL alone doesn't prevent `SQLITE_BUSY` under concurrent requests. Also set `busy_timeout`.
- **Prisma with the LibSQL adapter: don't pass `datasourceUrl`**: The adapter already owns the connection.
- **Alert once, then stay quiet, using a marker file**: The marker must record *whether an alert was already sent*, not just that a failure happened.
- **External API 429s**: Use exponential backoff on 429 responses, plus a fixed delay between requests in sequential loops.
- **Express `URLSearchParams(req.query)` drops repeated params**: Loop over the query and call `.append()` for each value.
- **A copied OAuth token gets revoked when the source rotates**: Bootstrapping one container's auth by copying another's token means both share one refresh token. Give each consumer its own login.
- **SQLite UPSERT with optional columns**: Branch on whether the optional field was provided, with a separate prepared statement for each case, so a missing value never overwrites stored data with null.
- **Detect SQLite corruption and restore automatically**: Run `PRAGMA quick_check` at startup and restore from backup if it fails. Power loss, OOM kills mid-write, and disk I/O errors can all corrupt a database.
- **Editor commentary in multi-pass AI content generation**: A refinement pass will start with meta-commentary unless told otherwise. Tell it explicitly to put editor notes at the bottom, after the content.
- **Strip narration from both ends**: Remove trailing editor notes as well as leading narration, but only when the editor-notes heading is the last heading in the document.
- **Webhook queues: use an array, not a promise chain**: For bursty events that must be processed in order with I/O, an explicit array queue avoids a promise chain that grows without bound.
- **Multi-phase AI research pipeline with disqualification gates**: Run research-and-recommend agents as a sequence of phases that drop candidates first and then dig deeper into the ones left.
- **`for…of`: don't assign to a `const` loop variable**: It throws and can cause a crash loop. Use `let`. Setting a loop variable to null "to help GC" does nothing.
- **Slug guard**: If the derived slug is empty, return `[]` instead of an empty path segment.
- **Set timeouts on every network call in shell scripts**: In unattended scripts, any blocking network command (`curl`, `ssh`, `openssl s_client`, `dig`, `nc`) needs a timeout. One hang that holds a shared lock blocks every scheduled run behind it, for as long as the hang lasts.
- **Validate schema when loading from `localStorage`/`sessionStorage`**: Stored data may come from an older version of the app.
- **Required fields in user-authored config parsers**: Never read required keys with raw indexing (`d["type"]` gives a cryptic `KeyError`). Check for them and raise a clear error.
- **Autonomous agent repos: gitignore runtime state**: Add every runtime state file the loop writes to `.gitignore`.
- **Bare `JSON.parse` inside `.map()` over DB rows will crash**: One bad row kills the whole map.
- **Guard the output of string normalizers**: `slugify()`-style functions can return `''` or `['']` for empty or whitespace-only input. Check for it.
- **Check that a free tier still exists before depending on it**: Free tiers for AI CLIs get deprecated. Confirm the tier is still available before building on it.
- **Codex CLI gotchas**: Keep the CLI up to date, because old versions quietly break every model. The `-i` flag is variadic, so pass the prompt via stdin. `codex exec` echoes the prompt in its output, so tests must not mistake that echo for a result.
- **WSL overnight scheduling**: A wake timer works only if the machine is asleep. Sleep it, don't shut it down.
- **Custom skills: edit the repo first, then the live copy**: Make changes in the version-controlled source and sync from there, never the other way around.
- **Cron PATH trap for `claude` and `node`**: Add both bin directories to PATH at the top of any script cron runs.
- **Isolate failures per item in batch loops**: Without a guard, one bad item's throw aborts the whole batch. Wrap each iteration in its own try/catch.
- **`pm2 stop` doesn't survive a deploy**: `pm2 stop <app>` plus `pm2 save` can be undone by a deploy script that restarts everything. To retire an app for good, remove it from the deploy path too.
- **Cron failure alerts: EXIT trap plus a shared email helper**: Silent cron failures are the most common reason an expired login goes unnoticed for days.
- **Suspending an autonomous agent takes more than a PM2 stop**: Also disable its cron entries, deploy hooks, and any watchdog that would bring it back.
- **Cron jobs that call `claude` need its absolute path**: Cron's minimal PATH (`/usr/bin:/bin`) usually doesn't include where the CLI is installed.
- **Parallel Bash calls share the persisted shell cwd**: Always `cd` with an absolute path, or use absolute paths in commands.
- **A follow-mode log command piped into `head` leaks a shell forever**: When `head` exits, the streaming command upstream doesn't, so the process is never cleaned up.
- **Using a data column as a state machine hides failures from recovery**: Store state explicitly so recovery code can find stuck or failed items.
- **A generator that claims to be the source of truth for a live config is dangerous once they drift**: Reconcile the live config against the generator before you regenerate.
- **A Next.js standalone build in a git worktree nests the server**: The server lands under `.next/standalone/<path-from-repo-root>`, so fixed paths to `server.js` break.
- **A collapsed `<details>` still mounts and parses all its children**: Mount heavy content only when the element is opened.
- **Module-level `process.env` reads happen before `dotenv.config()` runs (ES modules)**: Imports are evaluated first, so the default gets locked in. Read env vars at call time, or put `import 'dotenv/config'` as the very first import in the entrypoint.
- **Node `fetch` (undici) times out slow non-streaming backends**: The default `headersTimeout` (about 300s) closes the socket when the server sends headers only after building the whole body. Raise it with a custom dispatcher.
- **`pkill -f` / `pgrep -f` also match the shell that runs them**: The pattern is in that shell's own command line. Use a pattern that can't match itself (for example `[m]yproc`).
- **"Safe to close, nothing unique lost" is a claim about the whole bundled diff**: Before making or trusting that claim on a PR, check each separate change in the diff against main.
- **Parallel backgrounded shell jobs (`cmd &` + `wait`) can silently lose output under resource pressure while the batch still reports exit 0**: Run at most 2-3 heavy build or test jobs at once, or give each job its own tool call. Before reading "no errors" into a log, check that the log file exists and isn't empty.
