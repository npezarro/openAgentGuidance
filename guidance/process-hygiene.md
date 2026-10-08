<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

If you start a long-running process (`npm run dev`, a background build, a watch command, a test runner in watch mode), you own it for the rest of your session.

- **Record the PID or process name** when you start it. You will need it to stop the process later.
- **Stop it before the session ends**, or record it in `context.md` so the next session knows it is running.
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

When you update `context.md` or `progress.md`, treat the update as its own step. Don't leave it as the last step in a chain that might not finish.

- **Update context files early and often**, not only at session end.
- **Commit the context update in the same commit as the work it describes.**
- Before a risky step (a build, a deploy, a large refactor), update `context.md` first. If the step crashes, the state is already saved.

## Temp File Cleanup

- Don't leave temp files in `/tmp`, in project directories, or anywhere else.
- Delete scratch files you created while debugging (`test.js`, `debug.log`, `temp.json`) before committing.
- If a process creates temp files (detached job output, build artifacts), clean them up or record where they are.

## Port and Process Conflicts

Before starting any server or service:

```bash
# Is the port already in use?
ss -tlnp | grep <port>

# Is a previous instance still running?
ps aux | grep <process-name>
pm2 list
```

Don't start a service on a port that is already in use. If the existing process is yours, stop it; otherwise use a different port. If the process belongs to another session, coordinate with it. Don't kill it.

### PM2 Restart EADDRINUSE Crash Loop

When PM2 restarts a process, the old Node instance may not release its port before the new one starts. The result is a loop: `EADDRINUSE`, crash, PM2 restart, repeat.

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
   - SIGINT covers Ctrl-C in dev; SIGTERM covers a PM2 restart. You need both.
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. This flushes the SQLite WAL and releases connections before the process exits, so the next PM2 start doesn't hit SQLITE_BUSY or "database is locked".
   - The force-exit stops PM2 from hanging on keep-alive connections that never drain.
   - The `unhandledRejection`/`uncaughtException` handlers log before exiting. Without them, PM2 sees a crash with no diagnostic output.
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
   - The build script must run `mkdir -p .next/standalone/.next` before `rm -rf .next/standalone/.next/static`. On a fresh clone that directory doesn't exist, and `cp` fails silently. Correct form: `next build && mkdir -p .next/standalone/.next && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static`

**Diagnosis:** a fast-rising restart count in `pm2 show <process>` plus `EADDRINUSE` in the logs means you have this problem.

**Extra safety: clear the port in start.sh.** If `kill_timeout` alone isn't enough (for example, a previous process crashed without releasing the socket), add a `kill_port()` function at the top of `start.sh` that frees the port before launch:

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

Start with SIGTERM, and escalate to SIGKILL only after several retries. Use `fuser` when it is available (util-linux) and fall back to `lsof` (macOS and minimal Linux). This works alongside `kill_timeout` in the ecosystem config; it doesn't replace it.

**Retry loop around `server.listen()`.** Even with all of the above, the OS sometimes still hasn't released the socket. Wrap `app.listen()` in a retry loop instead of exiting on the first failure:

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

- Retry only on `EADDRINUSE`; exit on every other error.
- The 2s delay gives the OS time to release the port between attempts.
- In practice, this retry loop ended intermittent crash loops that still happened with `kill_timeout: 10000`, graceful shutdown, and the start.sh port cleanup all in place.

**Client side: also retry `ECONNREFUSED`.** A worker or client that starts before its server is listening gets `ECONNREFUSED`, not `EADDRINUSE`. Add `ECONNREFUSED` to the retryable errors, next to network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). This handles the race when the server and client start at nearly the same time (for example, PM2 starting both back to back).

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

`cron_restart` with `autorestart: false` only restarts a process that PM2 still tracks as "stopped". On some deployments it doesn't reliably restart a batch script that exits normally after finishing its work. The script exits, PM2 marks it "stopped", and the cron never fires again. Nothing errors or alerts; the job just stops running, and this has gone unnoticed for more than a week.

**Fix:** for any run-once, batch, or cron-style PM2 process (digest posters, scrapers, daily scripts), make the system crontab the main scheduler and have it call `pm2 restart <name> --update-env`. You can keep `cron_restart` in `ecosystem.config.js` to document the schedule, but don't rely on it as the only trigger.

```cron
0 7 * * * /usr/bin/env pm2 restart my-batch-job --update-env >> "$HOME/logs/my-batch-job.cron.log" 2>&1
```

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop any dev servers, watch commands, or background tasks you started.
2. **Temp files:** Delete any scratch files you created.
3. **Ports:** Check that you haven't left a server bound to a port.
4. **Git state:** No uncommitted changes related to your task.
5. **Context:** `context.md` records what is still running and what isn't.

## Rule Digest

One line per lesson.

- **Refreshing Docker bind mounts**: When a container needs to see updated host files, run `docker compose down && docker compose up -d`, not `docker compose restart`.
- **Docker `exec` always needs `--user`**: If a container has a non-root application user, pass `--user <username>` on every `docker exec`.
- **Long text transfer**: Never give the user long commands, URLs, or multi-line text to copy and paste by hand.
- **Stale git lock files**: Any automated script that runs git should check for stale lock files and remove them before it starts.
- **Stale branch dedup lists**: An agent that decides what to work on from a dedup list built from `git log` or `git branch -r` can block on, or act on, stale data. Refresh the list before relying on it.
- **Bash `set -u` with optional parameters**: Write `${N:-}` (empty default) or `${N:-default}` for any positional parameter that might not be passed.
- **Bash `${VAR:-default}` vs `${VAR-default}`**: `${VAR:-default}` uses the default when `VAR` is unset OR empty; `${VAR-default}` uses it only when `VAR` is unset.
- **Python `smtplib`: validate addresses before sending**: Check that the address looks valid before every `smtplib` send call.
- **`pm2 restart <name>` ignores ecosystem config changes**: It restarts the process with the config PM2 already has in memory. To apply edits, run `pm2 delete <name>` and then `pm2 start ecosystem.config.js`, or use `pm2 reload ecosystem.config.js`.
- **PM2 crash loops from DB dependency on startup**: A service that connects to Postgres (or any external DB) when its module loads can crash-loop if the DB isn't ready at first boot or after a reboot. Connect with retry and backoff.
- **Bash `date +%H` breaks arithmetic**: It returns zero-padded hours (`08`, `09`), which bash arithmetic reads as invalid octal. Use `date +%-H` or `$((10#$h))`.
- **`WebFetch` runs through Anthropic's edge, not your local network**: Use `Bash: curl ...` for private or local URLs.
- **Generated crontabs**: If your crontab is generated from a registry file, edit the registry and regenerate. Never hand-edit the installed crontab; the next generation will overwrite it.
- **Bash `set -e` exits before error handlers run**: In any `set -e` or `set -euo pipefail` script, capture exit codes inline with `cmd || VAR=$?`.
- **Guard `git stash pop` in scripts**: Never call `git stash pop` unconditionally. Pop only if a stash was actually created.
- **PM2 jobs that exit when done need `autorestart: false` with `cron_restart`**: For any PM2 process that exits on completion (data pushes, sync jobs, batch processors), always set `autorestart: false` alongside `cron_restart`.
- **Cron wrappers on remote machines should sync themselves**: Cron scripts on hosts with no deploy pipeline should run `git pull --ff-only` at the start of each run.
- **`claude -p` vs `claude --print`**: In scripts that pipe stdin to `claude`, use `--print` (not `-p`) whenever other flags come after it.
- **Use ID-based cursors for large tables**: When processing a large DB table in batches, page with `WHERE id > ?` instead of `LIMIT N OFFSET M`.
- **Wrap every `JSON.parse()` of DB data in try/catch**: Serialized JSON columns (metadata, config blobs, event payloads) can contain bad data.
- **Check that async work actually finished, not only that it was dispatched**: A runner that creates a PR, ticket, or artifact for later pickup should check its own earlier outputs at the START of its next run, instead of waiting for a downstream janitor to notice.
- **Gemini CLI `-p` doesn't accept images or video**: In headless mode, `@filepath` references are read as text only.
- **Chokidar ignore rules: match path segments, not substrings**: Chokidar's `ignored` function receives the full file path, so a substring check can exclude files you meant to keep.
- **Bash `$HOSTNAME` is always set**: Never use `${HOSTNAME:-default}` to decide which address to bind; the default never applies.
- **SQLite `.iterate()` cleanup and watcher depth**: Always wrap `.iterate()` in try/finally so the cursor closes on error, and set a depth limit on file watchers.
- **Cap background queues in webhook handlers**: When a route handler starts fire-and-forget background work, track how many tasks are pending and return HTTP 503 once the count passes a cap.
- **SQLite bind-parameter limit and webhook timestamps**: SQLite limits bind parameters per statement (about 999 in older builds, up to 32766 in newer ones), so split large `createMany` calls into chunks. Also validate webhook timestamps.
- **Express API routes: null checks and try-catch**: A read right after a DB insert can still return null. Every route handler needs a try-catch. For nullable columns, check `!== undefined` instead of using `||`.
- **Claude CLI `--model` takes aliases, not API model IDs**: The `--model` flag expects short aliases.
- **Health endpoints should check data freshness**: A `/health` endpoint should check that background sync jobs wrote recently, not only that the DB is reachable.
- **Release large objects in batch functions**: V8 may keep large objects in memory until the function returns, even after you stop using them. Set them to null once you're done.
- **Watchers must ignore the service's own output**: A service that watches a directory and also writes inside it must exclude its own output files from the watcher, or it triggers itself in a loop.
- **`Promise.race` timeouts leave a timer running**: Clear the `setTimeout` once the main promise settles.
- **Defensive JSON parsing in batch loops**: If a loop moves a cursor or timestamp forward only after it finishes, one bad row with a bare `JSON.parse` stops the pipeline permanently.
- **SQLite needs `busy_timeout` alongside WAL**: WAL mode reduces write contention but doesn't prevent `SQLITE_BUSY` errors under concurrent requests. Set `busy_timeout` too.
- **JSON-file index updated by read-modify-write**: You need an in-process lock and atomic writes (write a tmp file, then rename). Without the lock, concurrent updates lose writes or corrupt the file. A bare "if missing, write `[]`" initializer is a separate race.
- **PrismaClient with the LibSQL adapter**: Don't pass `datasourceUrl` to the constructor. The adapter already owns the connection.
- **Monitoring scripts: alert once, then stay quiet**: The marker file must record whether an alert was already sent, not just that a failure happened.
- **External API 429s: exponential backoff plus throttling**: In a sequential loop of API calls, back off exponentially on 429 and wait a fixed interval between requests.
- **Express: `URLSearchParams(req.query)` drops repeated query params**: Loop over the values and call `.append()` for each one.
- **Copied OAuth tokens get revoked when the source rotates**: If you set up a container's auth by copying another container's token, the two share one refresh token. When either one refreshes, the other's token is revoked.
- **SQLite upserts with optional columns**: Branch on whether the optional field was provided and use a separate prepared statement for each case, so a missing value doesn't overwrite existing data with null.
- **Detect and restore SQLite corruption automatically**: Run `PRAGMA quick_check` at startup and restore from backup if it fails. Power loss, OOM kills mid-write, and disk I/O errors can all corrupt SQLite.
- **Multi-pass AI generation: where editor notes go**: Unless told otherwise, a refinement pass starts its output with meta-commentary. Tell it explicitly to put editor notes at the bottom, after the content.
- **Strip narration from both ends**: When you remove model narration from generated content, check the end of the output as well as the start. Remove a trailing editor-notes section only when it is the last heading in the document.
- **Webhook queues: use an array, not a promise chain**: For bursts of events that must be handled one at a time with I/O, use an array-based queue instead of an ever-growing promise chain.
- **AI research pipelines: phases with disqualification gates**: Structure research-and-recommend agents as sequential phases. Each phase drops disqualified candidates and researches the survivors in more depth.
- **`for…of` loops: don't assign to a `const` loop variable**: Use `let`. Setting a loop variable to null "to help GC" does nothing; the reference is released when the block exits.
- **Guard against empty slugs**: When a string becomes a slug for a URL path segment, return `[]` if the slug comes out empty.
- **Set timeouts on every network call in shell scripts**: In unattended scripts, `curl`, `ssh`, `openssl s_client`, `dig`, `nc` and similar commands hang forever without a timeout if the remote host is slow or unreachable. If the hang holds a shared lock or flock, every later scheduled run waits behind it, for days if nobody notices.
- **Validate client-side storage on load**: Check the schema of anything read from `localStorage` or `sessionStorage` before using it.
- **Required fields in user-written config**: When parsing user-written YAML, JSON, or dict configs, don't read required keys with raw indexing (`d["type"]` gives a cryptic `KeyError: 'type'`). Check for them and raise a clear error.
- **Autonomous agent repos: gitignore runtime state**: Gitignore every state file the autonomous loop writes at runtime.
- **Bare `JSON.parse` inside `.map()` over DB rows can crash the request**: Parse each row safely.
- **String normalizer output**: Functions like `slugify()` can return an empty string, or `['']`, for empty or whitespace-only input. Check the output.
- **Check that a free tier still exists before relying on it**: The free individual tier of the Gemini CLI (`GOOGLE_GENAI_USE_GCA=true`) has been deprecated.
- **Codex CLI gotchas**: Keep the CLI up to date, because stale versions break every model without saying why. The vision `-i` flag is variadic, so pass the prompt via stdin. In tests, note that `codex exec` echoes the prompt in its output.
- **WSL overnight scheduling**: Wake timers only work from sleep. Put the machine to sleep before an overnight run; don't shut it down.
- **Custom skills: edit the repo, not the live copy**: Keep custom skills in a repo as the source of truth. Edit there, then sync to the live install.
- **Cron PATH missing both claude and node**: At the top of any cron-invoked script, add both binary directories to PATH.
- **Isolate failures per item in batch loops**: One unguarded throw on bad data aborts the whole batch, not just that item.
- **`pm2 stop` doesn't stay stopped**: `pm2 stop <app>` plus `pm2 save` can be undone when a deploy restarts everything. Use `pm2 delete` and remove the app from the ecosystem file.
- **Alert on cron script failures**: Add an EXIT trap that calls a shared email or notification helper. Silent cron failures are the most common reason expired auth goes unnoticed for days.
- **Shutting down an autonomous agent for good**: Stopping it in PM2 isn't enough. Also remove its crontab entries, ecosystem entry, and any scheduled triggers.
- **Cron jobs that call `claude` need an absolute path**: Cron's minimal PATH (`/usr/bin:/bin`) doesn't include `/usr/local/bin`, where a global `claude` install usually lives.
- **Parallel Bash calls share the working directory**: Always `cd` to an absolute path explicitly, because another call may have changed it.
- **Follow-mode log commands piped into `head` leak a process**: If a streaming log command is piped into something that exits early, the shell process never exits.
- **Don't use a data column as a state machine**: When a data column doubles as state, failures are invisible to recovery logic.
- **A generator that claims to own a live config is dangerous once it drifts**: Check that the generated output matches what is live before you regenerate.
- **Next.js standalone builds in a git worktree**: The server ends up nested under `.next/standalone/<path-from-repo-root>`, not directly under `.next/standalone/`.
- **A collapsed `<details>` still renders its children**: Mount heavy content only when the element is opened.
- **Reading `process.env` at module level bakes in the default (ES modules)**: Imports run before `dotenv.config()`. Read the variable inside a function at call time, or make `import 'dotenv/config'` the very first import in the entrypoint.
- **Node.js `fetch` (undici) cuts off slow backends**: The default `headersTimeout` of about 300 seconds drops the connection when a backend sends headers only after building the whole body. Raise it for slow endpoints that don't stream.
- **`pkill -f`/`pgrep -f` can match the calling shell**: The pattern also matches the shell whose own command line contains it.
- **A PR closed as "nothing unique lost" makes a claim about its whole diff**: Before you trust or make that closure, check each separate change in the diff against main on its own.
- **Parallel background jobs (`cmd &` + `wait`) can drop output under load and still exit 0**: Run at most 2 or 3 heavy build or test jobs at once, or give each job its own background tool call so the harness notification, not shell `wait`, tells you it finished. Before treating a log's lack of errors as success, check that the log exists and isn't empty.
