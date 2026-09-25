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

Some configuration properties look like dead code but are essential in production. Never remove these during fix or cleanup runs without verifying the deployment context:

- **NextAuth/Auth.js**: `basePath`, `redirectProxyUrl`, provider `authorization.params`, `token.params`. These are required when the app is served under a subpath behind a reverse proxy; without them the OAuth callback URLs point at the wrong path.
- **Process manager config (e.g. PM2 `ecosystem.config.js`)**: `env`, `max_memory_restart`, `cwd`. Essential for production process management.
- **Proxy-aware URL construction in code**: any URL building that includes basePaths or proxy prefixes.

**Why:** an automated crash-fix run removed `basePath` and `redirectProxyUrl` from an auth config because they appeared unused. This broke OAuth on the subpath deployment and needed a manual restore.

## Default Review Workflow: Review-Ship-Review

Unless the user explicitly requests a single review pass, use the iterative review-ship-review pattern for all non-trivial code changes.

### How it works

1. **Implement**: make the requested changes, run tests, commit.
2. **Review (round 1)**: spawn 2-3 parallel reviewer agents. Each audits the diff independently, categorizing findings as Critical / Important / Minor / Deferred.
3. **Fix and commit**: address all Critical and Important findings. Commit the fixes.
4. **Review (round 2)**: spawn fresh reviewer agents on the updated code. Reviewers must not see prior review output; they audit with fresh eyes. This catches regressions introduced by the fixes and issues the first round missed.
5. **Repeat**: if round 2 produces Critical or Important findings, fix and run another round. Stop when a round returns clean (no Critical/Important). Minor and Deferred items can be noted but don't block.

### Why this is the default

Single-pass reviews miss bugs that only become visible after fixes land. In practice, fix commits introduce new issues 30-40% of the time (wrong variable reuse, stale state, interaction between fixes). The second round catches these before they ship.

### Reviewer agent instructions

Each reviewer agent should:
- Read all changed files (not just the diff) to understand full context
- Check for interactions between changes (e.g., a risk-check fix that bypasses a downstream guard)
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
| Prisma `globalForPrisma` dev-only cache | Connection leak in production | Cache on `globalThis` unconditionally (see below) |
| `new Date("2026-04-15")` for display | UTC parse, then local timezone off-by-one | Use `new Date(year, month, day)` for local dates |
| Shell-interpolating JSON into script strings | Special chars break syntax | Write to temp file, read in target language (see below) |
| Hardcoded timezone offset `timedelta(hours=-4)` | Breaks at DST transitions | Use `ZoneInfo('America/New_York')` or equivalent TZ library |
| `head -c N` before parsing structured output | Silent data loss: truncation drops blocks downstream code depends on | Size limit to max expected output, or extract specific fields first |
| `res.json({ error: err.message })` | Information disclosure: leaks paths, DB strings, stack traces | Return generic message, log details server-side (see below) |
| `child_process.exec(cmd + userInput)` | Command injection via string interpolation | Use `execFile(binary, [args])` with separate args array (see below) |
| `parseInt(queryParam)` without `\|\| default` fed to Prisma `skip`/`take` | `parseInt('abc')` is `NaN`; `Math.max(1, NaN)` stays `NaN`; Prisma `skip: NaN` gives a 500 | `Math.max(1, parseInt(String(raw ?? '1')) \|\| 1)`; the `\|\| 1` catches `NaN`. Define once in a shared helper; hand-rolling it in both an API lib and SSR pages guarantees they diverge |
| `if (secret === input)` | Timing attack leaks secret length/content | Use `crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b))` |
| `new URL(userInput)` without scheme check | SSRF via `file://`, `data://`, `javascript://` | Validate `url.protocol` is `http:` or `https:` before use |
| `path.join(base, userInput)` unsanitized | Path traversal via `../` sequences | Strip `..`, leading `/`, and non-alphanumeric chars from user path segments |
| `Infinity` in API responses | `JSON.stringify(Infinity)` is `"null"`; client sees `null`, not a number | Use a large finite number (e.g., `999999`) for "unlimited" values sent over JSON |
| Tailwind `@apply text-blue-600` in CSS | `@apply` with certain utility classes silently drops from compiled output | Use raw CSS values (`color: #2563eb`) instead of `@apply` for critical styles |
| Component hardcodes `relative` and caller passes `absolute inset-0` via `className` | Both position classes land on the element; Tailwind v4 stylesheet emission order (not JSX/prop order) decides which wins, so `.relative` can beat `.absolute` and collapse a full-bleed overlay to 0 height | Make position a component prop (e.g. `fill ? 'absolute inset-0' : 'relative'`); never stack conflicting position utilities. A 0-height lazy `<img>` never issues a network request, which looks like a missing asset, not a layout bug |

## Error Detail Leak Prevention

Never expose raw error messages, stack traces, internal paths, hostnames, or database connection strings in HTTP responses. This is OWASP "Improper Error Handling", and it is common: an audit across many small services found it in more than half a dozen.

```js
// ❌ Leaks internal paths, DB connection strings, etc.
catch (error) {
  res.status(500).json({ error: error.message });
  // or: res.status(500).json({ error: 'Failed', details: String(error) });
}

// ✅ Generic message to client, full error logged server-side
catch (error) {
  console.error('Route /api/foo failed:', error);
  res.status(500).json({ error: 'Internal server error' });
}
```

**Common leak vectors:** `details: String(error)`, `error: err.message`, `os.hostname()` in health endpoints, MulterError raw messages, CLI exit codes in spawn error handlers.

## Command Injection: exec vs execFile

Never use `child_process.exec()` with string interpolation for user-influenced values. `exec()` runs through a shell, so semicolons, backticks, and pipe characters in the input become shell commands.

```js
// ❌ Command injection: url could contain `; rm -rf /`
exec(`open "${url}"`);

// ✅ execFile bypasses the shell entirely
execFile('open', [url]);
```

When the value is a URL, also add a guard rejecting non-http(s) protocols.

## Prisma globalThis Singleton: Always Cache in Production

The standard Next.js Prisma pattern only caches the client in development:

```ts
// ❌ Bug: production creates new clients on duplicate module loads
if (process.env.NODE_ENV !== "production") globalForPrisma.prisma = prisma;
```

With adapters like `@prisma/adapter-libsql`, production can also load the module multiple times, leaking connections. Always cache unconditionally:

```ts
// ✅ Prevents connection leaks in both dev and production
globalForPrisma.prisma = prisma;
```

## Shell to Script Data Passing: Use Temp Files

Never embed JSON or structured data into script strings via shell variable expansion. Quotes, newlines, and special characters in the data will corrupt the target language syntax.

```bash
# ❌ Breaks when JSON contains quotes, newlines, or $
python3 -c "
import json
data = json.loads('''$JSON_VAR''')
"

# ✅ Write to temp file, read in target script
TMPFILE=$(mktemp)
echo "$JSON_VAR" > "$TMPFILE"
python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
" "$TMPFILE"
rm -f "$TMPFILE"
```

**Why:** a script silently produced malformed Python whenever input text (e.g. news headlines) contained special characters. Temp files eliminate all shell escaping concerns.

**Also applies to:** Node.js (`--eval` with interpolated strings), Ruby, any language invoked from bash with dynamic data. Stdin piping (`echo "$JSON" | python3 script.py`) is an alternative to temp files.

## Timezone Offsets: Never Hardcode

Don't use fixed UTC offsets like `timedelta(hours=-4)` or `new Date().getTimezoneOffset()` for business logic that must respect DST transitions.

```python
# ❌ Breaks every March and November
eastern = timezone(timedelta(hours=-4))

# ✅ Auto-handles EST/EDT
from zoneinfo import ZoneInfo
eastern = ZoneInfo('America/New_York')
```

**Why:** a market-hours check with a hardcoded summer offset produced zero executions for the whole winter half of the year. Also check cron schedules: UTC hours interpreted as local time is the same bug.

## Output Truncation Causes Silent Parse Failures

When bash scripts use `head -c N` or `head -n N` to limit command output before extracting structured blocks (via `grep`, `jq`, etc.), the truncation can silently drop the block downstream code depends on. The result is an empty match, not an error, so failures are invisible.

**Example:** `head -c 2000` on LLM CLI output truncated a marker block that later threading logic depended on. The script ran without errors but produced empty summaries for weeks.

**Fix:** size the limit to the maximum expected output (e.g., `head -c 10000` for LLM output), or extract the specific field first and truncate the extracted value. Never truncate structured output before parsing it.

## Structured Output Format Compliance

When a prompt specifies a strict output format (e.g., "ONLY valid JSON", "no markdown fences", "no explanation"), enforce it before submitting:

1. **Parse the constraint first**: read the format requirement exactly.
2. **Validate before submitting**: after writing the response, check it against the constraint.
3. **Fix, don't annotate**: if a violation is found, STOP and regenerate correctly. Never submit both the violation and a self-diagnosis of it.

**Common violations:** wrapping JSON in fences when told not to; adding explanatory text when told "no explanation"; submitting a self-diagnosis inside the violating output.

**Why:** agents repeatedly violated format constraints and then self-diagnosed the violation inside the same response, showing they knew the rule and still didn't fix it. Hard format constraints are enforcement gates for downstream parsers. Identifying a violation is not fixing it.

## Update CLAUDE.md When Adding Features

After implementing a new feature, route, export, or command, update the repo's CLAUDE.md before committing. Documentation lag is structural; close it at commit time. A post-commit drift check that flags commits adding exports/routes/env vars without a CLAUDE.md update is a cheap way to enforce this.

## Centralize Query-Param Parsing: Don't Hand-Roll Guards in SSR Pages

When an API route uses a `paginate()`/`parsePageParam()` helper to validate `?page=` (guarding against `parseInt('abc')` giving `NaN`, which becomes Prisma `skip=NaN` and a 500), SSR page components that re-implement the same parsing with `Math.max(1, parseInt(String(x||'1')))` will diverge as one or the other gains new guards. Extract one shared helper used by both API routes and every SSR page; any user-controlled value flowing into Prisma `skip`/`take`/`where` must pass through it.

## An Upper-Bound Clamp on a Query Param Is Not Validation

`const limit = Math.min(Number(url.searchParams.get("limit") || 50), 200)` reads like validation because it caps the max, but `Number()` on non-numeric input gives `NaN`, and nothing rejects `NaN`, negatives, or fractions before they reach the database. With Prisma + libSQL the failure modes are not symmetric, which makes this easy to under-test:

| input | what actually happens |
|---|---|
| `take: NaN` / `skip: NaN` (`?limit=all`, `?offset=abc`) | `PrismaClientValidationError`, uncaught, HTTP 500 |
| `skip: -1` | throws `Value can only be positive`, 500 |
| `take: -2` | **no error**: negative `take` means "last N rows", so under `orderBy: desc` the caller silently gets the OLDEST page with a 200 |
| `take: 1.5` / `skip: 1.5` | SQLite truncates silently; the response echoes back the fractional value |

The negative-`take` case is the dangerous one because it doesn't error. Rule: when a query param feeds an ORM/DB call, don't stop at "is the max capped". Reject non-numeric, negative, and fractional input with a 400 naming the bad param before it reaches the query layer.

## `backdrop-filter` Ancestors Confine `position:fixed` Overlays: Portal to Body

Any ancestor with a non-`none` `backdrop-filter` (e.g. glass-morphism / `backdrop-blur` cards) or `transform`/`filter` creates a containing block for `position:fixed` descendants. A `fixed inset-0` modal, lightbox, or toast rendered inside such a card is silently clipped to the card's bounds, not the viewport.

**Symptom:** overlay measures card dimensions instead of viewport; backdrop is unclickable or truncated.

**Fix:** use `ReactDOM.createPortal(overlay, document.body)` to render fixed overlays outside the containing ancestor.

**Two follow-on gotchas after portaling:**
1. Portals still bubble synthetic events through the React tree: clicks inside the overlay can still fire ancestor `onClick` handlers (e.g. a card's navigate). Add `e.stopPropagation()` on overlay and close-button handlers.
2. `aria-modal=true` does NOT trap keyboard focus. Implement an explicit Tab/Shift+Tab focus trap and reclaim focus if `document.activeElement` leaves the dialog.

**Where to look:** any `fixed` or `fixed inset-0` element inside a component that uses `backdrop-blur-*`, `blur-*`, `filter`, or CSS `transform`.

## JS Truthiness Guards Don't Reject Negatives: Use `<= 0` for Non-Negative External Quantities

When validating a non-negative numeric value parsed from external input (webhook payloads, API responses, user data), `!x || x === 0` does NOT reject negatives; negative numbers are truthy. A negative distance, duration, speed, price, or count flows through arithmetic and produces an invalid result.

```js
// BAD: lets negative durationSec through
if (!distanceM || !durationSec || distanceM === 0) return undefined;

// GOOD
if (!distanceM || !durationSec || distanceM <= 0 || durationSec <= 0) return undefined;
```

**Self-review trigger:** any guard on an externally-sourced numeric that represents a measured, non-negative quantity: ask "does `!x || x === 0` let negatives through?" If yes, change to `<= 0`. If a sibling adapter in the same codebase already uses `<= 0`, the inconsistency is itself the tell.

## Isolate Per-Item Failures in Batch Loops

When a loop processes a batch (DB rows, files, API records) and each iteration does an operation that can throw on bad data, an unguarded throw aborts the ENTIRE batch, not just the bad item. Two-layer defense:

1. Guard the throwing operation itself: compile a stored regex via a `safeCompile()` that returns null on SyntaxError; `JSON.parse` external files in try/catch; check a data-derived divisor is non-zero (e.g. duplicate timestamps in an interpolation `(t-t0)/(t1-t0)`).
2. Wrap each iteration in try/catch + continue so one bad record is skipped, not fatal.

Example shape: a detection endpoint compiled `new RegExp(template.pattern)` from stored strings inside an unguarded loop; one malformed pattern threw and 500'd the endpoint for every item the user had.

**Self-review trigger:** any `new RegExp(non-literal)`, `JSON.parse(file/network)`, or division by a data-derived value inside a loop: ask "does one bad input abort the whole batch?" Bonus: compile invariant regexes once before the loop, not per iteration.

## A Per-Field Guard Doesn't Make the Whole Record Safe

A collector that validates ONE field of each upstream record (e.g. its dedup key) reads downstream like "records are now clean", but it only guarantees THAT field. Every other field is still passed through verbatim from the untrusted source.

Example shape: a merge step validated `title` because it was the dedup key; a filter elsewhere called `g.platforms.toLowerCase()` unguarded, directly from `main()` with no surrounding try/catch. One record with a missing `platforms` crashed the whole run after earlier side effects had already happened. Fix: require `typeof g?.platforms === "string"` so a malformed record is treated as no-match and skipped.

**Self-review trigger:** when you see a guard on one key field, don't infer the record is safe elsewhere. Enumerate which OTHER fields downstream code dereferences and guard each at its own dereference site. A dereference inside a function called directly from a top-level orchestrator with no try/catch is a whole-run crash, not a local error.

## A Many-to-One Resolver Must Dedupe Before an Additive Accumulator Consumes It

A resolver that maps N input strings onto a catalog with exact-then-fuzzy matching is MANY-TO-ONE, but `inputs.map(resolve).filter(nonNull)` looks one-to-one. Every additive consumer downstream (a cost total, a line-item list, a coverage ratio, a score normalized on the total) then counts the same item once per input that mapped to it.

Example shape: `"chicken"` and `"chicken breast"` both fuzzy-matched the same verbose catalog product, so it was priced twice, listed twice, and the inflated total pushed the plan below a genuinely worse one in ranking. A sibling AI-assisted path already deduped by `id`; only the deterministic path lacked the guard.

**Fix:** dedupe AT THE RESOLVER (key on `id`, or object identity), keeping first-occurrence order, not in each caller.

**Self-review trigger:** whenever a matcher can return the same target for different inputs, check every consumer that sums, counts, or lists its output. When two paths produce the same kind of list, diff their post-processing; a dedup present on one and absent on the other is a bug. Discriminating test: two inputs resolving to the SAME row (expect one count) PLUS two inputs sharing a fuzzy prefix but resolving to DIFFERENT rows (expect both, guarding against over-deduping).

## Mixed `||` / `?:` Precedence Silently Drops Data

`a || b ? c : d` parses as `(a || b) ? c : d`, NOT `a || (b ? c : d)`. In an object-literal value this bites when the taken branch can yield null and a downstream schema rejects it.

Example shape: `salary: salary || data.range ? format(data.range) : undefined` evaluated `format(undefined)` (null) whenever `salary` existed but `range` didn't; the schema (`z.string().optional()`, rejects null) threw, and the record was silently dropped by a catch-and-filter.

Reviewer checklist:
1. Any `x || y ? ... : ...` or `x && y ? ... : ...` in a value position is suspect: add parens or split it.
2. Enable eslint `no-mixed-operators` and `no-unneeded-ternary`.
3. A correct sibling form nearby (e.g. `salary || undefined` in a parallel adapter) is a strong tell.

Fix pattern: `salary || format(range) || undefined`, so the field is never null.

## Check for Sibling Deliverables Before Revising a Doc

Before extending a deliverable, list the sibling files in its directory and follow every internal link in it. A parallel session may have produced deeper research that CONTRADICTS the doc you are about to extend, and the doc may already carry a superseded-by pointer. Extending without reading siblings can ship a confidently wrong recommendation that a newer doc already reversed.

```bash
ls <dir>                                   # siblings the doc may not link
grep -oE '\]\(\./[^)]+\)' <doc>            # every internal link
grep -inE 'supersede|correction|stale|outdated|use .* instead' <doc> <siblings>
```

Then verify each link resolves, since a superseded-by pointer to a missing file is worse than none:

```bash
for f in $(grep -oE '\]\(\./[^)]+\)' doc.md | sed 's/](\.\///; s/)$//'); do [ -e "$f" ] && echo "OK $f" || echo "MISSING $f"; done
```

## Substring-Matching Short Blocklist Tokens Silently Drops Legitimate Content

A keyword blocklist matched with a bare substring test (`any(w in text for w in WORDS)`, `text.includes(w)`, `LIKE '%w%'`) is wrong the moment ANY entry is short enough to sit inside an ordinary word. If the match feeds a HARD FILTER, the affected item is not down-ranked, it DISAPPEARS. Example: a profanity list containing "ass" flagged pass/class/assist/massive/password/grass/compass, and clean content was dropped from selection entirely.

Do NOT fix this by wrapping every entry in `\b`. That trades false positives for false NEGATIVES: `\bfuck\b` stops matching "fucking". Prefix-anchoring (`\bass\w*`) reintroduces the original bug ("assist").

Correct shape: keep substring matching as the DEFAULT (it catches inflections for free), keep an explicit whole-word exception set for the short entries, and enumerate compound forms in the main list:

```python
WHOLE_WORD = {"ass", "asses"}                       # \b-anchored
WORDS = [..., "asshole", "dumbass", "badass"]       # substring, unambiguous
parts = [rf'\b{re.escape(w)}\b' if w in WHOLE_WORD else re.escape(w) for w in WORDS]
PATTERN = re.compile('|'.join(parts))
```

Reviewer checklist:
1. For every blocklist, ask: is any entry 4 chars or fewer, and a substring of a common word? Grep it against a word list.
2. Trace whether a match causes a hard drop (return 0 / continue / filter out). Hard drops make the bug invisible because the dropped item leaves no log line.
3. When you add `\b` anchors, re-test in BOTH directions (innocent-must-be-clean AND bad-must-still-match).
4. Verify anchor interaction for non-alphabetic entries (`***`, `[__]`): `\b` doesn't apply where there are no word characters at the edges.

The compound list is an OPEN CLASS; any enumeration is incomplete by construction. Document it as incomplete and never claim "so nothing is lost". A three-item allowlist once shipped with that claim and a mechanical diff found 22 recall losses (jackass, smartass, half-assed, ...), which, because the match fed a hard gate, made previously gated items selectable.

Process lessons:
- Write the recall test in the SAME commit as the anchor change, enumerating strings the old form caught. A one-directional suite certifies the regression green.
- For any matching change, mechanically diff old vs new matcher over a few hundred strings from BOTH classes instead of reasoning about which cases changed.

## Enumerate Every Caller Before Claiming a Configured Limit Is Unreachable

When an interface cannot command some configured limit (a max, a cap, a timeout), the FIX is usually right, but "this parameter is dead, it can never bind" is a far stronger claim than the evidence normally supports. It holds only if every caller goes through the interface you looked at.

Check it: grep for the parameter name AND for the model's entry point, then read each caller. A second path often reaches the limit, typically an internal, scripted, or replay path passing RAW units while the public path passes normalized values. Scope the claim ("unreachable through the normalized interface"), not the parameter.

Example shape: a normalized `[-1,1]` action scaled both signs by the acceleration limit, so the larger braking limit was unreachable for the agent. The claim "brake limit can never bind" was false: scripted entities reached the same model through an unnormalized path and clamped against it several times per episode.

numpy corollary: collapsing an elementwise expression to a scalar (`float(x)`, `int(x)`, `.item()`) just to make a branch read nicely moves error detection upstream of the callee that validates shape, replacing its specific message with a generic TypeError. Prefer `np.where(cond, a, b)` so malformed input reaches the validating callee.

## A Control-Character Escape in an Edit Can Land as a Literal Byte

Writing a regex class such as `[\x00-\x1f]` into a file via an edit tool can emit the actual control bytes rather than the escape text. The file then counts as binary: grep stops printing matches for every pattern in it, which reads as "my edit did not land" rather than "the file is now binary".

- If grep suddenly finds nothing in a file you just edited, run `grep -a` before re-editing.
- In JS source, write control-character classes as `\u0000-\u001f`, which is plain ASCII.
- Check with: `python3 -c "d=open(f,'rb').read(); print([(i,b) for i,b in enumerate(d) if b<9 or (10<b<32 and b!=13) or b==127][:5])"`

## Adding a Config Passthrough Makes Every Previously Harmless Typo a Live Value

A loader silently dropped some tunable limits; the fix forwarded them with `float()`. That made one case strictly worse: PyYAML resolves `yes/no/on/off` to bools and `float(True)` is `1.0`, so `max_accel: yes`, previously ignored (sane default), now installed a limit of 1.0.

Rule: a passthrough and its validation must land in the SAME change. Ask: what did this key do before I honored it, and is the new behavior worse for a typo?

Checks for numeric config that `float()` alone passes:
- **bool**: reject explicitly, testing `isinstance(x, bool)` BEFORE `float()` (bool subclasses int).
- **non-finite**: `nan`/`inf` parse fine and propagate into state instead of failing.
- **negative**: worse than useless as a bound. `np.clip(v, -max_brake, max_accel)` with negative `max_brake` has min > max; numpy returns the max, so full brake became full throttle.

`np.clip` does not error when min > max; any clip whose bounds come from user input needs the bounds checked, not just the value.

Coerce and validate at the boundary, with an error naming the field and its location. Otherwise the failure surfaces far from its cause, e.g. an un-coerced string dying inside numpy as `ufunc 'clip' did not contain a loop with signature matching types ... dtype('<U2')`.

## Re-Verify an Absence Claim in a Backlog Item Before Implementing It

Backlog notes often assert an ABSENCE ("X has no indexes", "this path is untested", "there is no validation"). These are the least reliable items because they usually come from one grep of the file where the thing SHOULD be declared, not every place it COULD be.

Examples: "this table has no indexes" was based on an ORM schema file, but the indexes were created in raw DDL elsewhere (only composite variants were missing). "These functions have zero test coverage" was false; the matching test file had 11 direct tests.

Procedure:
- "No tests": grep the test dir for the symbol; don't infer from a coverage note.
- "No indexes/constraints/migrations": grep for raw DDL and migration files, not just the ORM schema.
- "No validation": read the route body, not the schema.

If the premise is false, WRITE THE CORRECTION back into the backlog with the file:line that disproves it, or the stale claim burns a session every time it is picked up.

## A Fix Documented as a Property of One File Never Reaches Its Siblings

A behavioral fix (browser UA, an "unverifiable" status bucket, per-request AbortController) was made to one HTTP probe with its constants LOCAL to that file and the rule documented under a heading naming that file. Weeks later sibling probes still had the bug, one of which silently deleted live records.

1. **Hoist the constants** into the shared module the siblings already import, and make the fixed file import them too. That creates a link that makes the next divergence visible.
2. **Name the doc section after the behavior, not the file.** "Link checker (link-checker.js)" is a rule nobody applies to a sibling file. "Probing third-party sites (every HEAD/GET against a page we don't own)", with call sites enumerated, is.

Corollary: an unused-import lint error at a fix site is a signpost, not noise. "X is defined but never used" at the line a fix touched usually means that file stopped sharing something with its siblings. When quoting how long CI has been red, page back to the first failure, not the latest.

## A Display Tag Is Not a Handle: Persist the User Id

A persisted job record stored the requester's *display tag* and no id. It rendered fine for months, but a recovery path needed an addressable id to attribute a reply; with none, it fell through to a single-user env fallback, so every recovered job was attributed to one user regardless of who asked. Correct by accident on one user, a silent identity swap with two.

A field chosen because it *displays* well fails the first time something needs to *act* on it. Two tells that a fallback is hiding a missing field: (1) it's a single per-deployment scalar rather than derived per record; (2) its justifying comment explains a *structural* absence rather than a rare one.

Fix: persist both, at every record-write site, pass the id through the consumer, and keep the fallback only for records written before the change. Test the resolution order: recorded id beats fallback; missing id uses fallback; neither present refuses rather than guessing.

## Turning a 500 into an Empty Success Makes an Unreachable Client State Reachable

A guard that converts an error into a valid empty response OPENS a code path the client has never executed. The client's zero-row rendering was dead code until that moment and may be worse than the error.

Example shape: a feed endpoint 500'd on a filtered empty page (`page[page.length - 1].review` on an empty array). The client's fetch hook never updated state on a rejected fetch, so stale data survived and the UI looked fine. After the guard returned `200 {reviews: []}`, the empty list landed and the page rendered its zero-row branch: the filter toolbar unmounted and a "follow some people" prompt appeared to a user who already followed people.

When reviewing or writing such a guard:
- Ask what the consumer does with the newly possible value and read that branch.
- Issue the request against both builds and diff the rendered output, not just the status code.
- If the client fix is in a different PR, say so in BOTH PR descriptions and ask for them to merge together.

This generalizes past HTTP: a swallowed exception, a short-circuited null, a retry that always failed; anything whose failure masked a downstream branch.

## A Narration Strip Must Cover Both Ends of the Artifact

A control that strips a model's process narration from a generated artifact usually anchors on where the real content starts ("everything from the first `#` heading on is the document"). That only handles narration prepended BEFORE the content. A later pass that appends commentary AFTER (e.g. a refinement pass writing `## Editor Notes` with its own QA log) is invisible to a front-anchored strip. In one corpus this leaked the model's internal QA log into nearly half the published documents, rendered as a navigable section so it looked intentional.

For any strip/redaction/extraction control over model output:
- Does it have an END condition as well as a START condition?
- Check every pass that can touch the artifact AFTER the strip's assumed boundary, not just the one the strip was written against. Adding a second pass silently makes a one-pass strip incomplete.
- Measure against the full corpus, not a hand-picked sample.

## A Hardening Sweep Keyed on a Construct's Presence Is Blind to Sites That Lack It

When hardening by grepping for the construct itself (every `LIMIT`, `ORDER BY`, try/catch, auth check), the sweep only finds sites that ALREADY have it. The strictly worse site that lacks it entirely never matches. Example: a pass gave every truncating list a `(createdAt, id)` total order, but a search query with no `LIMIT` and no `ORDER BY` never appeared in the sweep and stayed unbounded and nondeterministic.

Rule: enumerate the operations that SHOULD carry the guard (every list-returning endpoint, every user-input boundary), not the ones a grep for the guard turns up. The absence case is the most likely bug and the one a presence-keyed sweep cannot find.

## A Clipboard Write After an `await` Trips uBlock Origin's ClickFix Blocker

uBlock Origin's ClickFix protection (default badware list) hooks `navigator.clipboard.writeText()` and blocks writes outside a fresh user gesture. An `await` before the write (`await fetch(...)`) consumes transient user activation, so the write is blocked even inside the same click handler, with no user-visible error.

**Rule:** never auto-copy after an `await` in the same handler. Split it:
1. One action creates the link (the async fetch), with no clipboard write.
2. A dedicated **Copy link** button calls `writeText` synchronously in its own click handler, with the URL already in state.

Keep a visible, selectable `<a>` as a fallback. The heuristic is about gesture binding, not content: a plain `https://` URL still trips it if the write is gesture-unbound.

## A Range-to-Single-Label Formatter Must Compare the Enclosing Unit

A date-range formatter that collapsed a "single month" window to `Mon YYYY` tested only `start.getMonth() === end.getMonth()`. A 12-month period starting mid-month (Jun 15 2025 to Jun 14 2026) matched and rendered as "Jun 2026", implying one month and hiding the start year. Fix: also require `getFullYear()` to match before collapsing.

General shape: a single-unit shortcut keyed on sub-unit equality (month, day-of-week, hour) is wrong whenever the enclosing unit differs across endpoints. List the period kinds that actually reach the formatter and hand-check each, especially those whose length equals the sub-unit's cycle. The discriminating test constructs exactly that endpoints-share-the-sub-unit case and asserts the range form.

## A Unit-Decomposition Formatter Must Round the Total Before Splitting

```ts
const hours = Math.floor(minutes / 60);
const mins  = Math.round(minutes % 60);   // rounds the remainder in isolation
return `${hours}h ${mins}m`;              // "1h 60m" for 119.7
```

For raw float input, any value in `[k*60+59.5, (k+1)*60)` renders the malformed `"1h 60m"`, reachable in ordinary use. Fix: round the total first, then derive every displayed unit from the rounded total. This also promotes `59.7` to `"1h 0m"` instead of `"60 min"`.

Same family as the range formatter above: a special case validated against a sub-unit in isolation instead of the composed whole. Never round a sub-unit's remainder independently.

## Validate a Nullable Field at the Source Before Interpolating It

A stringified null survives a downstream emptiness guard. `[UPCOMING] ${el.title}` with a null title yields the non-empty string `"[UPCOMING] null"`, which passes a merge/dedup guard that correctly rejects a raw null, and a broken item titled "[UPCOMING] null" gets published.

Rule: validate or skip a nullable field in the SOURCE mapper, before it is embedded into a larger string. A guard after interpolation cannot distinguish a real value from `"null"`/`"undefined"`/`"0"`. When two paths build the same field and one wraps it in a template, both need the same source-level validation.

Discriminating test input: a non-string value that stringifies to non-empty (`null`, `undefined`, `0`). Empty/whitespace strings are NOT discriminating.

**Self-review trigger:** any `${x}` / `String(x)` embedding an externally-sourced nullable field, followed downstream by a non-empty/truthiness check on the result.

## After Deleting a Function, Grep for Its Callers

A state with 0 definitions and N remaining calls passes `node --check` (syntax is valid) and the page still loads, but the handlers throw `ReferenceError` when invoked. This happens easily when a concurrent session commits a partial refactor.

- Grep for callers, not just the definition, whenever you remove a function.
- Verify UI changes with a real headless browser run (e.g. Playwright capturing `pageerror` and `console.error`) before claiming done. `node --check` is necessary but not sufficient.
- On a shared checkout, build the fix from the current working tree, stage only the paths you changed, and after deploying a single file with a targeted copy (no `--delete`), diff the deployed file against committed HEAD to catch concurrent drift.

## A Moving Threshold Cannot Be Equality-Compared Against a Counter That Outlives It

A "notify once when a counter crosses a limit" check using `===` breaks when the limit is not constant. Example: alert when `consecutive_failures === alertThreshold(error)`, where the counter tracks the whole failure streak but the threshold depends on the LATEST error class (transient network fault alerts at 4, page fault at 2). Two transient failures then a page fault gives `3 === 2`, and every later comparison is false: the check failed forever and never alerted. It went unnoticed because the item was visibly red, reading as "known broken" rather than "alerting is broken". The reverse mismatch can send DUPLICATE alerts.

A verifier found the same shape a few lines away: thresholds built with `Math.max(1, Number(rawEnvVar || fallback))`; a malformed env var gives `NaN`, every comparison is false, and one typo silently disabled alerting for the whole install.

How to apply:
- Any counter-crosses-limit check where the limit can move (by input class, config, env) needs `>=`, not `===`. Track "already fired?" as its own persisted fact (boolean or timestamp). Derive the paired close-out (recovery / resolve) from that same fact, not by re-evaluating the open condition.
- Any threshold from `Number()` / `parseInt` / `parseFloat` without an explicit NaN check fails open. Validate at the boundary and fall back explicitly. Check empty string separately: `Number('')` is `0`, not `NaN`, and silently becomes a live threshold of 0.
- Test the TRANSITION case (a streak changing class; malformed vs absent config), not just a steady run. Steady-state tests pass identically on buggy and fixed code.
- When you find one "guard that cannot fire", grep the same module for siblings before closing the finding.

## A Stemmer That Strips to a Bare Key Must Try the Index's Citation Form First

When a lookup strips affixes before indexing a dictionary, lexicon, or enum table, don't assume the bare stem is a valid key; check what form the index actually uses. Example: a dictionary lookup stripped verb inflections to a bare stem, but the source dictionary lists verbs only under their citation form. The result was not just misses: bare stems collided with unrelated headwords sharing the same letters, so inflected verbs were confidently glossed as unrelated nouns and fed to a downstream LLM prompt as authoritative. Over the full lexicon, zero inflected verbs resolved to their own entry and thousands resolved to a wrong one.

How to apply:
- Generate candidates in the index's form (stem + citation ending) and try those before falling back to the bare stem.
- Measure over the entire dataset and count wrong hits separately from misses. A key silently matching an unrelated entry is worse than no match and only shows up if you check what was returned.
- If an affix is ambiguous across word classes, keep the existing reading as the first candidate and add the citation-form lookup as a fallback, so cases that already worked can't regress.
- Diff old vs new resolution across the WHOLE dataset before shipping, not just the targeted cases.

## A Relative-Step Control Must Read the Value the UI Displays

An increment/decrement handler ("current ± delta") has two candidate sources for "current": the value shown on screen and a separately persisted value (localStorage, extension storage, app state). These diverge whenever persistence is deliberately suppressed in some mode. Example: a playback-speed control's `[`/`]` keys stepped from the stored speed (3x) while the page was actually playing at the displayed 1x in a mode that ignores the stored default, so pressing "slower" jumped to 2.75x instead of 0.75x.

How to apply:
- Check that any +/-, step, or relative-adjust handler reads the SAME value the label renders. Use the persisted value only as the initial value before anything has rendered.
- When there can be multiple candidate targets (e.g. several `<video>` elements), pick the one actually active, not the first in the DOM.
