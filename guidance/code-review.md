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
- [ ] Existing functionality still works (spot-check by hand if there are no tests)

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
- [ ] PR addresses a single concern (one feature, one bug, one refactor)
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

Some configuration properties look like dead code but production depends on them. Never remove these during fix or cleanup runs until you have checked the deployment context:

- **NextAuth/Auth.js**: `basePath`, `redirectProxyUrl`, provider `authorization.params`, `token.params`. Apps deployed on a subpath behind a reverse proxy need these for OAuth callbacks to resolve correctly.
- **Process manager config (e.g. PM2 `ecosystem.config.js`)**: `env`, `max_memory_restart`, `cwd`. Production process management depends on them.
- **Reverse proxy references in code**: URL construction that includes basePaths or proxy prefixes.

**Why:** an automated crash-fix run removed `basePath` and `redirectProxyUrl` from an auth config because nothing in the repo appeared to use them. That broke OAuth on the subpath deployment, and someone had to restore them by hand. A property's use can live entirely in the deployment topology, where a grep of the repo can't find it.

## Default Review Workflow: Review-Ship-Review

For all non-trivial code changes, use the iterative review-ship-review pattern unless the user explicitly asks for a single review pass.

### How it works

1. **Implement**: make the requested changes, run tests, commit.
2. **Review (round 1)**: spawn 2-3 parallel reviewer agents. Each agent audits the diff independently and puts each finding into one of four categories: Critical, Important, Minor, Deferred.
3. **Fix and commit**: address all Critical and Important findings. Commit the fixes.
4. **Review (round 2)**: spawn fresh reviewer agents on the updated code. These reviewers must not see the earlier review output, so they audit with fresh eyes. This catches regressions introduced by the fixes and surfaces issues the first round missed.
5. **Repeat**: if round 2 produces Critical or Important findings, fix them and run another round. Stop when a round comes back clean (no Critical or Important findings). Note Minor and Deferred items, but they don't block.

### Why this is the default

Single-pass reviews miss bugs that only show up after the fixes land. In practice, fix commits introduce new issues 30-40% of the time (reusing the wrong variable, stale state, fixes that interact badly). The second round catches these before they ship.

### Reviewer agent instructions

Each reviewer agent should:
- Read all changed files, not just the diff, to understand the full context
- Check for interactions between changes (e.g., a risk-check fix that bypasses a downstream guard)
- Verify test coverage for new logic paths
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
| String concatenation for paths | Breaks across operating systems | Use `path.join()` |
| Prisma `globalForPrisma` dev-only cache | Connection leak in production | Cache on `globalThis` unconditionally |
| `new Date("2026-04-15")` for display | Parsed as UTC, so the local date can be off by one | Use `new Date(year, month, day)` for local dates |
| Shell-interpolating JSON into script strings | Special characters break syntax | Write to a temp file and read it in the target language |
| Hardcoded timezone offset `timedelta(hours=-4)` | Breaks at DST transitions | Use `ZoneInfo('America/New_York')` or an equivalent TZ library |
| `head -c N` before parsing structured output | Silent data loss: truncation drops blocks that downstream code depends on | Size the limit to the maximum expected output, or extract specific fields first |
| `res.json({ error: err.message })` | Information disclosure: leaks paths, DB strings, stack traces | Return a generic message and log details server-side |
| `child_process.exec(cmd + userInput)` | Command injection via string interpolation | Use `execFile(binary, [args])` with a separate args array |
| `parseInt(queryParam)` without `\|\| default` fed to Prisma `skip`/`take` | `parseInt('abc')` is `NaN`; `Math.max(1, NaN)` stays `NaN`; Prisma `skip: NaN` returns a 500 | `Math.max(1, parseInt(String(raw ?? '1')) \|\| 1)`, where the `\|\| 1` catches `NaN`. Define it once in a shared helper; if an API lib and SSR page components each hand-roll the same logic, they will diverge |

## Rule Digest

One line per lesson, in the order they were learned.

- **Error detail leak prevention**: never expose raw error messages, stack traces, internal paths, hostnames, or database connection strings in HTTP responses.
- **Command injection, exec vs execFile**: never use `child_process.exec()` with string interpolation for values the user can influence.
- **Prisma globalThis singleton, always cache in production**: the standard Next.js Prisma pattern caches the client only in development, so production leaks connections.
- **Shell to script data passing, use temp files**: never embed JSON or structured data into script strings via shell variable expansion.
- **Timezone offsets, never hardcode**: don't use fixed UTC offsets like `timedelta(hours=-4)` or `new Date().getTimezoneOffset()` for business logic that must respect DST transitions.
- **Output truncation causes silent parse failures**: either size the limit to the maximum expected output (e.g., `head -c 10000` for LLM output), or extract the specific field first and then truncate the extracted value.
- **Structured output format compliance**:
  - Parse the constraint first
  - Validate before submitting
  - Fix, don't annotate
- **Update CLAUDE.md when adding features**: after implementing a new feature, route, export, or command, update the repo's CLAUDE.md before committing.
- **Centralize query-param parsing, don't hand-roll guards in SSR pages**: when an API route validates a query param through a shared helper, SSR pages must call the same helper instead of re-implementing the guard.
- **`backdrop-filter` ancestors confine `position:fixed` overlays, so portal to body**: render fixed overlays outside the containing ancestor with `ReactDOM.createPortal(overlay, document.body)`.
- **JS truthiness guards don't reject negatives**: use `<= 0` for any external quantity that must be strictly positive.
- **Isolate per-item failures in batch loops**: guard any operation that can throw on stored or external data, so one bad item doesn't abort the batch.
- **A per-field guard doesn't make the whole record safe**: a collector that validates ONE field of each upstream record (e.g., a dedup key) reads downstream as "records are now clean", but it only guarantees THAT field.
- **A many-to-one resolver must dedupe before an additive accumulator consumes it**: otherwise the same target is counted once per alias.
- **Mixed `||` / `?:` precedence silently drops data**: `a || b ? c : d` parses as `(a || b) ? c : d`; parenthesize every mixed `||` / ternary expression.
- **Check for sibling deliverables before revising a doc another session may have deepened**: revising a stale copy can overwrite newer work.
- **Substring-matching short blocklist tokens silently drops legitimate content**: match on word boundaries or exact tokens.
- **Enumerate every caller before claiming a configured limit is unreachable or dead config.**
- **A control-character escape in an Edit can land as a literal byte and turn the file binary**: after that, grep treats the file as binary and goes silent.
- **Adding a config passthrough turns every previously harmless typo in that key into a live value**: audit existing values before wiring the key through.
- **Re-verify an absence claim in a backlog item before implementing it**: one grep of the canonical file is not proof.
- **A fix documented as a property of one file never reaches its siblings**: if a behavioural fix (e.g., browser UA, an "unverifiable status" bucket, a per-request AbortController) lives in constants local to one HTTP probe and is documented only there, sibling probes keep the bug. Move shared behaviour into a shared module and apply it to every sibling.
- **A display tag is not a handle**: persist the user id whenever a record may later need to address that user.
- **Turning a 500 into a successful empty response makes a previously unreachable client state reachable**: before merging the guard, check what the consumer renders for zero rows.
- **A narration strip must cover both ends of the artifact, not just where it starts.**
- **A hardening sweep keyed on a construct's presence misses the sites that lack the construct entirely**: also search for the sites where it should exist but doesn't.
- **A clipboard write after an awaited call trips uBlock Origin's ClickFix blocker**: do the clipboard write synchronously inside the user gesture.
- **A range-to-single-label formatter must compare the enclosing unit, not just the sub-unit**: e.g., same day in a different month is not the same date.
- **A unit-decomposition formatter must round the total before splitting**: rounding each sub-unit remainder on its own produces outputs like "1h 60m".
- **Validate a nullable field at the source before interpolating it into a string**: a stringified `"null"` gets past a downstream emptiness guard.
- **An upper-bound clamp on a query param is not validation**: check every other way a value can be wrong (NaN, negative, zero, wrong type).
- **After deleting a function, grep for its callers**: with zero definitions and N call sites, `node --check` still passes, but the calls throw ReferenceError at runtime.
- **A threshold that moves with the input cannot be equality-compared against a counter that outlives it**: use `>=`, or recompute both from the same input.
- **A stemmer or lookup that strips to a bare key must try the index's actual citation form first**: otherwise it silently hits an unrelated entry.
- **A relative-step control (+/- keys, arrow buttons) must read the same value the UI displays**, not a separately persisted value.
- **Scope a page-level loading gate to the initial load; don't toggle it on every refetch**: if the same `loading` flag gates the initial render and is also set by an inline mutation's refetch, any inline action (a "mark used" button, a row toggle) blanks the whole page to the placeholder and bounces scroll to the top.
- **An ordered suffix/prefix-stripping list where one entry ends with another must NOT default to longest-match-first**: first check which side of the boundary the shared character belongs to, then measure both orderings over the whole dataset before choosing one.
