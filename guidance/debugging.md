<!-- Load when: diagnosing issues, log analysis -->
# Debugging Guidance

A systematic approach to diagnosing and fixing issues.

## The Debugging Workflow

```
0. Gather Context -> 1. Reproduce -> 2. Read the Error -> 3. Isolate -> 4. Hypothesize -> 5. Verify -> 6. Fix -> 7. Confirm
```

### 0. Gather Existing Knowledge First

Before touching code or forming hypotheses, check whether this problem (or a closely related one) has been solved before:

- **Memory**: Read relevant feedback/project memory files. Corrections from past sessions are your highest-signal source.
- **CLAUDE.md**: The repo's CLAUDE.md documents architecture decisions and known gotchas.
- **Guidance**: Check the domain-specific guidance files in this repo (auth, deployment, etc.).
- **Knowledge base**: Scan your knowledge base index for cross-repo patterns.
- **Private context repo**: Check your private context repo for credentials, registered URIs, or infrastructure details that constrain the solution.
- **Git history**: `git log --oneline --grep="<keyword>"` to find prior fixes.

This is not optional background reading; it is the most efficient debugging step. **The previous session's fix is often already documented in memory.** Skipping this to "save time" causes multi-hour debugging loops.

### Approach Switching (15-minute rule)

If you've been trying variations of the same approach for 15+ minutes without progress:
1. Stop iterating on the current approach.
2. Re-read memory/guidance for the domain (Step 0 again).
3. Spawn a debugger agent for a fresh perspective.
4. Try a **fundamentally different** approach.

Repeating the same category of fix with different values is not debugging; it's brute force.

### 1. Reproduce the Issue

Before touching code, confirm you can trigger the problem:
- Run the exact command or action that causes the error.
- Note the exact error message, stack trace, and context.
- If you can't reproduce it, you can't confidently fix it.

### 2. Read the Error Fully

- Read the **entire** stack trace, not just the first line.
- Look for the **first** error in a chain; cascading failures often hide the root cause.
- Check if the error message directly tells you what's wrong (it often does).

### 3. Isolate the Problem

- **Binary search:** Comment out half the suspect code. Does the error persist?
- **Minimal reproduction:** Can you trigger it with a 5-line script?
- **Check boundaries:** Is the issue in your code, a dependency, or the environment?

### 4. Check the Obvious First

Before diving deep, rule out:

```bash
# Am I on the right branch?
git branch --show-current

# Is the latest code deployed/running?
git log --oneline -3

# Are env vars loaded?
echo $NODE_ENV
cat .env | head -5  # (don't log secrets)

# Are deps up to date?
npm ls <suspect-package>
npm install

# Is the right version running?
node -v
npm -v

# Any port conflicts?
ss -tlnp | grep <port>

# Disk space?
df -h

# Permissions?
ls -la <file>
```

### 5. Targeted Debugging

Add **focused** logging, not scattered `console.log("here")`:

```javascript
// Bad
console.log("here");
console.log("here2");

// Good
console.log('[DEBUG] processOrder input:', { orderId, items: items.length });
console.log('[DEBUG] processOrder result:', { status, total });
```

### 6. Use Git to Find What Changed

```bash
# What changed recently?
git log --oneline -20

# What's different from the working version?
git diff HEAD~3

# Find the exact commit that broke it
git bisect start
git bisect bad          # current commit is broken
git bisect good <hash>  # this commit was working
# Git will binary-search through commits
```

### 7. Common Patterns

| Symptom | Likely Cause |
|---------|-------------|
| `MODULE_NOT_FOUND` | Missing dependency, wrong path, missing build step |
| `EACCES` / permission denied | File ownership issue (`sudo chown`) |
| `EADDRINUSE` | Port already in use; kill the other process or use a different port |
| `TypeError: x is not a function` | Wrong import, wrong version, or `x` is undefined |
| `undefined` where you expect data | Async issue, wrong property name, missing await |
| Works locally, fails in CI | Different Node version, missing env vars, different OS |
| Works on first load, breaks on refresh | Client-side state not synced with server, stale cache |
| Script silently produces empty results | Path from JSON/jq contains `~`, which the shell does not expand. Use `${VAR/#\~/$HOME}` |
| Error log line ends in a bare colon | Logger dropped the arguments (see pino section below) |
| `"X failed: x failed"` style message | A fallback string fired because `err.message` was empty (see AggregateError section) |

### 8. After Fixing

- Remove all debug logging before committing.
- Write a regression test if possible.
- Document the root cause in the commit message.
- Update `context.md` if the fix reveals something about the environment.
- **Prefer a structural bound over a test of the one instance.** After the cause is fixed, ask "what would make this whole failure class impossible, rather than just absent?" (a size/time cap, an invariant check, a type or schema) and prove it by reintroducing the original cause and showing the bound contains it. A passing regression test only proves the known case is gone, not that the class is closed.

## Database Specifics

### SQLite & Prisma

- **Database is locked**: In SQLite, concurrent writes cause locking.
  - **Fix**: Move `updateMany` or `createMany` calls OUT of loops. Consolidate into a single operation per user/batch.
  - **Pragma**: Use `PRAGMA busy_timeout=5000;` to make SQLite wait instead of failing immediately.
- **executeRawUnsafe vs queryRawUnsafe for PRAGMAs**: Use `$queryRawUnsafe` for **both** `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000`. Catch and ignore `"Execute returned results"`; it means the PRAGMA worked. Log all other errors.
  ```ts
  prisma.$queryRawUnsafe(`PRAGMA journal_mode=WAL;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("WAL enable failed:", err);
  });
  prisma.$queryRawUnsafe(`PRAGMA busy_timeout=5000;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("busy_timeout failed:", err);
  });
  ```
- **`connection_limit=1` required for SQLite in Next.js.** Next.js spawns multiple worker threads; without this they contend for the SQLite file and cause "Database is locked". Add to DATABASE_URL:
  ```
  DATABASE_URL="file:./production.db?connection_limit=1&timeout=30&pool_timeout=30"
  ```
- **Prisma singleton: always assign to global, even in production.** The common guard `if (process.env.NODE_ENV !== 'production')` before `globalForPrisma.prisma = prisma` is wrong: Next.js worker threads reload modules without reinitializing globals, which can cause an OOM crash loop. Remove the guard:
  ```ts
  export const prisma = globalForPrisma.prisma || createPrisma();
  globalForPrisma.prisma = prisma;  // always, not just in dev
  ```
- **Next.js apps OOMing under load:** Increase heap in your process manager config (e.g. a PM2 ecosystem file):
  ```js
  env: { NODE_OPTIONS: '--max-old-space-size=1024' }
  ```
  Also raise the restart-on-memory threshold to match (e.g. `max_memory_restart: '1G'`).
- **`datetime('now')` strings parse as LOCAL time in `new Date()`, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"` (space-separated, no `T`/`Z`). The ECMAScript Date parser treats that non-ISO form as local time, so `new Date(created_at)` silently shifts a stored timestamp by the viewer's UTC offset, and can shift the displayed date near UTC midnight. This is a JS Date-parsing bug, so it affects Prisma-on-SQLite and raw `better-sqlite3` alike.
  - **Fix**: normalize before parsing. Strict-match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/` and rewrite to `` `${date}T${time}Z` ``; pass already-ISO strings through unchanged. SQL-side comparisons like `date(created_at) = utcToday` are unaffected (both sides stay UTC).
  - Verify on a non-UTC host: `new Date('2026-07-06 12:00:00').toISOString()` returns a shifted hour.
  - If several apps share a scaffolded timestamp component, grep all of them; a clone carries the same bug.
- **Prisma `NOT:` wrapper excludes NULL rows on nullable columns.** `NOT: { field: value }` compiles to SQL `NOT(col = 'value')`, which is NULL (and therefore excluded) for any row where the column IS NULL. Null-valued rows silently disappear with no error, and the loss can be most of the table. Fix: when negating a NULLABLE column while still wanting NULL rows, use the explicit OR form: `OR: [{ field: null }, { field: { not: value } }]`. Self-review trigger: any Prisma `NOT:` filter on a nullable column, especially in queries with unexpectedly low row counts.
- **sqlite3 CLI `readfile()` stores a BLOB, and a BLOB reaches a Node app as a Buffer.** `better-sqlite3` returns BLOB columns as `Buffer`, so a render path calling `.replace` on it dies with `TypeError: a.replace is not a function` (HTTP 500), while the insert reported success and `length(col)` looked fine.
  1. Wrap file loads: `CAST(readfile('/path') AS TEXT)`.
  2. After any hand-written row insert into a live app's DB, check `typeof()` on the column AND fetch the rendering page, not just the row.
  3. Byte length and character length differing after the cast confirms multi-byte UTF-8 decoded; it is not truncation.
  4. Tell: a Node/Next.js page that 500s with `X.replace is not a function` inside an `Array.map` right after a manual DB write is a storage-class bug, not a data bug.

### Prisma + PostgreSQL: Use pg.Pool, Not a Raw Connection String

When using `@prisma/adapter-pg` (PrismaPg), pass a `pg.Pool` instance for proper connection pool control:

```ts
import { PrismaPg } from "@prisma/adapter-pg";
import { Pool } from "pg";

const pool = new Pool({
  connectionString: process.env.DATABASE_URL!,
  max: 10,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 5000,
});
const adapter = new PrismaPg(pool);
const prisma = new PrismaClient({ adapter });
```

`new PrismaPg({ connectionString })` creates an unmanaged pool with no limits.

### Reading a SQLite DB Another Process Is Actively Writing (WAL Mode)

When polling a SQLite database a running app writes to (e.g. a desktop app's `*.sqlite` in WAL mode), a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot** that doesn't advance, even across freshly spawned reader processes. Symptom: "it caught the first change but never the next ones," while manual one-off queries look current.

Fix: open a **normal connection with `PRAGMA query_only=ON`**. It participates in the WAL protocol correctly and sees the latest committed rows, while `query_only` guarantees you never modify the app's data. Add `.timeout <ms>` so a momentary writer lock yields a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

Second gotcha when your reader writes to the macOS clipboard: an app that pastes via the clipboard often does save, paste, **restore**, clobbering your write. Re-assert (re-`pbcopy`) for about 1s, checking `pbpaste`, to win the race.

## Logging and Error Reporting

### Error Log Lines Ending in a Bare Colon = Logger Dropping Arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`. Extra args after a string message are printf interpolation values, and with no `%s`/`%d`/`%o` in the message they are **silently discarded**. Console-style calls like `logger.error('failed:', err.message)` produce `"msg":"failed:"`; the actual error never reaches any log. An error can repeat for hours with its cause invisible.

Fixing call sites one by one does not work: audits leave stragglers and new ones appear with every feature. **Fix the class at the logger:** install a `hooks.logMethod` that appends would-be-dropped extras to the message, with a test. Canonical `(obj, msg)` and printf-style calls pass through untouched. Any repo that adopts pino should get the hook from day one.

### A pino logger configured with `transport:` breaks modules loaded outside the managed process

`pino-pretty`/multistream transports run in a worker thread that doesn't reliably initialize outside the long-running process your process manager launches (e.g. a bare `node -e` or a standalone CLI script). Before importing a service module into a standalone script, check whether it (or anything it imports) constructs a pino instance with `transport:`; split out the logger-free piece or stub `require.cache` first.

### Never format an error with `.message` alone: AggregateError and undici hide the cause

- Node >= 20 dials a `localhost` hostname with happy-eyeballs (`::1` and `127.0.0.1` in parallel). When BOTH fail it throws an `AggregateError` whose `.message` is the **empty string**, with the real per-address errors in `.errors`. The idiom `err.message || "some fallback"` then selects the fallback and the diagnosis is gone.
- undici (and Node's global `fetch`) reports every transport failure as `TypeError: fetch failed`, with the real reason on `.cause`. Logging `err.message` records an identical line whether the service is restarting, a tunnel dropped, or the socket was reset.
- It is environment-dependent: a single-stack host resolves localhost to one address and throws a plain Error with a usable message; a dual-stack host throws the empty-message AggregateError. A test that dials a dead port asserts different things on different machines, so build the AggregateError by hand in the test.

How to apply:
1. Use a `describeError()` that walks BOTH `.cause` and `AggregateError.errors`, bounds the depth (a cause can be self-referential), and appends `.code` and address:port at each level.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match the FULL flattened description, or an AggregateError carrying `ECONNREFUSED` reads as non-transient and is treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature that the fallback fired.
4. A generic user-facing failure ("Task processing failed. Please try again.") reads as "your input broke it". When the transport never reached the service, say the service was unreachable; the user is deciding whether to spend another (possibly rate-limited) attempt.

### Size a retry against the dependency's recovery time, not a blink

A single retry 30s later is only correct when the failure is a lost packet. A dependency reached via a container recreate or an SSH reverse tunnel can take minutes to come back: a container refuses connections for the whole `docker compose up -d` cycle, and after a tunnel drop the server can hold the dead session's forward for `ClientAliveInterval x ClientAliveCountMax` (e.g. 120s x 3 = 6 minutes) while a client with `ExitOnForwardFailure=yes` exits on every reconnect inside that window.

Rule: before picking a retry delay, name the dependency's slowest NORMAL recovery event and read its actual duration from the config that governs it (systemd `RestartSec`, sshd `ClientAlive*`, a container healthcheck's `start_period`, an autoscaling cooldown). Back off across a window that covers the recovery, and stop early when the next sleep would outlive the call's own abort deadline; sleeping into an abort converts a diagnosable network error into a bare "timed out". For a job that only runs on a schedule, a lost run is lost until the next tick, so this matters more. If sibling repos share a scaffolded client, check each one: the scaffold may have diverged.

### A progress heartbeat that stores only a timestamp cannot say WHERE a job died

A reaper that kills jobs on silence since `last_progress_at` is correct for liveness, but liveness only needs a timestamp, while the question asked later is always "where did it stop?". If the heartbeat discards the phase, every reaped job stores the same sentence, and the process log that could say more is rotated before anyone looks.

1. Persist the phase next to the timestamp and put it in the terminal message the recovery sweep writes (`Interrupted ... (stopped during: <phase> <n>/<total>)`). Build that message from ONE function that every surface (DB row, email, notification) calls, so they cannot disagree.
2. Audit for heartbeat-free windows. Any stretch between two stamps is a blind spot sized by the reaper's cutoff. A long phase should heartbeat from INSIDE (a per-item callback, throttled to about one write a minute), not only at its boundaries.
3. A pool is not bounded just because its units are. `Promise.all` over workers with per-fetch timeouts still never settles if ONE worker never settles, stranding the job inside a live process where a restart-triggered reaper never fires. Wrap the pool in a wall-clock deadline that fails open. The deadline must NOT cancel the underlying work: an orphaned promise costs a little memory, a stranded job costs the whole run.

### Log the destination you resolved to, not the one you were handed

A feature that both DELIVERS a payload somewhere and ADDRESSES a reply channel back to it has two notions of "the location", and they can silently diverge. Example shape: a long answer is posted into a NEW overflow thread created at post time, while the reply-to address is derived from a thread id captured at job start. Every component tests green; the user still reports the feature broken because a correct delivery to the wrong place is indistinguishable from no delivery.

Tells:
1. The code holds a location id from EARLIER in the job and uses it for an address, while the actual post happens LATER through a helper that may create its own destination.
2. The posting helper returns void. A function that chooses a destination and does not report it forces every caller to guess.

Fix: make the posting helper RETURN the surface it delivered to (null when it created none), derive the address from that, and fall back to the earlier id only when no new surface was made. Point the abandoned surface at the real one ("Answer: <link>"). Any log line that reports a delivery must print where the payload actually landed. A sent address cannot be rewritten: persist moves as a redirect resolved at delivery time, bound the hops, guard cycles, and keep every trust gate on the ORIGINAL signed id so the redirect rewrites the address and never the authorization.

Debugging tell: when a user says "I replied and nothing showed up", get the id of the surface the user is looking at and the id the system posted to, and compare them BEFORE reading any transport code.

### SMTP 250 OK is not delivery

Transactional mail sent through a shared consumer email account can be silently discarded: the library resolves `250 OK`/`accepted`, no bounce arrives, and the message is absent from the recipient's inbox, spam, and trash (likely sender-reputation throttling).

1. An SMTP success response means the relay accepted bytes, not that the user was notified.
2. Check the sender's inbox for a DSN and the recipient's mailbox (including trash) before sending more probes. Each probe can deepen a throttle and destroy the signal; diagnose from natural traffic.
3. A fire-and-forget send with a swallowing catch is undiagnosable later. Persist a delivery record (status, error, attempt count) and drive retries from it.
4. The durable fix is a transactional provider on an owned domain with SPF/DKIM/DMARC, not a shared consumer account.

## Automation and Headless Agents

### Tools run by a `claude -p` agent must be non-interactive

An automation flow that dispatches work to a `claude -p` agent runs with no TTY. Any CLI the agent invokes that blocks on interactive input (e.g. a `readline` "approve/edit?" prompt) hangs silently, and the agent quietly falls back to a worse path or times out. Symptom: "the tool exists and is wired up, but the nice pipeline never seems to actually run."

- Give the tool an `--auto`/`--yes` flag AND auto-enable it when `!process.stdin.isTTY`.
- Don't depend on an `ANTHROPIC_API_KEY` for sub-steps when the agent runs on subscription auth; route model calls through the `claude -p` CLI so the tool runs in the same keyless environment.
- Make the tested tool the canonical path. Prompts that re-describe a "manual fallback" flow drift and silently lose features.

### `claude -p` is the full agentic CLI

`claude -p --dangerously-skip-permissions` is the FULL agentic Claude Code CLI, not a constrained text-completion endpoint. For any pipeline that shells out to it:

1. **CWD hygiene.** With cwd inside a repo, the sub-agent can explore it and inject meta-commentary (e.g. narrating a source path) into output. For free-text generation, run the subprocess in an empty directory (e.g. `tempfile.mkdtemp()`). Cheap insurance for strictly parsed calls too.
2. **Retry breadth.** Retry on ANY non-zero exit AND on empty stdout, not only when stderr matches "rate"/"limit". Nested invocations intermittently exit 1 with EMPTY stderr. Use exponential backoff up to N attempts.
3. **Timeout sizing.** A timeout tuned on a solo run silently SIGTERMs most calls once real concurrency raises latency; a SIGTERM'd session's transcript shows a user turn and no assistant turn. Size the timeout from latency measured under the job's REAL concurrency.
4. **Model/effort must be explicit.** Headless runs inherit the host's `settings.json` model and effort level; an inherited high effort can triple latency. Pass `--model` and `--effort` explicitly.
5. **Exit code must reflect failure.** The CLI (or your wrapper) can exit 0 on a killed or empty run. Treat exit 0 with empty stdout as an error. A batch caller must exit non-zero if ANY item failed, or its run ledger can never go red.
6. **Permissions must be explicit too.** `bypassPermissions` gives a data-pump call full tool access (Bash, Write, every connector write), not just the reads it needs. Lock it down with `--permission-mode dontAsk` plus explicit `--allowedTools`/`--disallowedTools`, and verify live rather than trusting the flags. `--allowedTools` approves tools; it does not by itself remove others.
7. **Concurrent children sharing one config dir race the token refresh.** Fanning out several children against one `CLAUDE_CONFIG_DIR` can lose most of the batch if the token expires mid-run: they race the same single-use refresh token, one wins, the rest exit 1 with `duration_api_ms 0`. Serialize a refresh near expiry, sync host and isolated credentials both ways, and check per-row errors, not just the summary.

### Browser CDP timeout recovery: kill and restart

When a service calls a browser-automation CLI and receives "Timeout waiting for browser response", the Chrome/CDP session is stuck, not slow. Retries pile up with no recovery unless you:

1. Detect the specific timeout string in your error handler.
2. Kill all chrome/chromium processes: `pkill -f chrome || true`.
3. Restart the browser service under your process manager.
4. Run a startup connectivity check that triggers recovery *before* the main task:

```js
async function checkBrowserConnectivity() {
  try {
    await runBrowserCLI(['status'], { timeout: 10000 });
  } catch (err) {
    if (err.message.includes('Timeout waiting for browser response')) {
      await restartBrowserSystem();
    }
  }
}

async function restartBrowserSystem() {
  execSync('pkill -f chrome || true');
  execSync('pm2 restart <browser-service>');
  await new Promise(resolve => setTimeout(resolve, 3000)); // wait for startup
}
```

Also raise the base CLI timeout from 60s to 120s to avoid false-positive timeouts on slow page loads (separate from CDP hangs).

### Parallel Bash calls that each `cd` can race on a shared shell's cwd

The Bash tool's working directory persists between calls. Sending several `cd /repo/X && npm run build` calls in one message can race: whichever `cd` lands last decides where another call's command actually runs. Both calls return exit 0 and a well-formed passing report, so a false "repo X: build OK, N tests passed" can be logged while repo X was never built.

- Run per-directory commands sequentially, or make each self-contained: `git -C /repo/X ...`, `npm --prefix /repo/X run build`, or `(cd /repo/X && cmd)` in an isolated subshell.
- Before trusting a batch of per-repo results, spot-check that outputs which should differ (package name, route list, paths) actually do. Two identical reports for different repos is the tell.

### "command not found" across several sibling repos at once is usually a missing dev environment

`vitest: not found` (exit 127), `Missing script`, or `ModuleNotFoundError` for a *direct* dependency, reproducing across **multiple unrelated repos in the same pass**, points at the shared host environment (missing `node_modules`, missing venv), not several simultaneous code regressions. `git status`/`git log` will show nothing, because there is no code-level cause.

- Confirm with `ls node_modules | wc -l` (JS) or whether the venv has the package (Python) before writing any fix.
- The fix is a local reinstall, not a commit: `npm ci`, or `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt` (system `pip install` may be blocked by PEP 668 `externally-managed-environment`).
- Verify by re-running the original failing command and reporting the real pass count. "`npm ci` exited 0" is not the same claim as "the tests now pass."
- If you don't know why the environment vanished, treat a recurrence as worth a fresh look rather than auto-applying the same fix.

## Shell and Cron

### `git symbolic-ref origin/HEAD` exits 128 when unset; under `set -euo pipefail` it kills the script

`origin/HEAD` is set by `git clone` and nothing else (not by `git remote add` + fetch, never refreshed). On a checkout lacking it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128. Piping into `sed` does not save you: `pipefail` promotes the 128 and `set -e` terminates the script. A trailing `2>/dev/null` hides the message but not the exit code, so the line looks handled when it is not. Everything below that line silently never runs, which can disable alerting entirely for weeks.

How to apply: any command substitution that can legitimately fail needs an explicit `|| true` under `set -e`, especially git plumbing. When a long script has an unexplained partial effect, suspect a mid-script non-zero exit before logic. A state file written on the last line and frozen at a specific date is the cheapest proof.

### cron's PATH excludes `/usr/local/bin`; with `set -e` that kills a script silently

cron runs with `PATH=/usr/bin:/bin`. Anything in `/usr/local/bin` (pm2, node, npm, most globally installed tooling) is not found, and with `set -euo pipefail` the first such call kills the script before it does anything. If the script is a monitor, nothing is watching.

The compounding trap: `>>` updates a log file's mtime only on an actual WRITE, not on open. A job that dies before producing output leaves its log at 0 bytes with the mtime frozen, so a freshness checker cannot distinguish "dead for weeks" from "nothing to say."

How to apply: put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of any script cron runs, or set `PATH=` in the crontab. Reproduce cron failures with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '...'` before theorising. Never conclude a job is healthy from log mtime; record each run explicitly.

### A numeric guard with mismatched units never fires, and nothing looks broken

A watchdog compared a process RSS from `ps -o rss=` (**kilobytes**) directly against a threshold configured in **megabytes** (`[ "$rss" -lt "$MIN_TARGET_MB" ]`). Both are bare integers, so no error; the comparison is just never true. A correctly converted value on an adjacent line (for a log message) can make the code look unit-aware when the comparison isn't.

How to apply: check unit agreement at the comparison itself. Name variables with their unit (`rss_kb`, not `rss`) so a mismatch is visible in the diff. For any guard whose condition is rare, don't accept "it hasn't logged as firing" as evidence it works: construct the triggering condition once, on purpose (e.g. a decoy process sized to cross the threshold), and confirm the branch executes.

## Searches, Gates, and State Reads

### An empty search result has two causes: absent, or the query couldn't find it

These are indistinguishable from the output, and the second is more common than it feels. Reporting "clean" without separating them asserts a negative you did not establish.

1. **Grepping the transport, not the sink.** A grep for a literal constant or function name misses a call through a local alias (`const url = process.env.X_WEBHOOK_URL; fetch(url)`). Trace aliases and wrappers before declaring "no calls to X".
2. **Grepping a file grep treats as binary.** See the next section.

Rule: before reporting "not found," prove the query could have found it. Grep for a string you can *see* in the file and confirm it matches. A search that misses a known-present sentinel is itself the finding.

### One split multi-byte character makes grep treat a whole text file as binary, silently

A file whose lines were truncated to a fixed byte width can contain half a UTF-8 character (e.g. an orphan `\xe2\x80` before a valid ellipsis). grep then classifies the file as binary and suppresses matches: `grep -n <term>` and even `grep -c ""` print nothing, which reads exactly like "not in the file."

- Detect: `python3 -c "open(P,encoding='utf-8').read()"` raises with the byte offset; `file P` reports `data` instead of UTF-8 text; `grep -c $ P` vs `grep -ac $ P` disagree. `grep -a` works throughout.
- Repair: read bytes, splice out the orphan sequence, `decode()` to prove the whole file is clean BEFORE writing back.
- Prevent: in any generator that truncates text (index files, digests, log summaries, commit subjects), truncate by characters after decoding, never by bytes.

### A grep-gated feature never fires when the gate pattern doesn't match real output

A consumer gated on `grep -q "keywordA|keywordB"` against files a producer writes, but the producer's actual template never contained those substrings. The write side worked, the read side never matched, and the feature was fully dark: no error, no log line. Fix was to gate on a string every real file contains (a fixed heading such as `^## Classification:`).

Lesson: when producer and consumer communicate via a string match on generated content rather than a shared constant or schema, test the match condition against a REAL generated sample, and confirm it does not newly match files it shouldn't.

### Prefer the API that reads live state over the convenient one

Windows WMI `Win32_VideoController` `CurrentHorizontalResolution`/`CurrentRefreshRate` are populated at driver init and not re-read on mode change, so they can report a resolution the machine hasn't been in for hours, with nothing marking them stale. `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)` reads the live mode.

**Two state-reading APIs disagreeing about the same instant is not noise to average out; it means at least one isn't reading live state.** Go to the authoritative source rather than adjudicating between convenient ones. The same trap exists for anything cached at init (WMI snapshots, `/proc` values sampled once, ORM caches, driver-reported structs). Confirm a fix by checking the consumer's own view (e.g. restart it and read what it reports), not by re-reading the same API.

### A descending threshold list scanned first-match-then-break fires the WIDEST crossed tier

A reminder with tiers `[30, 14, 7, 1]` days, scanned as "first crossed-and-unsent tier, act, `break`", fires the widest tier, not the most urgent one its comment promises. Invisible on the common path (one new tier crossed per run), it bites an item that enters mid-range, already past several tiers. With per-tier dedup on a fixed cron cadence, each run marks only the one tier it fired, so the item fires again on each following tick: four notifications on consecutive days instead of one, each individually plausible.

How to apply: for any tier/bucket/threshold list (rate-limit escalation, discount tiers, alert severity, backoff selection), collect every crossed-and-unhandled tier, pick the most urgent by explicit comparison (e.g. `reduce` to the minimum window), and mark ALL collected tiers handled in the same pass. Array order is config, not a selection algorithm. Test the input that starts already past several tiers.

## UI Diagnostics

### A collapsed `<details>` still mounts and renders every child

`<details>` keeps children in the DOM when collapsed; it only hides them. N heavy children (e.g. a markdown + sanitizer tree each) inside collapsed sections parse up front and re-parse on every parent re-render; a periodic poll that returns a fresh JSON string defeats naive `React.memo` identity checks and re-parses everything each tick, making long lists lag.

How to apply: lazy-mount expensive children until first expand, or memoize parsed output keyed on content. This applies to any CSS-only hide (`display:none`, `hidden`, a closed collapsible): none of them unmount.

### A tab row directly above a feed reads as a filter for that feed

When a tab strip that only scopes an input control sits immediately above a result list, users read it as a filter and report the list as broken ("X selected, can't click Y"). Label the tab row for what it actually scopes, and give the list its own explicit filter with an "All" default. Before rewriting behaviour, prove the claim: hit-test each row with `document.elementFromPoint` at its centre and check the tag/href. That separates "an overlay eats the tap" from "this row was never a link" from "the user misread the control." The real defect may differ from the report's wording (e.g. pending rows rendered as a `div` with no href, so they were genuinely unclickable).

### A desktop client that "keeps disconnecting" and "won't log back in" is two separate causes

- **Disconnect** is often the machine sleeping. On macOS, check `pmset -g custom` (AC sleep timer) and `pmset -g log` Sleep/DarkWake lines against the client's own log timestamps, converting UTC vs local first.
- **Can't log back in** is often DNS: a machine whose only nameserver is the router hard-fails resolution at wake, so the reconnect can't resolve the login host and the client latches an internal offline state its own login button can't clear. Check `scutil --dns` resolver order and compare `dig` against the router vs a public resolver such as `1.1.1.1`.
- Quitting the app doesn't reset it if a background helper survives and restores the wedged session. Reap the whole process family, preserving any auto-login config first.
- Read event order, not just the last error line; a stale "offline" line may already be superseded by a later successful login.

Treat the two symptoms as independent diagnoses that each need their own evidence.
