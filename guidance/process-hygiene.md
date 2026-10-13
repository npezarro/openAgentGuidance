<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

If you start a long-running process (`npm run dev`, a background build, a watch command, a test runner in watch mode), you own it for the rest of your session.

- **Record the PID or process name** when you start it. You will need it to stop it later.
- **Stop it before the session ends**, or write it down in `context.md` so the next session knows it is running.
- **Don't assume your process manager will look after it.** Only processes declared in its config (for example PM2's `ecosystem.config.cjs`) are managed. Anything you start with `node`, `npm run dev`, or `&` is orphaned when your session ends.

```bash
# Start a dev server and note the PID
npm run dev &
DEV_PID=$!
echo "Dev server running on PID $DEV_PID"

# Later, clean up
kill $DEV_PID
```

## Atomic State Writes

When you update `context.md` or `progress.md`, do it as a separate step. Don't leave it as the last step in a chain that might not finish.

- **Update context files early and often**, not only at session end.
- **Commit the context update in the same commit as the work it describes.**
- Before anything risky (a build, a deploy, a large refactor), update `context.md` first. If the risky step crashes, the state is already recorded.

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

Never start a service on a port that is already taken. Stop the existing process if it is yours, or use a different port. If the process belongs to another session, coordinate with that session and don't kill it.

### PM2 Restart EADDRINUSE Crash Loop

When PM2 restarts a process, the old Node instance may still hold its port when the new one starts. The result is a loop: `EADDRINUSE`, crash, PM2 restart, repeat.

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
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. That way the SQLite WAL is flushed and connections are released before exit, which prevents `SQLITE_BUSY` or "database is locked" on the next start.
   - The force-exit keeps PM2 from hanging on keep-alive connections that never drain.
   - The `unhandledRejection` and `uncaughtException` handlers log before exit. Without them, PM2 sees a crash with no diagnostic output.
3. **Run Next.js standalone through a `start.sh` wrapper.** With `next start` as the PM2 script, PM2 loses track of the real process. A wrapper lets PM2 signal the actual node process:
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
   - The build script must run `mkdir -p .next/standalone/.next` before `rm -rf .next/standalone/.next/static`. On a fresh clone that directory does not exist, and `cp` fails silently. Correct form: `next build && mkdir -p .next/standalone/.next && rm -rf .next/standalone/.next/static && cp -r .next/static .next/standalone/.next/static`

**Diagnosis:** `pm2 show <process>` shows a restart count that keeps climbing, and the logs contain `EADDRINUSE`.

**Extra safety: clear the port in start.sh.** Sometimes `kill_timeout` is not enough, for example when a previous process crashed without releasing the socket. Add a `kill_port()` function at the top of `start.sh` that frees the port before launch:

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

Send SIGTERM first (graceful) and escalate to SIGKILL only after several retries. Use `fuser` if it is installed (util-linux), otherwise fall back to `lsof` (macOS or minimal Linux). This works alongside `kill_timeout` in the ecosystem config. It does not replace it.

**Retry loop in `server.listen()`.** If the OS still hasn't released the socket after all of the above, retry `app.listen()` instead of exiting at once:

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
- This retry loop has stopped intermittent crash loops even with a long `kill_timeout`, graceful shutdown, and the start.sh port kill already in place.

**Client side: also retry `ECONNREFUSED`.** A worker or client that starts before its server has bound the port gets `ECONNREFUSED`, not `EADDRINUSE`. Add `ECONNREFUSED` to the retryable errors, next to the network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). This covers the race where the process manager starts server and client within moments of each other.

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

`cron_restart` with `autorestart: false` does not reliably wake a batch script that exits normally after its work. The script exits, PM2 marks it "stopped", and on some deployments the cron never fires again. There is no error and no alert: the job just stops running, and this can go unnoticed for weeks.

**Fix:** For any run-once, batch, or cron-style PM2 process (digest posters, scrapers, daily scripts), make the system crontab the main scheduler and have it call `pm2 restart <name> --update-env`. Keep `cron_restart` in `ecosystem.config.js` only as documentation of the intended schedule, never as the only trigger.

```bash
# crontab -e
0 7 * * * pm2 restart <name> --update-env >/dev/null 2>&1
```

Under cron, use the absolute path to `pm2` (or set PATH at the top of the crontab), because cron's PATH is minimal.

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop any dev servers, watch commands, or background tasks you started.
2. **Temp files:** Delete any scratch files you created.
3. **Ports:** Confirm you haven't left a server bound to a port.
4. **Git state:** No uncommitted changes related to your task.
5. **Context:** `context.md` says what is running and what is not.

## Rule Digest

One line per lesson.

- **Docker bind mount refresh**: When a container must pick up updated host files, run `docker compose down && docker compose up -d`. `docker compose restart` is not enough.
- **Docker `exec` always needs `--user`**: If a container has a non-root app user (for example `node`), pass `--user <username>` on every `docker exec`.
- **Long text transfer**: Never ask the user to copy-paste long commands, URLs, or multi-line text by hand.
- **Stale git lock files**: Any automated script that runs git should check for stale lock files and remove them before it starts.
- **Stale branch dedup lists**: An automated agent that checks for duplicate work against a list built from `git log` or `git branch -r` can block or act on stale data. Refresh the list before each run.
- **Bash `set -u` with optional parameters**: Write `${N:-}` (empty default) or `${N:-default}` for any positional parameter that might not be passed.
- **Bash `${VAR:-default}` vs `${VAR-default}`**: `${VAR:-default}` uses the default when `VAR` is **unset or empty**. `${VAR-default}` uses it only when `VAR` is unset.
- **Python `smtplib`: validate addresses before sending**: Run a basic address sanity check before every `smtplib` send.
- **`pm2 restart <name>` does NOT pick up ecosystem config changes**: It reuses the in-memory config. Use `pm2 delete <name> && pm2 start ecosystem.config.js --only <name>` (or `pm2 reload ecosystem.config.js`) to apply config edits.
- **PM2 crash loops from a DB dependency at startup**: A service that connects to Postgres (or any external DB) when its module loads can crash-loop if the DB isn't ready at first boot or after a reboot. Retry the connection with backoff instead of exiting.
- **Bash `date +%H` breaks arithmetic**: It outputs zero-padded hours (`08`, `09`), which bash reads as invalid octal. Use `$((10#$(date +%H)))` or `date +%-H`.
- **`WebFetch` routes through Anthropic's servers, not your local network**: For private or local URLs, use `Bash: curl ...` instead.
- **Generated crontabs**: If your crontab is generated from a registry file, edit the registry and regenerate. Never hand-edit the installed crontab, or the next generation silently undoes your change.
- **Bash `set -e` kills error handlers before they run**: In any `set -e` or `set -euo pipefail` script, capture exit codes inline with `cmd || VAR=$?`.
- **Guard `git stash pop` in scripts**: Never call `git stash pop` unconditionally. Pop only if the earlier stash actually created an entry.
- **PM2 periodic-exit scripts**: Any PM2 process that exits when done (data push scripts, sync jobs, batch processors) needs `autorestart: false`, and should be triggered by system crontab as described above.
- **Cron wrappers on remote machines should self-sync**: A cron script on a host with no deploy pipeline (a second PC, a Raspberry Pi) should run `git pull --ff-only` at the start of each run.
- **`claude -p` positional argument trap**: In any script or cron job that pipes stdin to `claude`, use `--print` instead of `-p` when other flags follow.
- **ID-based cursor iteration for large datasets**: To batch through a large DB table, paginate on ID (`WHERE id > ? ORDER BY id LIMIT N`), not `LIMIT N OFFSET M`.
- **Resilient DB JSON parsing**: Wrap every `JSON.parse()` of a stored JSON column (metadata, config blobs, event payloads) in `try/catch`.
- **Confirm async follow-through, not just dispatch**: If a runner creates a PR, ticket, or artifact for later pickup, it should check its own earlier outputs at the START of its next run. Don't count on a downstream janitor to notice.
- **Gemini CLI `-p` does NOT accept multimodal input**: In headless mode, `@filepath` references are treated as text only, so video and images are ignored.
- **Chokidar denylist: match path segments, not substrings**: The `ignored` function gets the full file path, so a substring match can exclude files you didn't mean to exclude.
- **Bash `$HOSTNAME` is always set**: Never use `${HOSTNAME:-default}` as a bind-address guard, because the default never applies.
- **SQLite `.iterate()` cleanup and watcher depth limits**: Wrap `.iterate()` in try/finally so the cursor closes even on error. Set a depth limit on file watchers.
- **Queue saturation guards for webhook handlers**: If a route handler starts fire-and-forget background work, count the pending tasks and return HTTP 503 once a cap is exceeded.
- **SQLite `createMany` variable limit and webhook timestamp validation**: SQLite caps bind parameters per statement (about 999 on older builds, up to 32766 on recent ones), so split bulk inserts into chunks. Validate webhook timestamps before you trust them.
- **Express routes: null-check after a DB insert, and try/catch everywhere**: A read right after a write can return null. Every route handler needs try/catch. For nullable columns, guard with `!== undefined` rather than `||`.
- **Claude CLI `--model` takes aliases, not SDK model IDs**: Pass short aliases (for example `sonnet`, `opus`) to the CLI.
- **Health endpoint freshness gate**: A `/health` endpoint should check that background sync jobs wrote recently, not only that the DB is reachable.
- **V8 object nullification in batch functions**: V8 may keep large objects in memory until the function returns, even after they stop being used. In long batch functions, release large intermediates explicitly or split the work into smaller functions.
- **File-watcher feedback loop**: A service that watches a directory and also writes into it must exclude its own output files from the watcher.
- **`Promise.race` timeout leaves a dangling timer**: Clear the `setTimeout` once the main promise settles.
- **Defensive JSON parsing in batch loops**: If a loop moves a cursor or timestamp forward after it finishes, one bare `JSON.parse` failure stalls the pipeline for good. Guard each parse.
- **SQLite `busy_timeout` alongside WAL mode**: WAL alone does not prevent `SQLITE_BUSY` under concurrent requests. Set `busy_timeout` too.
- **A JSON-file index updated by read-modify-write needs an in-process lock AND atomic tmp+rename writes**: Without serialization, concurrent "read, modify, write back" loses writes and can corrupt the file. A bare "if missing, write `[]`" init is a third, separate race.
- **Cross-host job handoff: a failed push needs a pending marker**: A primary/fallback wrapper that pulls shared state, runs, and pushes back must handle a failed push explicitly. Mark the file pending and re-push it before the next pull. Otherwise the other host's next pull overwrites a successful run with stale remote state. Pair this with a real cross-host mutual-exclusion lock, not a heartbeat heuristic, and acquire multi-file locks in sorted order to avoid deadlock.
- **PrismaClient + LibSQL adapter: don't pass `datasourceUrl`**: The adapter already owns the connection.
- **Monitoring scripts: alert once, then suppress via a marker**: The marker must record whether an alert was already sent. If a condition stays broken and never sends a clean recovery event, store a hash of the failure content instead of a boolean, so a *different* problem during suppression still alerts.
- **External API 429s: exponential backoff plus a throttle between requests**: Sequential API loops need both.
- **Express: `URLSearchParams(req.query)` drops repeated params**: Iterate over the values and call `.append()` for each one.
- **OAuth bootstrap: a copied token is revoked when the source rotates**: If you copy a token from one container or host to another, both now share the same refresh token, and rotation on either side breaks the other. Give each consumer its own login.
- **SQLite UPSERT with optional columns**: Branch on whether the optional field was provided, and use a separate prepared statement for each case, so an omitted field never overwrites stored data with null.
- **SQLite corruption: auto-detect and restore**: Run `PRAGMA quick_check` at startup and restore from backup automatically if it finds corruption (from power loss, an OOM kill mid-write, or disk I/O errors).
- **Multi-pass AI generation: editor commentary placement**: A refinement pass tends to open with meta-commentary. Tell it explicitly to put editor notes at the bottom. Strip narration from both ends of the output, leading and trailing, and remove a trailing notes section only when its heading is the last heading in the document.
- **Webhook queue: use an array-based queue, not promise chains**: For bursty events that must be processed in order with I/O, a growing promise chain leaks memory and hides errors.
- **Multi-phase AI research pipeline with disqualification gates**: For an agent that researches and recommends (restaurants, vendors, candidates), write the prompt as ordered phases that narrow the candidate list and then deepen research on what remains.
- **`for…of` loop: don't assign to a `const` loop variable**: That throws and can cause a crash loop, so use `let` if you must reassign. Setting a loop variable to null "to help GC" does nothing.
- **Slug guard: return `[]` for an empty derived slug**: Never let an empty string become a URL path segment.
- **Network calls in shell scripts need timeouts**: Unattended scripts that call `curl`, `ssh`, `openssl s_client`, `dig`, `nc`, or any other blocking network command must set timeouts. A hang that holds a shared lock or flock blocks every scheduled run behind it, for days if nobody notices.
- **Client-side storage: validate the schema on load**: Treat `localStorage` and `sessionStorage` contents as untrusted, and fall back to defaults on a mismatch.
- **Required fields in user-authored config parsers**: Never read required keys with raw indexing (`d["type"]` gives a cryptic `KeyError`). Validate them and raise a clear error.
- **Autonomous agent repos: gitignore runtime state**: Gitignore every state file the autonomous loop writes.
- **Bare `JSON.parse` inside `.map()` over DB rows will crash**: Parse each row inside a guard.
- **String normalization output guard**: `slugify()` and similar functions can return `''` or `['']` for empty or whitespace-only input. Check the output.
- **Free-tier CLIs can be deprecated**: Before you depend on a free tier (for example the Gemini CLI's individual Code Assist tier), confirm it still exists.
- **Codex CLI gotchas**: Keep the CLI updated, because old versions silently break all models. The vision `-i` flag is variadic, so pass the prompt via stdin. `codex exec` echoes the prompt in its output, so tests must not match on prompt text.
- **WSL overnight scheduling**: A wake timer needs the machine asleep, not shut down.
- **Custom skills: the repo is the source of truth**: Edit skills in their source repo and sync them to the live copy, never the other way around.
- **Cron PATH double trap: `claude` and `node`**: Add both bin directories to PATH at the top of any script cron runs.
- **Per-item failure isolation in batch loops**: Wrap each iteration so one bad record fails that item only, not the whole batch.
- **PM2 stop does not survive deploy-path restarts**: `pm2 stop <app>` plus `pm2 save` is not permanent. A deploy script can start the app again. Remove the app from the ecosystem config or the deploy path.
- **Cron script failure alerting: EXIT trap plus a shared alert helper**: Silent failures in unattended cron scripts are the main reason expired auth goes unnoticed for days.
- **Suspending an autonomous agent needs a full checklist**: Stopping the process alone is not enough. Also disable its schedulers, deploy-path restarts, and any watchdogs that would bring it back.
- **Cron jobs that call `claude` need an absolute binary path**: Cron's minimal PATH (`/usr/bin:/bin`) doesn't include `/usr/local/bin`.
- **Parallel Bash calls race on the shared shell cwd**: Always `cd` to an absolute path explicitly.
- **Follow-mode log commands piped into `head` leak a shell process forever**: A streaming log command whose reader exits early never terminates. Use a non-follow form (`--lines N --nostream`, `tail -n N`) when you only need a snapshot.
- **A data column used as a state machine hides failures from recovery**: A row stuck in an intermediate state never gets retried. Track status explicitly so recovery can find failed items.
- **A generator that claims to be the source of truth for a live config becomes dangerous once they drift**: Reconcile the two before you regenerate, or the next run silently deletes live entries.
- **A Next.js standalone build in a git worktree nests the server under `.next/standalone/<path-from-repo-root>`**: Start scripts that assume `.next/standalone/server.js` break there.
- **A collapsed `<details>` still mounts and parses all of its children**: Mount heavy content lazily, when the element is opened.
- **A module-level `process.env` read happens before `dotenv.config()` runs (ES modules)**: Read env vars at call time, inside a function, or make `import 'dotenv/config'` the very first import in the entrypoint.
- **Node.js `fetch` (undici) cuts off slow non-streaming backends at `headersTimeout`**: The default is about 300s. A backend that sends headers only after computing the whole body gets cut off, so raise the timeout with a custom dispatcher or stream the response.
- **`pkill -f` and `pgrep -f` also match the shell whose command line contains the pattern**: Make the pattern specific, or exclude your own PID.
- **"Safe to close, nothing unique lost" is a claim about the WHOLE bundled diff**: Before you trust or make that kind of closure, check each distinct change in the diff against main on its own.
- **Parallel backgrounded shell jobs (`cmd &` + `wait`) can silently lose output under resource pressure, even when the batch exits 0**: Limit heavy build and test fan-out to 2-3 concurrent jobs, or give each job its own backgrounded tool call. Always confirm a log file exists AND is non-empty before treating a lack of errors in it as success.
