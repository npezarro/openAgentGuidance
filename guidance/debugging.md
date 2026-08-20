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
- **Guidance**: Check the rest of the guidance repo for domain-specific rules covering the area you're in (auth, deployment, data access)
- **Knowledge base**: Scan your knowledge base index for cross-repo patterns
- **Private context repo**: Check for credentials, registered URIs, or infrastructure details that constrain the solution
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
- Update your environment notes if the fix reveals something about the environment.

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
  This took several successive commits to stabilise in one app; treat it as the starting configuration, not a last resort.
- **Prisma singleton: always assign to global, even in production.** The common guard `if (process.env.NODE_ENV !== 'production')` before `globalForPrisma.prisma = prisma` is wrong; Next.js worker threads reload modules without reinitializing globals. Remove the guard:
  ```ts
  export const prisma = globalForPrisma.prisma || createPrisma();
  globalForPrisma.prisma = prisma;  // always, not just in dev
  ```
  Observed as an OOM crash loop that persisted until the guard was removed.
- **Next.js apps OOMing under load:** Increase heap in your process manager's config:
  ```js
  env: { NODE_OPTIONS: '--max-old-space-size=1024' }
  ```
  Also raise the memory-restart threshold to match (e.g., `1G`).
- **`datetime('now')` strings parse as LOCAL time in `new Date()`, not UTC.** SQLite stores UTC as `"YYYY-MM-DD HH:MM:SS"` (space-separated, no `T`/`Z`). The ECMAScript Date parser treats that non-ISO form as local time, so rendering a stored timestamp via `new Date(created_at)` silently shifts it by the viewer's UTC offset (7-8h for US Pacific viewers), and can shift the displayed date near UTC midnight. This bites both Prisma-on-SQLite and raw `better-sqlite3` apps alike; it's a JS Date-parsing bug, not a Prisma one.
  - **Fix**: normalize before parsing; strict-match `/^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$/` and rewrite to `` `${date}T${time}Z` ``; pass already-ISO strings through unchanged. SQL-side comparisons like `date(created_at) = utcToday` are unaffected (both sides stay UTC).
  - Verify with: `new Date('2026-07-06 12:00:00').toISOString()` on a non-UTC host; it returns the local-shifted instant. When you find this in one component, grep for clones of that component across sibling projects; shared UI files get copied and carry the bug with them.

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
  execSync('<your process manager> restart browser-agent');
  await new Promise(resolve => setTimeout(resolve, 3000)); // wait for startup
}
```

Also increase the base CLI timeout from 60s to 120s to avoid false-positive timeouts on slow page loads (separate from CDP hangs). Without a recovery path, CDP sessions hang silently after connectivity loss and retries pile up forever.

### 13. Reading a SQLite DB Another Process Is Actively Writing (WAL Mode)

When polling a SQLite database that a running app writes to (e.g. a desktop app's `*.sqlite` in WAL mode), a `mode=ro` / `SQLITE_OPEN_READONLY` connection can return a **stale snapshot**; it reads committed WAL frames as of some earlier point and doesn't advance, even across freshly-spawned reader processes. Classic symptom: "it caught the first change but never the next ones," while the process is alive and manual one-off queries look current.

Fix: open a **normal (read-write-capable) connection with `PRAGMA query_only=ON`** instead. It participates in the WAL protocol correctly and reliably sees the latest committed rows, while `query_only` guarantees you never modify the app's data. Add `.timeout <ms>` so a momentary writer lock yields a retry instead of an empty read.

```sh
# stale under load:
sqlite3 "file:app.sqlite?mode=ro" "SELECT ..."
# reliable:
sqlite3 -cmd ".timeout 2000" -cmd "PRAGMA query_only=ON" app.sqlite "SELECT ..."
```

Second gotcha when your reader writes to the system clipboard: an app that pastes via the clipboard often does save→paste→**restore**, clobbering your write. Re-assert the copy for ~1s, checking the clipboard contents each time, to win the race.

### 14. Error Log Lines Ending in a Bare Colon = Logger Dropping Arguments (pino)

Pino's signature is `logger.error(mergingObject, msg)`; extra args after a string message are printf interpolation values, and with no `%s`/`%d`/`%o` in the message they are **silently discarded**. Console-style calls like `logger.error('failed:', err.message)` produce `"msg":"failed:"`; the diagnostic ends at the colon and the actual error never reaches any log. Symptom while debugging: an error repeats but its message trails off with `:` and nothing after.

Fixing call sites one-by-one does not work: two audit passes over one repo still left 135 multi-arg sites, and new ones reappear with every feature. **Fix the class at the logger:** install a `hooks.logMethod` that appends would-be-dropped extras to the message. Canonical `(obj, msg)` and printf-style calls pass through untouched. Any repo that adopts pino should get the hook from day one.

Cost of not doing this: a background job error-logged an upstream 500 every 5 minutes for hours with the cause invisible, weeks after a per-site audit had "fixed" the same bug class.

### 15. `claude -p` Is the Full Agentic CLI: Neutral CWD + Broad Retries

`claude -p --dangerously-skip-permissions` is the FULL agentic Claude Code CLI, not a constrained text-completion endpoint. Two operational consequences apply to any pipeline that shells out to it:

1. **CWD hygiene.** When the subprocess runs with its working directory inside a repo, the spawned sub-agent can explore that repo and inject meta-commentary into its output (observed: a generated free-text brief narrated the relative source path it was invoked from). FIX: for free-text generation calls, set the subprocess cwd to an empty/neutral directory (e.g. a `tempfile.mkdtemp()`) so there is no repo to explore. For calls whose output is strictly parsed (e.g. JSON extraction) the risk is lower, but the same cwd hygiene is cheap insurance.

2. **Retry breadth.** Retry logic for `claude -p` must retry on ANY non-zero exit code AND on empty stdout, not only when stderr matches "rate"/"limit". Nested `claude -p` invocations intermittently exit 1 with an EMPTY stderr (a transient); code that only retries on rate/limit strings hard-fails on the first blip. FIX: retry on any non-zero return or empty output, with exponential backoff, up to N attempts.

### 16. `git symbolic-ref origin/HEAD` Exits 128 When Unset and Kills the Script Under `set -e`

`origin/HEAD` is populated by `git clone` and by nothing else; not by `git remote add` + fetch, and never refreshed afterwards. On a checkout that lacks it, `git symbolic-ref refs/remotes/origin/HEAD` exits 128.

Under `set -euo pipefail`, piping that into `sed` does NOT save you: `pipefail` promotes the 128 past the `sed`, and `set -e` terminates the script. A trailing `2>/dev/null` hides the MESSAGE but not the exit code, which makes the line look handled when it is not.

Observed: a watchdog script died two-thirds of the way through on every run for weeks. Everything below that line never ran, including the reachability check and the entire alert-sending block. The proof was its state file, written on the last line, frozen at the exact date the check was added.

**Why:** exit-code propagation through `pipefail` is invisible when stderr is suppressed. **How to apply:** any command substitution that can legitimately fail needs an explicit `|| true` under `set -e`, especially git plumbing. When a long script has an unexplained silent partial-effect, check for a mid-script non-zero exit before suspecting logic. A frozen end-of-script state file is the cheapest proof.

### 17. cron PATH Excludes `/usr/local/bin`; With `set -e` That Kills a Script Silently

cron runs with `PATH=/usr/bin:/bin`. Anything in `/usr/local/bin` (node, npm, process managers, and most globally-installed tooling) is NOT found. Combined with `set -euo pipefail`, the first such call kills the script before it does anything.

Observed: a watchdog had been dying on every `*/5` run because its process-manager binary was not on cron's PATH. It is a MONITOR, so its death meant nothing was watching the thing it guarded.

The compounding nuance, which is the reusable part: `>>` updates a log file's mtime only on an actual WRITE, not on open. A job that fails before producing output leaves its log 0 bytes with the mtime frozen at whenever it last wrote. So a freshness checker watching that file sees nothing move and cannot distinguish "silently dead for weeks" from "never had anything to say."

**Why:** cron deliberately uses a minimal environment; `set -e` turns a missing binary into a silent full stop. **How to apply:** put `export PATH="/usr/local/bin:/usr/bin:/bin:$PATH"` at the top of any script cron will run, or declare `PATH=` in the crontab. When a script works interactively but fails under cron, reproduce with `env -i HOME=$HOME PATH=/usr/bin:/bin bash -c ...` before theorising. Never conclude a job is healthy from log mtime.

### 18. An Empty `err.message` (AggregateError) Makes a Fallback String Look Like the Real Error

Node >= 20 dials a `localhost` hostname with happy-eyeballs (`::1` and `127.0.0.1` in parallel). When BOTH fail it throws an `AggregateError` whose `.message` is the EMPTY STRING, with the real per-address errors in `.errors`. So the ubiquitous idiom `err.message || "some fallback"` selects the fallback and the diagnosis is gone.

Observed: an app stored and logged "Recovery failed: recovery failed", naming neither the error code nor the port, so the outage took a live repro to identify. `undici` compounds it: every connection failure is reported as the opaque string `"fetch failed"` with the real reason hidden in `.cause`.

It is ENVIRONMENT-DEPENDENT, which is why it does not reproduce locally: a single-stack host resolves `localhost` to one address and throws a plain `Error` with a usable message; a dual-stack host throws the empty-message `AggregateError`. A test that dials a dead port therefore asserts different things on the two machines; build the `AggregateError` by hand in the test instead.

How to apply:
1. Never format an error with `.message` alone. Use a `describeError()` that walks `.errors` and `.cause` and appends code + `address:port`.
2. Any predicate that matches on error text (`isTransientError`, `isRetryable`) must match the FULL description, or an `AggregateError` carrying `ECONNREFUSED` reads as non-transient and is treated as permanent.
3. A self-referential message ("X failed: x failed") is the signature; it means the fallback fired, not that the error was unhelpful.

### 19. A Composer-Style Tab Row Directly Above a Feed Reads as a Filter for That Feed

When a tab strip that only scopes an input control sits immediately above a result list, users read it as a filter on the list and report the list as broken ("X selected, cannot click on Y") even when the list is not gated at all. Two fixes, both cheap: label the tab row for what it actually scopes, and give the list its own explicit filter with an All default.

Before rewriting behaviour, prove the gating claim: hit-test each row with `document.elementFromPoint` at its centre and check the tag/href. That separates "an overlay eats the tap" from "this row was never a link" from "the user misread the control." In the observed case the real defect was different from the report's literal wording: pending rows rendered as a `div` with no `href`, so any still-running result was genuinely unclickable.

### 20. One Split Multi-Byte Character Makes grep Treat a Whole Text File as Binary

Seen in a generated index file whose per-entry hooks are truncated to a fixed width; one truncation cut a UTF-8 ellipsis in half, leaving an orphan `\xe2\x80` immediately before a valid `\xe2\x80\xa6`. Two stray bytes in 13KB.

The failure mode is silence, not an error. grep classifies the file as binary and suppresses matches, so `grep -n <term> FILE` printed nothing and `grep -c "" FILE` printed nothing, which reads exactly like "that term is not in the file." Three greps in a row came back empty before python's `open().read()` finally raised `UnicodeDecodeError` and named the offset. Note that `grep -a` would have worked all along, and so would python with `errors='replace'`; the trap is that the natural first tool fails quietly.

Detect:
```sh
python3 -c "open('FILE',encoding='utf-8').read()"   # raises, and the exception carries the byte offset
file FILE                                           # reports 'data' rather than 'UTF-8 Unicode text'
grep -c '$' FILE ; grep -ac '$' FILE                # the two disagree
```

Repair: read bytes, splice out the orphan sequence, `decode()` to prove the whole file is clean BEFORE writing back.

Generalises to any generated file whose lines are truncated to a width: index files, log summaries, digests, commit-message subjects, anything doing `s[:80]` on text that may contain non-ASCII. Truncate by characters after decoding, never by bytes.

### 21. A Grep-Gated Feature Never Fires When the Gate Pattern Doesn't Match the Generated Content

A pipeline's context-injection step gated on `grep -q "crash-priority|restart_time|CRASH CONTEXT"` against generated `*-priority.md` files, but the write template that produced those files never emitted any of those three substrings (it wrote `**Restart count:**` and `## Classification: <...>`). Result: the write side was implemented and producing real files, but the read side's gate silently never matched, so the context was NEVER injected: a fully dark feature with no error, no log line, nothing.

Fix was to gate on `^## Classification:`, the heading every real file actually contains, verified directly against a live generated file (old pattern: no match; new pattern: match) and checked for regressions against the other files in the directory.

**General lesson:** when a producer and consumer communicate via a string/grep match on generated content rather than a shared constant or schema, verify the match condition against a REAL generated sample, not against the keywords that seem intuitive. This class of bug produces zero errors and zero symptoms, so it only surfaces via direct inspection of whether the consumer's condition ever actually fires. The same shape appears elsewhere: a token refresh once ran at 0% success for weeks behind a fallback that kept the end state healthy.

### 22. A Cached/Stale State API Makes You Report a Confidently Wrong Number

Diagnosing why a streaming host was capped at 30fps, the display mode was read from Windows WMI `Win32_VideoController` (`CurrentHorizontalResolution`, `CurrentVerticalResolution`, `CurrentRefreshRate`) and reported as "1920x1080 @ 30Hz". The real mode, from `EnumDisplaySettings(dev, ENUM_CURRENT_SETTINGS)`, was **1280x720 @ 30Hz**. WMI's `Current*` fields are populated at driver init and are NOT re-read on mode change, so they can report a mode the machine has not been in for hours. The refresh rate happened to be right, the resolution was wrong, and nothing in the WMI output distinguishes the two; both look equally authoritative.

What made it survivable: another API disagreed. `System.Windows.Forms.Screen.AllScreens` reported bounds of 1280x720 in the *same* parallel tool call. **Two state-reading APIs disagreeing about the same instant is not noise to average out or pick the likelier value from; it means at least one is not reading live state, and the question is which.** The same shape shows up when a summarizer confidently misreads a document that was fetched correctly, and the resolution is the same: go to the authoritative source rather than adjudicating between convenient ones.

Rule: for any state you are going to REPORT to a user or branch a decision on, prefer the API whose contract is "read the live value now" over the one that is convenient or already in your output. On Windows specifically: `EnumDisplaySettings` over `Win32_VideoController` for display mode. The same class of trap exists for anything cached at init (WMI `Win32_*` snapshots, `/proc` values sampled once, ORM-level caches, any getter that returns a driver-reported struct rather than querying).

Corroboration beats assertion when closing this out: confirm a fix not by re-reading the same API, but by restarting the consumer and checking what IT reports, plus looking for pre-fix log lines that show what the client had been asking for all along.
