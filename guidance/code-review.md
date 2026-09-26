<!-- Load when: self-review checklist before committing -->
# Code Review Guidance

Self-review checklist to run before every commit and PR.

## Pre-Commit Checklist

### 1. Correctness
- [ ] Does the change solve the stated problem?
- [ ] Are edge cases handled (empty input, null, zero, negative numbers)?
- [ ] Are error states handled at system boundaries?
- [ ] Does async code properly `await` and handle rejections?

### 2. No Regressions
- [ ] Build passes: `npm run build`
- [ ] Tests pass: `npm test`
- [ ] Existing functionality still works (manual spot-check if no tests)

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

Some configuration properties look like dead code but are essential for production. Never remove these during fix or cleanup runs without verifying the deployment context:

- **NextAuth/Auth.js**: `basePath`, `redirectProxyUrl`, provider `authorization.params`, `token.params`. These are required when an app is deployed under a URL subpath behind a reverse proxy; without them OAuth callbacks resolve to the wrong URL.
- **Process manager config (e.g. PM2 `ecosystem.config.js`)**: `env`, `max_memory_restart`, `cwd`. These are essential for production process management.
- **Apache/proxy config references in code**: URL construction that includes basePaths or proxy prefixes.

**Why:** an automated crash-fix run once removed `basePath` and `redirectProxyUrl` from an app's auth config because they appeared unused. That broke OAuth on the subpath deployment and required a manual restore. "Looks unused" is not proof when the consumer is the deployment environment.

## Default Review Workflow: Review-Ship-Review

Unless the user explicitly requests a single review pass, use the iterative review-ship-review pattern for all non-trivial code changes. This is the default.

### How it works

1. **Implement**: make the requested changes, run tests, commit.
2. **Review (round 1)**: spawn 2-3 parallel reviewer agents. Each agent audits the diff independently, categorizing findings as Critical / Important / Minor / Deferred.
3. **Fix & commit**: address all Critical and Important findings. Commit the fixes.
4. **Review (round 2)**: spawn fresh reviewer agents on the updated code. Reviewers must not see prior review output; they audit with fresh eyes. This catches regressions introduced by the fixes and surfaces issues the first round missed.
5. **Repeat**: if round 2 produces Critical or Important findings, fix and run another round. Stop when a review round returns clean (no Critical/Important findings). Minor and Deferred items can be noted but don't block.

### Why this is the default

Single-pass reviews miss bugs that only become visible after fixes land. In practice, fix commits introduce new issues 30-40% of the time (wrong variable reuse, stale state, interaction between fixes). The second review round catches these before they ship.

### Reviewer agent instructions

Each reviewer agent should:
- Read all changed files (not just the diff) to understand full context
- Check for interactions between changes (e.g., a risk check fix that bypasses a downstream guard)
- Verify test coverage for new logic paths
- Flag shell injection, state mutation bugs, and off-by-one errors
- Categorize each finding: **Critical** (breaks correctness or security), **Important** (likely bug or missing coverage), **Minor** (style, naming), **Deferred** (nice-to-have, not blocking)

### When to skip

- Trivial changes (typo fixes, comment updates, config value changes)
- User explicitly says "just commit" or "skip review"
- Single-line fixes with obvious correctness

## Common Issues to Watch For

| Pattern | Problem | Fix |
|---------|---------|-----|
| `catch (e) {}` | Swallowed error | Log or rethrow |
| `array.length > 0 ? array[0] : undefined` | Verbose | `array[0]` (already undefined if empty) |
| `if (x == null)` | Loose equality | `if (x === null \|\| x === undefined)` or keep `== null` if intentional |
| `async` function with no `await` | Unnecessary async wrapper | Remove `async` keyword |
| `new Date()` in business logic | Untestable | Inject time as parameter |
| String concatenation for paths | OS-incompatible | Use `path.join()` |
| Prisma `globalForPrisma` dev-only cache | Connection leak in production | Cache on `globalThis` unconditionally |
| `new Date("2026-04-15")` for display | UTC parse, then local timezone off-by-one | Use `new Date(year, month, day)` for local dates |
| Shell-interpolating JSON into script strings | Special chars break syntax | Write to temp file, read in target language |
| Hardcoded timezone offset `timedelta(hours=-4)` | Breaks at DST transitions | Use `ZoneInfo('America/New_York')` or equivalent TZ library |
| `head -c N` before parsing structured output | Silent data loss: truncation drops blocks downstream code depends on | Size limit to max expected output, or extract specific fields first |
| `res.json({ error: err.message })` | Information disclosure: leaks paths, DB strings, stack traces | Return generic message, log details server-side |
| `child_process.exec(cmd + userInput)` | Command injection via string interpolation | Use `execFile(binary, [args])` with separate args array |
| `parseInt(queryParam)` without `\|\| default` fed to Prisma `skip`/`take` | `parseInt('abc')` is `NaN`; `Math.max(1, NaN)` stays `NaN`; Prisma `skip: NaN` returns a 500 | `Math.max(1, parseInt(String(raw ?? '1')) \|\| 1)`; the `\|\| 1` catches `NaN`. Define once in a shared helper; hand-rolling the same logic in both an API lib and SSR page components guarantees they diverge |

## Rule Digest

One line per lesson, in the order they were learned.

- **Error Detail Leak Prevention**: Never expose raw error messages, stack traces, internal paths, hostnames, or database connection strings in HTTP responses.
- **Command Injection: exec vs execFile**: Never use `child_process.exec()` with string interpolation for user-influenced values.
- **Prisma globalThis Singleton: Always Cache in Production**: The standard Next.js Prisma pattern only caches the client in development.
- **Shell to Script Data Passing: Use Temp Files**: Never embed JSON or structured data into script strings via shell variable expansion.
- **Timezone Offsets: Never Hardcode**: Don't use fixed UTC offsets like `timedelta(hours=-4)` or `new Date().getTimezoneOffset()` for business logic that must respect DST transitions.
- **Output Truncation Causes Silent Parse Failures**: Either size the limit to the maximum expected output (e.g., `head -c 10000` for LLM output), or extract the specific field first and truncate the extracted value.
- **Structured Output Format Compliance**:
  - Parse the constraint first
  - Validate before submitting
  - Fix, don't annotate
- **Update CLAUDE.md When Adding Features**: After implementing a new feature, route, export, or command, update the repo's CLAUDE.md before committing.
- **Centralize query-param parsing: don't hand-roll guards in SSR pages**: When an API route validates a query param through a shared helper, SSR pages must call the same helper instead of re-implementing the guard.
- **`backdrop-filter` Ancestors Confine `position:fixed` Overlays, Portal to Body**: Use `ReactDOM.createPortal(overlay, document.body)` to render fixed overlays outside the containing ancestor.
- **JS Truthiness Guards Don't Reject Negatives: Use `<= 0` for Non-Negative External Quantities**: Use `<= 0` for any quantity that must be strictly positive.
- **Isolate per-item failures in batch loops; guard operations that throw on stored/external data**
- **A per-field guard doesn't make the whole record safe**: A collector that validates ONE field of each upstream record (e.g. a dedup key) reads downstream like "records are now clean," but it only guarantees THAT field.
- **A many-to-one resolver must dedupe before an additive accumulator consumes it**
- **Mixed || / ?: precedence silently drops data**: `a || b ? c : d` parses as `(a || b) ? c : d`; parenthesize every mixed `||` / ternary expression.
- **Check for sibling deliverables before revising a doc another session may have deepened**
- **Substring-matching short blocklist tokens silently drops legitimate content**
- **Enumerate every caller before claiming a configured limit is unreachable or dead config**
- **A control-character escape in an Edit can land as a literal byte and turn the file binary, so grep goes silent**
- **Adding a config passthrough makes every previously-harmless typo in that key a live value**
- **Re-verify an absence claim in a backlog item before implementing it, one grep of the canonical file is not proof**
- **A fix documented as a property of one file never reaches its siblings**: A behavioural fix (browser UA, unverifiable-status bucket, per-request AbortController) made to one HTTP probe, with its constants declared local to that file, does not protect sibling probes; hoist shared behaviour into a shared module.
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
