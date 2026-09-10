<!-- Load when: diagnosing issues, log analysis -->
# Debugging Guidance

A systematic approach to diagnosing and fixing issues.

## The Debugging Workflow

```
0. Gather Context → 1. Reproduce → 2. Read the Error → 3. Isolate → 4. Hypothesize → 5. Verify → 6. Fix → 7. Confirm
```

### 0. Gather Existing Knowledge First

Before touching code or forming hypotheses, check whether this problem (or a closely related one) has been solved before:

- **Memory**: Read relevant feedback/project memory files; corrections from past sessions are your highest-signal source
- **CLAUDE.md**: The repo's CLAUDE.md documents architecture decisions and known gotchas
- **Guidance**: Check this repo's other guidance files for domain-specific rules
- **Knowledge base**: Scan your knowledge base index for cross-repo patterns
- **Your private context repo**: Check for credentials, registered URIs, or infrastructure details that constrain the solution
- **Git history**: `git log --oneline --grep="<keyword>"` to find prior fixes

This is not optional background reading; it's the most efficient debugging step. **The previous session's fix is often already documented in memory.** Skipping this to "save time" causes multi-hour debugging loops.

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
| Script silently produces empty results | Path from JSON/jq contains `~`, not expanded by shell. Use `${VAR/#\~/$HOME}` |

### 8. After Fixing

- Remove all debug logging before committing.
- Write a regression test if possible.
- Document the root cause in the commit message.
- Update `context.md` if the fix reveals something about the environment.

### 9. SQLite & Prisma Specifics

- **Database is locked**: In SQLite, concurrent writes cause locking.
  - **Fix**: Move updateMany or createMany calls OUT of loops. Consolidate into a single operation per user/batch.
  - **Pragma**: Use PRAGMA busy_timeout=5000; to make SQLite wait instead of failing immediately.
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
- **Prisma singleton: always assign to global, even in production.** The common guard `if (process.env.NODE_ENV !== 'production')` before `globalForPrisma.prisma = prisma` is wrong; Next.js worker threads reload modules without reinitializing globals. Remove the guard:
  ```ts
  export const prisma = globalForPrisma.prisma || createPrisma();
  globalForPrisma.prisma = prisma;  // always, not just in dev
  ```
  (Observed as an OOM crash loop that only stopped once the guard was removed.)
- **Next.js apps OOMing under load:** Increase heap in the process manager's config:
  ```js
  env: { NODE_OPTIONS: '--max-old-space-size=1024' }
  ```
  Also raise the memory-restart threshold to match (e.g., `1G`).
- **`datetime('now')` strings parse as LOCAL time in `new Date()`, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"` (space-separated, no `T`/`Z`). The ECMAScript Date parser treats that non-ISO form as local time, so rendering a stored timestamp via `new Date(created_at)` silently shifts it by the viewer's UTC offset, and can shift the displayed date near UTC midnight. This bites both Prisma-on-SQLite and raw `better-sqlite3` apps alike; it's a JS Date-parsing bug, not a Prisma one.
  - **Fix**: normalize before parsing; strict-match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/` and rewrite to `` `${date}T${time}Z` ``; pass already-ISO strings through unchanged. SQL-side comparisons like `date(created_at) = utcToday` are unaffected (both sides stay UTC).
  - Verify with: `new Date('2026-07-06 12:00:00').toISOString()` on a non-UTC host. Check for copies of the same timestamp component cloned into sibling apps; the bug travels with the copy.
- **Prisma `NOT:` logical wrapper excludes NULL rows on nullable columns.** `NOT: { field: value }` compiles to SQL `NOT(col = 'value')`, which is NULL, and therefore excluded, for any row where the column IS NULL. The result: null-valued rows silently disappear from the result set with no error. Observed case: `NOT: { accountStatus: "closed" }` dropped every account with a null `accountStatus`, returning 3,420 of 12,851 rows (73% silent loss). Fix: when negating a NULLABLE column while still wanting NULL rows, use the explicit OR form: `OR: [{ field: null }, { field: { not: value } }]`. Self-review trigger: any Prisma `NOT:` filter on a nullable column, especially in queries with unexpectedly low row counts.

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

An automation flow that dispatches work to a `claude -p` agent runs with no TTY. Any CLI the agent invokes that blocks on interactive input (e.g. a `readline` "approve/edit?" prompt) will hang silently, and the agent will quietly fall back to a worse path (or time out). Symptoms: "the tool exists and is wired up, but the nice pipeline never seems to actually run."

Fixes:
- Give the tool an `--auto`/`--yes` flag AND auto-enable it when `!process.stdin.isTTY`, so it never hangs regardless of how it's launched.
- Don't depend on an `ANTHROPIC_API_KEY` for sub-steps; route model calls through the `claude -p` CLI (subscription auth) so the tool runs in the same keyless environment as the agent.
- Make the tested tool the canonical path; prompts that re-describe a "manual fallback" flow drift and silently lose features.

### 12. Browser CDP Timeout Recovery: Kill + Restart Pattern

When a service calls a browser-agent CLI and receives "Timeout waiting for browser response", the Chrome/CDP session is stuck (not just slow). Recovery requires:

1. Detect the specific timeout error string in your error handler
2. Kill all chrome/chromium processes: `pkill -f chrome || true`
3. Restart the browser-agent service via your process manager
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
  execSync('<process-manager> restart browser-agent');
  await new Promise(resolve => setTimeout(resolve, 3000)); // wait for startup
}
```

Also increase the base CLI timeout from 60s to 120s to avoid false-positive timeouts on slow page loads (separate from CDP hangs).

### 13. Reading a SQLite DB Another Process Is Actively Writing (WAL Mode)

When polling a SQLite database that a running app writes to (e.g. a desktop app's `*.sqlite` in WAL mode), a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot**; it reads committed WAL frames as of some earlier point and doesn't advance, even across freshly-spawned reader processes. Classic symptom: "it caught the first change but never the next ones," while the process is alive and manual one-off queries look current.

Fix: open a **normal (read-write-capable) connection with `PRAGMA query_only=ON`** instead. It participates in the WAL protocol correctly and reliably sees the latest committed rows, while `query_only` guarantees you never modify the app's data. Add `.timeout <ms>` so a momentary writer lock yields a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

Second gotcha when your reader writes to the macOS clipboard: an app that pastes via the clipboard often does save → paste → **restore**, clobbering your write. Re-assert (re-`pbcopy`) for ~1s, checking `pbpaste`, to win the race.

### 14. Error Log Lines Ending in a Bare Colon = Logger Dropping Arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`; extra args after a string message are printf interpolation values, and with no `%s`/`%d`/`%o` in the message they are **silently discarded**. Console-style calls like `logger.error('failed:', err.message)` produce `"msg":"failed:"`; the diagnostic ends at the colon and the actual error never reaches any log. Symptom while debugging: an error repeats but its message trails off with `:` and nothing after.

Fixing call sites one-by-one does not work: repeated audit passes still left 100+ multi-arg sites, and new ones reappear with every feature. **Fix the class at the logger:** install a `hooks.logMethod` that appends would-be-dropped extras to the message. Canonical `(obj, msg)` and printf-style calls pass through untouched. Any repo that adopts pino gets the hook from day one.

### 15. `claude -p` Is the Full Agentic CLI: Empty CWD for Free-Text, Retry Broadly

`claude -p --dangerously-skip-permissions` is the FULL agentic Claude Code CLI, not a constrained text-completion endpoint. Two operational consequences apply to any pipeline that shells out to it:

1. **CWD hygiene.** When the subprocess runs with its working directory inside a repo, the spawned sub-agent can explore that repo and inject meta-commentary into its output (observed: a generated free-text brief narrated the relative source path it was invoked from). FIX: for free-text generation calls, set the subprocess cwd to an empty/neutral directory (e.g. `tempfile.mkdtemp()`) so there is no repo to explore. For calls whose output is strictly parsed (e.g. JSON extraction) the risk is lower, but the same cwd hygiene is cheap insurance.

2. **Retry breadth.** Retry logic for `claude -p` must retry on ANY non-zero exit code AND on empty stdout, not only when stderr matches "rate"/"limit". Nested `claude -p` invocations intermittently exit 1 with an EMPTY stderr (a transient); code that only retries on rate/limit strings hard-fails on the first blip. FIX: retry on any non-zero return or empty output, with exponential backoff, up to N attempts.

### 16. `git symbolic-ref origin/HEAD` Exits 128 When Unset; Under `set -euo pipefail` It Silently Kills the Rest of the Script

`origin/HEAD` is populated by `git clone` and by nothing else: not by `git remote add` + fetch, and never refreshed afterwards. On a checkout that lacks it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128.

Under `set -euo pipefail`, piping that into sed does NOT save you: pipefail promotes the 128 past the sed, and `set -e` terminates the script. A trailing `2>/dev/null` hides the MESSAGE but not the exit code, which makes the line look handled when it is not.

Observed: a watchdog script died two-thirds of the way through on every run for months. Everything below that line never ran, including its reachability check and the entire alert-sending block. The proof was its state file, written on the last line, frozen at the exact date the check was added.

**Why:** exit-code propagation through pipefail is invisible when stderr is suppressed. **How to apply:** any command substitution that can legitimately fail needs an explicit `|| true` under `set -e`, especially git plumbing. When a long script has an unexplained silent partial-effect, check for a mid-script non-zero exit before suspecting logic. A frozen end-of-script state file is the cheapest proof.

### 17. cron PATH Excludes /usr/local/bin; With `set -e` That Kills a Script Silently, and a Silent Job's Log mtime Never Moves

cron runs with `PATH=/usr/bin:/bin`. Anything in `/usr/local/bin` (node, npm, process managers, and most globally-installed tooling) is NOT found. Combined with `set -euo pipefail`, the first such call kills the script before it does anything.

Observed: a process-manager watchdog had been dying on every scheduled run because its process-manager binary was not on cron's PATH. It is a MONITOR, so its death meant nothing was watching the processes at all.

The compounding nuance, which is the reusable part: `>>` updates a log file's mtime only on an actual WRITE, not on open. A job that fails before producing output leaves its log 0 bytes with the mtime frozen at whenever it last wrote. So a freshness checker watching that file sees nothing move and cannot distinguish "silently dead for weeks" from "never had anything to say".

**Why:** cron deliberately uses a minimal environment; `set -e` turns a missing binary into a silent full stop. **How to apply:** put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of any script cron will run, or declare `PATH=` in the crontab. When a script works interactively but fails under cron, reproduce with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c ...` before theorising. Never conclude a job is healthy from log mtime.

### 18. An Empty `err.message` (AggregateError) Makes a Fallback String Look Like the Real Error

Node >= 20 dials a `localhost` hostname with happy-eyeballs (::1 and 127.0.0.1 in parallel). When BOTH fail it throws an AggregateError whose `.message` is the EMPTY STRING, with the real per-address errors in `.errors`. So the ubiquitous idiom `err.message || "some fallback"` selects the fallback and the diagnosis is gone.

Observed: an app stored and logged "Recovery failed: recovery failed" as its only record of an outage, naming neither the code nor the port, so identifying it took a live repro. undici compounds it: every connection failure is reported as the opaque string "fetch failed" with the real reason hidden in `.cause`.

It is ENVIRONMENT-DEPENDENT, which is why it does not reproduce locally: a single-stack host resolves localhost to one address and throws a plain Error with a usable message; a dual-stack host throws the empty-message AggregateError. A test that dials a dead port therefore asserts different things on the two machines; build the AggregateError by hand in the test instead.

How to apply:
1. Never format an error with `.message` alone. Use a `describeError()` that walks `.errors` and `.cause` and appends code + address:port.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match the FULL description, or an AggregateError carrying ECONNREFUSED reads as non-transient and is treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature; it means the fallback fired, not that the error was unhelpful.

### 19. A Composer-Style Tab Row Directly Above a Feed Reads as a Filter for That Feed

When a tab strip that only scopes an input control sits immediately above a result list, users read it as a filter on the list and report the list as broken ("X selected, cannot click on Y") even when the list is not gated at all. Two fixes, both cheap: label the tab row for what it actually scopes, and give the list its own explicit filter with an All default.

Before rewriting behaviour, prove the gating claim: hit-test each row with `document.elementFromPoint` at its centre and check the tag/href, which separates "an overlay eats the tap" from "this row was never a link" from "the user misread the control". In the observed case the real defect the report pointed at was different from its literal wording: pending rows rendered as a div with no href, so any still-running result was genuinely unclickable.

### 20. One Split Multi-Byte Character Makes grep Treat a Whole Text File as Binary and Report Nothing, With No Error

Observed in a generated index file whose per-entry hooks are truncated to a fixed width; one truncation cut a UTF-8 ellipsis in half, leaving an orphan `\xe2\x80` immediately before a valid `\xe2\x80\xa6`. Two stray bytes in 13KB.

The failure mode is silence, not an error. grep classifies the file as binary and suppresses matches, so `grep -n <term> FILE` printed nothing and `grep -c "" FILE` printed nothing, which reads exactly like "that term is not in the file". Three greps in a row came back empty before python's `open().read()` finally raised `UnicodeDecodeError` and named the offset. Note that `grep -a` would have worked all along, and so would python with `errors='replace'`; the trap is that the natural first tool fails quietly.

Detect: `python3 -c "open(P,encoding='utf-8').read()"` and let it raise; the exception carries the byte offset. Or `file P` (reports "data" rather than "UTF-8 Unicode text"), or `grep -c $ P` vs `grep -ac $ P` disagreeing.

Repair: read bytes, splice out the orphan sequence, `decode()` to prove the whole file is clean BEFORE writing back.

Generalises to any generated file whose lines are truncated to a width: index files, log summaries, digests, commit-message subjects, anything doing `s[:80]` on text that may contain non-ASCII. Truncate by characters after decoding, never by bytes.

### 21. A Grep-Gated Feature Never Fires When the Gate Pattern Doesn't Match the Actual Generated Content

A pipeline gated its crash-context injection on `grep -q "crash-priority|restart_time|CRASH CONTEXT"` against generated `*-priority.md` files, but the prompt template that actually WRITES those files never emits any of those three substrings (it writes `**Restart count:**` and `## Classification: <...>`). Result: the write side had been implemented and was producing real files, but the read side's gate silently never matched, so the context was NEVER injected: a fully dark feature with no error, no log line, nothing. Fixed by changing the gate to `grep -q "^## Classification:"`, the heading every real file actually contains, verified directly against a live generated file (old pattern: no match; new pattern: match).

**General lesson:** when a producer and consumer communicate via a string/grep match on generated content rather than a shared constant or schema, verify the match condition against a REAL generated sample, not against the keywords that seem intuitive. This class of bug produces zero errors and zero symptoms, so it only surfaces via direct inspection of whether the consumer's condition ever actually fires.

### 22. An Empty Search Result Has Two Causes: The Thing Is Absent, or the Query Was Incapable of Finding It

These are indistinguishable from the output, and the second is far more common than it feels. Reporting "clean" without separating them is asserting a negative you did not establish.

Two observed patterns that produce the silent failure:
1. **Grepping the transport, not the sink.** A grep for the obvious pattern (a webhook URL constant, a function name) misses a call that uses a local variable assigned one expression away (`const url = process.env.X_WEBHOOK_URL`, then `fetch(url)`). Before declaring "no calls to X", trace all aliases and wrapping functions, not just the literal constant.
2. **Grepping a file that grep treats as binary.** A file with embedded NUL bytes or a split multibyte character makes grep silently find nothing for patterns that are plainly present: `grep -n "pattern" file.js` returns zero hits while `grep -an "pattern" file.js` returns the expected lines. Detect with `file <path>` (says "data" not "ASCII text"); use `grep -a` on files suspected to contain binary markers.

Rule: before reporting "not found," prove the query could have found the thing. The cheapest discriminator is to grep for a string you can *see* in the file and confirm it matches. A search that finds a known-present sentinel is a calibrated search; one that returns nothing for a sentinel you expect is itself the finding.

### 23. A Cached/Stale State API Makes You Report a Confidently Wrong Number

Diagnosing why a display was capped at 30fps, the mode was read from Windows WMI `Win32_VideoController` (`CurrentHorizontalResolution`, `CurrentVerticalResolution`, `CurrentRefreshRate`) and reported to the user as "1920x1080 @ 30Hz". The real mode, from `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)`, was **1280x720 @ 30Hz**. WMI's `Current*` fields are populated at driver init and are NOT re-read on mode change, so they can report a mode the machine has not been in for hours. The refresh rate happened to be right, the resolution was wrong, and nothing in the WMI output distinguishes the two; both look equally authoritative.

What made it survivable: another API disagreed. `System.Windows.Forms.Screen.AllScreens` reported bounds of 1280x720 in the *same* parallel tool call. **Two state-reading APIs disagreeing about the same instant is not noise to average out or pick the likelier value from; it means at least one is not reading live state, and the question is which.** Same shape as a web-fetch summarizer confidently misreading a document it fetched correctly, and the same resolution: go to the authoritative source rather than adjudicating between convenient ones.

Rule: for any state you are going to REPORT to a user or branch a decision on, prefer the API whose contract is "read the live value now" over the one that is convenient or already in your output. On Windows specifically: `EnumDisplaySettings` over `Win32_VideoController` for display mode; and note the same class of trap exists for anything cached at init (WMI `Win32_*` snapshots, `/proc` values sampled once, ORM-level caches, any `Get-*` that returns a driver-reported struct rather than querying).

Corroboration beats assertion when closing this out: the fix was confirmed not by re-reading the same API, but by restarting the CONSUMER and checking IT reported the corrected refresh rate, plus finding a pre-fix log line proving the client had been asking for the higher rate all along and the display was the refusing party.

### 24. `sqlite3 readfile()` Stores a BLOB, and a BLOB Column Reaches a Node App as a Buffer That 500s the Page

Inserting a markdown answer into a table with the sqlite3 CLI's `readfile()` produced a row whose `typeof(answer)` is `'blob'`, not `'text'`. better-sqlite3 returns a BLOB as a Node Buffer, so the render path called `.replace` on a Buffer and every SSR request for that page died with `TypeError: a.replace is not a function` and an HTTP 500. The insert itself reported success and the row looked correct to `select length(answer)`.

Rules:
1. When loading file content into SQLite from the CLI, wrap it: `CAST(readfile('/path') AS TEXT)`. `readfile()` is documented to return a blob; the type is invisible unless you ask for `typeof()`.
2. After any hand-written row insert into a live app's DB, check `typeof()` on the column AND fetch the rendering page, not just the row. A row that selects cleanly can still be the wrong storage class for the consumer.
3. Byte length and character length differ after the cast (35618 bytes to 35320 characters here, from multi-byte characters). That difference is the confirmation the text decoded as UTF-8, not a sign of truncation.
4. Symptom to recognize: a Node/Next.js page that 500s with `X.replace is not a function` inside an `Array.map` right after a manual DB write is a storage-class bug, not a data bug.

### 25. A Reply-Address Must Name Where the Payload Landed, Not a Location the Job Was Holding

A feature that both DELIVERS a payload to a location and ADDRESSES a reply channel back to it has two independent notions of "the location", and they can silently diverge. When they do, every component tests green and the user still reports the feature as broken, because a correct delivery to the wrong place is indistinguishable from no delivery at all.

Concrete shape: a long answer is folded into a NEW overflow thread created at post time, while the completion email derived its Reply-To from the job record's original streaming thread id. Both were real, live, in the same parent channel. The emailed reply relayed correctly, the agent answered correctly, the "your follow-up is complete" mention fired correctly, and all three landed in the thread holding only progress updates while the user read the thread holding the answer.

Two tells that this class of bug is present:
1. The code has a thread/channel/room id in hand from EARLIER in the job (a record field, a variable captured at start) and uses it for an address, while the actual post happens LATER through a helper that may create its own destination.
2. The posting helper returns void. A function that chooses a destination and does not report it forces every caller to guess.

Fix shape: make the posting helper RETURN the surface it delivered to (and null when it did not create one), and have the caller derive the address from that return value, falling back to the previously known id only when the helper made no new surface. Also name the divergence where it is visible: the abandoned surface should point at the real one ("Answer: <link>"), or it reads as a job that produced nothing.

Two follow-on rules, both code rules rather than debugging tells:
1. **LOG THE DESTINATION YOU RESOLVED TO, not the one you were handed.** The log line read "Relaying ... into thread `<id>`" using the ADDRESSED id, so the misroute looked like a healthy relay in the logs and sent the investigation at the transport code instead of at the two ids. Any line that reports a delivery must print the surface the payload actually landed on.
2. **A SENT ADDRESS CANNOT BE REWRITTEN.** If the reply-address is signed (or simply already delivered), fixing the code only helps future sends; everything already in the recipient's inbox still points at the old surface. Persist the move as a redirect resolved at delivery time, bound the hops and guard the cycle, and keep every trust gate on the ORIGINAL signed id so the redirect rewrites the address and never the authorisation.

Debugging tell: when a user says "I replied and nothing showed up", do not start from the relay. Get the id of the surface the user is looking at and the id the system posted to, and compare them BEFORE reading any transport code.

### 26. Size a Retry Against the Dependency's Recovery Time, and Log the Cause Chain

1. **THE RETRY WAS SIZED AGAINST A BLINK, NOT AGAINST RECOVERY.** A client retried a transport failure once, 30 seconds later, then failed the job. But the dependency was a container on another host reached over a reverse SSH tunnel, and NEITHER of its recovery paths finishes in 30s: recreating the container refuses connections for the whole `docker compose up -d` cycle, and after a tunnel drop the SERVER holds the dead session's forward for up to `ClientAliveInterval x ClientAliveCountMax` (120s x 3 = 6 minutes) while the client's `ExitOnForwardFailure=yes` makes every reconnect inside that window exit instead of binding the port. So the retry constant was chosen against an imagined packet loss, not against the measured time the service takes to come back.

   RULE: before picking a retry delay, name the dependency's slowest NORMAL recovery event and read its actual duration out of the config that governs it (systemd `RestartSec`, sshd `ClientAlive*`, a container healthcheck's `start_period`, an autoscaler's cooldown). A single retry is only correct when the failure is a lost packet. Back off across a window that covers the recovery, and stop early when the next sleep would outlive the call's own abort deadline; sleeping into an abort converts a diagnosable network error into a bare "timed out" and discards the cause.

2. **THE LOG THREW THE DIAGNOSIS AWAY.** undici (and Node's global fetch) reports EVERY transport failure as the same six characters, `TypeError: fetch failed`, and puts the real reason on `.cause`. Logging `err.message` alone therefore records an identical, useless line whether the service is mid-restart, the tunnel dropped, or the far end reset the socket mid-body. Two days of production failures left exactly one repeated line and nothing to tell the three apart.

   Worse: when the URL host is `localhost` it resolves to BOTH ::1 and 127.0.0.1, so an all-refused connect arrives as an AggregateError whose own `.message` is the EMPTY STRING and whose real reasons live in `.errors`, not in `.cause`. A `.cause`-only walk prints "(no message)" and adds nothing.

   RULE: log the flattened cause chain, not `err.message`. Walk BOTH `.cause` and `AggregateError.errors`, bound the depth (a cause can be self-referential), and include `.code` at each level. Classify transient-vs-permanent against the FLATTENED string for the same reason: a matcher reading only the outer message cannot see ECONNREFUSED behind an empty-message AggregateError.

3. **A GENERIC FAILURE MESSAGE MISATTRIBUTES BLAME.** "Task processing failed. Please try again." reads as "your input broke it". When the transport never reached the service, say the service was unreachable: the user is deciding whether to spend another rate-limited action, and only one of those two messages answers that.

   When porting this fix, check the sibling app before assuming it needs the same patch: scaffolded clones diverge, and one may already read `.cause` while another still carries the single-retry sleep.

### 27. A Progress Heartbeat That Stores Only a Timestamp Cannot Say WHERE a Job Died

A job reaper was correctly rewritten to reap on silence since `last_progress_at` rather than age since `created_at`. But `touchJobProgress(id, phase)` took the phase and used it ONLY inside an error message: the column stored the time and threw the phase away.

Two long-running jobs then stranded and were reaped. Investigating two days later, the only surviving evidence was "last heartbeat 18-22 minutes in" plus one line, `Unexpected error: fetch failed`, in a process-manager log that rotates daily and had already been flushed. Every reaped job stored the identical sentence, so the row could not tell them apart either.

Why: a heartbeat gets written to answer "is this still alive?", which is a liveness question, and liveness only needs a timestamp. The question actually asked later is always "where did it stop?", which is a diagnosis question, and the phase is the whole answer. The two get conflated because one UPDATE serves both and the diagnosis half is free.

How to apply:
1. Persist the phase next to the timestamp and put it in the terminal message the recovery sweep writes ("Interrupted ... (stopped during: sweep-item-212/419)"). Build that message from ONE function the row, the email and the notification all call, so three surfaces cannot disagree about one event.
2. Audit for heartbeat-free windows. Any stretch between two stamps is a blind spot sized by the reaper's cutoff. A long phase should heartbeat from INSIDE (pass a per-item callback, throttled to one write a minute), not only at its boundaries.
3. A pool is not bounded just because its units are. An enrichment phase built as a `Promise.all` over workers whose fetches had 12s timeouts and whose child processes had kill-signal timeouts still hangs forever if ONE worker never settles: `Promise.all` never settles and strands the whole job inside a LIVE process, where a restart-triggered reaper never fires. Wrap the pool in a wall-clock deadline that fails open. The deadline must NOT cancel the underlying work: an orphaned promise costs a little memory, a stranded job costs the user the entire run.
4. For a job that only runs on a schedule, a lost run is lost until the next tick, so size retries against the dependency's real recovery time rather than against a blink.

### 28. A Collapsed `<details>` Still Mounts and Renders Every Child; "Collapsed" Is Not "Unmounted"

An HTML `<details>` element keeps its children in the DOM when collapsed; it only hides them visually via CSS. Rendering N heavy children (e.g. a `react-markdown` + `rehype-sanitize` tree per item) inside a collapsed `<details>` parses all N up front, and re-parses them on every parent re-render, even though nobody opened the section. On one list-detail page this was the dominant cause of "the list page lags when it has a lot of results": a 3s poll re-triggered the full re-parse of every collapsed item's markdown on every tick, independent of whether any section was ever expanded. A fresh JSON string on each poll also defeats naive `React.memo`/identity checks, so the markdown re-parses even when the underlying content hasn't changed.

**How to apply:** when a list of collapsible items each renders expensive content (markdown, syntax highlighting, embedded media), don't assume `<details>`/an accordion's closed state protects you from that cost. Either lazy-mount the child (render nothing, or a lightweight placeholder, until first expand) or memoize the parsed output so a poll that hasn't changed that item's content doesn't re-run the parser. This generalizes past `<details>` to any CSS-only-hide (`display:none`, `hidden`, a closed `<Collapsible>`); none of them unmount, so none of them free the render cost of what they're hiding.

### 29. A Numeric Guard With Mismatched Units on Either Side of the Comparison Never Fires

A memory-pressure watchdog's "spare a small process" branch compared a process's RSS, read from `ps`, which reports **kilobytes**, directly against a threshold constant named for and configured in **megabytes**, with no conversion at the comparison site (`[ "$rss" -lt "$MIN_TARGET_MB" ]`). Both sides are bare integers, so the shell never raises a type error; the comparison just always evaluates false, because a real multi-GB process's RSS in KB is three to four orders of magnitude larger than the intended MB threshold (e.g. `3145728 -lt 3` is never true). The guard shipped, passed review, and sat live through real memory-pressure events without ever once taking its intended branch: no crash, no error log, no symptom distinguishing "correctly evaluated false" from "structurally can't ever be true."

Found only by a **contained live-fire test**: deliberately spawning a decoy process sized to actually cross the intended threshold and confirming the guard's branch executes, rather than trusting a quiet log (no "guard fired" lines) as evidence the condition had simply never occurred.

**Why this is easy to miss:** a mismatched-unit comparison doesn't crash and produces no anomalous output of its own, and a correctly-converted value can sit right next to it (e.g. a GB figure computed on an adjacent line purely for a log message), which makes the surrounding code look unit-aware even though the actual comparison isn't. It's the same shape as the grep-gate pattern above: a gate that structurally cannot be satisfied is indistinguishable, from a static read or a quiet run, from a gate that has simply never been triggered.

**How to apply:** for any bash (or other untyped-numeric) comparison against a hardcoded threshold, check unit agreement explicitly at the comparison, not just at display time; a command like `ps -o rss=` returns KB regardless of what the constant it's compared against is named. Name the variable with its actual unit (`rss_kb`, not `rss`) so a mismatch is visible in the diff. For any guard whose fire condition is rare (only crosses under real pressure/scale), don't accept "it hasn't logged as firing" as evidence it works: construct the triggering condition once, on purpose, and confirm the branch actually executes.

### 30. A Descending-Order Threshold List Scanned First-Match-Then-Break Fires the WIDEST Crossed Tier, Not the Most Urgent One

An expiry reminder ordered its tiers widest-window-first (`[30, 14, 7, 1]` days) and scanned with "first tier whose window is crossed and unsent → act → `break`". Descending order plus first-match means the **first** tier that matches is the **widest** one, which is the opposite of the loop's own comment ("send the most urgent threshold"). On the common path this is invisible: an item tracked from beyond the widest window crosses exactly one new tier per evaluation, so first-crossed and only-crossed are the same tier and the bug never shows.

It only bites an item that enters **mid-range**: already past one or more tiers the first time it's ever evaluated (e.g. an item added with 5 days already left, so the 30d and 14d tiers are both already "crossed"). Compounded by a per-tier dedup log on a **fixed cron cadence**: each run logs only the ONE tier it fired and moves on, so the wider tiers it silently skipped stay marked unsent. The item then re-enters the loop on the next tick, crosses the *next* tier down, and fires again: 30d, then 14d, then 7d, then 1d, one notification per day for four days instead of one. Each individual send looks correct (a real crossed-and-unsent tier), so nothing flags it as a duplicate.

**Why this is easy to miss:** the loop's inline comment describes the intended behavior correctly ("most urgent"), and the code visibly tries to enforce "only one per run" via the `break`. Both readings are locally true; what's wrong is which tier `break` stops on. A reviewer checking "does it send more than one at a time" sees the guard and moves on without checking *which* one that guard selects when more than one tier is already crossed.

**How to apply:** any tier/bucket/threshold list scanned with first-match semantics (rate-limit escalation, discount/loyalty tiers, alert severity, retry backoff selection) must select by **comparing crossed candidates against each other**, not by declaring the array's iteration order authoritative; order in the source array is a display/config concern, not a selection algorithm. Concretely: collect every tier whose condition is met and unhandled, pick the most urgent (narrowest window / highest severity) by explicit comparison, and mark **all** of the collected tiers as handled in that same pass (not just the one that fired), otherwise the skipped wider tiers remain live to re-fire on the next tick. Test the case where the input starts already past several tiers, not just the case where it crosses them one at a time in sequence; the latter is the path every reviewer's mental model runs by default.
