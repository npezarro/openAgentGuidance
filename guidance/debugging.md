<!-- Load when: diagnosing issues, log analysis -->
# Debugging Guidance

A systematic way to diagnose and fix issues.

## The Debugging Workflow

```
0. Gather Context → 1. Reproduce → 2. Read the Error → 3. Isolate → 4. Hypothesize → 5. Verify → 6. Fix → 7. Confirm
```

### 0. Gather Existing Knowledge First

Before you touch code or form a hypothesis, check whether this problem (or a close relative) has already been solved:

- **Memory**: Read the relevant feedback and project memory files. Corrections from past sessions are your highest-signal source.
- **CLAUDE.md**: The repo's CLAUDE.md records architecture decisions and known gotchas.
- **Guidance**: Check this repo's guidance files for domain-specific rules (auth, deployment, and so on).
- **Knowledge base**: Scan your knowledge base index for patterns that span repos.
- **Private context repo**: Check your private context repo for credentials, registered URIs, or infrastructure details that limit what a fix can be.
- **Git history**: `git log --oneline --grep="<keyword>"` finds earlier fixes.

This step is required, not background reading. It is the cheapest debugging step there is. **The previous session's fix is often already written down in memory.** Skipping this to "save time" leads to debugging loops that run for hours.

### Approach Switching (15-minute rule)

If you've spent 15+ minutes trying variations of one approach without progress:
1. Stop iterating on that approach.
2. Re-read memory and guidance for the domain (Step 0 again).
3. Spawn a debugger agent to get a fresh view.
4. Try a **fundamentally different** approach.

Trying the same kind of fix with different values isn't debugging. It's brute force.

### 1. Reproduce the Issue

Before you touch code, confirm you can trigger the problem:
- Run the exact command or action that causes the error.
- Write down the exact error message, the stack trace, and the context.
- If you can't reproduce it, you can't be confident you fixed it.

### 2. Read the Error Fully

- Read the **entire** stack trace, not just the first line.
- Find the **first** error in a chain. Cascading failures often hide the root cause.
- Check whether the message tells you directly what's wrong. It often does.

### 3. Isolate the Problem

- **Binary search:** Comment out half the suspect code. Does the error persist?
- **Minimal reproduction:** Can a 5-line script trigger it?
- **Check boundaries:** Is the issue in your code, a dependency, or the environment?

### 4. Check the Obvious First

Rule these out before you dig deep:

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
| `EACCES` / permission denied | File ownership problem (`sudo chown`) |
| `EADDRINUSE` | Port already in use: kill the other process or pick another port |
| `TypeError: x is not a function` | Wrong import, wrong version, or `x` is undefined |
| `undefined` where you expect data | Async issue, wrong property name, or missing await |
| Works locally, fails in CI | Different Node version, missing env vars, or different OS |
| Works on first load, breaks on refresh | Client state out of sync with the server, or a stale cache |
| Script silently produces empty results | A path from JSON/jq contains `~`, which the shell doesn't expand. Use `${VAR/#\~/$HOME}` |
| `X: not found` / `Missing script` across several repos at once | Missing local dev environment, not a code bug (see below) |

### 8. After Fixing

- Remove all debug logging before you commit.
- Write a regression test if you can.
- Record the root cause in the commit message.
- Update `context.md` if the fix tells you something about the environment.
- **Prefer a structural bound over a test of the one instance.** Once the cause is fixed, ask what would make the whole class of failure impossible rather than just absent: a size or time cap, an invariant check, a type or a schema. Prove the bound works by putting the original cause back and showing the bound contains it. A passing regression test only shows the known case is gone; it doesn't show the class is closed.
- **Confirm the new test fails against the old code.** A regression test that passes on both the buggy and the fixed version proves nothing. This often happens when an earlier OR-branch short-circuits before reaching the faulty branch.

### 9. SQLite & Prisma Specifics

- **Database is locked**: In SQLite, concurrent writes cause locking.
  - **Fix**: Move `updateMany`/`createMany` calls OUT of loops. Combine them into one operation per user or batch.
  - **Pragma**: Use `PRAGMA busy_timeout=5000;` so SQLite waits instead of failing at once.
- **executeRawUnsafe vs queryRawUnsafe for PRAGMAs**: Use `$queryRawUnsafe` for **both** `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000`. Catch and ignore `"Execute returned results"`, which means the PRAGMA worked. Log every other error.
  ```ts
  prisma.$queryRawUnsafe(`PRAGMA journal_mode=WAL;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("WAL enable failed:", err);
  });
  prisma.$queryRawUnsafe(`PRAGMA busy_timeout=5000;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("busy_timeout failed:", err);
  });
  ```
- **SQLite in Next.js needs `connection_limit=1`.** Next.js spawns several worker threads. Without this setting they compete for the SQLite file and you get "Database is locked". Add it to DATABASE_URL:
  ```
  DATABASE_URL="file:./production.db?connection_limit=1&timeout=30&pool_timeout=30"
  ```
- **Prisma singleton: always assign to global, even in production.** The common guard `if (process.env.NODE_ENV !== 'production')` before `globalForPrisma.prisma = prisma` is wrong. Next.js worker threads reload modules without reinitializing globals, which can cause an OOM crash loop. Remove the guard:
  ```ts
  export const prisma = globalForPrisma.prisma || createPrisma();
  globalForPrisma.prisma = prisma;  // always, not just in dev
  ```
- **Next.js apps running out of memory under load:** Raise the heap in your process manager config, for example:
  ```js
  env: { NODE_OPTIONS: '--max-old-space-size=1024' }
  ```
  Raise any memory-restart threshold to match (for example `1G`).
- **`new Date()` parses `datetime('now')` strings as LOCAL time, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"` (space-separated, no `T` or `Z`). JavaScript's Date parser treats that non-ISO form as local time, so `new Date(created_at)` quietly shifts a stored timestamp by the viewer's UTC offset. Near UTC midnight it can also shift the displayed date. This is a JS Date-parsing bug, so it hits Prisma-on-SQLite and raw `better-sqlite3` alike. Check every copy of a shared timestamp component, because cloned components carry the same bug.
  - **Fix**: Normalize before parsing. Strictly match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/` and rewrite it to `` `${date}T${time}Z` ``; pass strings that are already ISO through unchanged. SQL-side comparisons like `date(created_at) = utcToday` aren't affected, since both sides stay UTC.
  - Check it: on a non-UTC host, `new Date('2026-07-06 12:00:00').toISOString()` won't return `12:00Z`.
- **Prisma's `NOT:` wrapper drops NULL rows on nullable columns.** `NOT: { field: value }` compiles to SQL `NOT(col = 'value')`. For any row where the column IS NULL that expression is NULL, so the row is excluded. Null rows vanish from the results with no error, and this can silently drop most of a table. Fix: when you negate a NULLABLE column and still want NULL rows, use the explicit OR form: `OR: [{ field: null }, { field: { not: value } }]`. Review trigger: any Prisma `NOT:` filter on a nullable column, especially in a query whose row count is surprisingly low.
- **sqlite3 CLI `readfile()` stores a BLOB, and a BLOB column reaches Node as a Buffer.** `better-sqlite3` returns a BLOB as a `Buffer`, so render code that calls `.replace` on it throws `TypeError: x.replace is not a function` and the page returns 500. The insert reports success, and `length()` looks fine.
  1. When you load file content from the CLI, wrap it: `CAST(readfile('/path') AS TEXT)`.
  2. After any hand-written insert into a live app's DB, check `typeof()` on the column AND load the page that renders it.
  3. After the cast, byte length and character length differ when the text has multi-byte characters. That shows it decoded as UTF-8; it isn't truncation.
  4. Symptom to recognize: a Node page that 500s with `X.replace is not a function` inside an `Array.map` right after a manual DB write. That's a storage-class bug, not a data bug.

### 10. Prisma + PostgreSQL: Use pg.Pool, Not Raw Connection String

When you use `@prisma/adapter-pg` (PrismaPg), pass a `pg.Pool` instance so you control the connection pool:

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

### 11. Tools Run by a `claude -p` Agent Must Be Non-Interactive

An automation flow that hands work to a `claude -p` agent runs with no TTY. If any CLI the agent calls blocks on interactive input (for example a `readline` "approve/edit?" prompt), it hangs silently, and the agent quietly falls back to a worse path or times out. Symptom: the tool exists and is wired up, but the good pipeline never seems to run.

Fixes:
- Give the tool an `--auto`/`--yes` flag AND turn it on automatically when `!process.stdin.isTTY`, so it never hangs however it's launched.
- Don't make sub-steps depend on an `ANTHROPIC_API_KEY`. Route model calls through the `claude -p` CLI (subscription auth) so the tool runs in the same keyless environment as the agent.
- Make the tested tool the canonical path. Prompts that re-describe a "manual fallback" flow drift and silently lose features.

### 12. `claude -p` Is the Full Agentic CLI

`claude -p --dangerously-skip-permissions` is the FULL agentic Claude Code CLI, not a limited text-completion endpoint. Any pipeline that shells out to it should follow these rules:

1. **CWD hygiene.** If the subprocess runs with its working directory inside a repo, the sub-agent can explore that repo and put commentary about it into the output (for example, narrating the source path it was called from). For free-text generation calls, set the cwd to an empty, neutral directory (for example `tempfile.mkdtemp()`). For calls whose output is strictly parsed (JSON extraction) the risk is lower, but the same hygiene is cheap insurance.
2. **Retry breadth.** Retry on ANY non-zero exit AND on empty stdout, not only when stderr matches "rate"/"limit". Nested `claude -p` calls sometimes exit 1 with EMPTY stderr as a transient failure. Use exponential backoff, up to N attempts.
3. **Timeout sizing.** A fixed timeout tuned on a solo test run will SIGTERM most calls once real concurrency raises latency. A SIGTERM'd session's transcript shows a user turn and no assistant turn. Size the timeout from latency measured at the job's REAL concurrency.
4. **Model and effort must be explicit.** Headless claude inherits the host's `settings.json` model and effort level. A high inherited effort can make calls several times slower. Pass both `--model` and `--effort`.
5. **Exit code must reflect failure.** The CLI can exit 0 on a killed or empty run, so treat exit 0 with empty stdout as an error. A batch caller must exit non-zero if ANY item failed, or its run ledger can never go red.
6. **Permissions must be explicit too.** `bypassPermissions` gives a headless data-pump call full tool access (Bash, Write, every connector write), not just the reads it needs. Lock it down with `--permission-mode dontAsk` plus explicit `--allowedTools`/`--disallowedTools`, and check live behavior rather than trusting the flags. `--allowedTools` controls approval, not availability.
7. **Concurrent children that share one config dir race the token refresh.** If you fan out several `claude -p` children against one isolated `CLAUDE_CONFIG_DIR` and the token expires mid-run, every child races for the same single-use refresh token. One wins, and the rest exit 1 with `duration_api_ms 0`. Serialize a refresh when expiry is near, sync host and isolated credentials both ways, and check each row for errors, not just the summary table.

### 13. Browser CDP Timeout Recovery: Kill + Restart

When a service calls a browser-automation CLI and gets "Timeout waiting for browser response", the Chrome/CDP session is stuck, not just slow. Retries pile up with no recovery. To recover:

1. Detect that specific timeout string in your error handler.
2. Kill all chrome/chromium processes: `pkill -f chrome || true`
3. Restart the browser-agent service through your process manager.
4. Add a startup connectivity check that triggers recovery *before* the main task:

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

Also raise the base CLI timeout (for example from 60s to 120s) so slow page loads don't look like CDP hangs.

### 14. Reading a SQLite DB Another Process Is Actively Writing (WAL Mode)

When you poll a SQLite database that a running app writes to in WAL mode, a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot**. It reads committed WAL frames as of some earlier point and doesn't advance, even across freshly spawned reader processes. Classic symptom: "it caught the first change but never the next ones," while the process is alive and one-off manual queries look current.

Fix: open a **normal (read-write-capable) connection with `PRAGMA query_only=ON`**. It takes part in the WAL protocol correctly and sees the latest committed rows, and `query_only` guarantees you never change the app's data. Add `.timeout <ms>` so a brief writer lock causes a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

A second gotcha if your reader writes to the macOS clipboard: an app that pastes through the clipboard often does save → paste → **restore**, which overwrites your write. Re-assert it (re-run `pbcopy`) for about 1s, checking `pbpaste`, so you win the race.

## Logging and Error Reporting

### Error log lines ending in a bare colon mean the logger is dropping arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`. Extra arguments after a string message are printf interpolation values, and if the message has no `%s`/`%d`/`%o` they are **silently discarded**. A console-style call like `logger.error('failed:', err.message)` produces `"msg":"failed:"`: the output stops at the colon and the real error never reaches any log. Symptom: an error repeats, but its message ends in `:` with nothing after it.

Fixing call sites one at a time doesn't work, because new ones appear with every feature. **Fix the whole class at the logger:** install a `hooks.logMethod` that appends the extras that would be dropped to the message, and test it. Canonical `(obj, msg)` calls and printf-style calls pass through unchanged. Any repo that adopts pino should get the hook from day one.

### A pino logger configured with `transport:` breaks modules loaded outside the long-running process

`pino-pretty` and multistream transports run in a worker thread that doesn't reliably start outside the long-running process your process manager launches (for example under bare `node -e` or in a standalone CLI script). Before you import a service module into a standalone script, check whether it, or anything it imports, builds a pino instance with `transport:`. Split out the logger-free piece, or stub `require.cache` first.

### An empty `err.message` (AggregateError) makes a fallback string look like the real error

Node 20 and later connect to a `localhost` hostname with happy-eyeballs (`::1` and `127.0.0.1` in parallel). When BOTH fail, Node throws an AggregateError whose `.message` is the EMPTY STRING; the real per-address errors are in `.errors`. So the common idiom `err.message || "some fallback"` picks the fallback, and the diagnosis is lost. undici makes it worse: it reports every connection failure as the opaque string `"fetch failed"` and hides the real reason in `.cause`.

It depends on the environment, which is why it won't reproduce locally. A single-stack host resolves localhost to one address and throws a plain Error with a usable message. A dual-stack host throws the empty-message AggregateError. A test that dials a dead port therefore asserts different things on different machines, so build the AggregateError by hand in the test.

How to apply:
1. Never format an error with `.message` alone. Use a `describeError()` that walks `.errors` and `.cause` (with a depth limit, since a cause can point back to itself) and appends `code` plus `address:port` at each level.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match the FULL flattened description. Otherwise an AggregateError carrying ECONNREFUSED reads as non-transient and gets treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature. It means the fallback fired, not that the error was unhelpful.

### Size a retry against the dependency's recovery time

A single retry 30 seconds after a transport failure only covers a lost packet. It can't span a container recreate (connections are refused for the whole `up -d` cycle) or an SSH reverse-tunnel reconnect (the server can hold the dead session's forward for `ClientAliveInterval x ClientAliveCountMax`, and `ExitOnForwardFailure=yes` makes every reconnect inside that window fail).

Rules:
1. Before you pick a retry delay, name the dependency's slowest NORMAL recovery event and read its actual duration from the config that governs it (systemd `RestartSec`, sshd `ClientAlive*`, a container healthcheck's `start_period`, an autoscaling cooldown). Back off across a window that covers that recovery.
2. Stop early if the next sleep would outlast the call's own abort deadline. Sleeping into an abort turns a diagnosable network error into a bare "timed out" and throws away the cause.
3. Log the flattened cause chain (see above). Otherwise "service mid-restart", "tunnel dropped" and "socket reset mid-body" all log as the same `TypeError: fetch failed`.
4. Make user-facing failure messages honest. "Task processing failed, please try again" reads as "your input broke it". If the transport never reached the service, say the service was unreachable; the user is deciding whether to spend another rate-limited action.
5. When you fix this in one app, check sibling apps built from the same scaffold. Scaffolds drift, so check each one before porting the fix.

### A progress heartbeat that stores only a timestamp can't say WHERE a job died

A reaper that reaps on silence since `last_progress_at` is correct. But if the heartbeat function receives the phase name and stores only the time, then later all you know is "last heartbeat 18 minutes in". Process logs rotate before anyone looks, and every reaped job carries the same sentence.

Why: a heartbeat gets written to answer "is this still alive?", which only needs a timestamp. The question you actually ask later is "where did it stop?", and the phase is the whole answer to that. One UPDATE can serve both, and the diagnosis half costs nothing.

How to apply:
1. Persist the phase next to the timestamp, and include it in the terminal message the recovery sweep writes (`Interrupted ... (stopped during: <phase> <i>/<n>)`). Build that message in ONE function that the DB row, the email and the notification all call, so the three can't disagree about one event.
2. Audit for windows with no heartbeat. Any stretch between two stamps is a blind spot as long as the reaper's cutoff. A long phase should heartbeat from INSIDE (a per-item callback, throttled to about one write a minute), not only at its start and end.
3. A pool isn't bounded just because each unit is. One worker that never settles makes `Promise.all` never settle and strands the job inside a LIVE process, where a reaper triggered by restarts never fires. Wrap the pool in a wall-clock deadline that fails open. The deadline must NOT cancel the underlying work: an orphaned promise costs a little memory, while a stranded job costs the user the whole run.
4. For a job that only runs on a schedule, a lost run stays lost until the next tick, so size retries against the dependency's real recovery time.

### A reply address must name where the payload landed, not a location the job was holding

Some features both DELIVER a payload somewhere and ADDRESS a reply channel back to it. They then have two separate notions of "the location", and the two can silently diverge. For example, a long answer is folded into a NEW overflow thread at post time, while the reply-to address comes from the job record's original thread id. Every component tests green, and the user still reports the feature as broken, because a correct delivery to the wrong place looks the same as no delivery.

Signs this bug is present:
1. The code holds a thread/channel/room id from EARLIER in the job and uses it for an address, while the actual post happens LATER through a helper that may create its own destination.
2. The posting helper returns void. A function that chooses a destination and doesn't report it forces every caller to guess.

Fix: make the posting helper RETURN the surface it delivered to (null if it didn't create one), and derive the address from that return value. Fall back to the earlier id only when the helper created nothing new. Make the abandoned surface point at the real one ("Answer: <link>").

Follow-on rules:
- **Log the destination you resolved to, not the one you were handed.** A log line that prints the addressed id makes a misroute look like a healthy relay and sends the investigation to the transport code.
- **A sent address can't be rewritten.** Fixing the code only helps future sends. Persist the move as a redirect resolved at delivery time, limit the number of hops and guard against cycles, and keep every trust check on the ORIGINAL signed id, so the redirect changes the address but never the authorization.

Debugging tell: when a user says "I replied and nothing showed up", don't start with the relay. Get the id of the surface the user is looking at and the id the system posted to, and compare them BEFORE you read any transport code.

## Silent Failures: Gates, Searches, and Scripts That Never Fire

### An empty search result has two causes

The thing may be absent, or the query may have been unable to find it. The output looks identical either way, and the second cause is far more common than it feels. Reporting "clean" without telling the two apart asserts a negative you haven't established.

Two common ways it happens:
1. **Grepping the transport, not the sink.** A grep for the obvious pattern (a URL constant, a function name) misses a call that uses a local variable assigned one expression away (`const url = process.env.X_URL`, then `fetch(url)`). Trace aliases and wrapper functions before declaring "no calls to X".
2. **Grepping a file that grep treats as binary.** See the next section.

Rule: before you report "not found", prove the query could have found it. Grep for a string you can *see* in the file and confirm it matches. A search that finds a known-present sentinel is calibrated. If it returns nothing for a sentinel you expected, that is your finding.

### One split multi-byte character makes grep treat a text file as binary and report nothing

If a generated file truncates lines by bytes and cuts a UTF-8 character in half, grep classifies the whole file as binary and suppresses matches. You get no error. `grep -n <term> file` and even `grep -c "" file` print nothing, which reads exactly like "the term isn't there".

- Detect: `python3 -c "open(P,encoding='utf-8').read()"` raises with the byte offset. `file P` reports `data` instead of `UTF-8 Unicode text`. `grep -c $ P` and `grep -ac $ P` disagree.
- Work around: `grep -a`, or python with `errors='replace'`.
- Repair: read the bytes, splice out the orphan sequence, and `decode()` the whole buffer to prove it's clean BEFORE you write it back.
- Prevent: anything that truncates text to a width (index files, log summaries, digests, commit subjects, `s[:80]`) must truncate by characters after decoding, never by bytes.

### A grep-gated feature never fires when the gate pattern doesn't match the real generated content

A producer writes files from a template, and a consumer gates on `grep -q "<keywords>"` against those files. If the template never contains those keywords, the read side never matches. The feature is completely dark: no error, no log line, no symptom.

Lesson: when a producer and consumer communicate through a string match on generated content instead of a shared constant or schema, test the match condition against a REAL generated sample, not against the keywords that seem intuitive. Prefer matching a structural line every real file contains (for example a fixed heading), and check that existing files that shouldn't match still don't.

### A numeric guard with mismatched units never fires, and nothing looks broken

A guard compared a process's RSS from `ps -o rss=` (**kilobytes**) directly with a threshold configured in **megabytes** (`[ "$rss" -lt "$MIN_TARGET_MB" ]`). Both sides are bare integers, so the shell raises no error. The comparison is always false, and the branch never runs, even under real pressure. A correctly converted value on a nearby line (computed only for a log message) made the code look unit-aware.

How to apply:
- In any bash (or other untyped numeric) comparison against a hardcoded threshold, check that the units agree at the comparison itself, not just in display code.
- Name variables with their unit (`rss_kb`, not `rss`) so a mismatch shows up in the diff.
- For a guard whose condition is rare, "it hasn't logged as firing" is not evidence it works. Create the triggering condition once on purpose (for example a decoy process sized to cross the threshold) and confirm the branch runs.

### A descending threshold list scanned first-match-then-break fires the WIDEST crossed tier, not the most urgent

Tiers ordered widest-first (`[30, 14, 7, 1]` days) and scanned with "first crossed-and-unsent tier → act → `break`" select the widest tier, which contradicts the usual intent ("send the most urgent"). On the common path it's invisible: an item tracked from before the widest window crosses one tier per evaluation. It bites an item that enters mid-range, already past several tiers. With per-tier dedup on a fixed cron cadence, each run logs only the tier it fired, the skipped wider tiers stay unsent, and the item fires once per tick for each remaining tier.

How to apply: any tier, bucket or threshold list scanned with first-match semantics (rate-limit escalation, discount tiers, alert severity, backoff selection) must choose by **explicitly comparing the crossed candidates**, not by trusting the array's order. Collect every tier that is met and unhandled, fire the most urgent one, and mark **all** collected tiers handled in the same pass. Test an input that starts already past several tiers, not just one that crosses them one at a time.

### `git symbolic-ref origin/HEAD` exits 128 when unset; under `set -euo pipefail` it silently kills the script

`origin/HEAD` is set by `git clone` and nothing else. It isn't set by `git remote add` + fetch, and it's never refreshed. On a checkout without it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128.

Under `set -euo pipefail`, piping that into `sed` doesn't help: pipefail passes the 128 through the pipe, and `set -e` ends the script. A trailing `2>/dev/null` hides the MESSAGE but not the exit code, so the line looks handled when it isn't. Everything after that line, including any alerting at the end of the script, silently never runs.

How to apply: any command substitution that can legitimately fail needs an explicit `|| true` under `set -e`, especially git plumbing. When a long script shows an unexplained partial effect, look for a mid-script non-zero exit before you suspect the logic. A state file written on the script's last line with a frozen mtime is the cheapest proof.

### cron's PATH excludes `/usr/local/bin`; with `set -e` that kills a script silently

cron runs with `PATH=/usr/bin:/bin`. Anything in `/usr/local/bin` (often node, npm, process managers, globally installed tools) isn't found, and with `set -euo pipefail` the first such call kills the script before it does anything. If the script is a monitor, nothing is being monitored.

The part worth remembering: `>>` updates a log file's mtime only on an actual WRITE, not on open. A job that dies before producing output leaves its log at 0 bytes with the mtime frozen at its last write. A freshness checker can't tell "silently dead for weeks" from "had nothing to say".

How to apply:
- Put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of any script cron runs, or set `PATH=` in the crontab.
- When a script works interactively but fails under cron, reproduce with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c '...'` before you theorize.
- Never conclude a job is healthy from its log's mtime.

### A cached state API makes you report a confidently wrong number

Some state APIs fill in their values at init and never re-read them. For example, Windows WMI `Win32_VideoController` `Current*` fields are set at driver init and don't change when the display mode changes, so they can report a resolution the machine left hours ago. Nothing in the output marks the value as stale.

Rule: **two state-reading APIs that disagree about the same moment aren't noise to average out.** At least one isn't reading live state, and the question is which. For any state you'll REPORT or branch on, prefer the API whose contract is "read the live value now" over the convenient one. On Windows, prefer `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)` over `Win32_VideoController` for the display mode. The same trap applies to anything cached at init: WMI snapshots, `/proc` values sampled once, ORM caches, driver-reported structs.

Confirm the fix through a different source, not by re-reading the same API: for example, restart the consumer and check what it reports, or find log evidence of what it requested.

## UI and Rendering

### A tab row directly above a feed reads as a filter for that feed

A tab strip that only scopes an input control, placed right above a result list, gets read as a filter on the list. Users then report the list as broken ("X is selected, I can't click Y"). Fixes: label the tab row for what it actually scopes, and give the list its own explicit filter with an "All" default.

Before you rewrite behavior, test the claim. Hit-test each row with `document.elementFromPoint` at its center and check the tag and href. That separates "an overlay eats the tap", "this row was never a link" and "the user misread the control". The real defect may differ from the report's wording, for example pending rows rendered as a `div` with no href.

### A collapsed `<details>` still mounts and renders every child

A collapsed `<details>` element keeps its children in the DOM and only hides them with CSS. If you render N heavy children (for example a markdown + sanitizer tree per item) inside collapsed `<details>`, all N get parsed up front, and parsed again on every parent re-render, even if nobody opens anything. A polling refresh that produces a new JSON string each tick also defeats `React.memo` and identity checks.

How to apply: when each item in a list of collapsible items renders expensive content (markdown, syntax highlighting, embedded media), lazy-mount the child (render nothing or a light placeholder until it's first opened), or memoize the parsed output by content so an unchanged item isn't re-parsed. This applies to any CSS-only hide (`display:none`, `hidden`, a closed collapsible component): none of them unmount, so none of them avoid the render cost.

## Environment Issues

### "command not found" / "Missing script" across several sibling repos at once is usually a missing local environment, not a code bug

If `npm test` fails with `vitest: not found` (exit 127), `Missing script`, or `ModuleNotFoundError` for a *direct* dependency, check whether the tool or package itself can't be found. If that same failure shows up in **several unrelated repos on the same pass**, suspect the shared host environment, not several simultaneous code regressions. Clean `git status`/`git log` output that explains nothing is another hint.

How to apply:
1. Confirm before writing any fix: `ls node_modules | wc -l` (JS), or check whether the expected venv/interpreter has the package installed (Python). System `pip install` may be blocked by PEP 668 (`externally-managed-environment`), which is a sign a venv is missing.
2. The fix is a **local reinstall**, not a commit: `npm ci` (node_modules is gitignored), or `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`. No PR, no code change.
3. Verify by re-running the original failing command and quoting the real pass count. "npm ci exited 0" is a different claim from "the tests now pass". Re-check independently in a clean subagent if you can.
4. Don't assume the environment is stable afterwards. If you never found why the dependencies went missing, a recurrence deserves a fresh look rather than a blind re-run of the same fix.
