<!-- Load when: diagnosing issues, log analysis -->
# Debugging Guidance

A systematic approach to diagnosing and fixing issues.

## The Debugging Workflow

```
0. Gather Context → 1. Reproduce → 2. Read the Error → 3. Isolate → 4. Hypothesize → 5. Verify → 6. Fix → 7. Confirm
```

### 0. Gather Existing Knowledge First

Before touching code or forming hypotheses, check whether this problem (or a closely related one) has been solved before:

- **Memory**: Read relevant feedback/project memory files. Corrections from past sessions are your highest-signal source.
- **CLAUDE.md**: The repo's CLAUDE.md documents architecture decisions and known gotchas.
- **Guidance**: Check this repo's guidance files for domain-specific rules (auth, deployment, etc.).
- **Knowledge base**: Scan your knowledge base index for cross-repo patterns.
- **Private context**: Check your private context repo for credentials, registered URIs, or infrastructure details that constrain the solution.
- **Git history**: `git log --oneline --grep="<keyword>"` to find prior fixes.

This is not optional background reading; it is the most efficient debugging step. **The previous session's fix is often already documented in memory.** Skipping this to "save time" causes multi-hour debugging loops.

### Approach Switching (15-minute rule)

If you've been trying variations of the same approach for 15+ minutes without progress:
1. Stop iterating on the current approach
2. Re-read memory/guidance for the domain (Step 0 again)
3. Spawn a debugger agent for a fresh perspective
4. Try a **fundamentally different** approach

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

### 8. After Fixing

- Remove all debug logging before committing.
- Write a regression test if possible.
- Document the root cause in the commit message.
- Update `context.md` if the fix reveals something about the environment.
- **Prefer a structural bound over a test of the one instance.** After the cause is fixed, ask "what would make this whole failure class impossible, rather than just absent?" (a size/time cap, an invariant check, a type or schema) and prove it by reintroducing the original cause and showing the bound contains it. A passing regression test only proves the known case is gone, not that the class is closed.

### 9. SQLite & Prisma Specifics

- **Database is locked**: In SQLite, concurrent writes cause locking.
  - **Fix**: Move `updateMany` or `createMany` calls OUT of loops. Consolidate into a single operation per user/batch.
  - **Pragma**: Use `PRAGMA busy_timeout=5000;` to make SQLite wait instead of failing immediately.
- **executeRawUnsafe vs queryRawUnsafe for PRAGMAs**: Use `$queryRawUnsafe` for **both** `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000`. Catch and ignore `"Execute returned results"` (it means the PRAGMA worked). Log all other errors.
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
  Also raise the memory-restart threshold to match (e.g. `max_memory_restart: '1G'`).
- **`datetime('now')` strings parse as LOCAL time in `new Date()`, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"` (space-separated, no `T`/`Z`). The ECMAScript Date parser treats that non-ISO form as local time, so rendering a stored timestamp via `new Date(created_at)` silently shifts it by the viewer's UTC offset, and can shift the displayed date near UTC midnight. This affects Prisma-on-SQLite and raw `better-sqlite3` apps alike; it's a JS Date-parsing bug, not a Prisma one.
  - **Fix**: normalize before parsing: strict-match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/` and rewrite to `` `${date}T${time}Z` ``; pass already-ISO strings through unchanged. SQL-side comparisons like `date(created_at) = utcToday` are unaffected (both sides stay UTC).
  - Verify on a non-UTC host: `new Date('2026-07-06 12:00:00').toISOString()` returns a shifted hour. If one component has this bug, grep for copies of it in sibling projects.
- **Prisma `NOT:` logical wrapper excludes NULL rows on nullable columns.** `NOT: { field: value }` compiles to SQL `NOT(col = 'value')`, which is NULL (and therefore excluded) for any row where the column IS NULL. Null-valued rows silently disappear with no error; in practice this can drop the large majority of a result set. Fix: when negating a NULLABLE column while still wanting NULL rows, use the explicit OR form: `OR: [{ field: null }, { field: { not: value } }]`. Self-review trigger: any Prisma `NOT:` filter on a nullable column, especially in queries with unexpectedly low row counts.

### 10. Prisma + PostgreSQL: Use pg.Pool, Not Raw Connection String

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

### 11. Tools Run by a `claude -p` Agent Must Be Non-Interactive

An automation flow that dispatches work to a `claude -p` agent runs with no TTY. Any CLI the agent invokes that blocks on interactive input (e.g. a `readline` "approve/edit?" prompt) will hang silently, and the agent will quietly fall back to a worse path (or time out). Symptom: "the tool exists and is wired up, but the nice pipeline never seems to actually run."

Fixes:
- Give the tool an `--auto`/`--yes` flag AND auto-enable it when `!process.stdin.isTTY`, so it never hangs regardless of how it's launched.
- Don't depend on an `ANTHROPIC_API_KEY` for sub-steps; route model calls through the `claude -p` CLI (subscription auth) so the tool runs in the same keyless environment as the agent.
- Make the tested tool the canonical path. Prompts that re-describe a "manual fallback" flow drift and silently lose features.

### 12. Browser CDP Timeout Recovery: Kill + Restart Pattern

When a service calls a browser-agent CLI and receives "Timeout waiting for browser response", the Chrome/CDP session is stuck (not just slow), and retries pile up with no recovery. Recovery requires:

1. Detect the specific timeout error string in your error handler
2. Kill all chrome/chromium processes: `pkill -f chrome || true`
3. Restart the browser-automation service via your process manager
4. Implement a startup connectivity check that triggers recovery *before* the main task:

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
  execSync('pm2 restart <browser-agent-service>');
  await new Promise(resolve => setTimeout(resolve, 3000)); // wait for startup
}
```

Also increase the base CLI timeout from 60s to 120s to avoid false-positive timeouts on slow page loads (separate from CDP hangs).

### 13. Reading a SQLite DB Another Process Is Actively Writing (WAL Mode)

When polling a SQLite database that a running app writes to (e.g. a desktop app's `*.sqlite` in WAL mode), a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot**: it reads committed WAL frames as of some earlier point and doesn't advance, even across freshly spawned reader processes. Classic symptom: "it caught the first change but never the next ones," while the process is alive and manual one-off queries look current.

Fix: open a **normal (read-write-capable) connection with `PRAGMA query_only=ON`** instead. It participates in the WAL protocol correctly and reliably sees the latest committed rows, while `query_only` guarantees you never modify the app's data. Add `.timeout <ms>` so a momentary writer lock yields a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

Second gotcha when your reader writes to the macOS clipboard: an app that pastes via the clipboard often does save→paste→**restore**, clobbering your write. Re-assert (re-`pbcopy`) for ~1s, checking `pbpaste`, to win the race.

### 14. Error Log Lines Ending in a Bare Colon = Logger Dropping Arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`. Extra args after a string message are printf interpolation values, and with no `%s`/`%d`/`%o` in the message they are **silently discarded**. Console-style calls like `logger.error('failed:', err.message)` produce `"msg":"failed:"`: the diagnostic ends at the colon and the actual error never reaches any log. Symptom while debugging: an error repeats for hours but its message trails off with `:` and nothing after.

Fixing call sites one by one does not work: audit passes leave many multi-arg sites behind, and new ones reappear with every feature. **Fix the class at the logger:** install a `hooks.logMethod` that appends would-be-dropped extras to the message, with a test. Canonical `(obj, msg)` and printf-style calls pass through untouched. Any repo that adopts pino should get the hook from day one.

### A pino logger configured with `transport:` breaks any module that pulls it in outside its normal managed process

`pino-pretty`/multistream transports run in a worker thread that doesn't reliably initialize outside the long-running process your process manager launches (e.g. a module loaded via bare `node -e`, or a standalone CLI). Before adding a service-module import to a standalone script, check whether it (or anything it imports) constructs a pino instance with `transport:`; split out the logger-free piece or stub `require.cache` first.

### `claude -p` is the full agentic CLI: run free-text calls in an empty cwd and retry on any non-zero exit or empty stdout

`claude -p --dangerously-skip-permissions` is the FULL agentic Claude Code CLI, not a constrained text-completion endpoint. Operational consequences for any pipeline that shells out to it:

1. **CWD hygiene.** When the subprocess runs with its working directory inside a repo, the spawned sub-agent can explore that repo and inject meta-commentary into its output (e.g. narrating the source path it was invoked from). For free-text generation calls, set the subprocess cwd to an empty/neutral directory (e.g. `tempfile.mkdtemp()`). For strictly parsed output (JSON extraction) the risk is lower, but the same hygiene is cheap insurance.

2. **Retry breadth.** Retry on ANY non-zero exit code AND on empty stdout, not only when stderr matches "rate"/"limit". Nested `claude -p` invocations intermittently exit 1 with an EMPTY stderr (a transient); code that only retries on rate/limit strings hard-fails on the first blip. Use exponential backoff, up to N attempts.

3. **Timeout sizing.** A fixed spawn timeout tuned against a solo test run silently SIGTERMs most calls once real concurrency raises latency. A SIGTERM'd session's transcript shows a user turn and no assistant turn. Size the timeout from measured latency under the job's REAL concurrency.

4. **Model/effort must be explicit.** Headless claude inherits the host's `settings.json` model and effort level. An inherited high effort can make each call several times slower than `--effort medium`. Pass both `--model` and `--effort` explicitly.

5. **Exit code must reflect failure.** The CLI can exit 0 on a killed or empty run; treat exit 0 with empty stdout as an error. A batch caller must exit non-zero if ANY item failed, or its run ledger can never go red.

6. **Permissions must be explicit too.** `bypassPermissions` gives a headless data-pump call full tool access (Bash, Write, every connector write), not just the reads it needs. Lock it down with `--permission-mode dontAsk` and explicit `--allowedTools`/`--disallowedTools`, and verify live rather than trusting the flags. Note that `--allowedTools` controls approval, not availability.

7. **Concurrent children sharing one config dir race the token refresh.** Fanning out several `claude -p` children against one isolated `CLAUDE_CONFIG_DIR` loses most of the batch if the token expires mid-run: every child races the same single-use refresh token, one wins, the rest exit 1 with `duration_api_ms 0`. Serialize a refresh near expiry and sync host/isolated credentials both ways; check individual rows for errors, not just the summary.

### `git symbolic-ref origin/HEAD` exits 128 when unset; under `set -euo pipefail` it silently kills the rest of the script

origin/HEAD is populated by `git clone` and nothing else: not by `git remote add` + fetch, and never refreshed afterwards. On a checkout that lacks it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128.

Under `set -euo pipefail`, piping that into sed does NOT save you: pipefail promotes the 128 past the sed, and `set -e` terminates the script. A trailing `2>/dev/null` hides the MESSAGE but not the exit code, which makes the line look handled when it is not. A monitoring script can die partway through on every run for weeks this way, never reaching its alerting block.

**How to apply:** any command substitution that can legitimately fail needs an explicit `|| true` under `set -e`, especially git plumbing. When a long script has an unexplained partial effect, check for a mid-script non-zero exit before suspecting logic. A state file written on the script's last line, frozen at a past date, is the cheapest proof.

### cron PATH excludes /usr/local/bin; with `set -e` that kills a script silently, and a silent job's log mtime never moves

cron runs with `PATH=/usr/bin:/bin`. Anything in `/usr/local/bin` (often pm2, node, npm, and globally installed tooling) is NOT found. Combined with `set -euo pipefail`, the first such call kills the script before it does anything. If the script is a monitor, nothing is being watched at all.

The compounding nuance: `>>` updates a log file's mtime only on an actual WRITE, not on open. A job that fails before producing output leaves its log at 0 bytes with the mtime frozen at its last write. A freshness checker watching that file cannot distinguish "silently dead for weeks" from "never had anything to say".

**How to apply:** put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of any script cron will run, or declare `PATH=` in the crontab. When a script works interactively but fails under cron, reproduce with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c ...` before theorising. Never conclude a job is healthy from log mtime.

### An empty `err.message` (AggregateError) makes a fallback string look like the real error

Node >= 20 dials a `localhost` hostname with happy-eyeballs (::1 and 127.0.0.1 in parallel). When BOTH fail it throws an AggregateError whose `.message` is the EMPTY STRING, with the real per-address errors in `.errors`. So the idiom `err.message || "some fallback"` selects the fallback and the diagnosis is gone. undici compounds it: every connection failure is reported as the opaque string "fetch failed" with the real reason hidden in `.cause`.

It is ENVIRONMENT-DEPENDENT, which is why it may not reproduce locally: a single-stack host resolves localhost to one address and throws a plain Error with a usable message; a dual-stack host throws the empty-message AggregateError. A test that dials a dead port therefore asserts different things on different machines; build the AggregateError by hand in the test instead.

How to apply:
1. Never format an error with `.message` alone. Use a `describeError()` that walks `.errors` and `.cause` and appends code + address:port.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match the FULL description, or an AggregateError carrying ECONNREFUSED reads as non-transient and is treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature: it means the fallback fired, not that the error was unhelpful.

### Size a retry against the dependency's recovery time, and log the cause chain

1. **The retry must span the dependency's recovery, not a blink.** A client that retries a transport failure once, 30 seconds later, cannot survive a dependency whose normal recovery takes longer: e.g. a container being recreated refuses connections for its whole `docker compose up -d` cycle, and after an SSH reverse-tunnel drop the server holds the dead forward for up to `ClientAliveInterval x ClientAliveCountMax` while `ExitOnForwardFailure=yes` makes every reconnect inside that window exit. **Rule:** before picking a retry delay, name the dependency's slowest NORMAL recovery event and read its actual duration from the config that governs it (systemd `RestartSec`, sshd `ClientAlive*`, a container healthcheck's `start_period`, an autoscaler cooldown). A single retry is only correct when the failure is a lost packet. Back off across a window that covers the recovery, and stop early when the next sleep would outlive the call's own abort deadline; sleeping into an abort converts a diagnosable network error into a bare "timed out".

2. **Log the flattened cause chain, not `err.message`.** `TypeError: fetch failed` is identical for a mid-restart service, a dropped tunnel, and a reset socket. Walk BOTH `.cause` and `AggregateError.errors`, bound the depth (a cause can be self-referential), and include `.code` at each level. Classify transient vs permanent against the FLATTENED string.

3. **A generic failure message misattributes blame.** "Task processing failed. Please try again." reads as "your input broke it". When the transport never reached the service, say the service was unreachable; the user is deciding whether to spend another rate-limited action.

When the same client scaffold was copied into sibling projects, check each sibling before porting the fix; copies diverge.

### A progress heartbeat that stores only a timestamp cannot say WHERE a job died

A heartbeat gets written to answer "is this still alive?", which only needs a timestamp. The question actually asked later is "where did it stop?", and the phase is the whole answer. If the heartbeat function takes a phase argument but only stores the time, every reaped job gets the identical failure sentence, and the process log that could have told them apart has often rotated before anyone investigates.

How to apply:
1. Persist the phase next to the timestamp and put it in the terminal message the recovery sweep writes (e.g. "Interrupted (stopped during: sweep-board-212/419)"). Build that message from ONE function that every surface (DB row, email, chat notification) calls, so they cannot disagree about one event.
2. Audit for heartbeat-free windows. Any stretch between two stamps is a blind spot sized by the reaper's cutoff. A long phase should heartbeat from INSIDE (pass a per-item callback, throttled to about one write a minute), not only at its boundaries.
3. A pool is not bounded just because its units are. Workers with per-fetch timeouts inside a `Promise.all` still leave the whole job stranded if ONE worker never settles, inside a live process where a restart-triggered reaper never fires. Wrap the pool in a wall-clock deadline that fails open. The deadline must NOT cancel the underlying work: an orphaned promise costs a little memory, a stranded job costs the user the entire run.
4. For a job that only runs on a schedule, a lost run is lost until the next tick, so size retries against the dependency's real recovery time.

### A grep-gated feature never fires when the gate pattern doesn't match the actual generated content

When a producer writes a file and a consumer decides whether to use it via `grep -q "<keywords>"`, the gate can silently never match if the producer's real template never contains those keywords. The write side works, the read side never fires, and the feature is fully dark with no error and no log line.

**How to apply:** when a producer and consumer communicate via a string match on generated content rather than a shared constant or schema, verify the match condition against a REAL generated sample, not against the keywords that seem intuitive. Gate on a structural marker every real file contains (e.g. a fixed heading like `^## Classification:`), and confirm the old pattern fails and the new one matches on a live file.

### An empty search result has two causes: the thing is absent, or the query was incapable of finding it

These are indistinguishable from the output, and the second is far more common than it feels. Reporting "clean" without separating them is asserting a negative you did not establish.

Two patterns that produce the silent failure:
1. **Grepping the transport, not the sink.** A grep for the obvious pattern (a webhook URL constant, a function name) misses a call that uses a local alias (`const url = process.env.X_WEBHOOK_URL`, then `fetch(url)`). Before declaring "no calls to X", trace all aliases and wrapping functions.
2. **Grepping a file that grep treats as binary.** See the next section.

Rule: before reporting "not found", prove the query could have found the thing. Grep for a string you can *see* in the file and confirm it matches. A search that finds a known-present sentinel is calibrated; one that misses a sentinel is itself the finding.

### One split multi-byte character makes grep treat a whole text file as binary and report nothing, with no error

A generated file whose lines are truncated to a fixed width by bytes can cut a UTF-8 character in half, leaving an orphan sequence (e.g. `\xe2\x80` before a valid `\xe2\x80\xa6`). Two stray bytes are enough: grep classifies the file as binary and suppresses matches, so `grep -n <term> file` and even `grep -c "" file` print nothing, which reads exactly like "that term is not in the file". The same happens with embedded NUL bytes.

Detect:
- `python3 -c "open(P,encoding='utf-8').read()"` and let it raise; the exception carries the byte offset.
- `file P` reports `data` rather than `UTF-8 Unicode text`.
- `grep -c $ P` vs `grep -ac $ P` disagree.
- `grep -a` works all along; the trap is that the natural first tool fails quietly.

Repair: read bytes, splice out the orphan sequence, `decode()` to prove the whole file is clean BEFORE writing back.

Prevent: anything doing `s[:80]` on text that may contain non-ASCII (index files, log summaries, digests, commit subjects) must truncate by characters after decoding, never by bytes.

### A cached state API makes you report a confidently wrong number

Some state APIs are populated once (at driver init, at process start) and are NOT re-read on change, so they report a value the system has not been in for hours, with nothing marking it stale. Example: on Windows, WMI `Win32_VideoController` `CurrentHorizontalResolution`/`CurrentVerticalResolution`/`CurrentRefreshRate` can report a stale display mode; `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)` reads the live one.

**Two state-reading APIs disagreeing about the same instant is not noise to average out or pick the likelier value from; it means at least one is not reading live state.** Go to the authoritative source rather than adjudicating between convenient ones.

Rule: for any state you will REPORT to a user or branch a decision on, prefer the API whose contract is "read the live value now" over the one that is convenient or already in your output. The same trap exists for anything cached at init: WMI `Win32_*` snapshots, `/proc` values sampled once, ORM-level caches, any call that returns a driver-reported struct rather than querying.

Corroborate the fix from the consumer side: restart the consuming process and check that IT reports the expected value, rather than re-reading the same API.

### sqlite3 `readfile()` stores a BLOB, and a BLOB column reaches a Node app as a Buffer that 500s the page

Inserting file content with the sqlite3 CLI's `readfile()` produces a row whose `typeof(col)` is `blob`, not `text`. better-sqlite3 returns a BLOB as a Node Buffer, so a render path calling `.replace` on it dies with `TypeError: a.replace is not a function` and an HTTP 500. The insert reports success and `select length(col)` looks fine.

Rules:
1. When loading file content into SQLite from the CLI, wrap it: `CAST(readfile('/path') AS TEXT)`.
2. After any hand-written row insert into a live app's DB, check `typeof()` on the column AND fetch the rendering page, not just the row.
3. Byte length and character length differ after the cast for multi-byte text. That difference confirms UTF-8 decoding, not truncation.
4. Symptom to recognize: a Node/Next.js page that 500s with `X.replace is not a function` inside an `Array.map` right after a manual DB write is a storage-class bug, not a data bug.

### A reply-address must name where the payload landed, not a location the job was holding

A feature that both DELIVERS a payload to a location and ADDRESSES a reply channel back to it has two independent notions of "the location", and they can silently diverge. Example shape: a long answer is folded into a NEW overflow thread created at post time, while the reply-by-email address is derived from the job record's original thread id. Every component works and tests green; the reply lands in a thread the user isn't reading, so they report the feature as broken.

Tells:
1. The code holds a thread/channel/room id from EARLIER in the job (a record field, a variable captured at start) and uses it for an address, while the actual post happens LATER through a helper that may create its own destination.
2. The posting helper returns void. A function that chooses a destination and does not report it forces every caller to guess.

Fix shape: make the posting helper RETURN the surface it delivered to (null when it created none), and derive the address from that return value, falling back to the previously known id only when no new surface was made. Make the abandoned surface point at the real one ("Answer: <link>").

Follow-on rules:
- **Log the destination you resolved to, not the one you were handed.** A log line printing the addressed id makes a misroute look like a healthy relay and sends the investigation at the transport code.
- **A sent address cannot be rewritten.** Fixing the code only helps future sends. Persist the move as a redirect resolved at delivery time, bound the hops, guard against cycles, and keep every trust gate on the ORIGINAL signed id so the redirect rewrites the address and never the authorisation.

Debugging tell: when a user says "I replied and nothing showed up", get the id of the surface the user is looking at and the id the system posted to, and compare them BEFORE reading any transport code.

### A composer-style tab row directly above a feed reads as a filter for that feed

When a tab strip that only scopes an input control sits immediately above a result list, users read it as a filter on the list and report the list as broken ("X selected, cannot click on Y"). Cheap fixes: label the tab row for what it actually scopes, and give the list its own explicit filter with an "All" default. Before rewriting behaviour, prove the gating claim: hit-test each row with `document.elementFromPoint` at its centre and check the tag/href. That separates "an overlay eats the tap" from "this row was never a link" from "the user misread the control". The real defect may differ from the report's literal wording (e.g. pending rows rendered as a `div` with no href, so they were genuinely unclickable).

### A collapsed `<details>` still mounts and renders every child; "collapsed" is not "unmounted"

An HTML `<details>` element keeps its children in the DOM when collapsed; it only hides them visually. Rendering N heavy children (e.g. a `react-markdown` + `rehype-sanitize` tree per item) inside collapsed `<details>` parses all N up front, and re-parses them on every parent re-render. A polling list page that re-renders every few seconds will lag in proportion to the number of items even if no section is ever opened. A fresh JSON string on each poll also defeats naive `React.memo`/identity checks.

**How to apply:** when collapsible list items render expensive content (markdown, syntax highlighting, embedded media), either lazy-mount the child (render nothing or a lightweight placeholder until first expand) or memoize the parsed output keyed on content, so a poll that didn't change an item doesn't re-run the parser. This applies to any CSS-only hide (`display:none`, `hidden`, a closed collapsible component): none of them unmount.

### A numeric guard with mismatched units never fires, and nothing about it looks broken

Example: a memory-pressure watchdog compared a process's RSS from `ps` (which reports **kilobytes**) directly against a threshold configured in **megabytes** (`[ "$rss" -lt "$MIN_TARGET_MB" ]`). Both sides are bare integers, so the shell raises nothing; the comparison is just always false. The guard can sit live through real pressure events without ever taking its branch. A correctly converted value on an adjacent line (e.g. a GB figure for a log message) makes the code look unit-aware when the comparison isn't.

**How to apply:**
- For any untyped numeric comparison against a hardcoded threshold, check unit agreement at the comparison itself, not at display time. `ps -o rss=` returns KB regardless of what the constant is named.
- Name variables with their actual unit (`rss_kb`, not `rss`) so a mismatch is visible in the diff.
- For any guard whose fire condition is rare, don't accept "it hasn't logged as firing" as evidence it works. Construct the triggering condition once, on purpose (e.g. a decoy process sized to cross the threshold), and confirm the branch executes. A gate that structurally cannot be satisfied is indistinguishable, from a static read or a quiet run, from one that has never been triggered.

### A descending threshold list scanned first-match-then-break fires the WIDEST crossed tier, not the most urgent one

A reminder with tiers ordered widest-first (`[30, 14, 7, 1]` days), scanned with "first crossed-and-unsent tier → act → `break`", selects the widest tier, the opposite of "send the most urgent". On the common path (an item tracked from before the widest window) only one tier is crossed per evaluation, so the bug never shows.

It bites an item that enters **mid-range**, already past several tiers on its first evaluation. Compounded by per-tier dedup on a fixed cron cadence: each run marks only the ONE tier it fired, the skipped wider tiers stay unsent, and the item fires again on each following tick (30d, then 14d, then 7d, then 1d: four notifications instead of one). Each send looks individually correct.

**How to apply:** for any tier/bucket/threshold list scanned with first-match semantics (rate-limit escalation, loyalty tiers, alert severity, backoff selection), don't treat array order as the selection algorithm. Collect every tier whose condition is met and unhandled, pick the most urgent by explicit comparison (e.g. `reduce` to the minimum-days tier), and mark **all** collected tiers as handled in the same pass. Test the case where the input starts already past several tiers, not just the one-at-a-time path.

### "command not found" / "Missing script" across several sibling repos at once is usually a missing local dev environment, not a code bug

Symptoms like `vitest: not found` (exit 127), `Missing script`, or `ModuleNotFoundError` for a *direct* dependency, reproducing across **multiple unrelated repos in the same pass**, point at the shared host environment, not several simultaneous code regressions. Common causes: `node_modules` entirely or partly missing, or no Python venv (with system `pip install` blocked by PEP 668 `externally-managed-environment`). `git status`/`git log` will show clean trees, because there is no code-level cause.

**How to apply:**
- Confirm via `ls node_modules | wc -l` (JS) or whether the expected venv has the package (Python) before writing any fix.
- The fix is a **local reinstall**, not a commit: `npm ci`, or `python3 -m venv .venv && .venv/bin/pip install -r requirements.txt`. No PR, no code change.
- Verify by re-running the original failing command and reporting the real pass count, then re-verify independently (e.g. a clean subagent), since "npm ci exited 0" is not the same claim as "the tests now pass".
- If you haven't identified *why* the environments went missing, treat a recurrence as worth a fresh look rather than auto-applying the same fix.

### Parallel Bash calls that each `cd` into a different repo can race on a shared shell's cwd

The working directory persists between Bash calls, which is easy to misread as "each call gets its own cwd". Sending several `cd /repo/X && npm run build` calls in one message, intending parallelism, can race: whichever `cd` lands last decides where another call's command actually runs. Both calls return exit 0 and well-formed, passing reports; the only tell is that the outputs of two *different* commands are byte-identical (same package name, same route list, same paths). In an unattended run, a false "repo B: build OK" can be logged while repo B was never built.

**How to apply:**
- Either run per-repo calls sequentially, or make each call immune to the shared cwd: `git -C /repo/X ...`, `npm --prefix /repo/X run build`, or `(cd /repo/X && cmd)` in a subshell.
- Before trusting a batch of per-repo results, spot-check that outputs which should differ actually do. Two identical reports for different repos is the tell, not a coincidence. Re-run the suspect call alone to confirm.

### A desktop client that "keeps disconnecting" and "won't log back in" is two separate causes, not one

- **Disconnect** is often the machine sleeping. On macOS, check `pmset -g custom` (AC sleep timer) and `pmset -g log` Sleep/DarkWake lines against the client's own log timestamps, converting UTC vs local first.
- **Can't log back in** is often DNS. A machine whose only nameserver is the router can hard-fail resolution at wake before the router recovers, so the reconnect can't resolve the login host and the client latches an internal offline state its own login button can't clear. Check `scutil --dns` resolver order, and compare `dig` against the router vs a public resolver such as `1.1.1.1`.
- Quitting the app may not reset it if a background agent/helper process survives and restores the same wedged session. Reap the whole process family, preserving any auto-login config file first.
- A state readout must compare event order, not just the last error line: a stale "offline" line may already be superseded by a later successful login.

**How to apply:** treat "disconnects" and "can't reconnect" as two independent diagnoses needing separate evidence. Rule out weak-signal Wi-Fi theories with data before acting on them.
