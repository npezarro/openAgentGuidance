<!-- Load when: diagnosing issues, log analysis -->
# Debugging Guidance

A systematic approach to diagnosing and fixing issues.

## The Debugging Workflow

```
0. Gather Context → 1. Reproduce → 2. Read the Error → 3. Isolate → 4. Hypothesize → 5. Verify → 6. Fix → 7. Confirm
```

### 0. Gather Existing Knowledge First

Before you touch code or form a hypothesis, check whether this problem (or one close to it) has already been solved:

- **Memory**: Read the relevant feedback and project memory files. Corrections from past sessions are your highest-signal source.
- **CLAUDE.md**: The repo's CLAUDE.md records architecture decisions and known gotchas.
- **Guidance**: Check the domain-specific guidance files in this repo (auth, deployment, and so on).
- **Knowledge base**: Scan your knowledge base index for patterns that span repos.
- **Private context repo**: Look for credentials, registered URIs, or infrastructure details that limit what the fix can be.
- **Git history**: `git log --oneline --grep="<keyword>"` finds earlier fixes.

This step is not optional background reading. It is usually the fastest debugging step there is. **The previous session's fix is often already written down in memory.** Skipping this step to "save time" leads to debugging loops that last hours.

### Approach Switching (15-minute rule)

If you have spent 15+ minutes trying variations of one approach with no progress:
1. Stop iterating on that approach.
2. Re-read memory and guidance for the domain (Step 0 again).
3. Spawn a debugger agent to get a fresh perspective.
4. Try a **fundamentally different** approach.

Repeating the same kind of fix with different values is not debugging. It is brute force.

### 1. Reproduce the Issue

Confirm you can trigger the problem before you touch code:
- Run the exact command or action that causes the error.
- Write down the exact error message, stack trace, and context.
- If you can't reproduce it, you can't be confident you fixed it.

### 2. Read the Error Fully

- Read the **entire** stack trace, not just the first line.
- Find the **first** error in a chain. Cascading failures often hide the root cause.
- Check whether the error message tells you what's wrong. It often does.

### 3. Isolate the Problem

- **Binary search:** Comment out half the suspect code. Does the error persist?
- **Minimal reproduction:** Can you trigger it with a 5-line script?
- **Check boundaries:** Is the issue in your code, a dependency, or the environment?

### 4. Check the Obvious First

Rule these out before you dig deeper:

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
| Log line ends in a bare colon (`"failed:"`) | Logger dropping extra arguments (see section 14) |
| Error reads `"X failed: x failed"` | An empty `err.message` made a fallback string fire (see the AggregateError section) |
| Next.js page 500s with `X.replace is not a function` right after a manual DB write | Column stored as BLOB, not TEXT (see the sqlite3 `readfile()` section) |

### 8. After Fixing

- Remove all debug logging before committing.
- Write a regression test if you can.
- Record the root cause in the commit message.
- Update `context.md` if the fix taught you something about the environment.

### 9. SQLite & Prisma Specifics

- **Database is locked**: Concurrent writes in SQLite cause locking.
  - **Fix**: Move `updateMany` or `createMany` calls out of loops. Consolidate them into one operation per user or batch.
  - **Pragma**: Use `PRAGMA busy_timeout=5000;` so SQLite waits instead of failing immediately.
- **executeRawUnsafe vs queryRawUnsafe for PRAGMAs**: Use `$queryRawUnsafe` for **both** `PRAGMA journal_mode=WAL` and `PRAGMA busy_timeout=5000`. Catch and ignore `"Execute returned results"`, because that message means the PRAGMA worked. Log every other error.
  ```ts
  prisma.$queryRawUnsafe(`PRAGMA journal_mode=WAL;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("WAL enable failed:", err);
  });
  prisma.$queryRawUnsafe(`PRAGMA busy_timeout=5000;`).catch((err) => {
    if (!err.message?.includes("Execute returned results")) console.error("busy_timeout failed:", err);
  });
  ```
- **`connection_limit=1` is required for SQLite in Next.js.** Next.js spawns several worker threads. Without this setting they fight over the SQLite file and you get "Database is locked". Add it to DATABASE_URL:
  ```
  DATABASE_URL="file:./production.db?connection_limit=1&timeout=30&pool_timeout=30"
  ```
  Without it, stabilizing an app on this setup can take many commits of trial and error.
- **Prisma singleton: always assign to the global, even in production.** The common guard `if (process.env.NODE_ENV !== 'production')` before `globalForPrisma.prisma = prisma` is wrong. Next.js worker threads reload modules without reinitializing globals, so every reload creates a new client, which can end in an OOM crash loop. Remove the guard:
  ```ts
  export const prisma = globalForPrisma.prisma || createPrisma();
  globalForPrisma.prisma = prisma;  // always, not just in dev
  ```
- **Next.js apps running out of memory under load:** Raise the heap in the process manager config (for example, a PM2 ecosystem file):
  ```js
  env: { NODE_OPTIONS: '--max-old-space-size=1024' }
  ```
  Raise `max_memory_restart` to match (for example, `1G`).
- **`datetime('now')` strings parse as LOCAL time in `new Date()`, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"` (space-separated, no `T` or `Z`). The ECMAScript Date parser treats that non-ISO form as local time. As a result, `new Date(created_at)` silently shifts a stored timestamp by the viewer's UTC offset, and near UTC midnight it can show the wrong date. This affects Prisma-on-SQLite and raw `better-sqlite3` apps equally, because the bug is in JS Date parsing, not in Prisma. On a UTC-7 host, `new Date('2026-07-06 12:00:00').toISOString()` gives `19:00Z`.
  - **Fix**: Normalize before parsing. Strict-match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/` and rewrite the value to `` `${date}T${time}Z` ``. Pass strings that are already ISO through unchanged. SQL-side comparisons such as `date(created_at) = utcToday` are unaffected, because both sides stay UTC.
  - If several apps share a copied timestamp component, grep every copy. A fix in one copy does not reach the others.
- **Prisma's `NOT:` wrapper excludes NULL rows on nullable columns.** `NOT: { field: value }` compiles to SQL `NOT(col = 'value')`. That expression is NULL for any row where the column IS NULL, so those rows are excluded. Null-valued rows disappear from the results with no error. For example, `NOT: { status: "closed" }` can silently drop most of a table when most rows have a null status. **Fix**: When you negate a NULLABLE column and still want the NULL rows, use the explicit OR form: `OR: [{ field: null }, { field: { not: value } }]`. **Self-review trigger**: Any Prisma `NOT:` filter on a nullable column, especially in a query that returns fewer rows than expected.

### 10. Prisma + PostgreSQL: Use pg.Pool, Not a Raw Connection String

When you use `@prisma/adapter-pg` (PrismaPg), pass it a `pg.Pool` instance so you control the connection pool:

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

An automation flow that hands work to a `claude -p` agent runs without a TTY. If a CLI the agent calls blocks waiting for interactive input (for example, a `readline` "approve/edit?" prompt), it hangs silently. The agent then quietly falls back to a worse path, or times out. The symptom is "the tool exists and is wired up, but the good pipeline never seems to run."

Fixes:
- Give the tool an `--auto`/`--yes` flag, AND turn it on automatically when `!process.stdin.isTTY`, so the tool never hangs no matter how it is launched.
- Don't require an `ANTHROPIC_API_KEY` for sub-steps. Route model calls through the `claude -p` CLI (subscription auth) so the tool runs in the same keyless environment as the agent.
- Make the tested tool the canonical path. Prompts that re-describe a "manual fallback" flow drift over time and silently lose features.

### 12. Browser CDP Timeout Recovery: Kill + Restart

When a service calls a browser-agent CLI and gets "Timeout waiting for browser response", the Chrome/CDP session is stuck, not just slow. Recovery takes these steps:

1. Detect that specific timeout string in your error handler.
2. Kill all chrome/chromium processes: `pkill -f chrome || true`
3. Restart the browser-agent service through your process manager (for example, `pm2 restart <browser-service>`).
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

Also raise the base CLI timeout from 60s to 120s so slow page loads don't cause false-positive timeouts. That is a separate problem from CDP hangs. Without recovery, CDP sessions hang silently after a connectivity loss and retries pile up.

### 13. Reading a SQLite DB Another Process Is Actively Writing (WAL Mode)

When you poll a SQLite database that a running app writes to (for example, an Electron app's `*.sqlite` in WAL mode), a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot**. It reads the committed WAL frames as of some earlier point and never moves forward, even across freshly spawned reader processes. The classic symptom: "it caught the first change but never the next ones," while the process is alive and one-off manual queries look current.

**Fix**: Open a **normal (read-write-capable) connection with `PRAGMA query_only=ON`** instead. It takes part in the WAL protocol correctly and reliably sees the latest committed rows, and `query_only` guarantees you never modify the app's data. Add `.timeout <ms>` so a brief writer lock produces a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

A second gotcha applies if your reader writes to the macOS clipboard. Apps that paste through the clipboard often save, paste, then **restore**, which overwrites what you wrote. To win the race, re-assert your value (run `pbcopy` again) for about 1s, checking `pbpaste` each time.

### 14. Error Log Lines Ending in a Bare Colon = Logger Dropping Arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`. Any extra arguments after a string message are printf interpolation values. If the message has no `%s`/`%d`/`%o`, those arguments are **silently discarded**. A console-style call such as `logger.error('failed:', err.message)` produces `"msg":"failed:"`, so the diagnostic stops at the colon and the real error never reaches any log. The symptom while debugging: an error repeats, and its message trails off with `:` and nothing after it.

Fixing call sites one at a time does not work. Audit passes still miss sites (often a hundred or more in a large codebase), and new ones appear with every feature. **Fix the whole class at the logger:** install a `hooks.logMethod` that appends the extras that would be dropped to the message. Canonical `(obj, msg)` calls and printf-style calls pass through untouched. Cover the hook with a test, and give it to any repo that adopts pino from day one.

### 15. `claude -p` Is the Full Agentic CLI: Neutral cwd, Broad Retries, Explicit Model

`claude -p --dangerously-skip-permissions` is the FULL agentic Claude Code CLI, not a limited text-completion endpoint. Any pipeline that shells out to it has to handle the following:

1. **CWD hygiene.** If the subprocess's working directory is inside a repo, the sub-agent can explore that repo and put meta-commentary into its output (for example, a generated text that mentions the source path it was called from). **Fix**: For free-text generation calls, set the subprocess cwd to an empty, neutral directory (for example, `tempfile.mkdtemp()`). Calls whose output is strictly parsed (such as JSON extraction) are at lower risk, but the same cwd hygiene is cheap insurance.
2. **Retry breadth.** Retry on ANY non-zero exit code AND on empty stdout, not only when stderr matches "rate" or "limit". Nested `claude -p` calls sometimes exit 1 with an EMPTY stderr, which is transient. Code that only retries on rate/limit strings fails hard on the first blip. Use exponential backoff, up to N attempts.
3. **Timeout sizing.** A fixed spawn timeout tuned on a solo test run will SIGTERM almost every call once real concurrency raises latency. A SIGTERM'd session's transcript shows a user turn and no assistant turn. Size the timeout from latency you measured under the job's REAL concurrency.
4. **Model and effort must be explicit.** Headless claude inherits the host's `settings.json` model and effort level. An inherited high effort level can make each call take about three times as long as `--effort medium`. Pass both `--model` and `--effort` explicitly.
5. **The exit code must reflect failure.** The CLI (or your wrapper) can exit 0 after a killed or empty run. Treat exit 0 with empty stdout as an error. A batch caller that handles several items must exit non-zero if ANY item failed, or its run history can never show a failure.

### 16. `git symbolic-ref origin/HEAD` Exits 128 When Unset; Under `set -euo pipefail` It Silently Kills the Script

`origin/HEAD` is set by `git clone` and by nothing else. `git remote add` plus fetch does not set it, and it is never refreshed afterwards. On a checkout without it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128.

Under `set -euo pipefail`, piping that command into `sed` does NOT save you: pipefail carries the 128 past the sed, and `set -e` ends the script. A trailing `2>/dev/null` hides the MESSAGE but not the exit code, so the line looks handled when it isn't. A monitoring script can die halfway through on every run for weeks this way, with everything after that line (including the alerting block) never running. The proof is a state file written on the script's last line whose timestamp is frozen at the date the bad line was added.

**How to apply:** Any command substitution that can legitimately fail needs an explicit `|| true` under `set -e`, especially git plumbing commands. When a long script has an unexplained partial effect with no error, look for a non-zero exit partway through before you suspect the logic. A frozen end-of-script state file is the cheapest proof.

### 17. cron's PATH Excludes /usr/local/bin; With `set -e` That Kills a Script Silently, and a Silent Job's Log mtime Never Moves

cron runs with `PATH=/usr/bin:/bin`. Nothing in `/usr/local/bin` is found, and that is where pm2, node, npm, and most globally installed tools usually live. With `set -euo pipefail`, the first such call kills the script before it does anything. If that script is a watchdog, nothing is watching at all.

There is a second, compounding problem. `>>` updates a log file's mtime only when something is actually WRITTEN, not when the file is opened. A job that fails before producing output leaves its log at 0 bytes, with the mtime frozen at the last time it wrote. A freshness checker watching that file sees nothing change and can't tell "silently dead for weeks" apart from "had nothing to say."

**How to apply:** Put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of every script cron will run, or set `PATH=` in the crontab. When a script works interactively but fails under cron, reproduce it with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c ...` before you start theorizing. Never conclude that a job is healthy from its log's mtime.

### 18. An Empty `err.message` (AggregateError) Makes a Fallback String Look Like the Real Error

Node >= 20 connects to a `localhost` hostname using happy-eyeballs (::1 and 127.0.0.1 in parallel). When BOTH fail, it throws an AggregateError whose `.message` is the EMPTY STRING, and the real per-address errors are in `.errors`. The common idiom `err.message || "some fallback"` then picks the fallback, and the diagnosis is lost. undici makes it worse: it reports every connection failure as the opaque string `"fetch failed"` and hides the real reason in `.cause`.

This depends on the environment, which is why it often won't reproduce locally. A single-stack host resolves localhost to one address and throws a plain Error with a usable message. A dual-stack host throws the empty-message AggregateError. A test that connects to a dead port therefore checks different things on the two machines, so build the AggregateError by hand in the test instead.

How to apply:
1. Never format an error with `.message` alone. Use a `describeError()` that walks `.errors` and `.cause` and appends the code and address:port.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match against the FULL description. Otherwise an AggregateError that carries ECONNREFUSED looks non-transient and gets treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature of this bug. It means the fallback fired, not that the error was unhelpful.

### 19. A Tab Row Directly Above a Feed Reads as a Filter for That Feed

When a tab strip that only scopes an input control sits directly above a result list, users read it as a filter on the list. They then report the list as broken ("X selected, can't click Y") even when the list isn't filtered at all. Two cheap fixes: label the tab row with what it actually scopes, and give the list its own explicit filter with an "All" default.

Before you change behavior, test the claim that the list is gated. Hit-test each row with `document.elementFromPoint` at its center and check the tag and href. That separates three cases: an overlay eats the tap, the row was never a link, or the user misread the control. The real defect behind the report may differ from what the report says. For example, pending rows rendered as a `div` with no href can make every still-running result genuinely unclickable.

### 20. One Split Multi-Byte Character Makes grep Treat a Text File as Binary and Report Nothing

If a generated file truncates lines to a fixed width, a truncation can cut a UTF-8 character in half and leave orphan bytes behind. Two stray bytes in a 13KB file are enough.

The failure is silence, not an error. grep classifies the file as binary and suppresses matches, so `grep -n <term> file` and even `grep -c "" file` print nothing, which looks exactly like "that term isn't in the file." `grep -a` would have worked the whole time, and so would Python with `errors='replace'`. The trap is that the natural first tool fails quietly.

- **Detect:** Run `python3 -c "open(P,encoding='utf-8').read()"` and let it raise; the exception includes the byte offset. Alternatively, `file P` reports `data` rather than `UTF-8 Unicode text`, or `grep -c $ P` and `grep -ac $ P` disagree.
- **Repair:** Read the bytes, splice out the orphan sequence, and `decode()` to prove the whole file is clean BEFORE writing it back.
- **Prevent:** This applies to any generated file whose lines are truncated to a width: index files, log summaries, digests, commit subjects, anything that does `s[:80]` on text that may contain non-ASCII. Truncate by characters after decoding, never by bytes.

### 21. A Grep-Gated Feature Never Fires When the Gate Pattern Doesn't Match the Real Generated Content

Suppose a consumer script only injects extra context when `grep -q "keywordA|keywordB|KEYWORD C"` matches a generated file, but the producer's actual write template never contains any of those strings. The producer then writes real files, the consumer's gate never matches, and the feature stays completely dark: no error, no log line, nothing. The fix is to gate on something every real file actually contains (for example, a fixed heading like `^## Classification:`). Verify the old pattern fails and the new pattern matches against a live file, and check that the new pattern doesn't change behavior on the other files in the directory.

**Lesson:** When a producer and a consumer communicate through a string or grep match on generated content, instead of a shared constant or schema, check the match condition against a REAL generated sample, not against keywords that seem intuitive. This kind of bug produces zero errors and zero symptoms. The only way to find it is to check directly whether the consumer's condition ever fires.

### 22. An Empty Search Result Has Two Causes: The Thing Is Absent, or the Query Couldn't Find It

The output can't tell you which of the two happened, and the second is far more common than it feels. Reporting "clean" without ruling it out asserts a negative you haven't established.

Two patterns that cause the silent failure:
1. **Grepping the transport, not the sink.** A grep for the obvious pattern (a webhook URL constant, a function name) misses a call that goes through a local variable assigned one expression earlier (`const url = process.env.X_WEBHOOK_URL`, then `fetch(url)`). Before you declare "no calls to X", trace every alias and wrapper function, not just the literal constant.
2. **Grepping a file that grep treats as binary.** Embedded NUL bytes or a split multibyte character make grep silently find nothing for patterns that are plainly there. `grep -n "pattern" file.js` returns zero hits while `grep -an "pattern" file.js` returns the expected lines. Detect this with `file <path>` (it says "data" rather than "ASCII text"), and use `grep -a` on suspect files.

**Rule:** Before you report "not found," prove the query could have found it. The cheapest check is to grep for a string you can *see* in the file and confirm it matches. A search that finds a known-present sentinel is calibrated. A search that returns nothing for a sentinel you expected is itself the finding.

### 23. A Cached or Stale State API Makes You Report a Confidently Wrong Number

On Windows, WMI's `Win32_VideoController` `CurrentHorizontalResolution` / `CurrentVerticalResolution` / `CurrentRefreshRate` are filled in when the driver initializes and are NOT re-read when the mode changes. They can report a display mode the machine left hours ago. In one case they reported 1920x1080 while the real mode, from `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)`, was 1280x720. The refresh rate happened to be correct and the resolution was wrong, and nothing in the WMI output distinguishes the two. Both look equally authoritative.

What exposed it was a second API that disagreed: `System.Windows.Forms.Screen.AllScreens` reported 1280x720 bounds in the same call. **When two state-reading APIs disagree about the same moment, that isn't noise to average or a choice of which value looks likelier. It means at least one of them isn't reading live state, and your job is to find out which.**

**Rule:** For any state you will REPORT to a user or base a decision on, prefer the API whose contract is "read the live value now" over one that is convenient or already in your output. On Windows, use `EnumDisplaySettings` rather than `Win32_VideoController` for the display mode. The same trap exists for anything cached at init: WMI `Win32_*` snapshots, `/proc` values sampled once, ORM-level caches, and any `Get-*` that returns a driver-reported struct instead of querying.

Close the issue out with corroboration, not by re-reading the same API. For example, restart the consuming application and confirm that its own log now reports the expected value.

### 24. sqlite3 `readfile()` Stores a BLOB, and a Node App Receives a BLOB as a Buffer That 500s the Page

If you insert file content with the sqlite3 CLI's `readfile()`, the row's `typeof(answer)` is `'blob'`, not `'text'`. better-sqlite3 returns a BLOB as a Node Buffer, so render code that calls `.replace` on it throws `TypeError: a.replace is not a function`, and every SSR request for that page returns HTTP 500. The insert reports success, and the row looks correct to `select length(answer)`.

Rules:
1. When you load file content into SQLite from the CLI, wrap it: `CAST(readfile('/path') AS TEXT)`. `readfile()` is documented to return a blob, and you can't see the type unless you ask for `typeof()`.
2. After inserting any row by hand into a live app's DB, check `typeof()` on the column AND fetch the page that renders it, not just the row. A row that selects cleanly can still have the wrong storage class for the code that reads it.
3. Byte length and character length differ after the cast when the text contains multi-byte characters. That difference confirms the text decoded as UTF-8. It is not a sign of truncation.

### 25. A Reply Address Must Name Where the Payload Landed, Not a Location the Job Was Holding

A feature that both DELIVERS a payload to a location and ADDRESSES a reply channel back to it has two separate ideas of "the location," and they can drift apart without any error. When they do, every component tests green and the user still reports the feature as broken, because a correct delivery to the wrong place looks the same as no delivery.

Example shape: a long answer is moved into a NEW overflow thread created when it's posted, while the notification email builds its Reply-To from the streaming thread id stored on the job record. Both threads are real and live under the same parent. The reply relays correctly, the agent answers correctly, the completion mention fires correctly, and all of it lands in the thread that only holds progress updates, while the user is reading the thread that holds the answer.

Two tells that this bug is present:
1. The code has a thread, channel, or room id from EARLIER in the job (a record field, a variable captured at the start) and uses it as an address, while the actual post happens LATER through a helper that may create its own destination.
2. The posting helper returns void. A function that chooses a destination and doesn't report it forces every caller to guess.

**Fix shape:** Have the posting helper RETURN the surface it delivered to (and null if it didn't create one). The caller builds the address from that return value and falls back to the previously known id only when the helper created nothing new. Also make the divergence visible: the abandoned surface should point at the real one ("Answer: <link>"), or it looks like a job that produced nothing.

Follow-on rules:
- **Log the destination you resolved to, not the one you were given.** A log line that prints the ADDRESSED id makes a misroute look like a healthy relay and sends the investigation to the transport code. Any line that reports a delivery must print where the payload actually landed.
- **A sent address can't be rewritten.** Fixing the code only helps future sends. Every message already delivered still points at the old surface. Store the move as a redirect that is resolved at delivery time, limit the number of hops, and guard against cycles. Keep every trust check on the ORIGINAL signed id, so the redirect changes the address but never the authorization.

**Debugging tell:** When a user says "I replied and nothing showed up," don't start from the relay. Get the id of the surface the user is looking at and the id the system posted to, and compare them BEFORE you read any transport code.

### 26. Size a Retry Against the Dependency's Recovery Time, and Log the Cause Chain

1. **Size the retry against recovery, not against a blink.** A client that retries a transport failure once, 30 seconds later, can only survive packet loss. If the dependency is a container on another host reached through an autossh reverse tunnel, neither of its recovery paths finishes in 30s. Recreating the container refuses connections for the entire `docker compose up -d` cycle. After a tunnel drop, the SERVER keeps the dead session's port forward for up to `ClientAliveInterval x ClientAliveCountMax` (120s x 3 = 6 minutes), and the client's `ExitOnForwardFailure=yes` makes every reconnect in that window exit instead of binding the port.

   **Rule:** Before you pick a retry delay, identify the dependency's slowest NORMAL recovery event and read its actual duration from the config that controls it (systemd `RestartSec`, sshd `ClientAlive*`, a container healthcheck's `start_period`, an autoscaling cooldown). Back off across a window that covers that recovery. Stop early when the next sleep would run past the call's own abort deadline. Sleeping into an abort turns a diagnosable network error into a bare "timed out" and throws away the cause. For a job that only runs on a schedule, a lost run stays lost until the next tick, so this matters even more.

2. **Log the cause chain, because the wrapper message is the same for every transport failure.** undici (and Node's global fetch) reports EVERY transport failure as `TypeError: fetch failed` and puts the real reason on `.cause`. Logging only `err.message` records the same useless line whether the service is restarting, the tunnel dropped, or the far end reset the socket mid-body. With a `localhost` host, an all-refused connect arrives as an AggregateError with an empty `.message` and its reasons in `.errors`, not `.cause`, so a `.cause`-only walk adds nothing.

   **Rule:** Log the flattened cause chain. Walk BOTH `.cause` and `AggregateError.errors`, limit the depth (a cause can refer back to itself), and include `.code` at every level. Classify transient vs permanent against the FLATTENED string.

3. **A generic failure message puts the blame in the wrong place.** "Task processing failed. Please try again." reads as "your input broke it." When the transport never reached the service, say the service was unreachable. The user is deciding whether to spend another rate-limited action, and only the accurate message helps them decide.

If several apps were scaffolded from the same template, check each sibling before porting the fix. They may have diverged, and one may already be fixed or have a different defect.

### 27. A Progress Heartbeat That Stores Only a Timestamp Can't Say WHERE a Job Died

A job reaper that reaps on silence since `last_progress_at` (rather than age since `created_at`) is correct. But if `touchProgress(jobId, phase)` accepts the phase and only uses it in an error message, the database keeps the time and throws the phase away. When jobs are stranded and reaped, the only surviving evidence is "last heartbeat N minutes in" plus a vague log line in a process log that rotates daily and is gone before anyone looks. Every reaped job stores the same sentence, so the rows can't tell the failures apart.

Why it happens: a heartbeat gets written to answer "is this still alive?", which only needs a timestamp. The question people actually ask later is "where did it stop?", and the phase is the whole answer. One UPDATE serves both, and the diagnostic half costs nothing extra.

How to apply:
1. Store the phase next to the timestamp and include it in the terminal message the recovery sweep writes ("Interrupted ... (stopped during: sweep-board-212/419)"). Build that message in ONE function that the row, the email, and the chat notification all call, so three surfaces can't disagree about one event.
2. Audit for windows with no heartbeat. Any stretch between two heartbeats is a blind spot as large as the reaper's cutoff. A long phase should send heartbeats from INSIDE the phase (pass a per-item callback, throttled to about one write per minute), not only at its start and end.
3. A pool is not bounded just because each unit in it is. A `Promise.all` over workers whose fetches and child processes all have timeouts still never settles if ONE worker never settles, and the job is stranded inside a LIVE process where a restart-triggered reaper never fires. Wrap the pool in a wall-clock deadline that fails open. The deadline must NOT cancel the underlying work: an orphaned promise costs a little memory, while a stranded job costs the user the entire run.

### 28. A Collapsed `<details>` Still Mounts and Renders Every Child

An HTML `<details>` element keeps its children in the DOM when collapsed; CSS only hides them. If you render N heavy children (for example, a `react-markdown` + `rehype-sanitize` tree per item) inside collapsed `<details>` elements, all N are parsed up front and parsed again on every parent re-render, even if nobody opens a section. A polling list page (say, a 3s poll) re-parses every collapsed item's markdown on every tick, which makes large lists lag. A fresh JSON string on each poll also defeats naive `React.memo` or identity checks, so the markdown is re-parsed even when the content hasn't changed.

**How to apply:** When each item in a list of collapsible items renders expensive content (markdown, syntax highlighting, embedded media), don't assume the closed state of a `<details>` or accordion saves you that cost. Either lazy-mount the child (render nothing, or a lightweight placeholder, until the first expand), or memoize the parsed output so a poll that didn't change an item's content doesn't re-run the parser. This applies beyond `<details>` to any CSS-only hide (`display:none`, `hidden`, a closed `<Collapsible>`). None of them unmount, so none of them remove the render cost of what they hide.

### 29. A Numeric Guard With Mismatched Units on Each Side Never Fires, and Nothing Looks Broken

A memory-pressure watchdog's "spare a small process" branch compared a process's RSS from `ps`, which reports **kilobytes**, directly against a threshold named and configured in **megabytes**, with no conversion: `[ "$rss" -lt "$MIN_TARGET_MB" ]`. Both sides are bare integers, so the shell never raises a type error. The comparison is simply always false, because a real multi-GB process's RSS in KB is orders of magnitude larger than the MB threshold (`3145728 -lt 3` is never true). A guard like this can pass review and stay live through real pressure events without ever taking its branch. It produces no crash, no error log, and no sign that separates "correctly false" from "can never be true."

What catches it is a **contained live-fire test**: deliberately spawn a decoy process sized to cross the intended threshold and confirm that the branch runs. Don't treat a quiet log (no "guard fired" lines) as evidence that the condition simply never happened.

Why it's easy to miss: a correctly converted value often sits right next to the bad comparison (for example, a GB figure computed on the next line only for a log message), which makes the code look unit-aware even though the actual comparison isn't. It has the same shape as the grep-gate bug in section 21: a gate that can never be satisfied looks the same, on a static read or a quiet run, as a gate that has never been triggered.

**How to apply:** For any bash (or other untyped numeric) comparison against a hardcoded threshold, check that the units agree at the comparison itself, not just in the display code. `ps -o rss=` returns KB no matter what the constant it's compared with is called. Put the unit in the variable name (`rss_kb`, not `rss`) so a mismatch shows up in the diff. For any guard whose condition is rare (it only triggers under real pressure or scale), create the triggering condition once, on purpose, and confirm the branch runs.

### 30. A Descending Threshold List Scanned First-Match-Then-Break Fires the WIDEST Crossed Tier, Not the Most Urgent

An expiry reminder ordered its tiers widest window first (`[30, 14, 7, 1]` days) and scanned them with "take the first tier whose window is crossed and not yet sent, act, then `break`." With descending order, the **first** match is the **widest** tier, which is the opposite of the "send the most urgent threshold" comment on the loop. On the common path you can't see the bug: an item tracked from beyond the widest window crosses exactly one new tier per evaluation, so the first crossed tier and the only crossed tier are the same.

The bug appears when an item enters **mid-range**, already past one or more tiers the first time it is evaluated (for example, added with 5 days left, so the 30d and 14d tiers are both already crossed). A per-tier dedup log on a **fixed cron schedule** makes it worse. Each run logs only the ONE tier it fired, so the wider tiers it skipped stay marked unsent. On the next tick the item crosses the *next* tier down and fires again: 30d, 14d, 7d, 1d, one notification per day for four days instead of one. Each individual send looks correct (a real crossed-and-unsent tier), so nothing flags it as a duplicate.

Why it's easy to miss: the comment describes the intended behavior correctly, and the `break` visibly enforces "only one per run." A reviewer checking "does it send more than one at a time?" sees the guard and moves on without checking *which* tier the guard picks when several are already crossed.

**How to apply:** Any tier, bucket, or threshold list scanned with first-match semantics (rate-limit escalation, discount or loyalty tiers, alert severity, retry backoff selection) must choose by **comparing the crossed candidates with each other**. The order of the source array is a display or config concern, not a selection algorithm. Concretely: collect every tier whose condition is met and not yet handled, pick the most urgent (narrowest window or highest severity) by explicit comparison, and mark **all** of the collected tiers as handled in the same pass, not just the one that fired. Otherwise the skipped wider tiers stay live and fire again on the next tick. Test the case where the input starts already past several tiers, not only the case where it crosses them one at a time. The one-at-a-time path is the one every reviewer's mental model follows by default.
