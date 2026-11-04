<!-- Load when: self-review checklist before committing -->
# Code Review Guidance

Run this self-review checklist before every commit and PR.

## Pre-Commit Checklist

### 1. Correctness
- [ ] Does the change solve the stated problem?
- [ ] Are edge cases handled (empty input, null, zero, negative numbers)?
- [ ] Are error states handled at system boundaries?
- [ ] Does async code properly `await` and handle rejections?

### 2. No Regressions
- [ ] Build passes: `npm run build`
- [ ] Tests pass: `npm test`
- [ ] Existing functionality still works (do a manual spot-check if there are no tests)

### 3. Security
- [ ] No secrets, API keys, tokens, or passwords in the diff
- [ ] No hardcoded credentials or URLs with auth info
- [ ] User input is validated or sanitized at entry points
- [ ] SQL/NoSQL queries use parameterized inputs (no string interpolation)
- [ ] No `eval()`, `innerHTML`, or `dangerouslySetInnerHTML` with user data

### 4. Code Quality
- [ ] Variable and function names are descriptive and follow existing conventions
- [ ] No dead code, commented-out blocks, or debug `console.log` statements
- [ ] No duplicated logic that should be extracted
- [ ] Functions do one thing and are reasonably short
- [ ] Complex logic has a brief comment explaining *why*

### 5. File Hygiene
- [ ] No unintended files staged (`.DS_Store`, `node_modules/`, build output, `.env`)
- [ ] Lockfiles (`package-lock.json`) are updated if dependencies changed
- [ ] No unrelated changes mixed into the commit

### 6. Git Hygiene
- [ ] Commit message explains *why*, not just *what*
- [ ] Commit is on the correct branch (not `main`)
- [ ] `git diff --staged` reviewed line by line

## PR Review Checklist

When opening a PR, also verify:

### 7. PR Scope
- [ ] PR addresses a single concern (one feature, one bug, or one refactor)
- [ ] PR title is clear and under 70 characters
- [ ] PR description explains what changed and why
- [ ] A reviewer can understand the change without prior context

### 8. Testing Evidence
- [ ] Describe how the change was tested
- [ ] Include test output or screenshots if applicable
- [ ] Note any areas that need manual testing

### 9. Deployment Impact
- [ ] Any environment variable changes documented
- [ ] Any migration or data changes noted
- [ ] Rollback plan identified for risky changes

## Protected Configuration (Do Not Remove)

Some configuration properties look like dead code but production depends on them. Never remove these during fix or cleanup runs unless you have checked the deployment context:

- **NextAuth/Auth.js**: `basePath`, `redirectProxyUrl`, provider `authorization.params`, `token.params`. Apps deployed on a subpath behind a reverse proxy need these.
- **PM2 ecosystem.config.js** (or your process manager's equivalent): `env`, `max_memory_restart`, `cwd`. Production process management relies on them.
- **Apache/proxy config references in code**: URL construction that includes basePaths or proxy prefixes.

**Why:** an automated crash-fix run once removed `basePath` and `redirectProxyUrl` from an auth config because they looked unused. That broke OAuth on a subpath deployment, and someone had to restore them by hand.

## Default Review Workflow: Review-Ship-Review

Use the iterative review-ship-review pattern for all non-trivial code changes unless the user explicitly asks for a single review pass. This is the default.

### How it works

1. **Implement**: make the requested changes, run tests, commit.
2. **Review (round 1)**: spawn 2-3 parallel reviewer agents. Each one audits the diff independently and sorts its findings into Critical / Important / Minor / Deferred.
3. **Fix & commit**: address all Critical and Important findings, then commit the fixes.
4. **Review (round 2)**: spawn fresh reviewer agents on the updated code. They must not see the earlier review output, so they audit with fresh eyes. This round catches regressions the fixes introduced and issues the first round missed.
5. **Repeat**: if round 2 produces Critical or Important findings, fix them and run another round. Stop when a round comes back clean (no Critical or Important findings). Minor and Deferred items can be noted but don't block.

### Why this is the default

Single-pass reviews miss bugs that only show up after fixes land. In practice, fix commits introduce new issues 30-40% of the time (reusing the wrong variable, stale state, two fixes interacting). The second round catches these before they ship.

### Reviewer agent instructions

Each reviewer agent should:
- Read every changed file in full (not just the diff) to understand the context
- Check how the changes interact (e.g., a fix to a risk check that bypasses a guard further downstream)
- Verify test coverage for new logic paths
- Flag shell injection, state mutation bugs, and off-by-one errors
- Categorize each finding: **Critical** (breaks correctness or security), **Important** (likely bug or missing coverage), **Minor** (style, naming), **Deferred** (nice to have, not blocking)

### When to skip

- Trivial changes (typo fixes, comment updates, config value changes)
- The user explicitly says "just commit" or "skip review"
- Single-line fixes that are obviously correct

## Common Issues to Watch For

| Pattern | Problem | Fix |
|---------|---------|-----|
| `catch (e) {}` | Swallowed error | Log or rethrow |
| `array.length > 0 ? array[0] : undefined` | Verbose | `array[0]` (already undefined if empty) |
| `if (x == null)` | Loose equality | `if (x === null \|\| x === undefined)`, or keep `== null` if intentional |
| `async` function with no `await` | Unnecessary async wrapper | Remove the `async` keyword |
| `new Date()` in business logic | Untestable | Inject time as a parameter |
| String concatenation for paths | Breaks across operating systems | Use `path.join()` |
| Prisma `globalForPrisma` cached in dev only | Connection leak in production | Cache on `globalThis` unconditionally |
| `new Date("2026-04-15")` for display | Parsed as UTC, so local timezones show the previous day | Use `new Date(year, month, day)` for local dates |
| Shell-interpolating JSON into script strings | Special characters break the syntax | Write to a temp file and read it in the target language |
| Hardcoded timezone offset `timedelta(hours=-4)` | Breaks at DST transitions | Use `ZoneInfo('America/New_York')` or an equivalent TZ library |
| `head -c N` before parsing structured output | Silent data loss: truncation drops blocks that downstream code depends on | Set the limit to the maximum expected output, or extract the specific fields first |
| `res.json({ error: err.message })` | Information disclosure: leaks paths, DB strings, stack traces | Return a generic message and log the details server-side |
| Catch-all Express error handler (`app.use((err,req,res,next)=>res.status(500)...)`) with no `err.status`/`err.expose` check | Turns body-parser's own 4xx (malformed JSON, oversized body, non-object body in strict mode) into a 500, so a client mistake looks like a server crash | Pass the parser's 4xx through first: `if (err.expose && err.status >= 400 && err.status < 500) return res.status(err.status).json(...)` |
| `child_process.exec(cmd + userInput)` | Command injection through string interpolation | Use `execFile(binary, [args])` with a separate args array |
| `parseInt(queryParam)` with no `\|\| default`, fed to Prisma `skip`/`take` | `parseInt('abc')` is `NaN`, `Math.max(1, NaN)` is still `NaN`, and Prisma `skip: NaN` returns a 500 | `Math.max(1, parseInt(String(raw ?? '1')) \|\| 1)`; the `\|\| 1` catches `NaN`. Define it once in a shared helper: if an API lib and SSR page components each hand-roll it, they will diverge |
| `findMany({ take: N })` (or `SELECT ... LIMIT N`) for a "top N", trending, or windowed view with no `orderBy` | No error and no visibly wrong output, but once there are more than N rows the DB returns heap/insertion order. The ranking becomes an arbitrary sample, and the order can change between calls (duplicate or missing rows across pages) | Always pair `take`/`LIMIT` with an explicit `orderBy` that ends in a unique tiebreaker column (e.g. `[{ updatedAt: 'desc' }, { id: 'desc' }]`), and use the same ordering in every copy of the query |
| `[...new Set(list)].slice(-n)` for "last n distinct values" over a chronological list | A `Set` keeps FIRST-occurrence order, not last. An item seen early and revisited at the end is ranked by its first visit and can be cut from the tail, so "most recent" silently drops the item that is in focus right now | Walk the list from the end, collect unseen values until you have n, then reverse |
| Wrapping arbitrary generated text (a shell command, a file path) in single-backtick code spans | CommonMark closes a code span at the first backtick run of the same length as the opener, so a backtick inside the text ends the span early and leaves stray backticks. A newline inside it ends the enclosing list item | Use a fence one backtick longer than the longest run inside the text. Add a space on each side when the text touches the fence or already starts/ends with a space, and flatten line breaks to spaces. Check the output with a real parser (e.g. markdown-it), not by eye |
| A prefix/dispatch lookup (`startsWith(key)`) where one table key is also a namespace prefix of newer, more specific keys (model names, feature flags, config or route lookups) | The base key matches every newer dash-suffixed variant too. An unrecognized NEWER value silently resolves to the OLDER base's data instead of falling through to the "default to latest" path. The output looks plausible, nothing errors, and the bug only appears once a new value ships | Require a segment boundary after the match (e.g. skip when the remainder matches `/^-\d/`) before accepting a prefix hit, and let anything that fails the check fall through to the explicit latest/default branch |

## Rule Digest

One line per lesson, in the order they were learned. Add a new line here when a review turns up a new lesson. Edit, merge, or dedupe existing lines rather than appending dated sections.

- **Error Detail Leak Prevention**: never expose raw error messages, stack traces, internal paths, hostnames, or database connection strings in HTTP responses.
- **Command Injection, exec vs execFile**: never use `child_process.exec()` with string interpolation for values the user can influence.
- **Command Injection Where There's No Args-Array Escape Hatch**: `tmux send-keys`, `ssh host '<cmd>'`, a cron line, and `osascript -e 'do shell script ...'` have no `execFile`-style separate-args form. The only defense is to validate the value against an explicit allowlist or regex *before* interpolating it (e.g. a `case "$val" in opt1|opt2|...) ;; *) exit 1 ;; esac` gate on a CLI flag that gets typed into a live shell through `tmux send-keys`).
- **Prisma globalThis Singleton, Always Cache in Production**: the standard Next.js Prisma pattern only caches the client in development.
- **Shell to Script Data Passing, Use Temp Files**: never embed JSON or other structured data in script strings through shell variable expansion.
- **Timezone Offsets, Never Hardcode**: don't use fixed UTC offsets like `timedelta(hours=-4)` or `new Date().getTimezoneOffset()` in business logic that has to handle DST transitions.
- **Output Truncation Causes Silent Parse Failures**: either set the limit to the maximum expected output (e.g., `head -c 10000` for LLM output), or extract the field you need first and truncate that value.
- **Structured Output Format Compliance**:
  - Parse the constraint first
  - Validate before submitting
  - Fix, don't annotate
- **Update CLAUDE.md When Adding Features**: after implementing a new feature, route, export, or command, update the repo's CLAUDE.md before committing.
- **Centralize query-param parsing, don't hand-roll guards in SSR pages**: when an API route validates a query param through a shared helper, SSR pages must call the same helper instead of writing their own guard.
- **`backdrop-filter` ancestors confine `position:fixed` overlays, so portal to body**: render fixed overlays outside the containing ancestor with `ReactDOM.createPortal(overlay, document.body)`.
- **JS truthiness guards don't reject negatives, so use `<= 0` for non-negative external quantities**: use `<= 0` for any quantity that must be strictly positive.
- **Isolate per-item failures in batch loops; guard operations that throw on stored or external data.**
- **A per-field guard doesn't make the whole record safe**: a collector that validates ONE field of each upstream record (e.g. a dedup key) reads downstream as "records are clean now", but it only guarantees THAT field.
- **A many-to-one resolver must dedupe before an additive accumulator consumes it.**
- **Mixed `||` / `?:` precedence silently drops data**: `a || b ? c : d` parses as `(a || b) ? c : d`; parenthesize every expression that mixes `||` and a ternary.
- **Check for sibling deliverables before revising a doc that another session may have expanded.**
- **Substring-matching short blocklist tokens silently drops legitimate content.**
- **List every caller before claiming a configured limit is unreachable or dead config.**
- **A control-character escape in an Edit can land as a literal byte and turn the file binary, after which grep goes silent.**
- **Adding a config passthrough turns every previously harmless typo in that key into a live value.**
- **Re-check an absence claim in a backlog item before implementing it; one grep of the canonical file is not proof.**
- **A fix documented as a property of one file never reaches its siblings**: when a behavioural fix (browser UA, a bucket for unverifiable statuses, a per-request AbortController) goes into one HTTP probe with its constants declared local to that file, sibling probes keep the old bug. Put shared fixes in shared code.
- **A display tag is not a handle: store the user id whenever a record may later need to address that user.**
- **Turning a 500 into a successful empty response makes a client state reachable that wasn't before; check what the consumer renders for zero rows before merging the guard.**
- **A narration strip must cover both ends of the artifact, not just the start.**
- **A hardening sweep keyed on whether a construct is present can't see the site that lacks it entirely.**
- **A clipboard write after an awaited call trips uBlock Origin's ClickFix blocker.**
- **A range-to-single-label formatter must compare the enclosing unit, not just the sub-unit.**
- **A unit-decomposition formatter must round the total before splitting, not round each sub-unit remainder on its own.**
- **Validate a nullable field at the source before interpolating it into a string; a stringified null gets past a downstream emptiness guard.**
- **An upper-bound clamp on a query param is not validation: check every other way the value can be wrong.**
- **After deleting a function, grep for its callers; with 0 definitions and N calls, `node --check` still passes but the code throws ReferenceError at runtime.**
- **A threshold that moves with the input cannot be equality-compared against a counter that outlives it.**
- **A stemmer or lookup that strips to a bare key must try the index's actual citation form first, or it silently hits an unrelated entry.**
- **A relative-step control (+/- keys, arrow buttons) must read the same value the UI displays, not a separately persisted value.**
- **A page-level loading gate must be scoped to the initial load, not toggled on every refetch**: if one `loading` flag both gates the initial render and gets set by an inline mutation's refetch, any inline action (a "mark used" button, a row toggle) blanks the whole page to the placeholder and jumps the scroll to the top.
- **An ordered suffix/prefix-stripping list where one entry ends with another must NOT default to longest-match-first**: work out which side of the boundary the shared character belongs to before picking an order, and measure both orderings over the whole dataset.
- **A marker-strip regex needs `\s+` or `\b` before the marker, never `\s*`; and a guard like `pattern.test(x) && x.includes(c)` reduces to plain `includes(c)` whenever `pattern` makes `c` optional**: both silently make the regex match more than the author intended.
- **A bounded `take`/`LIMIT` window needs an explicit `orderBy` with a unique tiebreaker, or the ranking becomes an arbitrary sample and pagination becomes non-deterministic.**
- **`[...new Set(list)].slice(-n)` is not "last n distinct"**: a `Set` keeps FIRST-occurrence order, so a value revisited at the end is ranked by its first visit and can be cut from the tail.
- **A single-backtick code span must use more backticks than the longest run inside the wrapped text, or it closes early and leaks stray backticks.**
- **A catch-all Express error handler must pass through body-parser's own 4xx (`err.status`/`err.expose`) before defaulting to 500**: a flat `res.status(500)` on every `next(err)` turns malformed JSON, an oversized body, and a non-object strict-mode body into a false "server crash".
- **A base key that is also a `startsWith()` prefix of newer, more specific keys silently resolves every unrecognized newer value to the base's (older) data**: require a segment boundary after the match instead of accepting a bare prefix hit.
