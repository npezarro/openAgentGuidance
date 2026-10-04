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
- **Guidance**: Check this repo's guidance files for domain-specific rules (auth, deployment, and so on).
- **Knowledge base**: Scan your knowledge base index for patterns that span repos.
- **Private context repo**: Look for credentials, registered URIs, or infrastructure details that limit the solution.
- **Git history**: `git log --oneline --grep="<keyword>"` finds earlier fixes.

This step is not optional background reading. It is the most efficient debugging step, because **the previous session's fix is often already written down in memory.** Skipping it to "save time" leads to debugging loops that last hours.

### Approach Switching (15-minute rule)

If you have spent 15+ minutes trying variations of the same approach without progress:
1. Stop iterating on the current approach.
2. Re-read memory and guidance for the domain (Step 0 again).
3. Spawn a debugger agent for a fresh perspective.
4. Try a **fundamentally different** approach.

Repeating the same category of fix with different values is brute force, not debugging.

### 1. Reproduce the Issue

Before touching code, confirm you can trigger the problem:
- Run the exact command or action that causes the error.
- Write down the exact error message, stack trace, and context.
- If you can't reproduce it, you can't be confident you fixed it.

### 2. Read the Error Fully

- Read the **entire** stack trace, not just the first line.
- Find the **first** error in a chain. Cascading failures often hide the root cause.
- Check whether the error message tells you directly what's wrong (it often does).

### 3. Isolate the Problem

- **Binary search:** Comment out half the suspect code. Does the error persist?
- **Minimal reproduction:** Can you trigger it with a 5-line script?
- **Check boundaries:** Is the issue in your code, a dependency, or the environment?

### 4. Check the Obvious First

Before diving deep, rule these out:

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
| `MODULE_NOT_FOUND` | Missing dependency, wrong path, missing build step |
| `EACCES` / permission denied | File ownership issue (`sudo chown`) |
| `EADDRINUSE` | Port already in use: kill the other process or use a different port |
| `TypeError: x is not a function` | Wrong import, wrong version, or `x` is undefined |
| `undefined` where you expect data | Async issue, wrong property name, missing await |
| Works locally, fails in CI | Different Node version, missing env vars, different OS |
| Works on first load, breaks on refresh | Client-side state not synced with server, stale cache |
| Script silently produces empty results | Path from JSON/jq contains `~`, which the shell does not expand. Use `${VAR/#\~/$HOME}` |
| Error log line ends in a bare colon | Logger is dropping arguments (see the pino section below) |
| A self-referential message ("X failed: x failed") | An `err.message \|\| "fallback"` fired on an empty message (see AggregateError below) |

### 8. After Fixing

- Remove all debug logging before committing.
- Write a regression test if possible.
- Put the root cause in the commit message.
- Update `context.md` if the fix reveals something about the environment.
- **Prefer a structural bound over a test of the one instance.** Once the cause is fixed, ask "what would make this whole class of failure impossible, not just absent?" (a size or time cap, an invariant check, a type or schema). Prove the bound works by reintroducing the original cause and showing the bound contains it. A passing regression test only shows the known case is gone, not that the class is closed.
- **Confirm a new assertion fails against the pre-fix code.** A test that passes on both the broken and the fixed version proves nothing.

## Database Specifics

### SQLite & Prisma

- **Database is locked**: Concurrent writes lock SQLite.
  - **Fix**: Move `updateMany` or `createMany` calls OUT of loops. Consolidate them into one operation per user or batch.
  - **Pragma**: Use `PRAGMA busy_timeout=5000;` so SQLite waits instead of failing immediately.
- **Use `$queryRawUnsafe` for PRAGMAs**, both `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000`. Catch and ignore `"Execute returned results"`, which means the PRAGMA worked. Log all other errors.
  ```ts
  prisma.$queryRawUnsafe(`PRAGMA journal_mode=WAL;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("WAL enable failed:", err);
  });
  prisma.$queryRawUnsafe(`PRAGMA busy_timeout=5000;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("busy_timeout failed:", err);
  });
  ```
- **SQLite in Next.js requires `connection_limit=1`.** Next.js runs multiple worker threads. Without the limit they compete for the SQLite file and cause "Database is locked". Add it to DATABASE_URL:
  ```
  DATABASE_URL="file:./production.db?connection_limit=1&timeout=30&pool_timeout=30"
  ```
- **Always assign the Prisma singleton to global, production included.** The common guard `if (process.env.NODE_ENV !== 'production')` in front of `globalForPrisma.prisma = prisma` is wrong. Next.js worker threads reload modules without reinitializing globals, so the guard leads to repeated clients and can cause OOM crash loops. Remove the guard:
  ```ts
  export const prisma = globalForPrisma.prisma || createPrisma();
  globalForPrisma.prisma = prisma;  // always, not just in dev
  ```
- **Next.js apps that OOM under load:** Raise the heap in your process manager config (for example a PM2 ecosystem file):
  ```js
  env: { NODE_OPTIONS: '--max-old-space-size=1024' }
  ```
  Raise `max_memory_restart` to match (for example `1G`).
- **`datetime('now')` strings parse as LOCAL time in `new Date()`, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"` (space-separated, no `T` or `Z`). The ECMAScript Date parser treats that non-ISO form as local time, so `new Date(created_at)` silently shifts the timestamp by the viewer's UTC offset, and near UTC midnight it can show the wrong date. This is a JS Date-parsing bug, not a Prisma bug, so it affects raw `better-sqlite3` apps too.
  - **Fix**: Normalize before parsing. Strict-match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/` and rewrite to `` `${date}T${time}Z` ``. Pass strings that are already ISO through unchanged. SQL-side comparisons such as `date(created_at) = utcToday` are unaffected, because both sides stay UTC.
  - Check for it: on a non-UTC host, `new Date('2026-07-06 12:00:00').toISOString()` returns a shifted hour. If the same timestamp component has been copied across several apps, grep all of them.
- **Prisma's `NOT:` wrapper excludes NULL rows on nullable columns.** `NOT: { field: value }` compiles to SQL `NOT(col = 'value')`. That evaluates to NULL for any row where the column IS NULL, so those rows are excluded with no error. One real case lost more than 70% of rows this way. Fix: when you negate a NULLABLE column and still want the NULL rows, use the explicit OR form: `OR: [{ field: null }, { field: { not: value } }]`. Self-review trigger: any Prisma `NOT:` filter on a nullable column, especially in a query that returns surprisingly few rows.

### Prisma + PostgreSQL: Use pg.Pool, Not a Raw Connection String

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

### Reading a SQLite DB Another Process Is Actively Writing (WAL Mode)

When you poll a SQLite database that a running app writes to (for example an Electron app's `*.sqlite` in WAL mode), a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot**. It reads committed WAL frames as of an earlier point and doesn't advance, even across freshly spawned reader processes. Classic symptom: "it caught the first change but never the next ones," while the process is alive and manual one-off queries look current.

Fix: open a **normal (read-write-capable) connection with `PRAGMA query_only=ON`** instead. It takes part in the WAL protocol correctly and reliably sees the latest committed rows, and `query_only` guarantees you never modify the app's data. Add `.timeout <ms>` so a brief writer lock causes a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

A second gotcha applies if your reader writes to the macOS clipboard. An app that pastes through the clipboard often does save → paste → **restore**, which overwrites your write. Re-assert it (run `pbcopy` again) for about 1s, checking `pbpaste`, so your value wins the race.

### sqlite3 `readfile()` stores a BLOB, and a BLOB column reaches a Node app as a Buffer

If you insert file content with the sqlite3 CLI's `readfile()`, the row has `typeof(col) = 'blob'`, not `'text'`. better-sqlite3 returns a BLOB as a Node Buffer, so the render path calls `.replace` on a Buffer and every request for that page returns a 500 with `TypeError: a.replace is not a function`. The insert reports success and `select length(col)` looks fine.

1. When loading file content from the CLI, wrap it: `CAST(readfile('/path') AS TEXT)`.
2. After any hand-written insert into a live app's DB, check `typeof()` on the column AND load the page that renders it, not just the row.
3. After the cast, byte length and character length differ when the text has multi-byte characters. That difference confirms a UTF-8 decode; it is not truncation.
4. Symptom to recognize: a Node/Next.js page that returns a 500 with `X.replace is not a function` inside an `Array.map`, right after a manual DB write, has a storage-class bug, not a data bug.

## Headless Agents and CLIs

### Tools Run by a `claude -p` Agent Must Be Non-Interactive

An automation flow that hands work to a `claude -p` agent runs with no TTY. Any CLI the agent calls that waits for interactive input (for example a `readline` "approve/edit?" prompt) hangs silently, and the agent quietly falls back to a worse path or times out. Symptom: "the tool exists and is wired up, but the good pipeline never seems to run."

Fixes:
- Give the tool an `--auto`/`--yes` flag AND turn it on automatically when `!process.stdin.isTTY`, so the tool never hangs however it is launched.
- Don't make sub-steps depend on an `ANTHROPIC_API_KEY`. Route model calls through the `claude -p` CLI (subscription auth) so the tool runs in the same keyless environment as the agent.
- Make the tested tool the canonical path. Prompts that re-describe a "manual fallback" flow drift away from it and silently lose features.

### `claude -p` is the full agentic CLI: treat it accordingly

`claude -p --dangerously-skip-permissions` is the FULL agentic Claude Code CLI, not a limited text-completion endpoint. Any pipeline that shells out to it needs these rules:

1. **CWD hygiene.** If the subprocess runs inside a repo, the sub-agent can explore that repo and add meta-commentary to its output (for example, describing the source file it was called from). For free-text generation, set the subprocess cwd to an empty, neutral directory (for example `tempfile.mkdtemp()`). For strictly parsed output (JSON extraction) the risk is lower, but the same hygiene costs little.
2. **Retry breadth.** Retry on ANY non-zero exit code AND on empty stdout, not only when stderr matches "rate" or "limit". Nested `claude -p` calls sometimes exit 1 with EMPTY stderr as a transient failure. Use exponential backoff, up to N attempts.
3. **Timeout sizing.** A fixed timeout tuned on a solo test run will SIGTERM most calls once real concurrency raises latency. A SIGTERM'd session's transcript shows a user turn and no assistant turn. Size the timeout from latency measured under the job's REAL concurrency.
4. **Set model and effort explicitly.** Headless runs inherit the host's `settings.json` model and effort level. A high inherited effort can make each call several times slower. Pass both `--model` and `--effort`.
5. **The exit code must reflect failure.** The CLI can exit 0 on a killed or empty run. Treat exit 0 with empty stdout as an error. A batch or multi-item caller must exit non-zero if ANY item failed, or its run ledger can never go red.

## Logging and Error Reporting

### Error Log Lines Ending in a Bare Colon = Logger Dropping Arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`. Extra arguments after a string message are printf interpolation values, and if the message has no `%s`/`%d`/`%o` they are **silently discarded**. Console-style calls such as `logger.error('failed:', err.message)` produce `"msg":"failed:"`: the diagnostic stops at the colon and the real error never reaches any log.

Fixing call sites one at a time doesn't work, because new ones appear with every feature. **Fix the whole class at the logger:** install a `hooks.logMethod` that appends the extras that would be dropped to the message, and test it. Canonical `(obj, msg)` and printf-style calls pass through untouched. Any repo that adopts pino should have the hook from day one.

### A pino logger configured with `transport:` breaks modules loaded outside their normal process

`pino-pretty` and multistream transports run in a worker thread that doesn't reliably start outside the long-running process your process manager launches (for example a bare `node -e` or a standalone CLI script). Before importing a service module into a standalone script, check whether it, or anything it imports, creates a pino instance with `transport:`. Split out the logger-free piece, or stub `require.cache` first.

### An empty `err.message` (AggregateError) makes a fallback string look like the real error

Node >= 20 dials a `localhost` hostname with happy-eyeballs (`::1` and `127.0.0.1` in parallel). When BOTH fail it throws an AggregateError whose `.message` is the EMPTY STRING; the real per-address errors are in `.errors`. The common idiom `err.message || "some fallback"` therefore picks the fallback and the diagnosis is lost. undici (Node's global fetch) adds to this: every connection failure is reported as the opaque `"fetch failed"`, with the real reason in `.cause`.

This is **environment-dependent**: a single-stack host resolves localhost to one address and throws a plain Error with a usable message, while a dual-stack host throws the empty-message AggregateError. A test that dials a dead port asserts different things on the two machines, so build the AggregateError by hand in the test.

1. Never format an error with `.message` alone. Use a `describeError()` that walks `.errors` and `.cause` (bound the depth, since a cause can be self-referential) and appends `code` and address:port at each level.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match the FULL flattened description. Otherwise an AggregateError carrying ECONNREFUSED looks non-transient and is treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature that the fallback fired.

### Size a retry against the dependency's recovery time, and log the cause chain

When a client retries a transport failure once after a short delay (say 30s) and then fails the job, the retry was sized for a dropped packet, not for recovery. Many dependencies take longer than that to recover normally: a recreated container refuses connections for the whole `docker compose up -d` cycle, and after an SSH reverse tunnel drops, the server can hold the dead forward for `ClientAliveInterval x ClientAliveCountMax` (for example 120s x 3 = 6 minutes) while `ExitOnForwardFailure=yes` makes every reconnect in that window exit.

- **Rule:** before picking a retry delay, name the dependency's slowest NORMAL recovery event and read its real duration from the config that controls it (systemd `RestartSec`, sshd `ClientAlive*`, a container healthcheck's `start_period`, an autoscaling cooldown). A single retry is correct only when the failure is a lost packet. Back off across a window that covers recovery, and stop early when the next sleep would run past the call's own abort deadline. Sleeping into an abort turns a diagnosable network error into a bare "timed out" and throws the cause away.
- **Rule:** log the flattened cause chain (see `describeError()` above). `TypeError: fetch failed` is identical whether the service is restarting, the tunnel dropped, or the far end reset the socket.
- **Rule:** a generic failure message shifts blame onto the user. "Task processing failed. Please try again." reads as "your input broke it." If the transport never reached the service, say the service was unreachable; the user is deciding whether to spend another rate-limited action.
- When a scaffold has been copied into several apps, check each sibling before porting the fix. Copies diverge, and some may already be fixed or have different code.

### A progress heartbeat that stores only a timestamp cannot say WHERE a job died

A heartbeat is written to answer "is this still alive?", which only needs a timestamp. The question asked later is always "where did it stop?", and the phase is the whole answer. If the heartbeat function takes a phase but stores only the time, every reaped job ends up with the same message, and the log that could have told them apart has rotated away before anyone looks.

1. Store the phase next to the timestamp, and include it in the terminal message the recovery sweep writes (`Interrupted ... (stopped during: <phase> <i>/<n>)`). Build that message in ONE function that the DB row, email, and notification all call, so the three can't disagree about one event.
2. Audit for windows with no heartbeat. Any gap between two stamps is a blind spot as large as the reaper's cutoff. A long phase should heartbeat from INSIDE (a per-item callback, throttled to about one write per minute), not only at its boundaries.
3. A pool is not bounded just because each of its units is. If one worker never settles, `Promise.all` never settles, and the job is stranded inside a LIVE process where a restart-triggered reaper never runs. Wrap the pool in a wall-clock deadline that fails open. The deadline must NOT cancel the underlying work: an orphaned promise costs a little memory, while a stranded job costs the user the entire run.
4. For a scheduled job, a lost run stays lost until the next tick, so size retries against the dependency's real recovery time.

### Log the destination you resolved to, and make reply-addresses name where the payload landed

A feature that both DELIVERS a payload somewhere and ADDRESSES a reply channel back to it has two separate ideas of "the location", and they can quietly diverge. Example: a long answer goes into a NEW overflow thread created at post time, while the reply address was taken from the job record's original thread id. Every component tests green and the user still reports the feature as broken, because a correct delivery to the wrong place looks the same as no delivery.

Signs this bug class is present:
1. The code holds a thread/channel/room id from EARLIER in the job and uses it as an address, while the actual post happens LATER through a helper that may create its own destination.
2. The posting helper returns void. A function that picks a destination and doesn't report it forces every caller to guess.

Fix: have the posting helper RETURN the surface it delivered to (null if it created none), and derive the address from that return value. Fall back to the earlier id only when the helper created no new surface. Make the abandoned surface point to the real one ("Answer: <link>").

Related rules:
- **Log the resolved destination, not the one you were handed.** A log line that prints the addressed id makes a misroute look like a healthy delivery and sends the investigation to the transport code.
- **A sent address cannot be rewritten.** Fixing the code only helps future sends. Persist the move as a redirect resolved at delivery time, bound the hops, guard against cycles, and keep every trust check on the ORIGINAL signed id, so the redirect changes the address but never the authorization.
- **Debugging tip:** when a user says "I replied and nothing showed up", don't start with the relay. Get the id of the surface the user is looking at and the id the system posted to, and compare them before reading any transport code.

## Silent Failures in Scripts and Gates

### `git symbolic-ref origin/HEAD` exits 128 when unset; under `set -euo pipefail` it kills the rest of the script

`origin/HEAD` is set by `git clone` and nothing else. `git remote add` + fetch does not set it, and nothing refreshes it later. On a checkout without it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128.

Under `set -euo pipefail`, piping that into `sed` does NOT save you: pipefail passes the 128 through the sed, and `set -e` ends the script. A trailing `2>/dev/null` hides the MESSAGE but not the exit code, so the line looks handled when it isn't. A monitoring script can die partway through on every run for weeks, skipping its alerting block, with no visible error.

**How to apply:** any command substitution that can legitimately fail needs an explicit `|| true` under `set -e`, git plumbing especially. When a long script has an unexplained partial effect, look for a non-zero exit mid-script before suspecting the logic. An end-of-script state file whose timestamp stopped changing is the cheapest proof.

### cron's PATH excludes `/usr/local/bin`; with `set -e` that kills a script silently

cron runs with `PATH=/usr/bin:/bin`. Anything in `/usr/local/bin` (often `pm2`, `node`, `npm`, and most globally installed tools) is NOT found. With `set -euo pipefail`, the first such call ends the script before it does anything. If the script is a monitor, nothing is being monitored.

A complication: `>>` updates a log file's mtime only on an actual WRITE, not on open. A job that fails before writing leaves its log at 0 bytes with the mtime frozen at its last write. A freshness checker can't tell "silently dead for weeks" from "had nothing to say".

**How to apply:** put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of any script cron runs, or set `PATH=` in the crontab. When a script works interactively but fails under cron, reproduce with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '...'` before theorizing. Never judge a job healthy from its log mtime.

### A grep-gated feature never fires when the gate pattern doesn't match real generated content

When a producer and a consumer communicate through a string or grep match on generated content, instead of a shared constant or schema, the consumer's gate can match keywords that seem obvious but that the producer's template never writes. The feature then stays completely dark: the producer writes real files, the consumer's condition never matches, and nothing logs an error. Fix: gate on a string the producer's template is guaranteed to emit (for example its fixed heading). Verify the match against a REAL generated sample, and confirm it doesn't now falsely match other files in the same directory.

### A numeric guard with mismatched units never fires, and nothing looks broken

A comparison such as `[ "$rss" -lt "$MIN_TARGET_MB" ]`, where `ps -o rss=` returns **kilobytes** and the threshold is in **megabytes**, always evaluates false. Both sides are bare integers, so the shell raises no error. A correctly converted value on a nearby line (for example a GB figure computed only for a log message) can make the code look unit-aware when the comparison isn't.

**How to apply:** check unit agreement at the comparison itself, not just at display time. Name variables with their actual unit (`rss_kb`, not `rss`) so a mismatch shows up in the diff. For any guard whose condition is rare (only met under real pressure or scale), don't take "it hasn't logged as firing" as evidence it works. Create the triggering condition once on purpose (for example a decoy process sized to cross the threshold) and confirm the branch actually runs.

### A descending threshold list scanned first-match-then-break fires the WIDEST crossed tier, not the most urgent

Tiers ordered widest first (`[30, 14, 7, 1]` days) and scanned with "first crossed and unsent tier → act → `break`" select the **widest** tier, even when the code comment says "most urgent". On the common path, where an item crosses one tier per evaluation, this never shows. It bites an item that **enters mid-range**, already past several tiers. If a per-tier dedup log records only the tier that fired, the skipped wider tiers stay unsent and fire on later ticks, sending one notification per run instead of one total.

**How to apply:** for any tier, bucket, or threshold list (rate-limit escalation, loyalty tiers, alert severity, backoff selection), collect every tier whose condition is met and unhandled, pick the most urgent by explicit comparison, and mark **all** collected tiers as handled in the same pass. Array order is a display/config concern, not a selection algorithm. Test the case where the input starts already past several tiers.

### A permanently cached value that decides whether a gate runs will silently disable it

If a gate blocks only in one state (for example "only when the repo is PUBLIC") and that state is cached forever, a flip in state leaves a stale entry that switches the gate off with no signal. Never cache the value that decides whether a gate runs without an expiry. On lookup failure, fall back to the last known value rather than UNKNOWN, and do NOT refresh the cache mtime, or one transient failure marks a stale entry fresh for another full TTL. Also: a gate can detect the correct state and still print a hardcoded conclusion further down. Read the whole message-emitting path before debugging the detection, and remove duplicated copies of shared logic instead of fixing each one separately.

### Hooks installed as copies don't change when you edit the source

Git hooks live as COPIES in each `.git/hooks` (and `init.templateDir` puts them in every new clone). Editing the source changes nothing that is already installed. After any hook edit, re-install everywhere and verify by grepping the INSTALLED copies for a marker from the new code, not by reading the source.

## Searching and Reading State

### An empty search result has two causes: the thing is absent, or the query couldn't find it

The two can't be told apart from the output, and the second is more common than it feels. Reporting "clean" without separating them asserts a negative you haven't established.

1. **Grepping the transport, not the sink.** A grep for a literal constant or function name misses calls through a local alias (`const url = process.env.X_URL`, then `fetch(url)`). Before declaring "no calls to X", trace aliases and wrapping functions.
2. **Grepping a file grep treats as binary.** See below.

Rule: before reporting "not found", prove the query could have found it. The cheapest check is to grep for a string you can *see* in the file and confirm it matches. A search that finds a known sentinel is calibrated; one that misses a sentinel you expect is itself the finding.

### One split multi-byte character makes grep treat a whole text file as binary and report nothing

If a generated file truncates lines by byte width, one cut can split a UTF-8 sequence (for example half an ellipsis). grep then classifies the file as binary and suppresses matches. `grep -n <term> file` and even `grep -c "" file` print nothing, which looks exactly like "the term isn't there". No error is shown.

- **Detect:** `python3 -c "open(P,encoding='utf-8').read()"` raises and names the byte offset. `file P` reports `data` instead of `UTF-8 Unicode text`. `grep -c $ P` and `grep -ac $ P` disagree.
- **Work around:** `grep -a`.
- **Repair:** read the bytes, remove the orphan sequence, and `decode()` the whole file to prove it is clean BEFORE writing it back.
- **Prevent:** in any generated file (index files, log summaries, digests, commit subjects), truncate by characters after decoding, never by bytes.

### A cached state API makes you report a confidently wrong number

Some state APIs report values captured at init, not live values. On Windows, WMI `Win32_VideoController`'s `CurrentHorizontalResolution`/`CurrentRefreshRate` are filled in at driver init and not re-read on a mode change, so they can report a display mode the machine left hours ago. Nothing in the output marks them as stale.

- **Two state APIs disagreeing about the same moment is not noise to average out.** It means at least one isn't reading live state. Go to the authoritative source instead of choosing between convenient ones.
- For any state you will REPORT or base a decision on, prefer the API whose contract is "read the live value now". On Windows, use `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)` rather than `Win32_VideoController` for display mode. The same trap exists for anything cached at init: WMI `Win32_*` snapshots, `/proc` values sampled once, ORM caches, any `Get-*` that returns a driver-reported struct.
- Confirm the fix with corroboration, not by re-reading the same API: restart the consumer and check that it reports the expected value, and look in its earlier logs for proof of what it was asking for.

## Runtime and UI

### Browser CDP Timeout Recovery: Kill + Restart

When a service calls a browser-automation CLI and gets "Timeout waiting for browser response", the Chrome/CDP session is stuck, not just slow. Retrying stacks up calls and recovers nothing. Recovery:

1. Detect that specific timeout string in your error handler.
2. Kill all chrome/chromium processes: `pkill -f chrome || true`.
3. Restart the browser-automation service through your process manager (for example `pm2 restart <browser-service>`).
4. Run a connectivity check at startup that triggers recovery *before* the main task:

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

Also raise the base CLI timeout from 60s to 120s to avoid false timeouts on slow page loads (a separate problem from CDP hangs).

### A collapsed `<details>` still mounts and renders every child

An HTML `<details>` element keeps its children in the DOM when collapsed; it only hides them. Rendering N heavy children (for example a markdown + sanitizer tree per item) inside collapsed `<details>` parses all N up front and again on every parent re-render, even if nobody opens a section. A polling loop that returns a fresh JSON string each time also defeats `React.memo` identity checks, so the content is re-parsed even when it hasn't changed. This can be the main cause of "the list page lags with many results."

**How to apply:** don't assume a closed `<details>`, accordion, `display:none`, `hidden`, or collapsible protects you from render cost. None of them unmount. Lazy-mount the child (render nothing or a light placeholder until first expand), or memoize the parsed output by content so an unchanged poll doesn't re-run the parser.

### A tab row directly above a feed reads as a filter for that feed

If a tab strip that only controls an input sits right above a result list, users read it as a filter on the list and report the list as broken. Label the tab row for what it actually controls, and give the list its own explicit filter with an "All" default. Before rewriting behavior, check the user's claim: hit-test each row with `document.elementFromPoint` at its center and check the tag/href. That tells apart "an overlay eats the tap", "this row was never a link", and "the user misread the control". The real defect may differ from the report's wording, for example pending rows rendered as a `div` with no href.
