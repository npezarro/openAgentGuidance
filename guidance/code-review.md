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

- **NextAuth/Auth.js**: `basePath`, `redirectProxyUrl`, provider `authorization.params`, `token.params`: required for subpath deployments behind reverse proxies.
- **Process manager config (e.g. PM2 `ecosystem.config.js`)**: `env`, `max_memory_restart`, `cwd`: essential for production process management.
- **Apache/proxy config references in code**: URL construction that includes basePaths or proxy prefixes.

**Why:** an automated crash-fix run removed `basePath` and `redirectProxyUrl` from an app's auth config because they appeared unused. This broke OAuth on the subpath deployment and required a manual restore.

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
| Prisma `globalForPrisma` dev-only cache | Connection leak in production | Cache on `globalThis` unconditionally (see below) |
| `new Date("2026-04-15")` for display | UTC parse, then local timezone off-by-one | Use `new Date(year, month, day)` for local dates |
| Shell-interpolating JSON into script strings | Special chars break syntax | Write to temp file, read in target language (see below) |
| Hardcoded timezone offset `timedelta(hours=-4)` | Breaks at DST transitions | Use `ZoneInfo('America/New_York')` or equivalent TZ library |
| `head -c N` before parsing structured output | Silent data loss: truncation drops blocks downstream code depends on | Size limit to max expected output, or extract specific fields first |
| `res.json({ error: err.message })` | Information disclosure: leaks paths, DB strings, stack traces | Return generic message, log details server-side (see below) |
| `child_process.exec(cmd + userInput)` | Command injection via string interpolation | Use `execFile(binary, [args])` with separate args array (see below) |
| `parseInt(queryParam)` without `\|\| default` fed to Prisma `skip`/`take` | `parseInt('abc')` is `NaN`; `Math.max(1, NaN)` stays `NaN`; Prisma `skip: NaN` gives a 500 | `Math.max(1, parseInt(String(raw ?? '1')) \|\| 1)`: the `\|\| 1` catches `NaN`. Define once in a shared helper; hand-rolling the same logic in both an API lib and SSR page components guarantees they diverge |
| `if (secret === input)` | Timing attack leaks secret length/content | Use `crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b))` |
| `new URL(userInput)` without scheme check | SSRF via `file://`, `data://`, `javascript://` | Validate `url.protocol` is `http:` or `https:` before use |
| `path.join(base, userInput)` unsanitized | Path traversal via `../` sequences | Strip `..`, leading `/`, and non-alphanumeric chars from user path segments |
| `Infinity` in API responses | `JSON.stringify(Infinity)` === `"null"`, client sees `null` not a number | Use a large finite number (e.g., `999999`) for "unlimited" values sent over JSON |
| Tailwind `@apply text-blue-600` in CSS | `@apply` with certain utility classes silently drops from compiled output | Use raw CSS values (`color: #2563eb`) instead of `@apply` for critical styles |
| Component hardcodes `relative` + caller passes `absolute inset-0` via `className` | Both position classes land on the element; Tailwind v4 stylesheet emission order (not JSX/prop order) decides which wins, so `.relative` can beat `.absolute` and collapse a full-bleed overlay to 0 height | Make position a component prop (e.g. `fill ? 'absolute inset-0' : 'relative'`); never stack conflicting position utilities. A 0-height lazy `<img>` never issues a network request, which looks like a missing asset, not a layout bug |

## Error Detail Leak Prevention

Never expose raw error messages, stack traces, internal paths, hostnames, or database connection strings in HTTP responses. This is OWASP "Improper Error Handling" and it turns up repeatedly in audits.

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

For URLs, also add a validation guard rejecting non-http(s) protocols before the call.

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

**Why:** interpolated data silently produces malformed scripts (e.g. when news article titles contain special chars). Temp files eliminate all shell escaping concerns.

**Also applies to:** Node.js (`--eval` with interpolated strings), Ruby, any language invoked from bash with dynamic data. Use stdin piping (`echo "$JSON" | python3 script.py`) as an alternative to temp files.

## Timezone Offsets: Never Hardcode

Don't use fixed UTC offsets like `timedelta(hours=-4)` or `new Date().getTimezoneOffset()` for business logic that must respect DST transitions.

```python
# ❌ Breaks every March and November
eastern = timezone(timedelta(hours=-4))

# ✅ Auto-handles EST/EDT
from zoneinfo import ZoneInfo
eastern = ZoneInfo('America/New_York')
```

**Why:** a market-hours check with a hardcoded daylight-time offset produces zero executions for half the year. Also check cron schedules: UTC hours interpreted as local time are a common companion bug.

## Output Truncation Causes Silent Parse Failures

When bash scripts use `head -c N` or `head -n N` to limit command output before extracting structured blocks (via `grep`, `jq`, etc.), the truncation can silently drop the block downstream code depends on. The result is an empty match, not an error, so failures are invisible (a truncated LLM output that drops its trailing structured block can yield empty summaries for weeks).

**Fix:** either size the limit to the maximum expected output (e.g., `head -c 10000` for LLM output), or extract the specific field first and truncate the extracted value. Never truncate structured output before parsing it.

## Structured Output Format Compliance

When a prompt specifies a strict output format (e.g., "ONLY valid JSON", "no markdown fences", "no explanation"), enforce it before submitting:

1. **Parse the constraint first**: read the format requirement exactly.
2. **Validate before submitting**: after writing the response, check it against the constraint.
3. **Fix, don't annotate**: if a violation is found, STOP and regenerate correctly. Never submit both the violation and a self-diagnosis of it.

**Common violations:** wrapping JSON in fences when told not to; adding explanatory text when told "no explanation"; submitting a self-diagnosis inside the violating output.

**Why:** hard format constraints are enforcement gates for downstream parsers. An agent that notices its own violation and reports it inside the same output knew the rule and still didn't fix it. Identifying a violation is not fixing it.

## Update CLAUDE.md When Adding Features

After implementing a new feature, route, export, or command, update the repo's CLAUDE.md before committing. Documentation lag is structural; close it at commit time.

## Centralize Query-Param Parsing: Don't Hand-Roll Guards in SSR Pages

When an API route uses a `paginate()`/`parsePageParam()` helper to validate `?page=` (guarding against `parseInt('abc')=NaN`, then Prisma `skip=NaN`, then a 500), SSR page components that re-implement the same parsing with `Math.max(1, parseInt(String(x||'1')))` will diverge as one or the other gains new guards. Extract one shared helper used by both API routes and every SSR page; any user-controlled value flowing into Prisma `skip`/`take`/`where` must pass through it.

## An Upper-Bound Clamp on a Query Param Is Not Validation

`const limit = Math.min(Number(url.searchParams.get("limit") || 50), 200)` reads like validation because it caps the max, but `Number()` on anything non-numeric produces `NaN`, and nothing rejects `NaN`, negatives, or fractions before they reach the DB layer. With Prisma + `@prisma/adapter-libsql`, the failure modes are not symmetric, which makes this easy to under-test:

| input | what actually happens |
|---|---|
| `take: NaN` / `skip: NaN` (`?limit=all`, `?offset=abc`) | `PrismaClientValidationError`, uncaught, HTTP 500 |
| `skip: -1` | throws `Value can only be positive`, 500 |
| `take: -2` | **no error**: negative `take` means "last N rows", so under `orderBy: desc` the caller silently gets the OLDEST page with a 200 |
| `take: 1.5` / `skip: 1.5` | SQLite truncates silently; the response echoes the fractional value back |

**Rule:** for any query-param parser feeding an ORM/DB call, reject non-numeric, negative, and fractional input with a 400 naming the bad param. Capping the max is only one axis.

## `backdrop-filter` Ancestors Confine `position:fixed` Overlays: Portal to Body

Any ancestor with a non-`none` `backdrop-filter` (e.g. glass-morphism / `backdrop-blur` cards) or `transform`/`filter` creates a containing block for `position:fixed` descendants. A `fixed inset-0` modal, lightbox, or toast rendered inside such a card is silently clipped to the card's bounds, not the viewport.

**Symptom:** overlay measures card dimensions instead of viewport; backdrop is unclickable or truncated.

**Fix:** use `ReactDOM.createPortal(overlay, document.body)` to render fixed overlays outside the containing ancestor.

**Two follow-on gotchas after portaling:**
1. Portals still bubble synthetic events through the React tree: clicks inside the overlay can still fire ancestor `onClick` handlers (e.g. a card's `navigate`). Add `e.stopPropagation()` on overlay and close-button handlers.
2. `aria-modal=true` does NOT trap keyboard focus. Implement an explicit Tab/Shift+Tab focus trap and reclaim focus if `document.activeElement` leaves the dialog.

**Where to look:** any `fixed` or `fixed inset-0` element inside a component that uses `backdrop-blur-*`, `blur-*`, `filter`, or CSS `transform`.

## JS Truthiness Guards Don't Reject Negatives: Use `<= 0` for Non-Negative External Quantities

When validating a non-negative numeric value parsed from external input (webhook payloads, API responses, user data), `!x || x === 0` does NOT reject negatives; JavaScript treats negative numbers as truthy. A negative distance, duration, speed, price, or count flows through arithmetic and produces an invalid result.

```js
// BAD: lets negative durationSec through
if (!distanceM || !durationSec || distanceM === 0) return undefined;

// GOOD
if (!distanceM || !durationSec || distanceM <= 0 || durationSec <= 0) return undefined;
```

**Self-review trigger:** any guard on an externally-sourced numeric that represents a measured, non-negative quantity: ask "does `!x || x === 0` let negatives through?" If yes, change to `<= 0`. Also compare sibling adapters: if one uses `<= 0` and another uses `=== 0`, the outlier is the bug.

## Isolate Per-Item Failures in Batch Loops

When a loop processes a batch (DB rows, files, API records) and each iteration does an operation that can throw on bad data, an unguarded throw aborts the ENTIRE batch, not just the bad item. Two-layer defense:

1. Guard the throwing operation itself: compile a stored regex via a `safeCompile()` that returns null on SyntaxError; `JSON.parse` external files in try/catch; check the divisor is non-zero before dividing by data-derived deltas (e.g. duplicate timestamps in an interpolation).
2. Wrap each loop iteration in try/catch + continue so one bad record is skipped, not fatal.

A single malformed stored regex pattern compiled with `new RegExp(stored)` inside an unguarded loop can 500 an endpoint and kill processing for every record the user has.

**Self-review trigger:** any `new RegExp(non-literal)`, `JSON.parse(file/network)`, or division by a data-derived value inside a loop: ask "does one bad input abort the whole batch?" Bonus: compile invariant regexes once before the loop, not per iteration.

## A Per-Field Guard Doesn't Make the Whole Record Safe

A collector that validates ONE field of each upstream record (e.g. a dedup key) reads downstream like "records are now clean," but it only guarantees THAT field. Every other field is still passed through verbatim from the untrusted source, and any consumer that dereferences a different field must guard it at its own boundary.

Typical failure: the merge step validates `title` (its dedup key), then a filter does `g.platforms.toLowerCase()` unguarded, called directly from `main()` outside any try/catch. One record with a missing `platforms` throws, `main().catch` calls `process.exit(1)`, and the whole run dies after earlier side effects already happened. Fix: require `typeof g?.platforms === "string"` so a malformed record is treated as no-match and skipped.

**Self-review trigger:** whenever a collector/mapper validates one key field, enumerate which OTHER fields downstream code dereferences and guard each at its own dereference site. A dereference inside a function called directly from a top-level orchestrator with no surrounding try/catch is a whole-run crash, not a contained error.

## A Many-to-One Resolver Must Dedupe Before an Additive Accumulator Consumes It

A resolver that maps N input strings onto a catalog with exact-then-fuzzy matching is MANY-TO-ONE, but `inputs.map(resolve).filter(nonNull)` looks one-to-one. Every additive consumer downstream (a cost total, a line-item list, a coverage ratio, a score normalised on the total) then counts the same resolved item once per input string that mapped to it. E.g. `"chicken"` and `"chicken breast"` both fuzzy-match one verbose catalog product, it is priced twice, and ranking normalised on the inflated total prefers a genuinely worse plan.

**Fix:** dedupe AT THE RESOLVER (key on `id`, or object identity when the catalog returns the same reference), keeping first-occurrence order, not in each caller.

**Self-review trigger:** whenever a matcher can return the same target for different inputs, check every downstream consumer that sums, counts, or lists its output. When a codebase has two paths producing the same kind of list (a deterministic path and an AI/fallback path), diff their post-processing: a dedup guard present on one and absent on the other is a bug, not a style difference. Discriminating test: two distinct inputs resolving to the SAME row (expect it counted once) PLUS two inputs sharing a fuzzy prefix but resolving to DIFFERENT rows (expect both to survive, guarding against over-deduping).

## Mixed `||` / `?:` Precedence Silently Drops Data

`a || b ? c : d` parses as `(a || b) ? c : d`, NOT `a || (b ? c : d)`. In an object-literal value this bites when the taken branch can yield null/undefined and a downstream schema rejects it:

```js
// Bug: when salary exists but range doesn't, evaluates formatSalaryRange(undefined) -> null
salary: salary || data.salaryRange ? formatSalaryRange(data.salaryRange) : undefined
// Fix: coalesce so the field is never null
salary: salary || formatSalaryRange(data.salaryRange) || undefined
```

If the schema is `z.string().optional()` (rejects null) and a catch maps parse failures to null then filters them, the record silently disappears.

**Checklist:** (1) any `x || y ? ... : ...` or `x && y ? ... : ...` in a value position is suspect: add parens or split it; (2) enable eslint `no-mixed-operators` and `no-unneeded-ternary`; (3) a sibling correct form nearby (e.g. `salary || undefined` in a parallel adapter) is a strong tell.

## Check for Sibling Deliverables Before Revising a Doc Another Session May Have Deepened

Before extending a deliverable, list the sibling files in its directory and follow every internal link in it. A parallel session may have produced deeper research that CONTRADICTS the doc you are about to extend, and the doc may already carry a superseded-by pointer. Extending without reading siblings can ship a confidently-wrong recommendation that a newer doc already reversed.

Procedure before editing any deliverable:

```bash
ls <dir>                                   # siblings the doc may not link
grep -oE '\]\(\./[^)]+\)' <doc>           # every internal link
grep -inE 'supersede|correction|stale|outdated|use .* instead' <doc> <siblings>
```

Then verify each link resolves, since a superseded-by pointer to a missing file is worse than none:

```bash
for f in $(grep -oE '\]\(\./[^)]+\)' doc.md | sed 's/](\.\///; s/)$//'); do [ -e "$f" ] && echo "OK $f" || echo "MISSING $f"; done
```

## Substring-Matching Short Blocklist Tokens Silently Drops Legitimate Content

A keyword blocklist matched with a bare substring test (`any(w in text for w in WORDS)`, `text.includes(w)`, `LIKE '%w%'`) is wrong the moment ANY entry is short enough to sit inside an ordinary word. `"ass"` matches pass, class, assist, massive, password, grass, compass, classic. If the match feeds a HARD FILTER, the affected item is not down-ranked, it DISAPPEARS, with no log line.

Do NOT "fix" this by wrapping every entry in `\b`. That trades false positives for false NEGATIVES: `\bfuck\b` stops matching "fucking", `\bshit\b` stops matching "shitty". Prefix-anchoring (`\bass\w*`) reintroduces the original bug ("assist").

Correct shape: keep substring matching as the DEFAULT (it catches inflections for free), maintain an explicit whole-word exception set for the short entries, and enumerate compound forms in the main list:

```python
WHOLE_WORD = {"ass", "asses"}          # \b-anchored
WORDS = [..., "asshole", "dumbass", "badass"]  # substring, unambiguous
parts = [rf'\b{re.escape(w)}\b' if w in WHOLE_WORD else re.escape(w) for w in WORDS]
PATTERN = re.compile('|'.join(parts))
```

**Reviewer checklist:**
1. For every blocklist/keyword filter, ask "is any entry <= 4 chars, and is it a substring of a common word?" Grep the entry against a word list.
2. Trace whether a match causes a hard drop (return 0 / continue / filter out) rather than a score adjustment. Hard drops make the bug invisible.
3. When you add `\b` anchors, re-test the inflections the old substring form caught, in BOTH directions (innocent-must-be-clean AND bad-must-still-match). A one-directional suite will certify a recall regression green.
4. Verify escape/anchor interaction for non-alphabetic entries (censor markers like `***` or `[__]`): `\b` does not apply where there are no word characters at the edges.

The compound list is an OPEN CLASS and any enumeration is incomplete by construction. Document it as incomplete and do NOT claim "so nothing is lost"; a short allowlist of compounds will miss many (jackass, smartass, half-assed, kickass...), and when the match feeds a hard gate, each miss makes a previously-gated item selectable. Trading a false-positive bug for a false-negative bug of the same size is not a fix.

Two cheap process rules:
- Write the recall test in the SAME commit as the anchor change, enumerating the strings the old form caught.
- For any matching change, mechanically diff old vs new matcher output over a few hundred strings drawn from BOTH classes, rather than reasoning about which cases changed. Losses invisible to inspection are obvious to a diff.

## Enumerate Every Caller Before Claiming a Configured Limit Is Unreachable or Dead Config

When you find that an interface cannot command some configured limit (a max, a cap, a timeout), the FIX is usually right, but the justification "this parameter is dead, it can never bind" is a far stronger claim than the evidence normally supports. It holds only if every caller of the underlying model goes through the interface you looked at.

Check it: grep for the parameter name AND for the model's entry point, then read each caller. A second path often reaches the limit already, typically an internal, scripted, or replay path that passes RAW physical units while the public path passes normalized values. Scope the claim to what you verified ("unreachable through the normalized interface"), not to the parameter. A reviewer who knows about the other caller reads the overreach as evidence you did not look.

**numpy corollary:** collapsing an elementwise expression to a Python scalar (`float(x)`, `int(x)`, `.item()`) purely to make a branch read nicely moves error detection upstream of the callee that validates shape, and replaces that callee's specific message with a generic conversion TypeError. Prefer a shape-agnostic elementwise form (`np.where(cond, a, b)`) so malformed input still reaches the validating callee.

## A Control-Character Escape in an Edit Can Land as a Literal Byte and Turn the File Binary

Writing a regex character class such as `[\x00-\x1f]` into a file via an editing tool can emit the actual control bytes rather than the escape text. The file then counts as binary: grep stops printing matches (and `grep -c` prints nothing) for every pattern in that file, which reads as "my edit did not land" rather than "the file is now binary."

- If grep suddenly finds nothing in a file you just edited, run `grep -a` before re-editing.
- Write control-character classes as `\u0000-\u001f` in JS source: plain ASCII in the file, same meaning.
- Check with: `python3 -c "d=open(f,'rb').read(); print([(i,b) for i,b in enumerate(d) if b<9 or (10<b<32 and b!=13) or b==127][:5])"`

## Adding a Config Passthrough Makes Every Previously-Harmless Typo in That Key a Live Value

When a loader that silently dropped some keys is fixed to forward them (e.g. coercing with `float()`), every malformed value that was previously discarded becomes real. PyYAML resolves `yes/no/on/off` to Python bools, and `float(True)` is `1.0`, so `max_accel: yes` (previously ignored, leaving a sane default) now quietly installs a limit of 1.0.

**Rule:** a passthrough and its validation must land in the SAME change. Ask: what did this key do before I honored it, and is the new behavior worse for a typo?

Checks for numeric config, all of which `float()` alone passes:
- **bool:** reject explicitly. Test `isinstance(x, bool)` BEFORE `float()`, because bool is a subclass of int.
- **non-finite:** `'nan'`/`'inf'` parse fine and then propagate through arithmetic into state instead of failing.
- **negative:** worse than useless where the value is a bound. `np.clip(v, -max_brake, max_accel)` with a negative `max_brake` has min > max; numpy returns the max, so a full-brake command comes back as full throttle.

`np.clip` does not error when min > max; it silently returns the max. Any clip whose bounds come from user input needs the bounds checked, not just the value.

Coerce and validate at the boundary, with an error naming the offending field and its location. Otherwise the type error surfaces far from its cause (e.g. an un-coerced string dying inside numpy as "ufunc 'clip' did not contain a loop with signature matching types ... dtype('<U2')").

## Re-Verify an Absence Claim in a Backlog Item Before Implementing It

Carried-forward backlog notes (feature-idea logs, TODO lists, roadmap items) frequently assert an ABSENCE: "X has no indexes", "this path is untested", "there is no validation". These are the least reliable backlog items because they usually come from a single grep of the file where the thing SHOULD be declared, not every place it COULD be declared. Examples: an ORM schema file declares no `index()`, but indexes are created in a raw DDL string elsewhere; a "zero test coverage" note when the test file already has direct tests.

Procedure:
- For "no tests": grep the test dir for the symbol; don't infer from a coverage note.
- For "no indexes/constraints/migrations": grep for raw DDL and migration files, not just the ORM schema.
- For "no validation": read the route body, not the schema.
- If the premise is false, WRITE THE CORRECTION back into the backlog file with the `file:line` that disproves it. A stale absence claim otherwise survives indefinitely and burns one session each time it is picked up.

## A Fix Documented as a Property of One File Never Reaches Its Siblings

A behavioural fix (e.g. a browser User-Agent, an "unverifiable status" bucket, a per-request AbortController) made to one HTTP probe, with its constants declared LOCAL to that file and the rule documented under a heading naming that file, leaves sibling probes with the bug, and one of them may silently delete live records.

Two mechanisms, both fixable at the time of the original fix:
1. **Hoist the constants.** Move them to the shared module the siblings already import, and make the fixed file import them too. That creates the link that makes the next divergence visible.
2. **Name the doc section after the behaviour, not the file.** "Link Checker (src/link-checker.js)" is a rule nobody applies to a sibling file. "Probing third-party sites (every HEAD/GET against a page we do not own)", with covered call sites enumerated, is.

**Corollary:** an unused-import lint error at a fix site is a signpost, not noise. "X is defined but never used" at the exact line a fix touched usually means that file stopped sharing something with its siblings. When quoting how long CI has been red, page back to the first failing run; the latest failure's date understates the outage.

## A Display Tag Is Not a Handle: Persist the User ID Whenever a Record May Need to Address That User

A persisted job record that stores the requester's *display name/tag* but no id renders fine in notifications, so nothing looks wrong. But any later path that must *act* on the user (attribute a reply, run an authorization check, look up a session, mention them) cannot do it from a tag. Code then falls through to a single-user env fallback, which is correct by accident on a single-user deployment and a silent identity swap the moment there are two users.

Two tells that a fallback is hiding a missing field rather than handling a real edge case: (1) the fallback is a single per-deployment scalar rather than derived per-record, and (2) the comment justifying it explains a *structural* absence ("the recovery path has no user id") instead of a rare one.

**Fix:** persist both, at every record-write site; pass the id through the consumer; keep the env fallback only for records written before the change. Test the resolution order explicitly: recorded id beats fallback, missing id uses fallback, neither present refuses rather than guessing an identity.

## Turning a 500 into a Successful Empty Response Makes a Previously-Unreachable Client State Reachable

A server-side guard that converts an error into a valid empty response OPENS A CODE PATH the client has never executed. The client's zero-row rendering was dead code until that moment and may be worse than the error was.

Example: a feed endpoint 500s on an empty filtered page (dereferencing `page[page.length - 1]`). The client's fetch hook never updates state on a rejected fetch, so the stale non-empty list survives and the UI looks fine. Once the guard returns `200 {items: []}`, the empty list lands and the page renders its zero-row branch, which unmounts the filter toolbar and shows onboarding copy to an established user. The error-to-success fix alone converted a 500 into a UI dead end.

When reviewing or writing a guard like this:
- Ask what the consumer does with the newly-possible value and read that branch. "It returns valid JSON now" is not the end of the change.
- Issue the request against both builds and diff the rendered output, not just the status code.
- If the client fix lives in a different PR, say so in BOTH PR descriptions and ask for them to merge together; merging only the server half ships a regression neither diff shows.

Generalises past HTTP: an exception that was silently swallowed, a null that was short-circuited, a retry that always failed: anything whose failure masked a downstream branch.

## A Narration Strip Must Cover Both Ends of the Artifact

A control that strips a model's process-narration out of a generated artifact typically anchors on where the REAL content starts ("everything from the first `#` heading onward is the document"). That only covers narration prepended BEFORE the content. A downstream pass that appends its own commentary AFTER the content (e.g. a refinement pass writing an `## Editor Notes` QA log at the bottom) is invisible to a front-anchored strip. In practice this can leak internal QA logs into a large fraction of user-facing outputs, sometimes even as a navigation anchor that makes it look intentional.

When reviewing or writing any strip/redaction/extraction control over model-generated output:
- Ask whether the control has an END condition as well as a START condition.
- Check every pass that can touch the artifact AFTER the strip's assumed boundary, not just the pass the strip was written against. A strip built for a one-pass pipeline stops being complete the moment a second pass is added downstream.
- Measure against the full corpus, not a hand-picked sample; whether the leak appears may depend on which run generated the artifact.

## A Hardening Sweep Keyed on a Construct's Presence Is Blind to the Site That Lacks It Entirely

When hardening a class of code by grepping for the construct itself (every `LIMIT`, every `ORDER BY`, every try/catch, every auth check), the sweep only finds sites that ALREADY have the construct. The strictly-worse site that lacks it entirely (e.g. a search query with no `LIMIT` and no `ORDER BY` at all, unbounded and nondeterministic) never matches and stays invisible.

**Rule:** enumerate the operations that SHOULD carry the guard (every list-returning endpoint, every user-input boundary), not the ones a grep for the guard turns up. The absence case is the one most likely to be the actual bug.

## A Clipboard Write After an Awaited Call Trips uBlock Origin's ClickFix Blocker

uBlock Origin's ClickFix protection (default badware list) hooks `navigator.clipboard.writeText()` and blocks writes outside a fresh user gesture. An `await` before the write (`await fetch(...)`, `await somePromise`) consumes the transient user activation, so the write no longer qualifies even inside the same click handler. Symptom: a share button creates the URL successfully but the auto-copy is silently blocked.

**Rule:** never auto-copy to clipboard after an `await` inside the same handler. Split into two steps:
1. One action creates the link (the async fetch), with no clipboard write.
2. A dedicated **Copy link** button calls `writeText` synchronously inside its own click handler, with the URL already in state and no preceding `await`.

Keep a visible, selectable `<a>` as a fallback. The heuristic is about gesture-binding, not content: a plain `https://` URL still trips it if the write is gesture-unbound.

## A Range-to-Single-Label Formatter Must Compare the Enclosing Unit, Not Just the Sub-Unit

A date-range formatter that collapses a "single month" window to "Mon YYYY" by testing only `periodStart.getMonth() === periodEnd.getMonth()` fires for ANY window whose endpoints share a calendar month, including a 12-month anniversary-based period (Jun 15 2025 to Jun 14 2026), which then renders as "Jun 2026": implying one month and hiding that it began the prior year.

**Fix:** require the enclosing unit to match too (`&& getFullYear() === getFullYear()`) before collapsing; otherwise fall through to the range format.

**General shape:** a "single-unit" shortcut keyed on sub-unit equality (month, day-of-week, hour) is wrong whenever the enclosing unit (year, week, day) differs across the endpoints. When reviewing any range formatter, list every period kind that actually reaches it (calendar year, monthly, quarterly, semi-annual, anniversary year) and hand-check the label for each, especially those whose length equals the sub-unit's cycle. A discriminating test constructs exactly that endpoints-share-the-sub-unit case and asserts the range form.

## A Unit-Decomposition Formatter Must Round the Total Before Splitting

A duration/quantity formatter that rounds only a sub-unit remainder can produce a malformed carry:

```ts
const hours = Math.floor(minutes / 60);
const mins  = Math.round(minutes % 60);   // rounds the remainder in isolation
return `${hours}h ${mins}m`;              // -> "1h 60m" for 119.7
```

When `minutes` is a raw computed float, any value in `[k*60+59.5, (k+1)*60)` renders `"1h 60m"` instead of `"2h 0m"`. This is reachable in ordinary use, not just constructed edge cases.

**Fix:** round the total once at the top, then derive every displayed unit from the rounded total. This also promotes a sub-hour value that rounds up to 60 (e.g. `59.7`) into `"1h 0m"` instead of `"60 min"`. Same family as the range formatter above: a special case validated against the sub-unit in isolation instead of the composed whole.

## Validate a Nullable Field at the Source Before Interpolating It into a String

A value can pass an emptiness guard as a STRINGIFIED form of the very thing the guard rejects. `` `[UPCOMING] ${el.title}` `` with `el.title === null` yields the non-empty string `"[UPCOMING] null"`, which survives a downstream guard that correctly rejects a raw null. The result is not a crash but a silent data-hygiene defect (e.g. a notification titled "[UPCOMING] null"), while a sibling path that passes the raw null IS caught by the same guard.

**Rule:** validate or skip a nullable field at the SOURCE mapper, before embedding it in a larger string. A guard placed after interpolation cannot distinguish a real value from a stringified null/undefined/number. When two paths build the same field and one wraps it in a template, both need the same source-level validation.

**Discriminating test input:** a non-string value that stringifies to non-empty (null -> "null", undefined -> "undefined", 0 -> "0"). Whitespace or empty strings are NOT discriminating.

**Self-review trigger:** any `${x}` / `String(x)` / template literal embedding an externally-sourced nullable field, followed anywhere downstream by a non-empty/truthiness check on the result.

## After Deleting a Function, Grep for Its Callers

When removing a JS function, grep for its CALLERS, not just its definition. A state with 0 definitions but N remaining calls passes `node --check` (syntax is valid) and the page still loads, but the handlers throw ReferenceError when invoked, silently breaking those code paths. This is especially likely when a concurrent session commits a partial refactor.

- Verify UI changes with a real headless browser run (e.g. Playwright capturing `pageerror` + `console.error`) before claiming done. `node --check` is necessary but not sufficient.
- On a shared checkout, build the fix from the current working tree and remove BOTH defs and calls so your commit supersedes an incomplete sibling commit.
- Deploy a single file with a targeted `rsync` (no `--delete`), `git add` only that path, then diff the deployed file against committed HEAD to catch concurrent-deploy drift.

## A Threshold That Moves with the Input Cannot Be Equality-Compared Against a Counter That Outlives It

A "notify once when a counter crosses a limit" check written with `===` breaks silently whenever the limit is not a fixed constant. Example: `consecutive_failures === alertThreshold(error)`, where the counter belongs to the whole failure STREAK but the threshold depends on the LATEST error's class (transient network fault alerts at 4, page-level fault at 2). Two transient failures then a page fault arrives with `consecutive_failures=3` against `threshold=2`; `3 === 2` and every later comparison is false, so it fails forever and never alerts. Because the item is visibly red in the UI, it reads as "known broken" rather than "alerting is broken." The reverse drift can send DUPLICATE alerts.

A sibling bug often sits nearby: thresholds built as `Math.max(1, Number(rawEnvVar || fallback))` become `NaN` on a malformed env var, and every comparison against `NaN` is false, so one config typo disables alerting for the whole install.

How to apply:
- Any counter-crosses-a-limit check where the limit can move (varies by input class, read from config/env) needs `>=`, not `===`. Track "have we already fired?" as its own persisted fact (a boolean or timestamp), never re-derived from the counter/threshold pair. Derive the paired close-out (recovery / resolve / all-clear) from that SAME persisted fact; re-evaluating the open condition reads today's inputs to answer a question about yesterday.
- Any threshold built from `Number(x)` / `parseInt` / `parseFloat` without an explicit NaN check fails open. Validate parsed config at the boundary and fall back explicitly. Check the empty-string case separately: `Number('')` is `0`, not `NaN`, so an unset value can silently become a live threshold of 0.
- Test the TRANSITION case (a streak that changes class, a config value that is malformed vs. merely absent), not just a steady run of one class; a steady-state test passes on both buggy and fixed code.
- When you find one "guard that cannot fire," grep the same module for siblings before closing the finding.

## A Stemmer/Lookup That Strips to a Bare Key Must Try the Index's Actual Citation Form First

When a lookup strips affixes before indexing into a dictionary, lexicon, or enum table, don't assume the bare stem is a valid key; check what form the index actually keys entries under. If the dictionary lists verbs only under a citation form (stem + a specific ending), the bare stem not only misses, it can COLLIDE with unrelated headwords sharing the same letters, so inflected forms are confidently resolved to the wrong word. If those wrong results feed a downstream prompt or pipeline as authoritative, the error propagates invisibly. A "miss" count alone never surfaces this.

How to apply:
- When a lookup strips an affix, generate candidates in the form the index actually uses (stem + citation/canonical ending) and try those before falling back to the bare stem.
- Measure over the entire dataset, not a sample, and count wrong-hits separately from misses. A stripped key silently matching an unrelated entry is worse than no match.
- If an affix is ambiguous across word classes, keep the existing reading as the first candidate and add the citation-form lookup as a fallback, so the fix can't regress cases that already worked.
- Diff old-vs-new resolution across the WHOLE dataset before shipping, not just the targeted cases, to catch regressions in categories the change wasn't meant to touch.
