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
- [ ] Existing functionality still works (spot-check it by hand if there are no tests)

### 3. Security
- [ ] No secrets, API keys, tokens, or passwords in the diff
- [ ] No hardcoded credentials or URLs with auth info
- [ ] User input is validated/sanitized at entry points
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
- [ ] PR addresses a single concern (one feature, one bug, one refactor)
- [ ] PR title is clear and under 70 characters
- [ ] PR description explains what changed and why
- [ ] Reviewer can understand the change without prior context

### 8. Testing Evidence
- [ ] Describe how the change was tested
- [ ] Include test output or screenshots if applicable
- [ ] Note any areas that need manual testing

### 9. Deployment Impact
- [ ] Any environment variable changes documented
- [ ] Any migration or data changes noted
- [ ] Rollback plan identified for risky changes

## Protected Configuration (Do Not Remove)

Some configuration properties look like dead code but production depends on them. Never remove these during fix or cleanup runs until you have checked the deployment context:

- **NextAuth/Auth.js**: `basePath`, `redirectProxyUrl`, provider `authorization.params`, `token.params`. An app deployed on a subpath behind a reverse proxy needs these so OAuth callback URLs resolve to the proxied path rather than the root.
- **PM2 ecosystem.config.js**: `env`, `max_memory_restart`, `cwd`. Production process management depends on these.
- **Apache/proxy config references in code**: URL construction that includes basePaths or proxy prefixes.

**Why:** In one case an automated cleanup run removed `basePath` and `redirectProxyUrl` from an auth config because they looked unused. That broke OAuth on a subpath deployment, and someone had to restore them by hand.

## Default Review Workflow: Review-Ship-Review

Use the iterative review-ship-review pattern for all non-trivial code changes unless the user explicitly asks for a single review pass.

### How it works

1. **Implement**: Make the requested changes, run tests, commit.
2. **Review (round 1)**: Spawn 2-3 parallel reviewer agents. Each agent audits the diff independently and puts every finding in one of four categories: Critical, Important, Minor, Deferred.
3. **Fix & commit**: Address all Critical and Important findings. Commit the fixes.
4. **Review (round 2)**: Spawn fresh reviewer agents on the updated code. These reviewers must not see the earlier review output, so they look at the code with fresh eyes. This catches regressions introduced by the fixes and surfaces issues the first round missed.
5. **Repeat**: If round 2 produces Critical or Important findings, fix them and run another round. Stop when a round comes back clean (no Critical/Important findings). Note Minor and Deferred items, but they don't block.

### Why this is the default

A single review pass misses bugs that only appear after fixes land. In practice, fix commits introduce new issues 30-40% of the time (wrong variable reuse, stale state, interactions between fixes). The second round catches these before they ship.

### Reviewer agent instructions

Each reviewer agent should:
- Read all changed files (not just the diff) to understand the full context
- Check for interactions between changes (e.g., a risk-check fix that bypasses a downstream guard)
- Verify test coverage for new logic paths
- Flag shell injection, state mutation bugs, and off-by-one errors
- Categorize each finding: **Critical** (breaks correctness or security), **Important** (likely bug or missing coverage), **Minor** (style, naming), **Deferred** (nice-to-have, not blocking)

### When to skip

- Trivial changes (typo fixes, comment updates, config value changes)
- User explicitly says "just commit" or "skip review"
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
| Prisma `globalForPrisma` dev-only cache | Connection leak in production | Cache on `globalThis` unconditionally |
| `new Date("2026-04-15")` for display | Parsed as UTC, so local display can be off by one day | Use `new Date(year, month, day)` for local dates |
| Shell-interpolating JSON into script strings | Special characters break syntax | Write to a temp file and read it in the target language |
| Hardcoded timezone offset `timedelta(hours=-4)` | Breaks at DST transitions | Use `ZoneInfo('America/New_York')` or an equivalent TZ library |
| `head -c N` before parsing structured output | Silent data loss: truncation drops blocks that downstream code depends on | Size the limit to the maximum expected output, or extract specific fields first |
| `res.json({ error: err.message })` | Information disclosure: leaks paths, DB strings, stack traces | Return a generic message and log details server-side |
| `child_process.exec(cmd + userInput)` | Command injection via string interpolation | Use `execFile(binary, [args])` with a separate args array |
| `parseInt(queryParam)` without `\|\| default` fed to Prisma `skip`/`take` | `parseInt('abc')` is `NaN`, `Math.max(1, NaN)` stays `NaN`, and Prisma `skip: NaN` returns a 500 | `Math.max(1, parseInt(String(raw ?? '1')) \|\| 1)` (the `\|\| 1` catches `NaN`). Define it once in a shared helper; if the API lib and SSR page components each hand-roll it, the copies will drift apart |
| `findMany({ take: N })` (or `SELECT ... LIMIT N`) for a "top N"/trending/windowed view, with no `orderBy` | No error and no visibly wrong output, but once there are more than N rows the DB returns heap/insertion order. The ranking becomes an arbitrary sample, and the order changes between calls (duplicate or missing rows across pages) | Always pair `take`/`LIMIT` with an explicit `orderBy` that ends in a unique tiebreaker column (e.g. `[{ updatedAt: 'desc' }, { id: 'desc' }]`), and share it between every copy of the query |
| `[...new Set(list)].slice(-n)` for "last n distinct values" over a chronological list | A `Set` keeps FIRST-occurrence order, not last. An item visited early and revisited at the end is ranked by its first visit and can be cut from the tail, so "most recent" can drop the item that is in focus right now | Walk the list from the end, collect unseen values until you have n, then reverse |
| Wrapping arbitrary generated text (a shell command, a file path) in single-backtick code spans | CommonMark closes a code span at the first backtick run of exactly the opening length, so a backtick inside the text ends the span early and leaves stray backticks. A newline inside the span ends the enclosing list item | Use a fence one backtick longer than the longest run inside the text, add a space on each side when the text touches the fence or starts/ends with a space, and replace line breaks with spaces. Check the result with a real parser (e.g. markdown-it), not by eye |

## Rule Digest

One line per lesson, in the order the lessons were learned.

- **Error Detail Leak Prevention**: Never expose raw error messages, stack traces, internal paths, hostnames, or database connection strings in HTTP responses.
- **Command Injection: exec vs execFile**: Never use `child_process.exec()` with string interpolation for user-influenced values.
- **Command Injection Where There's No Args-Array Escape Hatch**: `tmux send-keys`, `ssh host '<cmd>'`, a cron line, `osascript -e 'do shell script ...'`. These targets have no `execFile`-style separate-args form, so the only defense is to validate the value against an explicit allowlist/regex *before* it goes into the string (e.g. a `case "$val" in opt1|opt2|...) ;; *) exit 1 ;; esac` gate on a CLI flag that gets typed into a live shell via `tmux send-keys`).
- **Prisma globalThis Singleton: Always Cache in Production**: The standard Next.js Prisma pattern only caches the client in development.
- **Shell → Script Data Passing: Use Temp Files**: Never embed JSON or structured data into script strings via shell variable expansion.
- **Timezone Offsets: Never Hardcode**: Don't use fixed UTC offsets like `timedelta(hours=-4)` or `new Date().getTimezoneOffset()` in business logic that must handle DST transitions.
- **Output Truncation Causes Silent Parse Failures**: Either size the limit to the maximum expected output (e.g., `head -c 10000` for LLM output), or extract the specific field first and then truncate that value.
- **Structured Output Format Compliance**:
  - Parse the constraint first
  - Validate before submitting
  - Fix, don't annotate
- **Update CLAUDE.md When Adding Features**: After you add a new feature, route, export, or command, update the repo's CLAUDE.md before committing.
- **Centralize query-param parsing: don't hand-roll guards in SSR pages**: If an API route validates a query param through a shared helper, SSR pages must call the same helper instead of writing their own guard.
- **`backdrop-filter` Ancestors Confine `position:fixed` Overlays, Portal to Body**: Render fixed overlays with `ReactDOM.createPortal(overlay, document.body)` so they sit outside the ancestor that confines them.
- **JS Truthiness Guards Don't Reject Negatives: Use `<= 0` for Non-Negative External Quantities**: Use `<= 0` for any quantity that must be strictly positive.
- **Isolate per-item failures in batch loops; guard operations that throw on stored/external data**
- **A per-field guard doesn't make the whole record safe**: A collector that validates ONE field of each upstream record (e.g. a dedup key) looks downstream as if the records are now clean, but only THAT field is guaranteed.
- **A many-to-one resolver must dedupe before an additive accumulator consumes it**
- **Mixed || / ?: precedence silently drops data**: `a || b ? c : d` parses as `(a || b) ? c : d`; put parentheses around every expression that mixes `||` with a ternary.
- **Check for sibling deliverables before revising a doc another session may have deepened**
- **Substring-matching short blocklist tokens silently drops legitimate content**
- **Enumerate every caller before claiming a configured limit is unreachable or dead config**
- **A control-character escape in an Edit can land as a literal byte and turn the file binary, so grep goes silent**
- **Adding a config passthrough makes every previously-harmless typo in that key a live value**
- **Re-verify an absence claim in a backlog item before implementing it, one grep of the canonical file is not proof**
- **A fix documented as a property of one file never reaches its siblings**: If a behavioral fix (browser UA, unverifiable-status bucket, per-request AbortController) lives in constants local to one HTTP probe, sibling probes never get it. Put shared fixes in a shared module and apply them to every sibling.
- **A display tag is not a handle: persist the user id whenever a record may later need to address that user**
- **Turning a 500 into a successful empty response makes a previously-unreachable client state reachable; check what the consumer renders for zero rows before merging the guard**
- **A narration strip must cover both ends of the artifact, not just where it starts**
- **A hardening sweep keyed on a construct's presence is blind to the site that lacks it entirely**
- **A clipboard write after an awaited call trips uBlock Origin's ClickFix blocker**
- **A range-to-single-label formatter must compare the enclosing unit, not just the sub-unit**
- **A unit-decomposition formatter must round the total before splitting, not round each sub-unit remainder in isolation**
- **Validate a nullable field at the source before interpolating it into a string, a stringified null survives a downstream emptiness guard**
- **An upper-bound clamp on a query param is not validation: check every other axis a value can be wrong on**
- **After deleting a function, grep for its callers; a 0-definition/N-call state passes node --check but throws ReferenceError at runtime**
- **A threshold that moves with the input cannot be equality-compared against a counter that outlives it**
- **A stemmer/lookup that strips to a bare key must try the index's actual citation form first, or it silently hits an unrelated entry**
- **A relative-step control (+/- keys, arrow buttons) must read the same value the UI displays, not a separately persisted value**
- **A page-level loading gate must be scoped to the initial load, not toggled on every refetch**: If one `loading` flag both gates the initial render and gets set by an inline mutation's refetch, every inline action (a "mark used" button, a row toggle) blanks the whole page to the placeholder and jumps the scroll back to the top.
- **An ordered suffix/prefix-stripping list where one entry ends with another must NOT default to longest-match-first**: Before choosing an order, check which side of the boundary the shared character belongs to, and measure both orders over the whole dataset.
- **A marker-strip regex needs `\s+`/`\b` before the marker, never `\s*`; and a guard `pattern.test(x) && x.includes(c)` degenerates to plain `includes(c)` whenever `pattern` makes `c` optional**: Both mistakes quietly make the regex match more than the author intended.
- **A bounded `take`/`LIMIT` window needs an explicit `orderBy` with a unique tiebreaker, or ranking becomes an arbitrary sample and pagination becomes non-deterministic**
- **`[...new Set(list)].slice(-n)` is not "last n distinct": a `Set` keeps FIRST-occurrence order, so a value revisited at the end is ranked by its first visit and can be cut from the tail**
- **A single-backtick code span must outgrow the backticks already inside the wrapped text, or it closes early and leaks stray backticks**
