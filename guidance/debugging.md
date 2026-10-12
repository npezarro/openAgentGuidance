<!-- Load when: diagnosing issues, log analysis -->
# Debugging Guidance

A systematic approach to diagnosing and fixing issues.

## The Debugging Workflow

```
0. Gather Context → 1. Reproduce → 2. Read the Error → 3. Isolate → 4. Hypothesize → 5. Verify → 6. Fix → 7. Confirm
```

### 0. Gather Existing Knowledge First

Before you touch code or form hypotheses, check whether this problem (or a close relative) has already been solved:

- **Memory**: Read the relevant feedback and project memory files. Corrections from past sessions are your highest-signal source.
- **CLAUDE.md**: The repo's CLAUDE.md records architecture decisions and known gotchas.
- **Guidance**: Check this repo for domain-specific rules (auth, deployment, and so on).
- **Knowledge base**: Scan your knowledge base index for patterns that span repos.
- **Private context repo**: Check your private context repo for credentials, registered URIs, or infrastructure details that constrain the solution.
- **Git history**: `git log --oneline --grep="<keyword>"` finds prior fixes.

This step is not optional background reading. It is the most efficient debugging step, because **the previous session's fix is often already written down in memory.** Skipping it to "save time" leads to debugging loops that last hours.

### Approach Switching (15-minute rule)

If you have spent 15+ minutes trying variations of the same approach without progress:
1. Stop iterating on the current approach.
2. Re-read memory and guidance for the domain (Step 0 again).
3. Spawn a debugger agent for a fresh perspective.
4. Try a **fundamentally different** approach.

Repeating the same category of fix with different values is brute force, not debugging.

### 1. Reproduce the Issue

Before you touch code, confirm you can trigger the problem:
- Run the exact command or action that causes the error.
- Note the exact error message, stack trace, and context.
- If you can't reproduce it, you can't be confident you fixed it.

### 2. Read the Error Fully

- Read the **entire** stack trace, not just the first line.
- Look for the **first** error in a chain. Cascading failures often hide the root cause.
- Check whether the error message tells you directly what's wrong. It often does.

### 3. Isolate the Problem

- **Binary search:** Comment out half the suspect code. Does the error persist?
- **Minimal reproduction:** Can you trigger it with a 5-line script?
- **Check boundaries:** Is the issue in your code, a dependency, or the environment?

### 4. Check the Obvious First

Before you dig deep, rule these out:

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

Add **focused** logging, not scattered `console.log("here")` calls:

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
| `MODULE_NOT_FOUND` | Missing dependency, wrong path, or missing build step |
| `EACCES` / permission denied | File ownership issue (`sudo chown`) |
| `EADDRINUSE` | Port already in use: kill the other process or use a different port |
| `TypeError: x is not a function` | Wrong import, wrong version, or `x` is undefined |
| `undefined` where you expect data | Async issue, wrong property name, or missing await |
| Works locally, fails in CI | Different Node version, missing env vars, or different OS |
| Works on first load, breaks on refresh | Client-side state out of sync with the server, or a stale cache |
| Script silently produces empty results | A path from JSON/jq contains `~`, which the shell does not expand. Use `${VAR/#\~/$HOME}` |
| Error log line ends in a bare colon | The logger is dropping arguments (see "Logging and Error Reporting") |
| Self-referential message ("X failed: x failed") | A fallback string replaced an empty `err.message` |
| Node page 500s with `x.replace is not a function` right after a manual DB write | Wrong storage class (BLOB stored where TEXT was expected), not bad data |

### 8. After Fixing

- Remove all debug logging before you commit.
- Write a regression test if you can.
- Record the root cause in the commit message.
- Update `context.md` if the fix reveals something about the environment.
- **Prefer a structural bound over a test of the one instance.** Once the cause is fixed, ask what would make the whole failure class impossible rather than just absent: a size or time cap, an invariant check, a type, or a schema. Prove it by reintroducing the original cause and showing the bound contains it. A passing regression test only proves the known case is gone, not that the class is closed.

## Database Specifics

### SQLite and Prisma

- **Database is locked**: concurrent writes to SQLite cause lock errors.
  - **Fix**: Move `updateMany` or `createMany` calls out of loops and consolidate them into one operation per user or batch.
  - **Pragma**: `PRAGMA busy_timeout=5000;` makes SQLite wait instead of failing immediately.
- **Use `$queryRawUnsafe` for PRAGMAs, not `$executeRawUnsafe`.** Use it for both `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000`. Catch and ignore `"Execute returned results"`, which means the PRAGMA worked. Log every other error.
  ```ts
  prisma.$queryRawUnsafe(`PRAGMA journal_mode=WAL;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("WAL enable failed:", err);
  });
  prisma.$queryRawUnsafe(`PRAGMA busy_timeout=5000;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("busy_timeout failed:", err);
  });
  ```
- **Next.js with SQLite needs `connection_limit=1`.** Next.js spawns multiple worker threads, and without this setting they fight over the SQLite file and cause "Database is locked". Add it to DATABASE_URL:
  ```
  DATABASE_URL="file:./production.db?connection_limit=1&timeout=30&pool_timeout=30"
  ```
- **Prisma singleton: always assign to global, even in production.** The common guard `if (process.env.NODE_ENV !== 'production')` before `globalForPrisma.prisma = prisma` is wrong. Next.js worker threads reload modules without reinitializing globals, so the guard leads to multiplying clients and OOM crash loops. Remove the guard:
  ```ts
  export const prisma = globalForPrisma.prisma || createPrisma();
  globalForPrisma.prisma = prisma;  // always, not just in dev
  ```
- **If Next.js apps OOM under load**, raise the heap in the process manager config:
  ```js
  env: { NODE_OPTIONS: '--max-old-space-size=1024' }
  ```
  Raise the memory-restart threshold to match (for example, `1G`).
- **`new Date()` parses SQLite `datetime('now')` strings as LOCAL time, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"` (space-separated, no `T` or `Z`). The ECMAScript Date parser treats that non-ISO form as local time, so `new Date(created_at)` silently shifts the timestamp by the viewer's UTC offset and can change the displayed date near UTC midnight. The bug is in JS Date parsing, so it affects Prisma and raw `better-sqlite3` alike.
  - **Fix**: normalize before parsing. Strictly match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/`, rewrite it to `` `${date}T${time}Z` ``, and pass already-ISO strings through unchanged. SQL-side comparisons such as `date(created_at) = utcToday` are unaffected, since both sides stay UTC.
  - Check: `new Date('2026-07-06 12:00:00').toISOString()` returns `19:00Z` on a host in UTC-7. If a timestamp component has been copied across several apps, grep for every copy and fix them all.
- **Prisma's `NOT:` wrapper drops NULL rows on nullable columns.** `NOT: { field: value }` compiles to SQL `NOT(col = 'value')`, which evaluates to NULL for any row where the column IS NULL, so those rows are excluded. No error is raised; null-valued rows just vanish. In one real case it silently dropped about 73% of rows. Fix: when you negate a nullable column and still want the NULL rows, use the explicit OR form: `OR: [{ field: null }, { field: { not: value } }]`. Self-review trigger: any Prisma `NOT:` filter on a nullable column, especially in a query that returns fewer rows than expected.

### Prisma and PostgreSQL: Use pg.Pool, Not a Raw Connection String

With `@prisma/adapter-pg` (PrismaPg), pass a `pg.Pool` instance so you control the connection pool:

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

### Reading a SQLite DB Another Process Is Writing (WAL Mode)

If you poll a SQLite database that a running app writes to in WAL mode, a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot**. It reads committed WAL frames as of some earlier point and stops advancing, even across freshly spawned reader processes. The classic symptom is "it caught the first change but never the next ones," even though the process is alive and one-off manual queries look current.

Fix: open a **normal (read-write-capable) connection with `PRAGMA query_only=ON`**. That connection follows the WAL protocol correctly and sees the latest committed rows, and `query_only` guarantees you never modify the app's data. Add `.timeout <ms>` so a brief writer lock causes a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

Related clipboard race: if your reader writes to the system clipboard and the other app pastes through the clipboard, it may save, paste, then **restore** the clipboard and overwrite what you wrote. Re-assert your value (re-copy) for about 1 second, checking the clipboard contents, to win the race.

### sqlite3 `readfile()` Stores a BLOB, Which Reaches Node as a Buffer

If you load file content with the sqlite3 CLI's `readfile()`, the row gets `typeof(col) = 'blob'`, not `'text'`. `better-sqlite3` returns a BLOB as a Node Buffer, so render code that calls `.replace` on it throws `TypeError: a.replace is not a function` and every SSR request for that page returns 500. The insert reports success and `length(col)` looks fine.

1. Wrap file loads: `CAST(readfile('/path') AS TEXT)`.
2. After any hand-written insert into a live app's DB, check `typeof()` on the column **and** fetch the page that renders it. A row that selects cleanly can still have the wrong storage class for its consumer.
3. After the cast, byte length and character length will differ because of multi-byte characters. That difference confirms the text decoded as UTF-8; it does not mean the text was truncated.

## Logging and Error Reporting

### Error Log Lines Ending in a Bare Colon: the Logger Is Dropping Arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`. Extra arguments after a string message are printf interpolation values, and if the message has no `%s`/`%d`/`%o` they are **silently discarded**. A console-style call such as `logger.error('failed:', err.message)` logs `"msg":"failed:"`, and the actual error never reaches any log. The symptom while debugging: an error keeps repeating, but its message stops at the colon.

Fixing call sites one by one does not work, because new multi-arg calls show up with every feature. **Fix the class at the logger:** install a `hooks.logMethod` that appends the would-be-dropped extras to the message, with a test. Canonical `(obj, msg)` and printf-style calls pass through unchanged. Install the hook in any repo the day it adopts pino.

### A pino Logger With `transport:` Breaks Modules Used Outside the Main Process

`pino-pretty` and multistream transports run in a worker thread that may fail to start outside the long-running process your process manager launches (for example, from a bare `node -e` or a standalone CLI script). Before a standalone script imports a service module, check whether that module (or anything it imports) builds a pino instance with `transport:`. If it does, split out the logger-free piece or stub `require.cache` first.

### An Empty `err.message` (AggregateError) Makes a Fallback String Look Like the Real Error

Node >= 20 connects to a `localhost` hostname with happy-eyeballs, trying `::1` and `127.0.0.1` in parallel. When **both** fail it throws an AggregateError whose `.message` is the **empty string**, with the real per-address errors in `.errors`. So the common idiom `err.message || "some fallback"` picks the fallback, and the diagnosis is lost. undici (Node's global `fetch`) makes this worse: it reports every transport failure as the same opaque `"fetch failed"`, with the real reason on `.cause`.

This depends on the environment, which is why it often doesn't reproduce locally. A single-stack host resolves localhost to one address and throws a plain Error with a usable message, while a dual-stack host throws the empty-message AggregateError. To test it reliably, build the AggregateError by hand instead of dialing a dead port.

How to apply:
1. Never format an error with `.message` alone. Use a `describeError()` that walks **both** `.cause` and `AggregateError.errors`, bounds the depth (a cause chain can loop back on itself), and appends `.code` and address:port at each level.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match the **full flattened description**. Otherwise an AggregateError carrying ECONNREFUSED looks non-transient and gets treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature of this bug. It means the fallback fired, not that the error itself was unhelpful.
4. Don't show users a generic "Task failed, please try again" when the transport never reached the service. Say the service was unreachable, so the user can decide whether to spend another rate-limited attempt.

### Log the Destination You Resolved To, Not the One You Were Handed

A log line that reports a delivery must print where the payload **actually** landed. A line like "Relaying into thread <id>" that prints the addressed id makes a misroute look like a healthy relay and sends the investigation to the wrong code.

## Retries, Timeouts, and Long-Running Jobs

### Size a Retry Against the Dependency's Recovery Time

A single retry after a short delay only covers a lost packet. It cannot span a container recreate (connections are refused for the whole `up -d` cycle) or an SSH reverse-tunnel reconnect. In the tunnel case the server can hold a dead session's forward for `ClientAliveInterval x ClientAliveCountMax`, which is often several minutes, and `ExitOnForwardFailure=yes` makes every reconnect inside that window exit.

Rule: before you choose a retry delay, name the dependency's slowest **normal** recovery event and read its real duration from the config that governs it (systemd `RestartSec`, sshd `ClientAlive*`, a container healthcheck's `start_period`, an autoscaler cooldown). Back off across a window that covers that recovery. Stop early if the next sleep would outlast the call's own abort deadline, because sleeping into an abort turns a diagnosable network error into a bare "timed out". For jobs that only run on a schedule, a lost run stays lost until the next tick, so this matters even more.

### A Heartbeat That Stores Only a Timestamp Cannot Tell You Where a Job Died

A progress heartbeat gets written to answer "is this still alive?", which only needs a timestamp. The question you actually ask later is "where did it stop?", and the phase is the whole answer. One UPDATE could serve both, so store both. Logs that could answer it are often rotated away before anyone looks.

1. Persist the phase next to the timestamp and put it in the terminal message the recovery sweep writes ("Interrupted (stopped during: <phase> 212/419)"). Build that message with **one** function that every surface (DB row, email, notification) calls, so the surfaces can't disagree about a single event.
2. Audit for windows with no heartbeat. Any stretch between two stamps is a blind spot as long as the reaper's cutoff. A long phase should heartbeat from **inside** (via a per-item callback, throttled to about one write a minute), not just at its boundaries.
3. A pool is not bounded just because each unit is. `Promise.all` over workers with per-request timeouts still never settles if one worker never settles, and the job is stranded inside a live process, where a reaper that only runs on restart never fires. Wrap the pool in a wall-clock deadline that fails open. The deadline must **not** cancel the underlying work: an orphaned promise costs a little memory, while a stranded job costs the user the whole run.

### Browser CDP Timeout Recovery: Kill and Restart

When a service calling a browser-automation CLI gets "Timeout waiting for browser response", the Chrome/CDP session is usually stuck, not slow. Retries just pile up. Recovery:

1. Detect the specific timeout string in your error handler.
2. Kill all Chrome/Chromium processes: `pkill -f chrome || true`.
3. Restart the browser-agent service through your process manager.
4. Add a startup connectivity check that runs recovery **before** the main task:

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
  execSync('<process-manager> restart browser-agent');
  await new Promise(resolve => setTimeout(resolve, 3000)); // wait for startup
}
```

Also raise the base CLI timeout (for example, 60s to 120s) so slow page loads don't produce false timeouts. That is a separate issue from CDP hangs.

## Headless Agents and Automation

### Tools Run by a `claude -p` Agent Must Be Non-Interactive

An automation flow that hands work to a `claude -p` agent runs with no TTY. Any CLI the agent calls that blocks on interactive input (such as a `readline` "approve/edit?" prompt) hangs silently, and the agent quietly falls back to a worse path or times out. Symptom: "the tool exists and is wired up, but the good pipeline never seems to run."

- Give the tool an `--auto`/`--yes` flag **and** turn it on automatically when `!process.stdin.isTTY`, so it never hangs no matter how it's launched.
- Don't make sub-steps depend on an API key the agent's environment lacks. Route model calls through the same CLI auth the agent uses.
- Make the tested tool the canonical path. Prompts that re-describe a "manual fallback" flow drift and silently lose features.

### `claude -p` Is the Full Agentic CLI

`claude -p --dangerously-skip-permissions` is the **full** agentic Claude Code CLI, not a constrained text-completion endpoint. For any pipeline that shells out to it:

1. **CWD hygiene.** If the subprocess runs inside a repo, the sub-agent can explore that repo and put meta-commentary in its output (for example, narrating the source path it was called from). For free-text generation, set the subprocess cwd to an empty directory (such as `tempfile.mkdtemp()`). For strictly parsed output (such as JSON) the risk is lower, but the same hygiene costs nothing.
2. **Retry breadth.** Retry on **any** non-zero exit and on empty stdout, not only when stderr mentions "rate" or "limit". Nested invocations sometimes exit 1 with **empty** stderr as a transient failure. Use exponential backoff, up to N attempts.
3. **Timeout sizing.** A fixed timeout tuned on a solo test run will SIGTERM almost every call once real concurrency raises latency. Size it from latency measured under the job's **real** concurrency. A killed session's transcript shows a user turn and no assistant turn.
4. **Model and effort must be explicit.** A headless run inherits the host's settings model and effort level. A high inherited effort can make calls more than 3x slower. Pass `--model` and `--effort` explicitly.
5. **The exit code must reflect failure.** The CLI can exit 0 on a killed or empty run. Treat exit 0 with empty stdout as an error. A batch caller must exit non-zero if **any** item failed, or its run ledger can never turn red.
6. **Permissions must be explicit too.** `bypassPermissions` gives a data-pump call full tool access (Bash, Write, every connector write), not just the reads it needs. Lock it down with `--permission-mode dontAsk` and explicit `--allowedTools`/`--disallowedTools`, then verify with a live run rather than trusting the flags. `--allowedTools` controls approval, not availability.
7. **Concurrent children sharing one config dir race the token refresh.** If several `claude -p` children share one isolated `CLAUDE_CONFIG_DIR` and the token expires mid-run, they all race for the same single-use refresh token. One wins and the rest exit 1 with `duration_api_ms 0`. Serialize the refresh when expiry is near, and sync credentials both ways between host and isolated dirs. Check individual rows for errors, not just the summary.

## Shell, Cron, and Scripts

### `git symbolic-ref origin/HEAD` Exits 128 When Unset, and `set -euo pipefail` Silently Kills the Script

Only `git clone` sets `origin/HEAD`. `git remote add` plus fetch does not, and nothing refreshes it afterwards. On a checkout without it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128.

Under `set -euo pipefail`, piping that into `sed` does **not** help: pipefail passes the 128 through the pipe and `set -e` ends the script. A trailing `2>/dev/null` hides the **message** but not the exit code, so the line looks handled when it isn't. In a long monitoring script, this can quietly disable everything below that line (including the alerting block) for weeks.

Apply: any command substitution that can legitimately fail needs an explicit `|| true` under `set -e`, especially git plumbing. If a long script has an unexplained partial effect, check for a mid-script non-zero exit before you suspect the logic. A state file written on the last line whose content is frozen at a particular date is the cheapest proof.

### cron's PATH Excludes /usr/local/bin

cron runs with `PATH=/usr/bin:/bin`. Anything in `/usr/local/bin` (node, npm, process managers, most globally installed tools) is not found. With `set -euo pipefail`, the first such call kills the script before it does anything. If that script is a monitor, nothing is watching anymore.

A related trap: `>>` only updates a log file's mtime when something is actually **written**, not when the file is opened. A job that fails before producing output leaves its log at 0 bytes with a frozen mtime. A freshness checker can't tell "silently dead for weeks" from "never had anything to say".

Apply: put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of every script cron runs, or set `PATH=` in the crontab. If a script works interactively but fails under cron, reproduce it with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '...'` before you theorise. Never decide a job is healthy from its log mtime.

### Numeric Guards With Mismatched Units Never Fire

A bash comparison like `[ "$rss" -lt "$MIN_TARGET_MB" ]`, where `ps -o rss=` returns **kilobytes** and the threshold is in **megabytes**, always evaluates false for a real process. Both sides are bare integers, so there's no error, no crash, and no log line that separates "correctly false" from "can never be true". A correctly converted value on an adjacent line (say, a GB figure computed for a log message) makes the code look unit-aware when the comparison isn't.

Apply: check unit agreement at the comparison itself. Name variables with their unit (`rss_kb`, not `rss`) so a mismatch shows up in the diff. For any guard whose fire condition is rare, don't take "it hasn't logged firing" as proof it works. Create the triggering condition once on purpose (for example, a decoy process sized to cross the threshold) and confirm the branch runs.

## Silent Search and Match Failures

### An Empty Search Result Has Two Causes

Either the thing is absent, or the query couldn't find it. The output looks the same either way, and the second cause is more common than it feels. If you report "clean" without telling them apart, you are asserting a negative you didn't establish.

Two common ways the query fails silently:
1. **Grepping the transport instead of the sink.** A grep for the obvious literal (a URL constant or function name) misses a call through a variable assigned one expression away (`const url = process.env.X_URL`, then `fetch(url)`). Before you declare "no calls to X", trace aliases and wrapper functions.
2. **Grepping a file grep treats as binary.** See below.

Rule: before you report "not found", prove the query could have found it. Grep for a string you can **see** in the file and confirm it matches. A search that finds a known sentinel is calibrated. If it misses a sentinel you expected, that miss is itself the finding.

### One Split Multi-Byte Character Makes grep Treat a Text File as Binary

If a generated file truncates lines by **bytes**, it can cut a UTF-8 character in half and leave orphan bytes. grep then classifies the whole file as binary and suppresses matches without an error: `grep -n <term> file` and even `grep -c "" file` print nothing, which reads exactly like "that term isn't there". `grep -a` works on the same file.

- Detect: `python3 -c "open(P,encoding='utf-8').read()"` raises `UnicodeDecodeError` with the byte offset. `file P` reports `data` instead of UTF-8 text. `grep -c $ P` and `grep -ac $ P` disagree.
- Repair: read the bytes, cut out the orphan sequence, and `decode()` the whole buffer to prove it's clean **before** you write it back.
- Prevent: anything that truncates text to a width (index files, log summaries, digests, commit subjects, `s[:80]`) must truncate by characters after decoding, never by bytes.

### A Grep-Gated Feature Never Fires When the Pattern Doesn't Match Real Output

If a producer and consumer communicate through a string or grep match on generated content rather than a shared constant or schema, the consumer's gate can quietly never match. For example, a gate looks for intuitive keywords the producer's template never writes. The write side works, the read side never fires, and nothing logs an error, so the whole feature is dark.

Apply: check the match condition against a **real** generated sample, not against keywords that seem likely. Better, gate on a structural marker the producer always emits (such as a fixed heading), or share a constant. Confirm the new pattern matches real files and still rejects the files it should reject.

### A Cached or Stale State API Gives You a Confidently Wrong Number

Some APIs fill their fields once at init and never re-read them. On Windows, WMI `Win32_VideoController` `Current*` fields are set at driver init and don't update on a mode change, so they can report a display mode the machine hasn't used for hours. `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)` reads the live mode. Nothing in the stale output marks it as stale.

**If two state-reading APIs disagree about the same moment, don't average them or pick the likelier value.** At least one of them isn't reading live state; find out which. For any state you will report to a user or base a decision on, prefer the API whose contract is "read the live value now" over the one that's convenient. The same trap exists for anything cached at init: WMI `Win32_*` snapshots, `/proc` values sampled once, ORM caches, and any getter that returns a driver-reported struct.

Close it out by corroborating, not by re-reading the same API. For example, restart the consumer and check what **it** reports, or find an earlier log line showing what the client actually asked for.

## Delivery and Routing Bugs

### A Reply Address Must Name Where the Payload Landed

A feature that both **delivers** a payload to a location and **addresses** a reply channel back to it has two separate ideas of "the location", and they can drift apart. When they do, every component passes its tests and the user still reports the feature as broken, because a correct delivery to the wrong place looks the same as no delivery.

Tells:
1. The code holds a destination id from **earlier** in the job (a record field, a variable captured at start) and uses it for an address, while the actual post happens **later** through a helper that may create its own destination.
2. The posting helper returns void. A function that picks a destination without reporting it forces every caller to guess.

Fix: make the posting helper **return** the surface it delivered to (null if it didn't create one), and derive the address from that return value. Fall back to the previously known id only when the helper created nothing new. Have the abandoned surface point to the real one, or it looks like a job that produced nothing.

A sent address can't be rewritten. Fixing the code only helps future sends. For addresses already delivered (especially signed ones), store the move as a redirect resolved at delivery time, bound the hops, and guard against cycles. Keep every trust check on the **original** signed id, so the redirect changes the address and never the authorisation.

Debugging tell: when a user says "I replied and nothing showed up", don't start with the relay. Get the id of the surface the user is looking at and the id the system posted to, and compare them **before** you read any transport code.

## Logic Bugs That Hide on the Common Path

### Descending Threshold List + First-Match-Then-Break Picks the Widest Tier, Not the Most Urgent

If tiers are ordered widest window first (`[30, 14, 7, 1]` days) and the loop does "first tier crossed and unsent → act → `break`", the first match is the **widest** crossed tier, which is the opposite of "most urgent". On the common path you never see it: an item tracked from outside the widest window crosses one tier per evaluation.

It bites when an item **enters mid-range**, already past several tiers the first time it's evaluated. Add per-tier dedup on a fixed cron cadence and each run marks only the one tier it fired. The skipped tiers stay unsent and fire one per tick, so the user gets four notifications on four days instead of one. Each send looks legitimate, so nothing flags a duplicate.

Apply to any tier, bucket, or threshold list scanned with first-match logic (rate-limit escalation, discount tiers, alert severity, backoff selection): collect every tier whose condition is met and unhandled, pick the most urgent by explicit comparison (for example, `reduce` to the minimum window), and mark **all** collected tiers as handled in the same pass. Source array order is configuration, not a selection algorithm. Test the case where input starts already past several tiers, not only the one-at-a-time path.

### A Collapsed `<details>` Still Mounts and Renders Every Child

An HTML `<details>` element keeps its children in the DOM when collapsed; CSS only hides them. If you render N heavy children (such as `react-markdown` + `rehype-sanitize` per item) inside collapsed sections, all N get parsed up front and parsed again on every parent re-render. A periodic poll that returns a fresh JSON string also defeats naive `React.memo` identity checks, so a list page with many results lags even though nobody opened a section.

Apply: CSS-only hiding (`<details>`, `display:none`, `hidden`, a closed collapsible) never unmounts anything, so it never saves the render cost. Lazy-mount the child (render nothing or a light placeholder until the first expand), or memoize the parsed output by content so an unchanged item doesn't re-run the parser.

### A Tab Row Directly Above a List Reads as a Filter for That List

If a tab strip that only scopes an input control sits right above a results list, users read it as a filter on the list and report the list as broken. Label the tab row for what it actually scopes, and give the list its own explicit filter with an "All" default.

Before you rewrite behaviour on a "can't click X" report, check the claim: hit-test each row with `document.elementFromPoint` at its centre and inspect the tag and href. That tells you whether an overlay is eating the tap, the row was never a link (for example, pending rows rendered as a `div` with no href), or the user misread the control. The real defect may differ from what the report literally says.
