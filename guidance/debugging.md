<!-- Load when: diagnosing issues, log analysis -->
# Debugging Guidance

A systematic approach to diagnosing and fixing issues.

## The Debugging Workflow

```
0. Gather Context → 1. Reproduce → 2. Read the Error → 3. Isolate → 4. Hypothesize → 5. Verify → 6. Fix → 7. Confirm
```

### 0. Gather Existing Knowledge First

Before you touch code or form a hypothesis, check whether this problem, or a close relative, has already been solved:

- **Memory**: Read the relevant feedback and project memory files. Corrections from past sessions are your highest-signal source.
- **CLAUDE.md**: The repo's CLAUDE.md records architecture decisions and known gotchas.
- **Guidance**: Check this repo's domain-specific guidance files (auth, deployment, and so on).
- **Knowledge base**: Scan your knowledge base index for patterns that span repos.
- **Private context**: Check your private context repo for credentials, registered URIs, or infrastructure details that limit which fixes are possible.
- **Git history**: `git log --oneline --grep="<keyword>"` finds prior fixes.

This step is required. It is the most efficient debugging step you have. **The previous session's fix is often already written down in memory.** Skipping this to "save time" leads to debugging loops that last hours.

### Approach Switching (15-minute rule)

If you have spent 15+ minutes trying variations of the same approach without progress:
1. Stop iterating on the current approach.
2. Re-read the memory and guidance for the domain (Step 0 again).
3. Spawn a debugger agent for a fresh perspective.
4. Try a **fundamentally different** approach.

Repeating the same kind of fix with different values is brute force, not debugging.

### 1. Reproduce the Issue

Confirm you can trigger the problem before you touch code:
- Run the exact command or action that causes the error.
- Note the exact error message, stack trace, and context.
- If you can't reproduce it, you can't be confident you fixed it.

### 2. Read the Error Fully

- Read the **entire** stack trace, not just the first line.
- Look for the **first** error in a chain. Cascading failures often hide the root cause.
- Check whether the error message states the problem directly. It often does.

### 3. Isolate the Problem

- **Binary search:** Comment out half the suspect code. Does the error persist?
- **Minimal reproduction:** Can you trigger it with a 5-line script?
- **Check boundaries:** Is the problem in your code, a dependency, or the environment?

### 4. Check the Obvious First

Rule these out before digging deeper:

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
| Works on first load, breaks on refresh | Client-side state out of sync with server, stale cache |
| Script silently produces empty results | Path from JSON/jq contains `~`, which the shell does not expand. Use `${VAR/#\~/$HOME}` |

### 8. After Fixing

- Remove all debug logging before committing.
- Write a regression test if you can.
- Put the root cause in the commit message.
- Update `context.md` if the fix reveals something about the environment.
- **Prefer a structural bound over a test of the one instance.** Once the cause is fixed, ask what would make the whole failure class impossible rather than just absent: a size or time cap, an invariant check, a type or schema. Prove it by reintroducing the original cause and showing the bound contains it. A passing regression test only proves the known case is gone. It does not prove the class is closed.

### 9. SQLite & Prisma Specifics

- **Database is locked**: In SQLite, concurrent writes cause locking.
  - **Fix**: Move `updateMany` or `createMany` calls out of loops. Consolidate them into one operation per user or batch.
  - **Pragma**: Use `PRAGMA busy_timeout=5000;` so SQLite waits instead of failing immediately.
- **executeRawUnsafe vs queryRawUnsafe for PRAGMAs**: Use `$queryRawUnsafe` for **both** `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000`. Catch and ignore `"Execute returned results"`, which means the PRAGMA worked. Log every other error.
  ```ts
  prisma.$queryRawUnsafe(`PRAGMA journal_mode=WAL;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("WAL enable failed:", err);
  });
  prisma.$queryRawUnsafe(`PRAGMA busy_timeout=5000;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("busy_timeout failed:", err);
  });
  ```
- **Next.js on SQLite needs `connection_limit=1`.** Next.js spawns multiple worker threads. Without this limit they compete for the SQLite file and cause "Database is locked". Add it to DATABASE_URL:
  ```
  DATABASE_URL="file:./production.db?connection_limit=1&timeout=30&pool_timeout=30"
  ```
  Leaving this out can take many commits of trial and error to stabilize.
- **Prisma singleton: always assign to global, even in production.** The common guard `if (process.env.NODE_ENV !== 'production')` before `globalForPrisma.prisma = prisma` is wrong. Next.js worker threads reload modules without reinitializing globals, so each reload creates a new client, and this can end in an OOM crash loop. Remove the guard:
  ```ts
  export const prisma = globalForPrisma.prisma || createPrisma();
  globalForPrisma.prisma = prisma;  // always, not just in dev
  ```
- **Next.js apps OOMing under load:** Raise the heap in your process manager config (for example a PM2 ecosystem file):
  ```js
  env: { NODE_OPTIONS: '--max-old-space-size=1024' }
  ```
  Raise the memory-restart threshold to match (for example `max_memory_restart: '1G'`).
- **`datetime('now')` strings parse as LOCAL time in `new Date()`, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"`: space-separated, with no `T` or `Z`. The ECMAScript Date parser treats that non-ISO form as local time. So `new Date(created_at)` silently shifts a stored timestamp by the viewer's UTC offset, and near UTC midnight it can show the wrong date. This affects Prisma-on-SQLite and raw `better-sqlite3` apps equally, because the bug is in JS Date parsing, not in Prisma.
  - **Fix**: Normalize before parsing. Strictly match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/` and rewrite it to `` `${date}T${time}Z` ``. Pass strings that are already ISO through unchanged. SQL-side comparisons such as `date(created_at) = utcToday` are unaffected, since both sides stay UTC.
  - Verify with: `new Date('2026-07-06 12:00:00').toISOString()` returns `19:00Z` on a host in UTC-7. If the same timestamp component was copied into sibling apps, grep for it and fix every copy.
- **Prisma's `NOT:` wrapper excludes NULL rows on nullable columns.** `NOT: { field: value }` compiles to SQL `NOT(col = 'value')`. For any row where the column IS NULL, that expression is NULL, so the row is excluded. Those rows disappear from the result with no error. Real case: `NOT: { accountStatus: "closed" }` dropped every account whose status was null and returned about 27% of the rows. Fix: when negating a NULLABLE column and you still want NULL rows, use the explicit OR form: `OR: [{ field: null }, { field: { not: value } }]`. Self-review trigger: any Prisma `NOT:` filter on a nullable column, especially in a query whose row count is unexpectedly low.

### 10. Prisma + PostgreSQL: Use pg.Pool, Not Raw Connection String

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

### 11. Tools Run by a `claude -p` Agent Must Be Non-Interactive

An automation flow that hands work to a `claude -p` agent runs without a TTY. Any CLI the agent calls that waits for interactive input (for example a `readline` "approve/edit?" prompt) hangs silently. The agent then quietly falls back to a worse path or times out. Symptom: "the tool exists and is wired up, but the good pipeline never seems to run."

Fixes:
- Give the tool an `--auto`/`--yes` flag AND turn it on automatically when `!process.stdin.isTTY`, so the tool never hangs however it is launched.
- Don't make sub-steps depend on an `ANTHROPIC_API_KEY`. Route model calls through the `claude -p` CLI (subscription auth) so the tool runs in the same keyless environment as the agent.
- Make the tested tool the canonical path. Prompts that re-describe a "manual fallback" flow drift over time and silently drop features.

### 12. Browser CDP Timeout Recovery: Kill + Restart Pattern

When a service calls a browser-agent CLI and gets "Timeout waiting for browser response", the Chrome/CDP session is stuck, not just slow. Retrying without recovery just piles up more hung attempts. To recover:

1. Detect that specific timeout error string in your error handler.
2. Kill all chrome/chromium processes: `pkill -f chrome || true`
3. Restart the browser-agent service through your process manager (for example `pm2 restart browser-agent`).
4. Add a startup connectivity check that runs recovery *before* the main task:

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
  execSync('pm2 restart browser-agent');
  await new Promise(resolve => setTimeout(resolve, 3000)); // wait for startup
}
```

Also raise the base CLI timeout from 60s to 120s. This avoids false timeouts on slow page loads, which are a separate problem from CDP hangs.

### 13. Reading a SQLite DB Another Process Is Actively Writing (WAL Mode)

When you poll a SQLite database that a running app writes to (for example an Electron app's `*.sqlite` in WAL mode), a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot**. It reads the committed WAL frames as of some earlier point and never advances, even across newly spawned reader processes. Classic symptom: "it caught the first change but never the later ones," while the process is alive and one-off manual queries look current.

Fix: open a **normal (read-write-capable) connection with `PRAGMA query_only=ON`** instead. That connection takes part in the WAL protocol correctly and reliably sees the latest committed rows, and `query_only` guarantees you never modify the app's data. Add `.timeout <ms>` so a brief writer lock produces a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

Second gotcha if your reader writes to the macOS clipboard: an app that pastes through the clipboard often does save → paste → **restore**, which overwrites your write. To win the race, re-assert (`pbcopy` again) for about 1s, checking with `pbpaste`.

### 14. Error Log Lines Ending in a Bare Colon = Logger Dropping Arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`. Any extra arguments after a string message are printf interpolation values, and if the message has no `%s`/`%d`/`%o` they are **silently discarded**. A console-style call like `logger.error('failed:', err.message)` logs `"msg":"failed:"`. The line ends at the colon and the actual error never reaches any log. Symptom while debugging: an error keeps repeating, but its message stops at `:` with nothing after it.

Fixing call sites one at a time does not work. Audit passes miss sites, and every new feature adds more. **Fix the whole class at the logger:** install a `hooks.logMethod` that appends the extras pino would drop to the message, and cover it with a test. Canonical `(obj, msg)` calls and printf-style calls pass through unchanged. Every repo that adopts pino should get this hook from day one.

### 15. `claude -p` Is the Full Agentic CLI: Isolate cwd, Retry Broadly, Size Timeouts Under Load

`claude -p --dangerously-skip-permissions` is the FULL agentic Claude Code CLI, not a limited text-completion endpoint. Any pipeline that shells out to it has to handle the following:

1. **CWD hygiene.** If the subprocess's working directory is inside a repo, the spawned agent can explore that repo and add meta-commentary to its output (for example, a generated brief that narrates the source path it was run from). Fix: for free-text generation calls, set the subprocess cwd to an empty or neutral directory (for example `tempfile.mkdtemp()`). Calls whose output is strictly parsed, like JSON extraction, are at lower risk, but the same hygiene costs almost nothing.
2. **Retry breadth.** Retry on ANY non-zero exit code AND on empty stdout, not only when stderr mentions "rate" or "limit". Nested `claude -p` calls sometimes exit 1 with EMPTY stderr as a transient failure. Code that only retries on rate/limit strings fails hard on the first blip. Use exponential backoff, up to N attempts.
3. **Timeout sizing.** A fixed spawn timeout tuned on a solo test run will SIGTERM most calls once real concurrency pushes latency up. A timeout sized from a light run can fail almost every session in a large concurrent batch. A SIGTERM'd session's transcript shows a user turn and no assistant turn. Size the timeout from latency measured under the job's REAL concurrency.
4. **Model and effort must be explicit.** Headless claude inherits the host's `settings.json` model and effort level. An inherited high effort level can make each call about 3x slower than `--effort medium`. Pass both `--model` and `--effort` explicitly.
5. **Exit code must reflect failure.** A wrapper can exit 0 on a killed or empty run. Treat exit 0 with empty stdout as an error. A batch caller must exit non-zero if ANY item failed, or its run history can never show red.

### 16. `git symbolic-ref origin/HEAD` Exits 128 When Unset; Under `set -euo pipefail` It Silently Kills the Script

origin/HEAD is set by `git clone` and by nothing else. `git remote add` plus fetch does not set it, and nothing refreshes it later. On a checkout without it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128.

Under `set -euo pipefail`, piping that into sed does NOT save you: pipefail carries the 128 past sed, and `set -e` ends the script. A trailing `2>/dev/null` hides the MESSAGE but not the exit code, so the line looks handled when it isn't. In a real case, a watchdog script died partway through on every run for weeks, and nothing below that line ever ran, including its alerting block. The proof was its state file, written on the last line, frozen at the date the failing check was added.

**How to apply:** under `set -e`, any command substitution that can legitimately fail needs an explicit `|| true`, especially git plumbing. When a long script has an unexplained partial effect, check for a non-zero exit mid-script before you suspect the logic. A frozen end-of-script state file is the cheapest proof.

### 17. Cron's PATH Excludes /usr/local/bin; With `set -e` That Kills a Script Silently, and a Silent Job's Log mtime Never Moves

cron runs with `PATH=/usr/bin:/bin`. Anything in `/usr/local/bin` (often pm2, node, npm, and most globally installed tools) is NOT found. With `set -euo pipefail`, the first such call kills the script before it does anything. When that script is a monitor, its death means nothing is watching.

The part that makes this worse: `>>` only updates a log file's mtime on an actual WRITE, not when the file is opened. A job that fails before producing output leaves its log at 0 bytes, with the mtime frozen at the last write. A freshness checker watching that file cannot tell "silently dead for weeks" from "had nothing to say."

**How to apply:** put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of any script cron runs, or set `PATH=` in the crontab. If a script works interactively but fails under cron, reproduce it with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c ...` before you theorize. Never conclude a job is healthy from its log's mtime.

### 18. An Empty `err.message` (AggregateError) Makes a Fallback String Look Like the Real Error

Node >= 20 connects to a `localhost` hostname with happy-eyeballs (::1 and 127.0.0.1 in parallel). When BOTH fail it throws an AggregateError whose `.message` is the EMPTY STRING, with the real per-address errors in `.errors`. The common idiom `err.message || "some fallback"` therefore picks the fallback, and the diagnosis is lost. undici makes it worse: it reports every connection failure as the opaque string "fetch failed" and hides the real reason in `.cause`.

This depends on the environment, which is why it often doesn't reproduce locally. A single-stack host resolves localhost to one address and throws a plain Error with a usable message. A dual-stack host throws the empty-message AggregateError. A test that connects to a dead port therefore asserts different things on the two machines, so build the AggregateError by hand in the test.

How to apply:
1. Never format an error with `.message` alone. Use a `describeError()` that walks `.errors` and `.cause` and appends the code and address:port.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match the FULL description. Otherwise an AggregateError carrying ECONNREFUSED looks non-transient and gets treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature. It means the fallback fired, not that the error had nothing useful to say.

### 19. A Composer-Style Tab Row Directly Above a Feed Reads as a Filter for That Feed

If a tab strip that only scopes an input control sits right above a result list, users read it as a filter on the list. They then report the list as broken ("X selected, can't click Y") even when nothing gates the list. Two cheap fixes: label the tab row for what it actually scopes, and give the list its own explicit filter with an "All" default.

Before you rewrite behavior, test the gating claim. Hit-test each row with `document.elementFromPoint` at its center and check the tag and href. This separates "an overlay eats the tap" from "this row was never a link" from "the user misread the control." The real defect can differ from what the report literally says. For example, pending rows rendered as a `div` with no href, so still-running results really were unclickable.

### 20. One Split Multi-Byte Character Makes grep Treat a Text File as Binary and Report Nothing, With No Error

A generated index file that cut its entries to a fixed width split a UTF-8 ellipsis in half and left two orphan bytes. grep then classified the whole file as binary and suppressed matches. `grep -n <term> file` printed nothing, and so did `grep -c "" file`, which looks exactly like "that term is not in the file." `grep -a` would have worked the whole time.

Detect: `python3 -c "open(P,encoding='utf-8').read()"` raises an exception that includes the byte offset. Also `file P` reports "data" instead of "UTF-8 Unicode text", and `grep -c $ P` and `grep -ac $ P` give different counts.

Repair: read the bytes, splice out the orphan sequence, and `decode()` the result to prove the whole file is clean BEFORE writing it back.

This applies to any generated file whose lines are cut to a width: index files, log summaries, digests, commit subjects, anything that does `s[:80]` on text that may contain non-ASCII. Truncate by characters after decoding, never by bytes.

### 21. A Grep-Gated Feature Never Fires When the Gate Pattern Doesn't Match the Actual Generated Content

In one case, a consumer script decided whether to inject context by grepping generated files for keywords that seemed obvious. The producer's write template never contained any of those keywords. The write side worked and produced real files, but the read side's gate never matched, so the feature was completely dark from the day it shipped: no error, no log line, nothing. The fix was to gate on a heading every real file actually contains, checked against a live file. Check that the old pattern fails on it and the new one matches, and that files which should not match still don't.

Lesson: when a producer and consumer communicate through a string or grep match on generated content, rather than a shared constant or schema, check the match condition against a REAL generated sample, not against keywords that seem intuitive. This bug class produces no errors and no symptoms. You only find it by checking directly whether the consumer's condition ever fires.

### 22. An Empty Search Result Has Two Causes: the Thing Is Absent, or the Query Couldn't Find It

The output looks the same either way, and the second cause is far more common than it feels. Reporting "clean" without telling them apart asserts a negative you never established.

Two patterns that produce this silent failure:
1. **Grepping the transport, not the sink.** A grep for the obvious pattern (a webhook URL constant, a function name) misses a call that goes through a local variable assigned one expression earlier (`const url = process.env.X_WEBHOOK_URL`, then `fetch(url)`). Before declaring "no calls to X", trace every alias and wrapper function, not just the literal.
2. **Grepping a file that grep treats as binary.** Embedded NUL bytes or a split multi-byte character make grep silently find nothing for patterns that are plainly there (see section 20). Use `file <path>` to detect it and `grep -a` to search it.

Rule: before reporting "not found," prove the query could have found it. The cheapest check is to grep for a string you can *see* in the file and confirm it matches. A search that finds a known sentinel is calibrated. A search that misses a sentinel you expected is itself the finding.

### 23. A Cached or Stale State API Makes You Report a Confidently Wrong Number

While diagnosing a streaming host capped at 30fps, the display mode was read from Windows WMI `Win32_VideoController` (`CurrentHorizontalResolution`, `CurrentVerticalResolution`, `CurrentRefreshRate`). It reported 1920x1080. The real mode, from `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)`, was 1280x720. WMI's `Current*` fields are filled in at driver init and are NOT re-read when the mode changes, so they can report a mode the machine left hours ago. Nothing in the output marks the stale field. It looks exactly as authoritative as the correct one.

What caught it: a second API (`System.Windows.Forms.Screen.AllScreens`) disagreed in the same call. **When two state-reading APIs disagree about the same instant, that is not noise to average away or a choice to settle by likelihood. At least one of them is not reading live state, and your job is to find out which.** Go to the authoritative source instead of arbitrating between convenient ones.

Rule: for any state you will REPORT to a user or base a decision on, prefer the API whose contract is "read the live value now" over the one that is convenient or already in your output. On Windows, use `EnumDisplaySettings` over `Win32_VideoController` for display mode. The same trap applies to anything cached at init: WMI `Win32_*` snapshots, `/proc` values sampled once, ORM-level caches, any `Get-*` that returns a driver-reported struct instead of querying.

Confirm by corroboration, not by re-reading the same API. Restart the consumer and check what IT reports, and look in its logs for evidence of what it requested all along.

### 24. `sqlite3 readfile()` Stores a BLOB, and a BLOB Column Reaches a Node App as a Buffer That 500s the Page

Loading a markdown document into a table with the sqlite3 CLI's `readfile()` produced a row where `typeof(answer)` is `'blob'`, not `'text'`. better-sqlite3 returns a BLOB as a Node Buffer. The render path called `.replace` on the Buffer, and every SSR request for that page failed with `TypeError: a.replace is not a function` and HTTP 500. The insert reported success, and the row looked fine to `select length(answer)`.

Rules:
1. When you load file content into SQLite from the CLI, wrap it: `CAST(readfile('/path') AS TEXT)`. `readfile()` is documented to return a blob, and the type stays invisible unless you ask for `typeof()`.
2. After any hand-written insert into a live app's DB, check `typeof()` on the column AND load the page that renders it. A row that selects cleanly can still have the wrong storage class for its consumer.
3. After the cast, byte length and character length differ when there are multi-byte characters. That difference confirms the text decoded as UTF-8. It does not mean truncation.
4. Symptom to recognize: a Node/Next.js page that 500s with `X.replace is not a function` inside an `Array.map` right after a manual DB write has a storage-class bug, not a data bug.

### 25. A Reply Address Must Name Where the Payload Landed, Not a Location the Job Was Holding

A feature that both DELIVERS a payload to a location and ADDRESSES a reply channel back to it has two separate ideas of "the location," and they can drift apart silently. When they do, every component tests green and the user still reports the feature as broken, because correct delivery to the wrong place looks the same as no delivery.

Concrete shape: a long answer was moved into a NEW overflow thread created at post time, while the completion email built its Reply-To from the streaming thread id stored on the job record. Both threads were real and live. The relay, the agent's answer, and the completion mention all worked, and all of them landed in the thread holding only progress updates, while the user was reading the thread holding the answer.

Two signs this bug class is present:
1. The code holds a thread/channel/room id from EARLIER in the job (a record field, a variable captured at start) and uses it as an address, while the actual post happens LATER through a helper that may create its own destination.
2. The posting helper returns void. A function that picks a destination and doesn't report it forces every caller to guess.

Fix: make the posting helper RETURN the surface it delivered to (null when it didn't create one). Derive the address from that return value, and fall back to the earlier id only when the helper made no new surface. Also make the split visible: the abandoned surface should point to the real one ("Answer: <link>"), or it looks like a job that produced nothing.

Two follow-on rules:
- **Log the destination you resolved to, not the one you were handed.** A log line that prints the ADDRESSED id makes a misroute look like a healthy relay and sends the investigation to the transport code. Any line that reports a delivery must print the surface the payload actually landed on.
- **A sent address cannot be rewritten.** If the reply address is signed or already delivered, fixing the code only helps future sends, and everything already in the recipient's inbox still points to the old surface. Store the move as a redirect resolved at delivery time, cap the number of hops, and guard against cycles. Keep every trust check on the ORIGINAL signed id, so the redirect changes the address and never the authorization.

Debugging tip: when a user says "I replied and nothing showed up," don't start with the relay. Get the id of the surface the user is looking at and the id the system posted to, and compare them BEFORE you read any transport code.

### 26. Size a Retry Against the Dependency's Recovery Time, and Log the Cause Chain

Recurring AI jobs failed on consecutive days with two defects, and the second is what made the first hard to find.

1. **The retry was sized for a blink, not for recovery.** The client retried a transport failure once, 30 seconds later, then failed the job. The dependency was a container on another host, reached over an autossh reverse tunnel, and NEITHER of its recovery paths finishes in 30s. Recreating the container refuses connections for the whole `docker compose up -d` cycle. After a tunnel drop, the SERVER holds the dead session's forward for up to `ClientAliveInterval x ClientAliveCountMax` (for example 120s x 3 = 6 minutes), and the client's `ExitOnForwardFailure=yes` makes every reconnect inside that window exit instead of binding the port.

   RULE: before you pick a retry delay, name the dependency's slowest NORMAL recovery event and read its actual duration from the config that controls it (systemd `RestartSec`, sshd `ClientAlive*`, a container healthcheck's `start_period`, an autoscaler's cooldown). A single retry is only right when the failure is a lost packet. Back off across a window that covers recovery. Stop early if the next sleep would run past the call's own abort deadline, because sleeping into an abort turns a diagnosable network error into a bare "timed out" and throws away the cause.

2. **The log threw away the diagnosis.** undici (and Node's global fetch) reports EVERY transport failure as `TypeError: fetch failed` and puts the real reason on `.cause`. Logging only `err.message` records the same useless line whether the service is mid-restart, the tunnel dropped, or the far end reset the socket mid-body. With a `localhost` URL, an all-refused connect arrives as an AggregateError with an empty `.message` and reasons in `.errors` (see section 18). A walk that only follows `.cause` prints "(no message)".

   RULE: log the flattened cause chain, not `err.message`. Walk BOTH `.cause` and `AggregateError.errors`, limit the depth (a cause can refer to itself), and include `.code` at each level. Classify transient vs. permanent against the flattened string for the same reason.

3. **A generic failure message puts the blame in the wrong place.** "Task processing failed. Please try again." reads as "your input broke it." When the transport never reached the service, say the service was unreachable. The user is deciding whether to spend another rate-limited action, and only the accurate message helps them decide.

If sibling apps were scaffolded from the same template, check each one for the same single-retry constant and missing `.cause` reads before porting the fix. Scaffolds drift, so verify each copy.

### 27. A Progress Heartbeat That Stores Only a Timestamp Can't Say WHERE a Job Died

A job reaper was correctly rewritten to reap on silence since `last_progress_at` rather than age since `created_at`. But the heartbeat function took a phase argument and used it only in an error message: the column stored the time and dropped the phase. When scheduled jobs stranded and were reaped, the only evidence left was "last heartbeat N minutes in" plus one `fetch failed` line in a process log that had already rotated. Every reaped job stored the same sentence, so the rows couldn't be told apart.

Why: a heartbeat is written to answer "is this still alive?", which only needs a timestamp. The question people ask later is always "where did it stop?", and the phase is the whole answer. The two get mixed up because one UPDATE serves both, and the diagnostic half costs nothing.

How to apply:
1. Store the phase next to the timestamp, and include it in the terminal message the recovery sweep writes ("Interrupted ... (stopped during: <phase> 212/419)"). Build that message in ONE function that the row, the email, and the chat notification all call, so three surfaces can't disagree about one event.
2. Audit for windows with no heartbeat. Any stretch between two stamps is a blind spot as long as the reaper's cutoff. A long phase should send heartbeats from INSIDE (pass a per-item callback, throttled to one write a minute), not only at its start and end.
3. A pool is not bounded just because its units are. Workers with per-fetch timeouts and child-process kill timeouts can still leave one promise that never settles, and then `Promise.all` never settles either. That strands the whole job inside a LIVE process, where a reaper that only runs on restart never fires. Wrap the pool in a wall-clock deadline that fails open. The deadline must NOT cancel the underlying work: an orphaned promise costs a little memory, while a stranded job costs the user the entire run.
4. For a job that only runs on a schedule, a lost run stays lost until the next tick, so size retries against the dependency's real recovery time (section 26).

### 28. A Collapsed `<details>` Still Mounts and Renders Every Child: "Collapsed" Is Not "Unmounted"

An HTML `<details>` element keeps its children in the DOM when collapsed and only hides them with CSS. If N collapsed items each render something heavy (for example a `react-markdown` + `rehype-sanitize` tree per item), all N are parsed up front and parsed again on every parent re-render, even if nobody ever opens a section. On a list page with a short polling interval, this was the main cause of "the page lags when there are a lot of results": every poll re-parsed every collapsed item's markdown. A fresh JSON string on each poll also defeats naive `React.memo` or identity checks, so the markdown re-parses even when its content hasn't changed.

**How to apply:** when each item in a collapsible list renders expensive content (markdown, syntax highlighting, embedded media), don't assume the closed state of `<details>` or an accordion protects you. Either lazy-mount the child (render nothing, or a light placeholder, until the first expand) or memoize the parsed output so a poll that didn't change an item doesn't re-run the parser. The same holds for any CSS-only hide (`display:none`, `hidden`, a closed `<Collapsible>`). None of them unmount, so none of them remove the render cost of what they hide.

### 29. A Numeric Guard With Mismatched Units Never Fires, and Nothing Looks Broken

A memory-pressure watchdog's "spare a small process" branch compared a process's RSS from `ps`, which reports **kilobytes**, directly against a threshold constant named and configured in **megabytes**, with no conversion: `[ "$rss" -lt "$MIN_TARGET_MB" ]`. Both sides are bare integers, so the shell raises no type error. The comparison is just always false, because a real multi-GB process's RSS in KB is orders of magnitude larger than the MB threshold (`3145728 -lt 3` is never true). The guard shipped, passed review, and stayed live through real memory-pressure events without ever taking its branch. There was no crash, no error log, and no sign to separate "correctly false" from "can never be true."

It was found only by a **contained live-fire test**: deliberately spawning a decoy process sized to cross the intended threshold and confirming the branch ran. A quiet log with no "guard fired" lines had been treated as proof the condition never came up.

Why it's easy to miss: a unit mismatch doesn't crash and produces no odd output. A correctly converted value may sit on the next line (for example a GB figure computed only for a log message), which makes the code look unit-aware when the comparison isn't. Like section 21, a gate that can never be satisfied looks, from a static read or a quiet run, exactly like one that simply hasn't been triggered yet.

**How to apply:** for any bash (or other untyped numeric) comparison against a hardcoded threshold, check that the units agree at the comparison itself, not just in display code. `ps -o rss=` returns KB no matter what the constant it's compared to is called. Name variables with their real unit (`rss_kb`, not `rss`) so a mismatch shows in the diff. For any guard whose condition is rare (only reached under real pressure or scale), don't accept "it hasn't logged firing" as evidence it works. Create the triggering condition once, on purpose, and confirm the branch runs.

### 30. A Descending Threshold List Scanned First-Match-Then-Break Fires the WIDEST Crossed Tier, Not the Most Urgent

An expiry reminder listed its tiers widest window first (`[30, 14, 7, 1]` days) and scanned with "first tier whose window is crossed and unsent → act → `break`." With descending order and first-match, the **first** match is the **widest** tier, the opposite of what the loop's own comment said ("send the most urgent threshold"). On the common path you can't see this: an item tracked from before the widest window crosses one new tier per run, so first-crossed and only-crossed are the same tier.

It only bites when an item enters **mid-range**, already past one or more tiers the first time it's evaluated (for example, added to the tracker with 5 days left, so the 30d and 14d tiers are both already crossed). A per-tier dedup log on a **fixed cron schedule** makes it worse. Each run logs only the ONE tier it fired, so the wider tiers it skipped stay marked unsent. On the next tick the item crosses the *next* tier down and fires again: 30d, then 14d, then 7d, then 1d, one notification a day for four days instead of one. Each send looks correct on its own (a real crossed, unsent tier), so nothing flags it as a duplicate.

Why it's easy to miss: the inline comment states the intended behavior correctly, and the `break` visibly enforces "one per run." Both readings are true locally. The bug is which tier the `break` stops on. A reviewer checking "does it send more than one at a time?" sees the guard and moves on without checking *which* tier it picks when several are already crossed.

**How to apply:** any tier/bucket/threshold list scanned first-match (rate-limit escalation, discount or loyalty tiers, alert severity, backoff selection) must choose by **comparing the crossed candidates against each other**. Don't let the array's iteration order decide, since source order is a display or config concern, not a selection algorithm. Concretely: collect every tier whose condition is met and not yet handled, choose the most urgent (narrowest window or highest severity) by explicit comparison, and mark **all** collected tiers as handled in the same pass. If you only mark the one that fired, the skipped wider tiers can fire on the next tick. Test the case where the input starts already past several tiers, not only the case where it crosses them one by one. The one-by-one path is the one every reviewer pictures by default.
