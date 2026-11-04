<!-- Load when: spawned processes, temp files, port conflicts -->
# Process Hygiene

Track what you start. Clean up what you leave behind.

## Track What You Start

If you spawn a long-running process (`npm run dev`, a background build, a watch command, a test runner in watch mode), you own it for the rest of your session.

- **Record the PID or process name** when you start something. You'll need it to stop it later.
- **Stop it before the session ends**, or document it in `context.md` so the next session knows it's running.
- **Don't assume your process manager is handling it.** It only manages processes in `ecosystem.config.cjs` (or the equivalent). Anything you start with `node`, `npm run dev`, or `&` is orphaned when your session ends.
- **Work that is long, or must outlive the turn, goes under a supervisor, not a raw background task.** A background child of the session (even `setsid nohup`) usually shares the session's process group or cgroup. It dies with the session, and then nothing reports on it. The supervisor should:
  - run the work outside the session;
  - call it done only when a completion check passes;
  - resume it after a death only if a re-run is safe;
  - report every outcome.
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

When you update `context.md` or `progress.md`, treat the update as its own operation. Don't make it the last step in a chain that might not finish.

- **Update context files early and often**, not just at session end.
- **Commit the context update in the same commit** as the work it describes.
- Before anything risky (a build, a deploy, a large refactor), update `context.md` *first*. If the step crashes, the state is already captured.

## Temp File Cleanup

- Don't leave temp files in `/tmp`, project directories, or anywhere else.
- Delete scratch files you made while debugging (`test.js`, `debug.log`, `temp.json`) before you commit.
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

Don't start a service on a port that's already taken. Either stop the existing process (if it's yours) or use a different port. If the process belongs to another session, coordinate with it; don't kill it.

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
   - Close the DB (and any other resource) inside the `server.close()` callback, not after it. This flushes the SQLite WAL and releases connections before exit, which prevents SQLITE_BUSY or "database is locked" on the next start.
   - The force-exit stops PM2 from hanging on keep-alive connections that never drain.
   - `unhandledRejection` and `uncaughtException` log before exiting. Without them, PM2 sees a silent crash with nothing in the logs.
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

**Diagnosis:** if `pm2 show <process>` shows a fast-rising restart count and the logs contain `EADDRINUSE`, it's this pattern.

**Extra safety: clear the port in start.sh first.** When `kill_timeout` alone isn't enough (for example, a previous process crashed without releasing the socket), add a `kill_port()` function at the top of `start.sh` that frees the port before launch:

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
# Wait up to 50s for the port to be free; escalate to SIGKILL at attempt 5
for i in {1..5}; do
  ss -tulpn 2>/dev/null | grep -q ":${PORT} " || break
  [ $i -eq 5 ] && kill_port 9
  sleep 10
done
```

Start with SIGTERM (graceful) and escalate to SIGKILL only after several retries. Use `fuser` when it's available (util-linux), and fall back to `lsof` (macOS, minimal Linux). This adds to the ecosystem config `kill_timeout`; it doesn't replace it.

**App-level retry loop around `server.listen()`.** Sometimes all of the above is in place and the OS still hasn't released the socket. For that case, wrap `app.listen()` in a retry loop instead of exiting on the first failure:

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
- With a long `kill_timeout`, graceful shutdown, and the proactive port kill all in place, intermittent EADDRINUSE can still happen. This retry loop is what finally ends it.

**Client-side companion: also retry `ECONNREFUSED`.** A worker or client that starts before its server has finished binding gets `ECONNREFUSED`, not `EADDRINUSE`. Add `ECONNREFUSED` to the retryable errors alongside the network errors (`EAI_AGAIN`, `ECONNRESET`, `ETIMEDOUT`). That covers the startup race when the server and client launch together (for example, PM2 starting both back to back).

### PM2 `cron_restart` Does Not Reliably Fire for Batch Jobs

PM2's `cron_restart` with `autorestart: false` does not reliably wake a batch script that exits normally after doing its work. The script exits, PM2 marks it "stopped", and on some deployments the cron never fires again. There's no error and no alert; the job just stops producing output, and this can go unnoticed for weeks.

**Fix:** for any run-once, batch, or cron-style PM2 process (digest posters, scrapers, daily scripts), make the system crontab the main scheduler, calling `pm2 restart <name> --update-env`. Leave `cron_restart` in `ecosystem.config.js` as documentation only, never as the sole trigger.

```cron
0 7 * * * /usr/bin/env pm2 restart my-batch-job --update-env >/dev/null 2>&1
```

## Cleanup Checklist (Before Session End)

1. **Processes:** Stop any dev servers, watch commands, or background tasks you started.
2. **Temp files:** Delete any scratch files you created.
3. **Ports:** Make sure you haven't left a stray server bound to a port.
4. **Git state:** No uncommitted changes related to your task.
5. **Context:** `context.md` says what's running and what's not.

## Rule Digest

One line per lesson. Check the relevant lines when you touch these systems.

- **Docker bind mount refresh**: Use `docker compose down && docker compose up -d`, not `docker compose restart`, whenever the container needs to see updated host files.
- **Docker `exec` always needs `--user`**: If a container runs a non-root application user, pass `--user <username>` on every `docker exec`.
- **PM2 lifecycle traps**: When a PM2 service misbehaves around restarts or monitoring, check restart-vs-config reload, stop durability, crash loops on startup dependencies, batch-job scheduling, and periodic-exit settings (each covered below).
- **Long text transfer**: Never ask the user to copy-paste long commands, URLs, or multi-line text by hand.
- **Stale git lock files**: Any automated script that runs git should check for stale lock files and remove them before it starts.
- **Stale branch dedup lists**: An automated agent that decides what's new from a list built from `git log` or `git branch -r` can block on stale data, or act on it. Refresh the list before using it.
- **Bash `set -u` with optional parameters**: Use `${N:-}` (empty default) or `${N:-default}` for any positional parameter that may not be passed.
- **Bash `${VAR:-default}` vs `${VAR-default}`**: `:-` uses the default when `VAR` is unset OR empty. `-` uses it only when unset. Pick deliberately.
- **Python `smtplib`: validate addresses before sending**: Check each address with a basic sanity test before every send call.
- **`pm2 restart <name>` does NOT pick up ecosystem config changes**: It restarts with the in-memory config. Use `pm2 delete <name> && pm2 start ecosystem.config.js --only <name>` (or `pm2 reload ecosystem.config.js --update-env`) after editing the config.
- **PM2 crash loops from a DB dependency at startup**: A service that connects to Postgres (or any external DB) when the module loads can crash-loop if the DB isn't ready on first boot or after a reboot. Retry the connection with backoff instead of exiting.
- **Bash `date +%H` breaks arithmetic**: It prints zero-padded hours (`08`, `09`), which Bash reads as invalid octal. Use `$((10#$(date +%H)))` or `date +%-H`.
- **Agent web-fetch tools may route through the provider's servers, not your local network**: Use `curl` from the shell for private or local URLs.
- **Generated crontabs**: If your crontab is generated from a registry file, edit the registry and regenerate. Hand edits to the installed crontab get overwritten, and the drift is invisible.
- **Bash `set -e` kills error handlers before they fire**: In any `set -e` or `set -euo pipefail` script, capture exit codes inline with `cmd || VAR=$?`.
- **Guard `git stash pop` in scripts**: Never call it unconditionally. Pop only if the script itself created a stash.
- **PM2 periodic-exit scripts need `autorestart: false` with `cron_restart`**: For any PM2 process that exits when it's done (data pushes, sync jobs, batch processors), always set the two together. Otherwise PM2 relaunches it in a tight loop.
- **Cron wrappers on remote machines self-sync**: Cron scripts on hosts with no deploy pipeline (a second PC, a Raspberry Pi) should `git pull --ff-only` at the start of each run.
- **`claude -p` vs `claude --print` positional trap**: In any script or cron job that pipes stdin to `claude`, use `--print` (not `-p`) when other flags follow it.
- **ID-based cursor iteration for large tables**: Batch through large tables with ID-based cursor pagination (`WHERE id > ? ORDER BY id LIMIT N`), not `LIMIT N OFFSET M`.
- **Resilient DB JSON parsing**: Wrap every `JSON.parse()` of a stored JSON column (metadata, config blobs, event payloads) in `try/catch`.
- **Confirm async follow-through, not just dispatch**: Any runner that creates a PR, ticket, or artifact for later pickup should check its own earlier outputs at the START of its next run, not count on a downstream janitor to notice.
- **Gemini CLI `-p` does not support multimodal input**: Headless `gemini -p` treats `@filepath` references as text only. Use the API for images or video.
- **Chokidar ignore matching**: Chokidar's `ignored` function gets the full file path. Match denylisted path segments, not substrings, or you'll ignore unrelated files.
- **Bash `$HOSTNAME` is always set**: Never use `${HOSTNAME:-default}` as a bind-address guard; the default never applies.
- **SQLite `.iterate()` cleanup and watcher depth**: Always wrap `.iterate()` in `try/finally` so the cursor closes even on error. Set a depth limit on file watchers.
- **Saturation guards for webhook background queues**: When a route handler spawns fire-and-forget background work, count pending tasks and return HTTP 503 once a cap is passed.
- **SQLite `createMany` variable limit**: SQLite caps bind parameters per statement (about 999 on older builds, up to 32766 on newer ones). Chunk bulk inserts. Also validate webhook timestamps before you store them.
- **Express routes: null-check after a DB insert and use try/catch everywhere**: A read right after a write can return null. Every route handler needs a try/catch. For nullable columns, guard with `!== undefined`, not `||`.
- **Claude CLI `--model` takes aliases, not SDK model IDs**: Pass a short alias (for example `opus`, `sonnet`), not a full API model ID.
- **Health endpoints should check data freshness**: `/health` should check that background sync jobs wrote recently, not just that the DB connects.
- **Null out large objects in batch functions**: V8 may not collect a large object while it's still in scope, even if nothing uses it anymore. Set it to null when you're done with it inside long batch functions.
- **File-watcher feedback loop**: A service that watches a directory and also writes into it must exclude its own output files from the watch.
- **`Promise.race` timeouts leave a dangling timer**: Call `clearTimeout` once the main promise settles, or the timer keeps the process alive.
- **Defensive JSON parsing in batch and summarization loops**: If a loop moves a cursor forward only after it finishes, one bare `JSON.parse` on a bad row stalls the pipeline for good. Guard each parse and skip the bad row.
- **SQLite `busy_timeout` alongside WAL**: WAL mode alone doesn't stop `SQLITE_BUSY` under concurrent requests. Also set `PRAGMA busy_timeout`.
- **A JSON-file index updated by read-modify-write needs an in-process lock AND atomic writes**: A plain "read index.json, modify, write back" with no serialization loses writes under concurrency and can corrupt the file. Write to a tmp file and rename it into place. A bare "if missing, write `[]`" init is a third, separate race.
- **Cross-host job handoff: a failed push needs a pending marker**: A primary/fallback job wrapper that pulls shared state, runs, and pushes it back must handle a failed push as its own case. Mark the file pending and re-push it before the next pull. Otherwise the other host's next pull fetches stale remote state and overwrites a run that succeeded locally. Add a real cross-host mutual-exclusion lock (not just a heartbeat check) so a flaky health check can't let both hosts run the same job at once. Acquire multi-file locks in sorted order to avoid deadlocks.
- **PrismaClient with the LibSQL adapter: don't pass `datasourceUrl`**: The adapter already owns the connection.
- **Monitoring scripts: alert once, then suppress**: The marker must record whether an alert was already sent, not just that something failed. If a failure can stay broken forever (no success event to clear the marker), store a hash of the failure content instead of a boolean, so a *different* problem during suppression still alerts.
- **External API 429 handling**: When looping over an external REST API, use both exponential backoff on 429 and a fixed delay between requests.
- **Express `URLSearchParams(req.query)` drops repeated params**: Loop over the values and call `.append()` for each.
- **OAuth bootstrap: a copied token gets revoked when the source rotates it**: If you bootstrap one container's auth by copying a token from another, both share one refresh token. Give each consumer its own credentials.
- **SQLite UPSERT with optional columns**: Branch on whether the optional field was provided and use a separate prepared statement for each case, so a missing value doesn't overwrite stored data with null.
- **Detect and restore SQLite corruption automatically**: Run `PRAGMA quick_check` at startup and restore from backup if it fails. Power loss, OOM kills mid-write, and disk I/O errors all corrupt databases.
- **Multi-pass AI generation: where editor notes go**: A refinement pass will open with meta-commentary unless told not to. Instruct it to put any editor notes at the bottom, after the content.
- **Strip narration at both ends**: When you strip model meta-commentary from generated content, strip the trailing editor-notes block too, but only when that heading is the LAST heading in the document.
- **Webhook processing: use an array-based queue, not promise chains**: For bursty events that must be processed in order with I/O, an explicit array queue with a single worker beats an ever-growing promise chain.
- **Multi-phase AI research pipelines with disqualification gates**: An agent that researches and recommends (vendors, venues, candidates) should run in sequential phases that narrow the candidates and then go deeper, with explicit rules that knock candidates out.
- **Don't reassign a `const` loop variable in `for...of`**: It throws, and in a service it causes a crash loop. Use `let`. Nulling a loop variable to "help GC" does nothing; the reference is released when the block exits.
- **Slug guard**: Code that turns a string into a URL path segment must handle an empty result; return `[]`, not `['']`.
- **Set timeouts on every network call in shell scripts**: In unattended scripts, `curl`, `ssh`, and any other blocking network command (`openssl s_client`, `dig`, `nc`, and so on) need explicit timeouts. Without them, a slow or unreachable host hangs the script forever. If the hang holds a shared lock, it silently blocks every scheduled run behind it, possibly for days.
- **Validate client-side storage on load**: Check the schema of anything read from `localStorage` or `sessionStorage`, and fall back to defaults if it doesn't match.
- **Required-field validation in user-authored config parsers**: Never read required keys from YAML, JSON, or dict config by raw indexing (`d["type"]` gives a cryptic `KeyError: 'type'`). Validate them and raise a clear error.
- **Autonomous agent repos: gitignore runtime state**: Gitignore every file the autonomous loop writes at runtime.
- **A bare `JSON.parse` inside `.map()` over DB rows can crash everything**: One bad row takes down the whole request. Guard each parse.
- **String normalizers can return empty output**: Functions like `slugify()` can return `''` or `['']` for empty or whitespace-only input. Check the output before using it.
- **Verify free tiers before depending on them**: Free CLI or API tiers get deprecated. Confirm the tier still exists before you build a job on it.
- **Codex CLI gotchas**: Keep the CLI up to date, because stale versions silently break every model. The vision `-i` flag is variadic, so pass the prompt on stdin. `codex exec` echoes the prompt in its output, which can make tests pass falsely.
- **WSL overnight scheduling**: A wake timer works from sleep, not from shutdown. Put the machine to sleep before an overnight run.
- **Skill source of truth: edit the repo before the live copy**: If your skills are kept in a repo and installed elsewhere, edit the repo and reinstall. Edits to the live copy get lost.
- **Cron PATH double trap**: Cron's minimal PATH often has neither `claude` nor `node`. Add both bin directories at the top of any script cron runs.
- **Isolate per-item failures in batch loops**: One unguarded throw on bad data aborts the whole batch. Wrap each iteration and log failures individually.
- **`pm2 stop` doesn't survive deploy-path restarts**: `pm2 stop <app>` plus `pm2 save` doesn't stop an app for good if a deploy script restarts everything. Remove it from the ecosystem file or `pm2 delete` it.
- **Cron failure alerting**: Use an EXIT trap plus a shared notification helper in every unattended cron script. Silent failures are the main reason an expired auth token goes unnoticed for days.
- **Suspending an autonomous agent: full checklist**: Stopping it in the process manager isn't enough. Also remove its cron entries, deploy-script references, and any watchdog that would restart it.
- **Cron jobs that call `claude` need an absolute binary path**: Cron's PATH (`/usr/bin:/bin`) doesn't include `/usr/local/bin`.
- **Parallel shell calls race on a shared cwd**: When tool calls run in parallel, always `cd` to an absolute path inside each command.
- **Follow-mode log commands piped into `head` leak a process forever**: `tail -f ... | head` (or `pm2 logs | head`) leaves the follower running after `head` exits. Use a non-follow form such as `--lines N --nostream`, or `tail -n`.
- **A data column used as a state machine hides failures from recovery**: If a status column can land in a state that no recovery path ever queries, failed items vanish. Every terminal or failed state needs an owner.
- **A generator that claims to be the source of truth for a live config is dangerous once they drift**: Before regenerating, diff the generator's output against the live config, or you'll silently wipe out live-only changes.
- **A Next.js standalone build in a git worktree nests the server under `.next/standalone/<path-from-repo-root>`**: Find `server.js` instead of hardcoding its path.
- **A collapsed `<details>` still mounts and parses all its children**: Mount heavy content only when the element opens.
- **Module-level `process.env` reads lock in the default before `dotenv.config()` runs (ES modules)**: Read env vars at call time inside a function, or make `import 'dotenv/config'` the very first import in the entrypoint.
- **Node `fetch` (undici) cuts slow non-streaming backends at about 300s**: The default `headersTimeout` drops the socket when a peer sends headers only after it has computed the whole body. Raise the timeout with a custom dispatcher, or stream.
- **`pkill -f` / `pgrep -f` also match the shell whose own command line contains the pattern**: Use a bracket trick (`pgrep -f '[m]y-process'`) or match on the PID file instead.
- **A PR closed as "nothing unique lost" is a claim about the WHOLE diff**: Check each distinct change against main on its own before trusting that kind of closure, or making one.
- **Parallel backgrounded shell jobs (`cmd &` plus `wait`) silently drop output under load, even when the batch exits 0**: Run at most 2 or 3 heavy build or test jobs at once, or give each job its own tracked background task. Before you trust a log's lack of errors, confirm the log file exists and is non-empty.
- **An "overdue job" check that gets its grace period from the job's own history never fires for a job with zero runs**: A job that has never run has no first-run row, so it's treated as "too new to judge" forever, when "never ran at all" is the worst case. Store the watcher's own baseline (when it started watching each job) separately from the job's history, so a job with no runs ages out of its grace period and alerts. Same family as "indeterminate is not healthy": an empty result must not count as a pass.
- **A "mark done" write that only checks whether the handler was called also marks the handler's silent no-ops as done**: If a store-then-process pipeline sets `processed = true` right after calling the processor, then payloads the processor doesn't recognize (no usable id, no samples, an unmapped type) get marked complete with nothing written and no log line. They look exactly like real successes. Have the processor return the number of rows it actually wrote, branch on that, and leave zero-effect calls pending so a retry or backfill can find them. This bug tends to recur, so check every sibling handler in the same dispatch table, not just the one that broke.
