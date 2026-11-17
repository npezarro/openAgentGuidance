<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

If you start a long-running process during your session, you own it until the session ends. That includes `npm run dev`, a background build, a watch command, or a test runner in watch mode.

- **Record the PID or process name** when you start something. You will need it to stop it later.
- **Stop it before the session ends**, or record it in `context.md` so the next session knows it is running.
- **Don't assume your process manager will manage it.** A process manager (PM2 or similar) only manages processes listed in its config (`ecosystem.config.cjs` or equivalent). Anything you start with `node`, `npm run dev`, or `&` is orphaned when your session ends.
- **Run long jobs, or jobs that must outlive the turn, under a supervisor, not as a raw background task.** A background child of the session (even `setsid nohup`) usually shares the session's process group or cgroup, so it dies with the session and nothing reports on it. The supervisor should:
  - run the job outside the session
  - mark it done only when a completion check passes
  - resume it after a death only if a re-run is safe
  - report every outcome
- **Never wait on work with a `pgrep -f` loop.** The pattern matches the waiter's own command line, so the loop never ends.

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

- **Update context files early and often**, not just at session end.
- **Commit the context update with the work it describes**, in the same commit.
- **Update `context.md` before a risky step** (a build, a deploy, a large refactor), so the state is saved if that step crashes.

## Temp File Cleanup

- Don't leave temp files in `/tmp`, in project directories, or anywhere else.
- Delete scratch files you created while debugging (`test.js`, `debug.log`, `temp.json`) before committing.
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

Don't start a service on a port that is already taken. Either stop the existing process (if it is yours) or use a different port. If the process belongs to another session, coordinate with it; don't kill it.

### PM2 Restart EADDRINUSE Crash Loop

When PM2 restarts a process, the old Node instance may still hold its port when the new one starts. The new one fails with `EADDRINUSE` and crashes, PM2 restarts it, and the cycle repeats.

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
   - SIGINT handles Ctrl-C in dev and SIGTERM handles a PM2 restart. You need both.
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. That flushes the SQLite WAL and releases connections before the process exits, which prevents `SQLITE_BUSY` or "database is locked" errors on the next start.
   - The force exit stops PM2 from hanging on keep-alive connections that never drain.
   - The `unhandledRejection` and `uncaughtException` handlers log before exiting. Without them, PM2 sees a silent crash with no diagnostic output.
3. **Use a `start.sh` wrapper for Next.js standalone.** If `next start` is the PM2 script, PM2 loses track of the real process. A wrapper that `exec`s node lets PM2 signal the actual node process:
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
   - The build script must run `mkdir -p .next/standalone/.next` before `rm -rf .next/standalone/.next/static`. On a fresh clone the directory doesn't exist and `cp` fails silently. Correct form: `next build && mkdir -p .next/standalone/.next && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static`

**Diagnosis:** if `pm2 show <process>` shows a restart count that keeps climbing and the logs show `EADDRINUSE`, this is the pattern.

**Extra safeguard: clear the port in `start.sh`.** `kill_timeout` alone may not be enough, for example when a previous process crashed without releasing the socket. In that case, add a `kill_port()` function at the top of `start.sh` that frees the port before launching:

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

Start with SIGTERM (graceful) and escalate to SIGKILL only after several retries. Use `fuser` when it is available (util-linux) and fall back to `lsof` (macOS, minimal Linux). This adds to `kill_timeout` in the ecosystem config; it doesn't replace it.

**Retry `server.listen()` in the app.** Sometimes `EADDRINUSE` still happens now and then even with a long `kill_timeout`, graceful shutdown, and the port cleanup above. In that case, wrap `app.listen()` in a retry loop instead of exiting right away:

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

**On the client side, also retry `ECONNREFUSED`.** A worker or client that starts before its server has bound the port gets `ECONNREFUSED`, not `EADDRINUSE`. Treat `ECONNREFUSED` as retryable along with the usual network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). This covers the startup race where the server and client launch together (for example, PM2 starting both one right after the other).

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

`cron_restart` with `autorestart: false` does not reliably wake up a batch script that exits normally after doing its work. The script exits, PM2 marks it stopped, and on some deployments the cron never fires again. Nothing errors and nothing alerts; the job just stops running, and that can go unnoticed for weeks.

**Fix:** for any run-once, batch, or cron-style PM2 process (digest posters, scrapers, daily scripts), make the system crontab the main scheduler and have it call `pm2 restart <name> --update-env`. Keep `cron_restart` in `ecosystem.config.js` only as documentation, never as the only trigger.

```cron
0 7 * * * /usr/bin/env PATH=/usr/local/bin:/usr/bin:/bin pm2 restart my-batch-job --update-env >> $HOME/logs/my-batch-job.cron.log 2>&1
```

## Cleanup Checklist (Before Session End)

1. **Processes:** stop any dev servers, watch commands, or background tasks you started.
2. **Temp files:** delete any scratch files you created.
3. **Ports:** check that you haven't left a server bound to a port.
4. **Git state:** no uncommitted changes related to your task.
5. **Context:** `context.md` says what is running and what isn't.

## Rule Digest

One line per lesson.

### Containers and process managers

- **Docker bind mount refresh:** to make a container pick up changed host files, run `docker compose down && docker compose up -d`. `docker compose restart` is not enough.
- **Docker `exec` needs `--user`:** if a container has a non-root application user, pass `--user <username>` on every `docker exec`. Otherwise files get created as root and the app can't write to them later.
- **`pm2 restart <name>` ignores ecosystem config changes:** it reuses the config held in memory. To apply edits, run `pm2 delete <name> && pm2 start ecosystem.config.js --only <name>` (or `pm2 startOrReload ecosystem.config.js`), then `pm2 save`.
- **`pm2 stop` does not survive deploys:** a deploy script that runs `pm2 restart` or `startOrReload` brings the app back. To retire an app for good, remove it from the ecosystem config and the deploy path, run `pm2 delete` and then `pm2 save`.
- **PM2 crash loops from a DB that isn't ready at startup:** a service that connects to Postgres (or any external DB) when its module loads can restart in a tight loop after a reboot. Connect lazily, retry with backoff, and set `restart_delay` / `exp_backoff_restart_delay`.
- **Periodic-exit PM2 scripts need `autorestart: false`:** any process that exits when finished (sync jobs, data pushes) must pair `cron_restart` with `autorestart: false`. Without it, PM2 reruns the job over and over. Schedule it with crontab as described above.
- **Retiring an autonomous agent:** stopping the process is not enough. Also remove its cron entries, any deploy-path restart, scheduled triggers, and webhooks, then run `pm2 save` and check that nothing brings it back.

### Shell scripting

- **Stale git lock files:** automated scripts that run git should check for a stale `.git/index.lock` (no git process running) and remove it before running.
- **Stale branch dedup lists:** an agent that decides what new work to start from a list built with `git log` or `git branch -r` must fetch and prune first, or it skips or redoes work based on stale data.
- **Bash `set -u` with optional parameters:** use `${N:-}` or `${N:-default}` for any positional parameter that may not be passed.
- **`${VAR:-default}` vs `${VAR-default}`:** `:-` uses the default when `VAR` is unset *or empty*, while `-` uses it only when `VAR` is unset. Pick the one you mean.
- **`date +%H` in arithmetic:** zero-padded `08` and `09` are invalid octal. Use `$((10#$(date +%H)))` or `date +%-H`.
- **`set -e` kills error handlers before they run:** capture exit codes inline with `cmd || rc=$?`.
- **Guard `git stash pop`:** never call it unconditionally in a script. Pop only if the stash step actually created a stash.
- **Cron wrappers on remote machines update themselves:** scripts on hosts with no deploy pipeline should run `git pull --ff-only` at the start of each run.
- **Cron PATH covers neither `claude` nor `node`:** cron's PATH is minimal (`/usr/bin:/bin`). Prepend both bin directories at the top of any cron-invoked script, or call the binaries by absolute path.
- **`claude -p` positional trap:** in scripts that pipe stdin to `claude`, use `--print` instead of `-p` when other flags follow, so the next argument isn't read as the prompt.
- **Claude CLI `--model` takes short aliases:** pass aliases (`opus`, `sonnet`, `haiku`) to the CLI, not SDK model IDs.
- **`$HOSTNAME` is always set in bash:** never use `${HOSTNAME:-default}` as a guard on a bind address. Use a dedicated variable.
- **Network calls in unattended scripts need timeouts:** set timeouts on `curl` (`--connect-timeout`, `--max-time`), `ssh` (`-o ConnectTimeout`, `ServerAliveInterval`), and any other blocking network command (`openssl s_client`, `dig`, `nc`). Wrap them in `timeout` if needed. A hang while holding a shared lock blocks every scheduled run queued behind it.
- **Cron failure alerting:** add an EXIT trap that sends an alert on a non-zero exit through a shared helper. Silent cron failures are the main reason expired credentials go unnoticed for days.
- **Alert once, then suppress:** a monitoring marker must record *whether an alert was already sent*. For a condition that never recovers cleanly, store a hash of the failure's content, so a *different* problem appearing during suppression still sends an alert.
- **Parallel Bash calls share the shell's working directory:** always `cd` with an absolute path inside each call.
- **Follow-mode logs piped into `head` leak a process:** `tail -f` or `pm2 logs` piped into something that exits early leaves the streamer running forever. Use non-follow flags (`--nostream`, `--lines N`) or `timeout`.
- **`pkill -f` / `pgrep -f` match their own invoking shell:** the pattern also matches the shell whose command line contains it. Use a bracket trick (`[m]yproc`), match exact names, or exclude `$$`.
- **Backgrounded parallel jobs (`cmd &` plus `wait`) can drop output under load and still exit 0:** run at most 2 or 3 heavy jobs at once, or give each its own tool call. Check that each log file exists and is non-empty before reading "no errors" from it.
- **Don't hand the user long commands to copy and paste:** deliver long commands, URLs, or multi-line text as a file or hosted snippet they can fetch with one short command.
- **WSL overnight scheduling:** wake timers fire only from sleep, not from shutdown. Put the machine to sleep before an overnight run.

### Data handling and databases

- **ID cursor pagination for large tables:** process big tables with `WHERE id > ? ORDER BY id LIMIT N`, not `LIMIT N OFFSET M`.
- **Wrap every `JSON.parse()` of stored data in try/catch:** this matters most inside `.map()` over DB rows and in batch loops that move a cursor forward after the loop. One bad row must not crash the request or stall the pipeline forever.
- **Isolate failures per item in batch loops:** wrap each iteration so one bad record is logged and skipped instead of aborting the whole batch.
- **SQLite `.iterate()` cleanup:** wrap it in try/finally so the cursor always closes.
- **SQLite `busy_timeout` with WAL:** WAL alone doesn't prevent `SQLITE_BUSY`. Also set `PRAGMA busy_timeout`.
- **SQLite bind-variable limit:** split `createMany` and bulk inserts into chunks below the per-statement parameter limit (999 on older builds).
- **SQLite UPSERT with optional columns:** branch on whether the optional field was provided and use a separate statement for each case, so a missing value doesn't overwrite stored data with NULL.
- **SQLite corruption:** run `PRAGMA quick_check` at startup and restore from backup automatically if it fails.
- **JSON-file index updated by read-modify-write:** it needs an in-process lock *and* atomic tmp-file-plus-rename writes. Without both, concurrent writes get lost and the file can be corrupted. A bare "if missing, write `[]`" init is a separate race.
- **A data column used as a state machine:** if a failure leaves a row in an intermediate state that recovery code never queries, the failure is invisible. Make failed and stuck states explicit and have recovery look for them.
- **"Mark done" must depend on what was stored, not on whether the call happened:** setting `processed = true` unconditionally after a handler also marks the handler's silent no-ops (unrecognized payload, no usable ID) as done. Return the rows actually written, branch on that, and leave zero-effect calls pending for a retry. Check every sibling handler in the same dispatch table.
- **PrismaClient with the LibSQL adapter:** don't pass `datasourceUrl` to the constructor. The adapter owns the connection.
- **Clean up V8 references in batch functions:** large objects that stay in scope until the function returns may not be garbage-collected. Split the work into smaller functions so they go out of scope sooner.

### Servers, APIs, and clients

- **Check for null after a DB insert:** a write followed by a read can return null. Put try/catch in every route handler, and use `!== undefined` rather than `||` for nullable columns.
- **Health endpoints should check data freshness:** besides DB connectivity, report unhealthy when background sync jobs haven't written recently.
- **Guard webhook handlers against queue saturation:** track how many background tasks are pending and return HTTP 503 above a cap. Validate webhook timestamps.
- **Use an array-based webhook queue, not promise chains:** for bursty events processed one after another, a growing promise chain leaks memory and hides errors. Use an explicit array queue and a worker loop.
- **Handle external API 429s with exponential backoff plus a delay between requests:** you need both in sequential paginated loops.
- **`URLSearchParams(req.query)` drops repeated params:** loop over the values and call `.append()` for each one.
- **A `Promise.race` timeout leaves a dangling timer:** `clearTimeout` in a `finally` block.
- **Node `fetch` (undici) has a default `headersTimeout` of about 300s:** it cuts off slow backends that send headers only after building the whole body. Set a custom dispatcher with longer timeouts, or stream.
- **Module-level `process.env` reads in ES modules run before `dotenv.config()`:** read env vars when they are used, or make `import 'dotenv/config'` the first import.
- **`for...of` loop variables are `const`:** assigning to one throws at runtime and can cause a crash loop. Use `let`. Setting loop variables to null to "help GC" does nothing.
- **Validate string normalization output:** `slugify()` and similar functions can return `''` or `['']`. If the derived slug is empty, return `[]` and never build a path from it.
- **Validate client-side storage on load:** check the schema of `localStorage` and `sessionStorage` data before using it, and fall back to defaults if it doesn't match.
- **Validate required fields in user-written config:** never read required keys by raw indexing (`d["type"]` gives a cryptic `KeyError`). Check them and report a clear error.
- **Validate email addresses before sending with `smtplib`:** check the address is sane before every send.
- **File watchers: exclude files the service itself writes:** otherwise it triggers itself in a loop. In chokidar's `ignored` function, match whole path segments, not substrings, and limit the watch depth.
- **`WebFetch`-style tools run outside your local network:** use `curl` from Bash for private or local URLs.
- **A copied OAuth token gets revoked when the source rotates it:** don't bootstrap one consumer by copying another's refresh token. Give each consumer its own auth.

### Agents and automation

- **Confirm async follow-through, not just dispatch:** a runner that creates a PR, ticket, or artifact for someone to pick up later should check its own earlier outputs at the start of its next run.
- **Cross-host job handoff:** treat a failed push of shared state as its own case. Mark the state pending and push it again before the next pull, or the other host overwrites the result with stale data. Use a real cross-host lock, not a heartbeat guess, and acquire multiple locks in sorted order.
- **An "overdue job" check must keep its own baseline:** if the grace period comes from the job's first run row, a job that never ran has no row and is treated as "too new" forever. Record when the watcher started watching each job.
- **Gitignore runtime state in autonomous agent repos:** never commit files the agent's own loop writes.
- **A generator that claims to own a live config is dangerous once they drift:** before regenerating, diff its output against the live config and reconcile.
- **A script that replaces a manual procedure inherits the original bugs:** diff the script against the procedure's latest fixes. Verify syncs with content diffs (`rsync -ain`), not counts.
- **"Safe to close, nothing unique lost" is a claim about the whole diff:** before closing a bundled PR on that basis, check each separate change against main.
- **Multi-pass AI content generation:** tell refinement passes to put any editor notes at the end. Strip narration from both the start and the end of the output.
- **Multi-phase AI research pipelines:** split the prompt into sequential phases with disqualification gates that narrow the candidates before the deep research.
- **Keep the Codex CLI up to date:** stale versions break all models silently. Its `-i` image flag is variadic, so pass the prompt via stdin. `codex exec` echoes the prompt, which can confuse tests that check its output.
- **Gemini CLI `-p` treats `@filepath` as text only:** it doesn't accept multimodal input in headless mode.

### Builds and front end

- **A Next.js standalone build in a git worktree** nests the server under `.next/standalone/<path-from-repo-root>`. Find `server.js` instead of hardcoding its path.
- **A collapsed `<details>` still mounts and parses all its children:** mount heavy content only when it is opened.

### Always-loaded files

- **Check format overhead first:** for any file injected every session (an index, a manifest, hook output), measure how much is signal and how much is syntax before cutting content. Normalizing the format often saves more than deleting entries.
