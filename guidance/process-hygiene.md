<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

Any long-running process you spawn is yours until your session ends. That includes `npm run dev`, a background build, a watch command, or a test runner in watch mode.

- **Record the PID or process name** when you start something, so you can stop it later.
- **Stop it before the session ends**, or note it in `context.md` so the next session knows it's running.
- **Don't assume PM2 will manage it.** PM2 only manages processes listed in `ecosystem.config.cjs` (or equivalent). Anything you start with `node`, `npm run dev`, or `&` is orphaned when your session ends.

```bash
# Start a dev server and note the PID
npm run dev &
DEV_PID=$!
echo "Dev server running on PID $DEV_PID"

# Later, clean up
kill $DEV_PID
```

## Atomic State Writes

Treat an update to `context.md` or `progress.md` as its own operation. Don't leave it as the last step in a chain that might not finish.

- **Update context files early and often**, not only at session end.
- **Commit the context update in the same commit as the work it describes.**
- **Before a risky step** (a build, a deploy, a large refactor), update `context.md` first. If the step crashes, the state is already recorded.

## Temp File Cleanup

- Don't leave temp files in `/tmp`, in project directories, or anywhere else.
- Delete scratch files from debugging (`test.js`, `debug.log`, `temp.json`) before committing.
- If a process creates temp files (detached job output, build artifacts), clean them up or document where they are.

## Port and Process Conflicts

Before starting any server or service:

```bash
# Is the port already in use?
ss -tlnp | grep <port>

# Is a previous instance still running?
ps aux | grep <process-name>
pm2 list
```

Don't start a service on a port that's already taken. Either stop the existing process (if it's yours) or use a different port. If the process belongs to another session, coordinate with it instead of killing it.

### PM2 Restart EADDRINUSE Crash Loop

When PM2 restarts a process, the old Node instance may still hold the port when the new one starts. The result is a loop: `EADDRINUSE`, crash, PM2 restart, repeat.

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
   - SIGINT covers Ctrl-C in dev. SIGTERM covers a PM2 restart. You need both.
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. That way the SQLite WAL is flushed and connections are released before the process exits, which prevents SQLITE_BUSY or "database is locked" on the next start.
   - The force-exit stops PM2 from hanging on keep-alive connections that never drain.
   - The `unhandledRejection`/`uncaughtException` handlers log before exiting. Without them, PM2 sees a silent crash with no diagnostic output.
3. **Use a `start.sh` wrapper for Next.js standalone.** With `next start` as the PM2 script, PM2 loses track of the real process. A wrapper lets PM2 signal the actual node process:
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
   - The build script must run `mkdir -p .next/standalone/.next` before `rm -rf .next/standalone/.next/static`. On a fresh clone that directory doesn't exist, and `cp` fails silently. Correct form: `next build && mkdir -p .next/standalone/.next && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static`

**Diagnosis:** a restart count in `pm2 show <process>` that climbs quickly, plus `EADDRINUSE` in the logs, means you have this pattern.

**Extra safety: clear the port in start.sh.** Sometimes `kill_timeout` alone isn't enough, for example when a previous process crashed without releasing the socket. Add a `kill_port()` function at the top of `start.sh` that clears the port before launch:

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

Start with SIGTERM (graceful) and escalate to SIGKILL only after several retries. Use `fuser` if it's available (util-linux); otherwise fall back to `lsof` (macOS or minimal Linux). This works alongside the ecosystem config's `kill_timeout`; it doesn't replace it.

**App-level retry loop in `server.listen()`.** Even with `kill_timeout`, graceful shutdown, and a port kill all in place, `EADDRINUSE` can still happen now and then. If it does, wrap `app.listen()` in a retry loop instead of exiting on the first failure:

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

- Retry only on `EADDRINUSE`. Exit immediately on any other error.
- The 2s delay gives the OS time to release the port between attempts.

**Client side: also retry `ECONNREFUSED`.** A worker or client that starts before its server has bound the port gets `ECONNREFUSED`, not `EADDRINUSE`. Treat `ECONNREFUSED` as retryable, along with network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). This covers the startup race when the server and client launch at the same time, for example when PM2 starts both back to back.

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

`cron_restart` + `autorestart: false` does not reliably wake up a batch script that exits normally after doing its work. The script exits, PM2 marks it "stopped", and on some setups the cron never fires again. There's no error and no alert; the job just stops running, and it can go unnoticed for days or weeks.

**Fix:** for any run-once, batch, or cron-style PM2 process (digest posters, scrapers, daily scripts), make the system crontab the primary scheduler and have it call `pm2 restart <name> --update-env`. Keep `cron_restart` in the ecosystem file only as documentation, never as the only trigger.

```cron
0 7 * * * /usr/local/bin/pm2 restart my-batch-job --update-env >> $HOME/logs/my-batch-job-cron.log 2>&1
```

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop any dev servers, watch commands, or background tasks you started.
2. **Temp files:** Delete any scratch files you created.
3. **Ports:** Check that you haven't left a stray server bound to a port.
4. **Git state:** No uncommitted changes related to your task.
5. **Context:** `context.md` says what is running and what isn't.

## Rule Digest

One line per lesson, in the order they were learned.

- **Docker bind mount refresh**: when a container must pick up updated host files, run `docker compose down && docker compose up -d`, not `docker compose restart`.
- **Docker `exec` always needs `--user`**: if a container runs as a non-root application user (for example `node`), pass `--user <username>` on every `docker exec` call.
- **Long text transfer**: never hand the user long commands, URLs, or multi-line text to copy and paste manually.
- **Stale git lock files**: any automated script that runs git commands should check for stale lock files and remove them before it starts.
- **Stale branch dedup lists**: if an automated agent decides what to work on using a dedup list built from `git log` or `git branch -r`, that list can be stale, and the agent can block or act on old data.
- **Bash `set -u` with optional parameters**: use `${N:-}` (empty default) or `${N:-default}` for any positional parameter that might not be passed.
- **Bash `${VAR:-default}` vs `${VAR-default}`**: `${VAR:-default}` uses the default when `VAR` is **unset or empty**. `${VAR-default}` uses it only when `VAR` is unset.
- **Python `smtplib`: validate addresses before sending**: guard every `smtplib` send call with a basic address sanity check.
- **`pm2 restart <name>` does not pick up ecosystem config changes**: it restarts with the config PM2 has in memory. To apply edits to `ecosystem.config.js`, run `pm2 delete <name>` and then `pm2 start ecosystem.config.js --only <name>`.
- **PM2 crash loops from a DB dependency at startup**: a service that connects to Postgres (or any external DB) at module load can fall into a tight restart loop if the DB isn't ready yet (first boot, or after a reboot). Retry the connection with backoff instead of exiting.
- **Bash `date +%H` breaks arithmetic**: it returns zero-padded hours (`08`, `09`), which bash arithmetic reads as invalid octal. Write `$((10#$(date +%H)))` instead.
- **`WebFetch` goes through a remote edge, not your local network**: for private or local URLs, use `curl` via Bash.
- **Generated crontabs**: if the crontab is generated from a registry file, edit the registry and regenerate. Never hand-edit the installed crontab, because the next generation overwrites your change.
- **Bash `set -e` kills error handlers before they run**: in any `set -e` or `set -euo pipefail` script, capture exit codes inline with `cmd || VAR=$?`.
- **Guard `git stash pop` in scripts**: never call `git stash pop` unconditionally. Pop only if the earlier stash actually saved something.
- **PM2 periodic-exit scripts need `autorestart: false` with `cron_restart`**: any PM2 process that exits when it finishes (data push scripts, sync jobs, batch processors) must pair `cron_restart` with `autorestart: false`. Also make system cron the primary trigger (see above).
- **Cron wrappers on remote machines should self-sync**: cron scripts on hosts with no automatic deploy pipeline (a second PC, a Raspberry Pi) should run `git pull --ff-only` at the start of every run.
- **`claude -p` vs `claude --print` positional trap**: in any script or cron job that pipes stdin to `claude`, use `--print` (not `-p`) whenever other flags come after it.
- **ID-based cursor pagination for large tables**: to process a large DB table in batches, page by ID cursor instead of `LIMIT N OFFSET M`.
- **Wrap every `JSON.parse()` of DB data in try/catch**: rows that store serialized JSON (metadata columns, config blobs, event payloads) can hold malformed data.
- **Confirm async follow-through, not just dispatch**: a runner that creates a PR, ticket, or artifact for later pickup should check its own earlier outputs at the START of its next run, not wait for a downstream janitor to notice.
- **Gemini CLI `-p` has no multimodal input**: in headless `gemini -p` mode, `@filepath` references are read as **text only**.
- **Chokidar: match denylists by path segment, not substring**: Chokidar's `ignored` function receives the **full file path**, so a substring match can exclude unrelated paths that happen to contain the string.
- **Bash `$HOSTNAME` is always set**: never use `${HOSTNAME:-default}` as a bind-address guard, because the default never applies.
- **Clean up SQLite `.iterate()` cursors**: wrap `.iterate()` in try/finally so the cursor closes even on error. Also limit file-watcher depth.
- **Cap background queues in webhook handlers**: when a route handler starts fire-and-forget background work (webhook processors, job dispatchers), track how many tasks are pending and return HTTP 503 once a cap is exceeded.
- **SQLite `createMany` bind limit; validate webhook timestamps**: SQLite limits bind parameters per statement (about 999 on older builds, up to 32766 on recent ones). Chunk bulk inserts to stay under it.
- **Express routes: null-check after DB insert, and try/catch everywhere**: a DB write followed by a read can return null. Wrap every route handler in try/catch. For nullable columns, check `!== undefined` instead of using `||`.
- **Claude CLI `--model` takes aliases**: the flag expects **short aliases**, not API model IDs.
- **Health endpoints should check data freshness**: a `/health` endpoint should check that background sync jobs have written recently, not just that the DB is reachable.
- **Null out large objects in V8 batch functions**: V8 doesn't always garbage-collect large objects that stay in scope until a function returns, even after the code stops using them.
- **File-watcher feedback loop**: a service that watches a directory (chokidar or any inotify-based watcher) and also writes files inside it must exclude its own output files from the watch.
- **`Promise.race` timeouts leave a dangling timer**: the naive form leaves `setTimeout` running after the main promise resolves. Call `clearTimeout` in a `finally`.
- **Defensive JSON parsing in batch loops**: if a batch loop moves a cursor or timestamp forward only **after** the loop, one bare `JSON.parse` failure stalls the pipeline permanently.
- **Set SQLite `busy_timeout` alongside WAL**: WAL mode reduces write contention, but it doesn't prevent `SQLITE_BUSY` when concurrent requests hit a read-write boundary.
- **A JSON-file index updated by read-modify-write needs an in-process lock AND atomic tmp+rename writes**: an unserialized "read index.json, modify, write back" loses writes under concurrency and can corrupt the file. A bare "if missing, write `[]`" init is a third, separate race.
- **Cross-host job handoff: a failed push needs a pending marker, not just a pull guard**: a primary/fallback job wrapper that pulls shared state, runs, and pushes back must treat a failed push as its own case. Mark the file pending and re-push it before the next pull. Otherwise a run that succeeded locally gets overwritten as soon as the other host pulls stale remote state. Add a cross-host mutual-exclusion lock (not just a staleness or heartbeat check) so a flaky health check can't let both hosts run the same job. Acquire multi-file locks in sorted order to avoid deadlocks between jobs that share files.
- **PrismaClient + LibSQL adapter: don't pass `datasourceUrl`**: the `PrismaLibSql` adapter already owns the connection.
- **Bash monitoring scripts: alert once, then suppress via a marker**: the marker must record *whether an alert was already sent*, not just that something failed. If a condition stays broken with no clean success to clear the marker, store a hash of the failure content instead of a boolean. Then a *different* problem arriving during suppression still alerts instead of being absorbed by the first one's marker.
- **External API 429s: exponential backoff plus a throttle between requests**: a sequential loop against an external REST API (pagination, per-entity fetches) needs both.
- **Express: `URLSearchParams(req.query)` mishandles repeated params**: iterate explicitly and call `.append()` for each value.
- **OAuth bootstrap: a copied token gets revoked when the source rotates it**: if you set up a container's auth by copying a token from another container, both now share one refresh token, and the first rotation breaks the other side.
- **SQLite UPSERT with optional columns**: branch on whether the optional field was provided, with a separate prepared statement for each case, so a missing value doesn't overwrite stored data with null.
- **Detect SQLite corruption and restore automatically**: run `PRAGMA quick_check` at startup and restore from backup if it reports corruption. Power loss, OOM kills mid-write, or disk I/O errors can all cause corruption.
- **Multi-pass AI generation: where editor commentary goes**: a refinement pass tends to open with meta-commentary. Tell it explicitly to put any editor notes at the bottom, after the content.
- **Strip narration at both ends, not just the front**: add a trailing editor-notes strip alongside the leading-narration strip. Only remove the trailing notes when the editor-notes heading is the LAST heading in the document.
- **Webhook queues: use an array queue, not promise chains**: when a handler gets bursty events and must process them in order with I/O (DB writes, API calls), use an explicit array-based queue. An ever-growing promise chain is the wrong tool here.
- **Multi-phase AI research pipeline with disqualification gates**: for an agent that researches and recommends (restaurants, vendors, candidates), structure the prompt as sequential phases. Each phase narrows the candidate list and goes deeper on the survivors.
- **`for…of`: don't assign to a `const` loop variable**: doing so throws and can cause a crash loop. Use `let`. Also, nulling a loop variable to "help GC" does nothing; modern JS drops the reference when the block exits.
- **Slug guard: return `[]` when the slug comes out empty**: when you turn a string into a URL path segment, guard against an empty result.
- **Set timeouts on every network call in shell scripts**: unattended scripts (cron jobs, PM2 start scripts, metrics pushers) that call `curl`, `ssh`, or any blocking network command (`openssl s_client`, `dig`, `nc`) without a timeout can hang forever when the remote host is slow or down. If the hung script holds a shared lock or flock, every other scheduled run waits behind it for as long as the hang lasts, which can be days.
- **Validate the schema of client-side storage**: validate `localStorage` / `sessionStorage` data against the expected shape when you load it.
- **Validate required fields in user-written config parsers**: when parsing user-written YAML, JSON, or dict-based config, never read required keys by raw indexing (`d["type"]` gives a cryptic `KeyError: 'type'`). Check for them and report a clear error.
- **Autonomous agent repos: gitignore runtime state files**: gitignore every runtime state file the autonomous loop writes.
- **Bare `JSON.parse` inside `.map()` over DB rows can crash**: never call `JSON.parse` directly inside `.map()` over database rows.
- **Guard the output of string normalizers (slugify, sanitize, etc.)**: functions like `slugify()` can return an **empty string or `['']`** for empty or whitespace-only input.
- **Check that a free tier still exists before depending on it**: the Gemini CLI's free individual tier (`GOOGLE_GENAI_USE_GCA=true`) was deprecated in June 2026.
- **Codex CLI gotchas**: keep the CLI updated, because old versions silently break every model. The vision `-i` flag is variadic, so pass the prompt via stdin. When testing, remember that `codex exec` echoes the prompt into its output.
- **WSL overnight scheduling: a wake timer needs sleep, not shutdown**: before an overnight run, put the machine to sleep instead of shutting it down.
- **Edit custom skills in their source repo first**: if your skills live in a repo and are copied or symlinked into a live location, change the repo copy first and then sync. Edits made only to the live copy get lost.
- **Cron PATH trap, part 1: `claude` and `node`**: at the top of any script cron runs, prepend both bin directories to PATH.
- **Isolate per-item failures in batch loops**: when each iteration can throw on bad data, one unguarded throw aborts the **whole** batch, not just that item. Catch and log per item.
- **`pm2 stop` doesn't survive a deploy-path restart**: `pm2 stop <app>` + `pm2 save` does NOT stop an app for good. Any deploy or restart path that starts it again will bring it back. Remove it from the ecosystem config and the deploy path too.
- **Cron failure alerts: an EXIT trap plus a shared email helper**: silent failures in unattended cron scripts are the most common reason expired auth goes unnoticed for days.
- **Suspending an autonomous agent needs a full checklist**: stopping the PM2 process is not enough. Also remove its cron entries, its ecosystem/deploy-path entries, and any other trigger that could restart it.
- **Cron PATH trap, part 2: call `claude` by absolute path**: cron runs with a minimal PATH (`/usr/bin:/bin`) that doesn't include `/usr/local/bin`, where a global `claude` install usually lives.
- **Parallel Bash calls race on the shared shell cwd**: always `cd` to an absolute path explicitly.
- **A follow-mode log command piped into `head` leaks a shell process forever**: when the reader exits early, the streaming command keeps running.
- **A data column used as a state machine hides failures from recovery.**
- **A generator that claims to be the source of truth for a live config is dangerous once it drifts**: the next regeneration silently overwrites live changes.
- **In a git worktree, Next.js standalone nests the server under `.next/standalone/<path-from-repo-root>`**: start scripts that assume `.next/standalone/server.js` won't find it.
- **A collapsed `<details>` still mounts and parses all its children**: lazy-mount heavy content.
- **A module-level `process.env` read locks in the default before `dotenv.config()` runs (ES modules)**: read the env var at **call time** (inside a function), not at import time, or make `import 'dotenv/config'` the very first import in the entrypoint.
- **Node.js `fetch` (undici) cuts off slow non-streaming backends at `headersTimeout`**: the default is about 300 seconds. A backend that only sends headers after computing the whole body gets its socket closed at that limit.
- **`pkill -f` / `pgrep -f` also match the shell whose command line contains the pattern**: you can kill your own shell or get a false "still running" result.
- **"Safe to close, nothing unique lost" is a claim about the WHOLE bundled diff**: before trusting or making that call on a PR, check each distinct change in the diff against main.
- **Parallel background shell jobs (`cmd &` + `wait`) can silently drop output under resource pressure, even when the batch exits 0**: run at most 2-3 heavy build or test jobs at a time, or give each job its own background tool call so the harness notification, not shell `wait`, tells you it finished. Before treating a log's lack of errors as success, check that the log file exists AND isn't empty.
- **An "overdue job" check that takes its grace period from the job's first run row never fires for a job with zero rows**: if a watcher reads "first run on this host" from the job's own history to decide "too new to judge" vs. "overdue", a job that has NEVER run has no row and looks permanently "too new", when it's really the worst case. Store the watcher's own baseline (when IT started watching each job) separately from the job's run history, so a zero-row job leaves its grace period and alerts like any other overdue job. Same family as "indeterminate is not healthy": a missing baseline must never read as a pass.
- **A "mark done" write after a handler call, keyed only on "the call happened", also marks the handler's silent no-ops as done**: when a store-then-process pipeline sets `processed = true` unconditionally after calling a processor, a payload the processor doesn't recognize (no usable ID, no samples, an unmapped type) gets marked complete with nothing written and nothing logged, exactly like a real success. The only fix is to branch on what the processor actually stored (rows written, not just "didn't throw"), and leave a call that wrote nothing pending so a retry or backfill can find it. This happened independently in two separate codebases and lost data more than once. When you fix it, check every sibling handler in the same dispatch table, not just the one that broke.
