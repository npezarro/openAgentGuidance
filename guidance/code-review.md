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
- [ ] User input is validated and sanitized at entry points
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

When opening a PR, also check:

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
- [ ] Any environment variable changes are documented
- [ ] Any migration or data changes are noted
- [ ] A rollback plan is identified for risky changes

## Protected Configuration (Do Not Remove)

Some configuration properties look like dead code but are essential in production. Never remove these during fix or cleanup runs unless you have checked the deployment context:

- **NextAuth/Auth.js**: `basePath`, `redirectProxyUrl`, provider `authorization.params`, `token.params`. Apps deployed under a subpath behind a reverse proxy need these; without them the OAuth callback URLs are built against the wrong path.
- **PM2 ecosystem.config.js** (or your process manager's equivalent): `env`, `max_memory_restart`, `cwd`. These are essential for production process management.
- **Proxy config references in code**: URL construction that includes basePaths or proxy prefixes.

**Why:** an automated crash-fix run once removed `basePath` and `redirectProxyUrl` from an auth config because they looked unused. That broke OAuth on the subpath deployment, and someone had to restore them by hand.

## Default Review Workflow: Review-Ship-Review

Unless the user explicitly asks for a single review pass, use the iterative review-ship-review pattern for every non-trivial code change. This is the default.

### How it works

1. **Implement**: make the requested changes, run the tests, commit.
2. **Review (round 1)**: spawn 2-3 parallel reviewer agents. Each one audits the diff on its own and sorts findings into Critical / Important / Minor / Deferred.
3. **Fix and commit**: address every Critical and Important finding, then commit the fixes.
4. **Review (round 2)**: spawn fresh reviewer agents on the updated code. They must not see the earlier review output, so they look at it with fresh eyes. This catches regressions the fixes introduced and turns up issues the first round missed.
5. **Repeat**: if round 2 produces Critical or Important findings, fix them and run another round. Stop when a round comes back clean (no Critical or Important findings). Note Minor and Deferred items, but they don't block.

### Why this is the default

Single-pass reviews miss bugs that only show up after fixes land. In practice, fix commits introduce new issues 30-40% of the time (reusing the wrong variable, stale state, two fixes interacting). The second round catches these before they ship.

### Reviewer agent instructions

Each reviewer agent should:
- Read all changed files in full, not just the diff, to get the whole context
- Check how the changes interact (e.g., a fix to a risk check that bypasses a guard further downstream)
- Verify that new logic paths have test coverage
- Flag shell injection, state mutation bugs, and off-by-one errors
- Categorize each finding: **Critical** (breaks correctness or security), **Important** (likely bug or missing coverage), **Minor** (style, naming), **Deferred** (nice-to-have, not blocking)

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
| String concatenation for paths | OS-incompatible | Use `path.join()` |
| Prisma `globalForPrisma` dev-only cache | Connection leak in production | Cache on `globalThis` unconditionally, in every environment |
| `new Date("2026-04-15")` for display | Parsed as UTC, so local timezone shows the previous day | Use `new Date(year, month, day)` for local dates |
| Shell-interpolating JSON into script strings | Special characters break syntax | Write to a temp file and read it in the target language |
| Hardcoded timezone offset `timedelta(hours=-4)` | Breaks at DST transitions | Use `ZoneInfo('America/New_York')` or an equivalent TZ library |
| `head -c N` before parsing structured output | Silent data loss: truncation drops blocks that downstream code depends on | Size the limit to the maximum expected output, or extract specific fields first |
| `res.json({ error: err.message })` | Information disclosure: leaks paths, DB strings, stack traces | Return a generic message and log the details server-side |
| `child_process.exec(cmd + userInput)` | Command injection via string interpolation | Use `execFile(binary, [args])` with a separate args array |
| `parseInt(queryParam)` without `\|\| default`, fed to Prisma `skip`/`take` | `parseInt('abc')` is `NaN`; `Math.max(1, NaN)` stays `NaN`; Prisma `skip: NaN` returns a 500 | `Math.max(1, parseInt(String(raw ?? '1')) \|\| 1)`; the `\|\| 1` catches `NaN`. Define it once in a shared helper; if you hand-roll the same logic in both an API lib and SSR page components, they will diverge |
| `findMany({ take: N })` (or `SELECT ... LIMIT N`) for a "top N", trending, or windowed view, with no `orderBy` | No error and no visibly wrong output, but once rows exceed N the DB returns heap/insertion order, so the ranking becomes an arbitrary sample. That order also isn't stable between calls, which gives duplicate or missing rows across pages | Always pair `take`/`LIMIT` with an explicit `orderBy` that includes a unique tiebreaker column (e.g. `[{ updatedAt: 'desc' }, { id: 'desc' }]`), and share it across every copy of the query |
| `[...new Set(list)].slice(-n)` for "last n distinct values" over a chronological list | A `Set` keeps FIRST-occurrence order, not last. An item visited early and revisited at the end is ranked by its first visit and can get cut from the tail, so "most recent" silently drops the item that is in focus right now | Walk the list from the end, collect unseen values until you have n, then reverse |

## Rule Digest

One line per lesson.

- **Error detail leak prevention**: never expose raw error messages, stack traces, internal paths, hostnames, or database connection strings in HTTP responses.
- **Command injection, exec vs execFile**: never use `child_process.exec()` with string interpolation for user-influenced values.
- **Command injection where there's no args-array escape hatch**: `tmux send-keys`, `ssh host '<cmd>'`, a cron line, and `osascript -e 'do shell script ...'` have no `execFile`-style form that keeps args separate. The only defense is to check the value against an explicit allowlist or regex *before* it is interpolated into the string (e.g. a `case "$val" in opt1|opt2|...) ;; *) exit 1 ;; esac` gate on a CLI flag that gets typed into a live shell via `tmux send-keys`).
- **Prisma globalThis singleton, always cache in production**: the standard Next.js Prisma pattern only caches the client in development.
- **Shell to script data passing, use temp files**: never embed JSON or structured data into script strings via shell variable expansion.
- **Timezone offsets, never hardcode**: don't use fixed UTC offsets like `timedelta(hours=-4)` or `new Date().getTimezoneOffset()` in business logic that must respect DST transitions.
- **Output truncation causes silent parse failures**: either size the limit to the maximum expected output (e.g., `head -c 10000` for LLM output), or extract the specific field first and truncate the extracted value.
- **Structured output format compliance**:
  - Parse the constraint first
  - Validate before submitting
  - Fix, don't annotate
- **Update CLAUDE.md when adding features**: after adding a new feature, route, export, or command, update the repo's CLAUDE.md before committing.
- **Centralize query-param parsing, don't hand-roll guards in SSR pages**: when an API route validates a query param through a shared helper, SSR pages must call that same helper instead of re-implementing the guard.
- **`backdrop-filter` ancestors confine `position:fixed` overlays, so portal to body**: use `ReactDOM.createPortal(overlay, document.body)` to render fixed overlays outside the containing ancestor.
- **JS truthiness guards don't reject negatives**: use `<= 0` for any external quantity that must be strictly positive.
- **Isolate per-item failures in batch loops**: guard operations that can throw on stored or external data, so one bad item doesn't abort the whole batch.
- **A per-field guard doesn't make the whole record safe**: a collector that validates ONE field of each upstream record (e.g. a dedup key) reads downstream like "records are now clean", but it only guarantees THAT field.
- **A many-to-one resolver must dedupe before an additive accumulator consumes it.**
- **Mixed `||` / `?:` precedence silently drops data**: `a || b ? c : d` parses as `(a || b) ? c : d`; parenthesize every expression that mixes `||` with a ternary.
- **Check for sibling deliverables before revising a doc that another session may have expanded.**
- **Substring-matching short blocklist tokens silently drops legitimate content.**
- **Enumerate every caller before claiming a configured limit is unreachable or dead config.**
- **A control-character escape in an edit can land as a literal byte and turn the file binary**, which makes grep go silent on it.
- **Adding a config passthrough turns every previously harmless typo in that key into a live value.**
- **Re-verify an absence claim in a backlog item before implementing it**: one grep of the canonical file is not proof.
- **A fix documented as a property of one file never reaches its siblings**: a behavioural fix (browser UA, an unverifiable-status bucket, a per-request AbortController) made to one HTTP probe, with its constants declared local to that file, has to be applied to every sibling probe too.
- **A display tag is not a handle**: persist the user id whenever a record may later need to address that user.
- **Turning a 500 into a successful empty response makes a previously unreachable client state reachable**: check what the consumer renders for zero rows before merging the guard.
- **A narration strip must cover both ends of the artifact, not just where it starts.**
- **A hardening sweep keyed on a construct's presence can't see the site that lacks the construct entirely.**
- **A clipboard write after an awaited call trips uBlock Origin's ClickFix blocker.**
- **A range-to-single-label formatter must compare the enclosing unit, not just the sub-unit.**
- **A unit-decomposition formatter must round the total before splitting**, not round each sub-unit remainder on its own.
- **Validate a nullable field at the source before interpolating it into a string**: a stringified null gets past a downstream emptiness guard.
- **An upper-bound clamp on a query param is not validation**: check every other way the value can be wrong.
- **After deleting a function, grep for its callers**: a state with 0 definitions and N calls passes `node --check` but throws ReferenceError at runtime.
- **A threshold that moves with the input cannot be equality-compared against a counter that outlives it.**
- **A stemmer or lookup that strips to a bare key must try the index's actual citation form first**, or it silently hits an unrelated entry.
- **A relative-step control (+/- keys, arrow buttons) must read the same value the UI displays**, not a separately persisted value.
- **Scope a page-level loading gate to the initial load, not every refetch**: if one `loading` flag gates the initial render and is also set by an inline mutation's refetch, any inline action (a "mark used" button, a row toggle) blanks the whole page to the placeholder and jumps the scroll back to the top.
- **An ordered suffix/prefix-stripping list where one entry ends with another must NOT default to longest-match-first**: check which side of the boundary the shared character belongs to before choosing an order, and measure both orderings over the whole dataset.
- **A marker-strip regex needs `\s+` or `\b` before the marker, never `\s*`; and a guard `pattern.test(x) && x.includes(c)` degenerates to plain `includes(c)` whenever `pattern` makes `c` optional**: both silently widen what the regex matches past what the author intended.
- **A bounded `take`/`LIMIT` window needs an explicit `orderBy` with a unique tiebreaker**, or ranking becomes an arbitrary sample and pagination becomes non-deterministic.
- **`[...new Set(list)].slice(-n)` is not "last n distinct"**: a `Set` keeps FIRST-occurrence order, so a value revisited at the end is ranked by its first visit and can be cut from the tail.
