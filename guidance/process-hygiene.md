<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Keep track of every process you start, and clean up whatever you leave behind.

## Track What You Start

If you spawn a long-running process, you own it for the whole session. That includes `npm run dev`, a background build, a watch command and a test runner in watch mode.

- **Record the PID or process name** when you start it. You will need it to stop the process later.
- **Stop it before the session ends**, or record it in `context.md` so the next session knows it is running.
- **Don't assume your process manager will look after it.** PM2 (or an equivalent) only manages processes listed in `ecosystem.config.cjs` or its equivalent. Anything you start with `node`, `npm run dev` or `&` becomes an orphan when your session ends.

```bash
# Start a dev server: note the PID
npm run dev &
DEV_PID=$!
echo "Dev server running on PID $DEV_PID"

# Later, clean up
kill $DEV_PID
```

## Atomic State Writes

Treat an update to `context.md` or `progress.md` as a separate operation. Don't make it the last step of a chain that might not finish.

- **Update context files early and often**, not only at the end of the session.
- **Commit the context update in the same commit** as the work it describes.
- Before a risky step (a build, a deploy, a large refactor), **update `context.md` first**. If the step crashes, the state is already recorded.

## Temp File Cleanup

- Don't leave temp files in `/tmp`, in project directories, or anywhere else.
- If you create scratch files while debugging (`test.js`, `debug.log`, `temp.json`), delete them before you commit.
- If a process creates temp files (output from a detached job, build artifacts), clean them up or write down where they are.

## Port and Process Conflicts

Before you start any server or service:

```bash
# Is the port already in use?
ss -tlnp | grep <port>

# Is a previous instance still running?
ps aux | grep <process-name>
pm2 list
```

Never start a service on a port that is already taken. Either stop the existing process (if you started it) or pick another port. If the process belongs to another session, coordinate with it; don't kill it.

### PM2 Restart EADDRINUSE Crash Loop

When PM2 restarts a process, the old Node instance may still hold the port when the new one starts. The result is a loop: `EADDRINUSE`, crash, PM2 restart, repeat.

**Diagnosis:** `pm2 show <process>` shows the restart count climbing fast, and the logs contain `EADDRINUSE`.

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
   - You need both signals: SIGINT covers Ctrl-C in development, and SIGTERM covers a PM2 restart.
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. That way the SQLite WAL is flushed and connections are released before the process exits, which prevents `SQLITE_BUSY` or "database is locked" on the next start.
   - The force-exit stops PM2 from hanging on keep-alive connections that never drain.
   - The `unhandledRejection` and `uncaughtException` handlers log before the process exits. Without them, PM2 sees a silent crash with no diagnostic output.
3. **Use a `start.sh` wrapper for Next.js standalone.** If `next start` is the PM2 script, PM2 loses track of the real process. A wrapper lets PM2 signal the actual node process:
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
   - The build script must run `mkdir -p .next/standalone/.next` before `rm -rf .next/standalone/.next/static`. On a fresh clone that directory doesn't exist, and `cp` fails silently. The correct form: `next build && mkdir -p .next/standalone/.next && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static`

**Belt-and-suspenders: clear the port in start.sh first.** `kill_timeout` alone may not be enough, for example when a previous process crashed without releasing the socket. In that case, add a `kill_port()` function at the top of `start.sh` that frees the port before launch:

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

Send SIGTERM first so the process can shut down cleanly, and escalate to SIGKILL only after several retries. Use `fuser` when it's available (util-linux) and fall back to `lsof` (macOS or minimal Linux). This works alongside `kill_timeout` in the ecosystem config; it doesn't replace it.

**App-level retry loop in `server.listen()`.** Sometimes all of the layers above are in place and `EADDRINUSE` still shows up now and then, because the OS hasn't released the socket yet. In that case, wrap `app.listen()` in a retry loop instead of exiting on the first failure:

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

**Client side: also retry `ECONNREFUSED`.** A worker or client that starts before its server has bound the port gets `ECONNREFUSED`, not `EADDRINUSE`. Add `ECONNREFUSED` to the retryable errors next to the network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). This covers the startup race when the server and client launch together, for example when PM2 starts both in quick succession.

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

Combining `cron_restart` with `autorestart: false` is supposed to re-run a batch script on a schedule. On some deployments it does not. The script finishes normally, PM2 marks it "stopped", and the cron never fires again. There is no error and no alert, so a scheduled job can stay silently dead for days.

**Fix:** For any run-once, batch or cron-style PM2 process (digest posters, scrapers, daily scripts), make the system crontab the primary scheduler and have it call `pm2 restart <name> --update-env`. Keep `cron_restart` in `ecosystem.config.js` only as documentation, never as the only trigger.

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop any dev servers, watch commands or background tasks you started.
2. **Temp files:** Delete any scratch files you created.
3. **Ports:** Confirm you haven't left a server bound to a port.
4. **Git state:** Leave no uncommitted changes related to your task.
5. **Context:** Make sure `context.md` says what is running and what isn't.

## Rule Digest

One line per lesson. When a line applies to what you are doing, follow it.

### Containers and process managers

- **Docker bind mount refresh:** If a container needs to pick up updated host files, use `docker compose down && docker compose up -d`, not `docker compose restart`.
- **`docker exec` always needs `--user`:** If a container runs as a non-root application user, pass `--user <username>` on every `docker exec` call. Otherwise, files it creates end up owned by root.
- **`pm2 restart <name>` ignores ecosystem config changes:** It restarts with the config held in memory. After editing `ecosystem.config.js`, run `pm2 delete <name> && pm2 start ecosystem.config.js --only <name>` (or `pm2 startOrReload`), then `pm2 save`.
- **PM2 crash loops from a DB dependency at startup:** A service that connects to Postgres (or any external DB) when its module loads can crash-loop if the DB isn't ready on first boot or after a reboot. Retry the connection with backoff instead of exiting.
- **PM2 periodic-exit scripts:** Any PM2 process that exits when it finishes (sync jobs, data pushes, batch processors) must pair `cron_restart` with `autorestart: false`, or PM2 re-runs it in a tight loop. For reliable scheduling, see the crontab rule above.
- **`pm2 stop` does not last through deploys:** `pm2 stop <app>` plus `pm2 save` doesn't keep an app stopped. A later deploy or `pm2 start ecosystem.config.js` brings it back. To disable an app, remove it from the ecosystem file (or `pm2 delete` it) and check every deploy path.
- **Suspending an autonomous agent takes more than stopping it:** Also remove it from the ecosystem file, delete its crontab entries, run `pm2 save`, and make sure no deploy script or watchdog restarts it.

### Shell scripting

- **Long text transfer:** Never give the user long commands, URLs or multi-line text to copy and paste by hand. Write it to a file or put it somewhere they can fetch it.
- **Stale git lock files:** Any automated script that runs git should check for stale `.git/*.lock` files and remove them before it starts. Remove a lock only after confirming that no git process owns it.
- **Stale branch dedup lists:** An agent that decides whether to start new work using a dedup list built from `git log` or `git branch -r` may be reading stale data. Run `git fetch --prune` first.
- **`set -u` with optional parameters:** Write `${N:-}` or `${N:-default}` for any positional parameter that may not be passed.
- **`${VAR:-default}` vs `${VAR-default}`:** `:-` substitutes the default when `VAR` is unset **or empty**. `-` substitutes it only when `VAR` is unset. Pick the one you mean.
- **`date +%H` in arithmetic:** The output is zero-padded (`08`, `09`), and bash reads a leading zero as octal. Force base 10 with `$((10#$(date +%H)))`.
- **`set -e` kills error handlers before they run:** In a `set -e` or `set -euo pipefail` script, capture exit codes inline with `cmd || VAR=$?`.
- **Guard `git stash pop`:** Never call it unconditionally in a script. Pop only if a stash was actually created, which you can tell by comparing `git stash list` before and after.
- **Scripts need timeouts on `curl` and `ssh`:** Without them, an unattended script hangs forever when the remote host is slow or unreachable. Use `curl --max-time` and `ssh -o ConnectTimeout=`.
- **`$HOSTNAME` is always set in bash:** `${HOSTNAME:-default}` never falls back. Don't use it as a bind-address guard; use a dedicated variable.
- **Parallel Bash calls race on the persisted cwd:** When tool calls run in parallel, always `cd` to an absolute path explicitly in each call.
- **Follow-mode logs piped into `head` leak a process:** `tail -f ... | head` or `pm2 logs ... | head` leaves a shell running forever. Use a non-following form, such as `--nostream` or `--lines N` without follow.
- **`pkill -f` / `pgrep -f` match their own shell:** A pattern can also match the shell whose command line contains that pattern, so the script kills itself. Anchor the pattern, or filter out your own PID.

### Cron and scheduling

- **Cron PATH trap:** Cron runs with a minimal PATH (`/usr/bin:/bin`). At the top of any script cron calls, prepend the bin directories for every tool it needs (for example `claude` and `node`).
- **Use an absolute binary path for `claude` in cron:** The global install is often in `/usr/local/bin` or a user bin directory, and cron's PATH includes neither.
- **Cron wrappers on remote machines self-sync:** A cron script on a host with no automatic deploy pipeline should run `git pull --ff-only` at the start of each run.
- **Generated crontabs:** If your crontab is generated from a registry file, edit the registry and regenerate. Before regenerating, check that the live crontab has no hand edits, or regenerating will silently drop them.
- **Alert on cron failures:** Silent failures in unattended scripts are how expired auth goes unnoticed for days. Add an `EXIT` trap that sends an alert through a shared notification helper whenever the exit status is non-zero.
- **Alert once, then suppress:** A monitoring script's marker file must record *whether an alert was already sent*, not only that a failure happened. Clear the marker on recovery.
- **Overnight runs on WSL:** A wake timer can wake a sleeping machine but not one that is shut down. Before a scheduled overnight run, sleep the machine; don't shut it down.

### CLI tools and agents

- **`claude -p` vs `--print`:** In scripts that pipe stdin to `claude`, use `--print` whenever other flags follow. `-p` can consume the next argument as its prompt.
- **`claude --model` takes aliases:** The CLI accepts short aliases, not API model IDs. Check which model actually served the request.
- **`WebFetch` runs outside your network:** The request comes from the tool provider's edge, not your machine. For private or local URLs, use `curl` through Bash.
- **Gemini CLI `-p` is text-only:** In headless mode, `@filepath` references are read as text, so video and image input don't work.
- **Check free tiers before depending on them:** Free CLI tiers (for example the Gemini CLI's individual free tier) get deprecated. Before building an unattended job on one, confirm it still exists.
- **Codex CLI:** Keep it up to date, because stale versions silently break every model. The vision `-i` flag is variadic, so pass the prompt through stdin. `codex exec` echoes the prompt in its output, so don't assert on the raw output.
- **Custom skills have one source of truth:** Edit the skill in its repo, then deploy the live copy. Never edit only the installed copy.
- **Copied OAuth tokens get revoked:** If you bootstrap a container's auth by copying a token from another container, both share one refresh token. When either side rotates it, the other is logged out. Give each consumer its own login.
- **Make sure async work actually finishes:** Any runner that creates a PR, ticket or artifact for later pickup should check its own earlier outputs at the start of its next run. Don't count on a downstream janitor to notice.
- **Verify a "safe to close" PR one change at a time:** Before closing a bundled PR as having nothing unique, check each distinct change in its diff against main separately.
- **Gitignore runtime state in autonomous agent repos:** Everything the loop itself writes (state files, caches, logs) belongs in `.gitignore`.

### Node and server code

- **Env vars read at module level bake in the default (ESM):** A module can read `process.env` before `dotenv.config()` runs. Read env vars at call time, or make `import 'dotenv/config'` the first import in the entrypoint.
- **undici `fetch` has a ~300s `headersTimeout`:** A backend that sends headers only after computing the whole body gets cut off. Raise the timeout with a custom dispatcher, or stream the response.
- **`Promise.race` timeouts leave a timer running:** Clear the `setTimeout` in a `finally` once the main promise settles.
- **Don't assign to a `const` loop variable in `for…of`:** It throws and can start a crash loop. Nulling a loop variable to "help GC" does nothing anyway.
- **Release large objects in batch functions:** V8 may keep a large object alive until the function returns, even after it's no longer used. Set it to `null` explicitly once you're done with it inside long-running batch functions.
- **Protect webhook handlers from queue saturation:** When a handler fires off background work, count the pending tasks and return HTTP 503 once a cap is reached.
- **Use an array-based queue for bursty events:** To process events one at a time, use an array queue with one worker loop. Don't use an ever-growing promise chain.
- **Express `URLSearchParams(req.query)` drops repeated params:** Iterate over the values and call `.append()` for each one.
- **Express routes:** Null-check after a DB insert followed by a read. Wrap every route handler in try/catch. Guard nullable columns with `!== undefined`, not `||`.
- **Handle 429s from external APIs:** In sequential API loops, use exponential backoff and also throttle between requests.
- **Health endpoints should check data freshness:** Beyond DB connectivity, check that background sync jobs have written recently.
- **Validate client-side storage schema:** Validate `localStorage` and `sessionStorage` data against the expected schema when you load it. Discard anything that doesn't match.
- **Validate required fields in config parsers:** Never read required keys from user-written YAML, JSON or dicts by raw indexing. Check for them and raise a clear error.
- **Validate email addresses before `smtplib` sends:** Run a basic sanity check on the address first.
- **Guard string normalization output:** `slugify()` and similar functions can return `''` or `['']`. When the derived slug is empty, return `[]` or reject the input.

### Data and batch processing

- **Use ID-based cursor pagination:** For large tables, use `WHERE id > ? ORDER BY id LIMIT N`, not `LIMIT N OFFSET M`.
- **Wrap every `JSON.parse` on DB rows in try/catch:** This matters most inside `.map()` and in loops that advance a cursor afterwards. One bad row must not crash the request or stall the pipeline forever.
- **Isolate failures per item in batch loops:** One bad record should be logged and skipped, not abort the whole batch.
- **Don't use a data column as a state machine:** If you record a failure by overwriting a status column, recovery queries can no longer find the item. Record failures explicitly.
- **Check generators against live config:** A generator that claims to be the source of truth is dangerous once the live config has drifted. Diff the live config before you regenerate.
- **SQLite `.iterate()`:** Always wrap it in try/finally so the cursor closes on error.
- **SQLite `busy_timeout` alongside WAL:** WAL mode alone doesn't prevent `SQLITE_BUSY`. Also set `busy_timeout`.
- **SQLite bind-parameter limit:** `createMany` and bulk inserts can exceed the per-statement limit (about 999 on older builds). Chunk the inserts. Also validate webhook timestamps before you store them.
- **SQLite upsert with optional columns:** Branch on whether the optional field was provided, and use a separate prepared statement for each case, so an absent field doesn't overwrite a stored value with null.
- **Detect SQLite corruption at startup:** Run `PRAGMA quick_check` at startup. If it reports corruption, restore automatically from the latest backup.
- **Prisma + LibSQL adapter:** Don't pass `datasourceUrl` to the constructor, because the adapter already owns the connection.
- **File watchers: exclude your own output:** A service that watches a directory and also writes into it must exclude its own output files, or it will trigger on itself forever.
- **Chokidar `ignored`:** The function receives the full path. Match path segments, not substrings, and limit the watch depth.

### AI content pipelines

- **Where editor commentary goes:** A refinement pass tends to open with meta-commentary. Tell it explicitly to put any editor notes at the bottom, after the content.
- **Strip narration at both ends:** When removing model meta-commentary, strip trailing notes as well as leading ones. Strip the trailing notes only when their heading is the last heading in the document.
- **Multi-phase research pipelines:** Split research-and-recommend prompts into sequential phases, with disqualification gates that narrow the candidates before the deeper research.

### Frontend and build

- **Next.js standalone in a git worktree:** The server is nested under `.next/standalone/<path-from-repo-root>`, not directly under `.next/standalone/`. Adjust start scripts to match.
- **A collapsed `<details>` still mounts its children:** Lazy-mount heavy content so it renders only when the element is opened.
