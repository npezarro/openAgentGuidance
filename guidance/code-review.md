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

Some configuration properties look like dead code but are essential for production. Never remove these during a fix or cleanup run without verifying the deployment context:

- **NextAuth/Auth.js**: `basePath`, `redirectProxyUrl`, provider `authorization.params`, `token.params`, required for subpath deployments behind reverse proxies.
- **PM2 / process-manager config**: `env`, `max_memory_restart`, `cwd`, essential for production process management.
- **Reverse-proxy config references in code**: URL construction that includes basePaths or proxy prefixes.

**Why:** an automated crash-fix run removed `basePath` and `redirectProxyUrl` from an app's auth config because they appeared unused. This broke OAuth on the subpath deployment and required a manual restore.

## Default Review Workflow: Review-Ship-Review

Unless the user explicitly requests a single review pass, use the iterative review-ship-review pattern for all non-trivial code changes. This is the default.

### How it works

1. **Implement**: Make the requested changes, run tests, commit.
2. **Review (round 1)**: Spawn 2-3 parallel reviewer agents. Each agent audits the diff independently, categorizing findings as Critical / Important / Minor / Deferred.
3. **Fix & commit**: Address all Critical and Important findings. Commit the fixes.
4. **Review (round 2)**: Spawn fresh reviewer agents on the updated code. Reviewers must not see prior review output; they audit with fresh eyes. This catches regressions introduced by the fixes and surfaces issues the first round missed.
5. **Repeat**: If round 2 produces Critical or Important findings, fix and run another round. Stop when a review round returns clean (no Critical/Important findings). Minor and Deferred items can be noted but don't block.

### Why this is the default

Single-pass reviews miss bugs that only become visible after fixes land. In practice, fix commits introduce new issues a substantial fraction of the time (wrong variable reuse, stale state, interaction between fixes). The second review round catches these before they ship.

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
| `new Date("2026-04-15")` for display | UTC parse → local timezone off-by-one | Use `new Date(year, month, day)` for local dates |
| Shell-interpolating JSON into script strings | Special chars break syntax | Write to temp file, read in target language (see below) |
| Hardcoded timezone offset `timedelta(hours=-4)` | Breaks at DST transitions | Use `ZoneInfo('America/New_York')` or equivalent TZ library |
| `head -c N` before parsing structured output | Silent data loss: truncation drops blocks downstream code depends on | Size limit to max expected output, or extract specific fields first |
| `res.json({ error: err.message })` | Information disclosure, leaks paths, DB strings, stack traces | Return generic message, log details server-side (see below) |
| `child_process.exec(cmd + userInput)` | Command injection via string interpolation | Use `execFile(binary, [args])` with separate args array (see below) |
| `parseInt(queryParam)` without `\|\| default` fed to an ORM `skip`/`take` | `parseInt('abc')` is `NaN`; `Math.max(1, NaN)` stays `NaN`; `skip: NaN` → 500 | `Math.max(1, parseInt(String(raw ?? '1')) \|\| 1)`, the `\|\| 1` catches `NaN`. Define once in a shared helper; hand-rolling the same logic in both an API lib and SSR page components guarantees they diverge |
| `if (secret === input)` | Timing attack leaks secret length/content | Use `crypto.timingSafeEqual(Buffer.from(a), Buffer.from(b))` |
| `new URL(userInput)` without scheme check | SSRF via `file://`, `data://`, `javascript://` | Validate `url.protocol` is `http:` or `https:` before use |
| `path.join(base, userInput)` unsanitized | Path traversal via `../` sequences | Strip `..`, leading `/`, and non-alphanumeric chars from user path segments |
| `Infinity` in API responses | `JSON.stringify(Infinity)` === `"null"`, client sees `null` not a number | Use a large finite number (e.g., `999999`) for "unlimited" values sent over JSON |
| Tailwind `@apply text-blue-600` in CSS | `@apply` with certain utility classes silently drops from compiled output | Use raw CSS values (`color: #2563eb`) instead of `@apply` for critical styles |
| Component hardcodes `relative` + caller passes `absolute inset-0` via `className` | Both position classes land on the element; Tailwind v4 stylesheet emission order (not JSX/prop order) decides which wins: `.relative` can beat `.absolute`, collapsing a full-bleed overlay to 0 height | Make position a component prop (e.g. `fill ? 'absolute inset-0' : 'relative'`); never stack conflicting position utilities. A 0-height lazy `<img>` never even issues a network request, which looks like a missing asset, not a layout bug |

## Error Detail Leak Prevention

Never expose raw error messages, stack traces, internal paths, hostnames, or database connection strings in HTTP responses. This is OWASP "Improper Error Handling", and it shows up across repos in any codebase-wide audit.

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

**Common leak vectors:** `details: String(error)`, `error: err.message`, `os.hostname()` in health endpoints, file-upload middleware raw messages, CLI exit codes in spawn error handlers.

## Command Injection: exec vs execFile

Never use `child_process.exec()` with string interpolation for user-influenced values. `exec()` runs through a shell, so semicolons, backticks, and pipe characters in the input become shell commands.

```js
// ❌ Command injection: url could contain `; rm -rf /`
exec(`open "${url}"`);

// ✅ execFile bypasses the shell entirely
execFile('open', [url]);
```

**Why:** an `openInBrowser()` helper passed user-controlled URLs through `exec()`. The fix was `execFile()` plus a URL validation guard rejecting non-http(s) protocols.

## Prisma globalThis Singleton: Always Cache in Production

The standard Next.js Prisma pattern only caches the client in development:

```ts
// ❌ Bug: production creates new clients on duplicate module loads
if (process.env.NODE_ENV !== "production") globalForPrisma.prisma = prisma;
```

With driver adapters, production can also load the module multiple times, leaking connections. Always cache unconditionally:

```ts
// ✅ Prevents connection leaks in both dev and production
globalForPrisma.prisma = prisma;
```

## Shell → Script Data Passing: Use Temp Files

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

**Why:** a shell wrapper was silently producing malformed Python when text fields contained special characters. Temp files eliminate all shell escaping concerns.

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

**Why:** a market-hours check used a hardcoded EDT offset, causing zero executions during EST months. The cron schedule was also wrong because UTC hours were interpreted as local time.

## Output Truncation Causes Silent Parse Failures

When bash scripts use `head -c N` or `head -n N` to limit command output before extracting structured blocks (via `grep`, `jq`, etc.), the truncation can silently drop the block downstream code depends on. The result is an empty match, not an error, so failures are invisible.

**Example:** a `head -c 2000` truncated a structured marker block that the downstream notification step depended on. The script ran without errors but produced empty summaries for weeks.

**Fix:** Either size the limit to the maximum expected output, or extract the specific field first and truncate the extracted value. Never truncate structured output before parsing it.

## Structured Output Format Compliance

When a prompt specifies a strict output format (e.g., "ONLY valid JSON", "no markdown fences", "no explanation"), enforce it before submitting:

1. **Parse the constraint first**: read the format requirement exactly.
2. **Validate before submitting**: after writing the response, check it against the constraint.
3. **Fix, don't annotate**: if a violation is found: STOP, regenerate correctly. Never submit both the violation and a self-diagnosis of it.

**Common violations:** wrapping JSON in fences when told not to; adding explanatory text when told "no explanation"; submitting a self-diagnosis inside the violating output.

**Why:** hard format constraints are enforcement gates for downstream parsers. Identifying a violation is not fixing it, and submitting both the violation and a note about it is still a failure.

## Update CLAUDE.md When Adding Features

After implementing a new feature, route, export, or command, update the repo's CLAUDE.md before committing. Documentation lag is structural; close it at commit time. A drift-check hook that flags commits adding exports/routes/env vars without a CLAUDE.md update makes this automatic.

### Centralize query-param parsing: don't hand-roll guards in SSR pages

When an API route uses a `paginate()`/`parsePageParam()` helper to validate `?page=` (guarding against `parseInt('abc')=NaN` → ORM `skip=NaN` → 500), SSR page components that re-implement the same parsing with `Math.max(1, parseInt(String(x||'1')))` will diverge as one or the other gains new guards. Extract one shared helper used by both API routes and every SSR page; any user-controlled value flowing into an ORM's `skip`/`take`/`where` must pass through it.

## `backdrop-filter` Ancestors Confine `position:fixed` Overlays, Portal to Body

Any ancestor with a non-`none` `backdrop-filter` (e.g. glass-morphism / `backdrop-blur` cards) or `transform`/`filter` creates a CSS containing block for `position:fixed` descendants. A `fixed inset-0` modal, lightbox, or toast rendered inside such a card is silently clipped to the card's bounds, not the viewport.

**Symptom:** overlay measures card dimensions instead of viewport; backdrop is unclickable or truncated.

**Fix:** Use `ReactDOM.createPortal(overlay, document.body)` to render fixed overlays outside the containing ancestor.

**Two follow-on gotchas after portaling:**
1. Portals still bubble synthetic events through the React tree: clicks inside the overlay can still fire ancestor `onClick` handlers (e.g. a card's `navigate`). Add `e.stopPropagation()` on overlay and close-button handlers.
2. `aria-modal=true` does NOT trap keyboard focus: implement an explicit Tab/Shift+Tab focus trap and reclaim focus if `document.activeElement` leaves the dialog.

**Where to look:** Any `fixed` or `fixed inset-0` element inside a component that uses `backdrop-blur-*`, `blur-*`, `filter`, or CSS `transform`. Applies across every component built on a shared glass-morphism card design system.

## JS Truthiness Guards Don't Reject Negatives: Use `<= 0` for Non-Negative External Quantities

When validating a physical or non-negative numeric value parsed from external input (webhook payloads, API responses, user data), `!x || x === 0` does NOT reject negative values; JavaScript treats negative numbers as truthy. A negative distance, duration, speed, price, or count flows through arithmetic and produces an invalid result.

**Fix:** Use `<= 0` for any quantity that must be strictly positive:
```js
// BAD: lets negative durationSec through
if (!distanceM || !durationSec || distanceM === 0) return undefined;

// GOOD
if (!distanceM || !durationSec || distanceM <= 0 || durationSec <= 0) return undefined;
```

**Self-review trigger:** Any guard on an externally-sourced numeric that represents a measured, non-negative quantity, ask "does `!x || x === 0` let negatives through?" If yes, change to `<= 0`.

**Real case:** a pace calculation guarded only `distanceM === 0`, so `computePace(8000, -100)` returned −12.5 (invalid negative pace) and propagated into an average. A sibling adapter in the same codebase already used `speed <= 0` correctly; the two were inconsistent.

## Isolate Per-Item Failures in Batch Loops

When a loop processes a batch (DB rows, files, API records) and each iteration does an operation that can throw on bad data, an unguarded throw aborts the ENTIRE batch, not just the bad item. Two-layer defense:

1. Guard the throwing operation itself: compile a stored regex via a `safeCompile()` that returns null on `SyntaxError`; `JSON.parse` external files in try/catch; check divisor != 0 before dividing on externally-sourced deltas.
2. Wrap each loop iteration in try/catch + continue so one bad record is skipped, not fatal.

**Real case:** an auto-detection routine compiled `new RegExp(storedPattern)` at three sites with no guard, inside a function that looped mappings with no try/catch. One malformed stored pattern threw `SyntaxError` and 500'd the endpoint, killing detection for every one of the user's records. Same shape seen elsewhere: `JSON.parse` on index/metadata files without try/catch; waypoint interpolation `alpha=(t-t0)/(t1-t0)` with no guard for duplicate timestamps.

**Self-review trigger:** any `new RegExp(non-literal)`, `JSON.parse(file/network)`, or division by a data-derived value inside a loop → ask "does one bad input abort the whole batch?" Bonus: compile invariant regexes once before the loop, not per-iteration.

## Mixed `||` / `?:` Precedence Silently Drops Data

`a || b ? c : d` parses as `(a || b) ? c : d`, NOT `a || (b ? c : d)`. In an object-literal value this bites when the taken branch can yield null/undefined and a downstream schema or consumer rejects it.

**Real case:** `salary: salary || data.salaryRange ? formatSalaryRange(data.salaryRange) : undefined` evaluated `formatSalaryRange(undefined)` → null whenever a text-extracted salary existed but the structured range didn't, so schema validation (`z.string().optional()` rejects null) threw and the record was silently dropped by a catch → null → filter chain.

**Reviewer checklist:**
1. Any `x || y ? ... : ...` or `x && y ? ... : ...` in a value position is suspect, add parens or split it.
2. Enable eslint `no-mixed-operators` and `no-unneeded-ternary` (default configs do not flag this).
3. A sibling correct form nearby is a strong tell: the file using `salary || undefined` was right; the outlier was wrong.

**Fix pattern:** `salary || formatSalaryRange(range) || undefined`, coalesce to undefined so the field is never null.

## Check for Sibling Deliverables Before Revising a Doc

Before extending a document, list the sibling files in its directory and follow every internal link in it. A parallel session may have produced deeper research that CONTRADICTS the doc you are about to extend, and the doc may already carry a superseded-by pointer.

A real case: a prep guide linked a companion briefing carrying a bold "Partly superseded" banner pointing at a third doc built from primary sources. That third doc reversed a core recommendation. Extending without reading siblings would have shipped a confidently-wrong claim into a same-day deliverable.

Procedure before editing any doc deliverable:
```bash
ls <dir>                                   # siblings the doc may not link
grep -oE '\]\(\./[^)]+\)' <doc>            # every internal link
grep -inE 'supersede|correction|stale|outdated|use .* instead' <doc> <siblings>
```

Then verify each link resolves, since a superseded-by pointer to a missing file is worse than none:
```bash
for f in $(grep -oE '\]\(\./[^)]+\)' doc.md | sed 's/](\.\///; s/)$//'); do
  [ -e "$f" ] && echo "OK $f" || echo "MISSING $f"
done
```

## Substring-Matching Short Blocklist Tokens Silently Drops Legitimate Content

A keyword blocklist matched with a bare substring test (`any(w in text for w in WORDS)`, `text.includes(w)`, `LIKE '%w%'`) is wrong the moment ANY entry is short enough to sit inside an ordinary word. The short entry silently matches unrelated text, and if the match feeds a HARD FILTER the affected item is not down-ranked, it DISAPPEARS.

**Real case:** a profanity list contained `"ass"`, matched via `any(p in all_text for p in WORDS)`. Every window containing pass/class/assist/massive/password/grass/compass/classic was flagged; because the scorer returned 0 for flagged windows below a threshold, clean clips were dropped from candidate selection entirely.

Do NOT "fix" this by wrapping every entry in `\b`. That trades false positives for false NEGATIVES: `\bfuck\b` stops matching "fucking", `\bshit\b` stops matching "shitty". And prefix-anchoring (`\bass\w*`) reintroduces the original bug ("assist", "assassin"). No single uniform rule is correct, because the list mixes long unambiguous tokens with short dangerous ones.

**Correct shape:** keep substring matching as the DEFAULT (it catches inflections for free), maintain an explicit whole-word exception set for the short entries, then enumerate the compound forms in the main list:

```python
WHOLE_WORD = {"ass", "asses"}                   # \b-anchored
WORDS = [..., "asshole", "dumbass", "badass"]   # substring, unambiguous
parts = [rf'\b{re.escape(w)}\b' if w in WHOLE_WORD else re.escape(w) for w in WORDS]
PATTERN = re.compile('|'.join(parts))
```

**Reviewer checklist:**
1. For every blocklist/keyword filter, ask "is any entry ≤ 4 chars, and is it a substring of a common word?" Grep the entry against a word list.
2. Trace whether a match causes a hard drop (`return 0` / `continue` / filter out) rather than a score adjustment. Hard drops make the bug invisible, since the dropped item leaves no log line.
3. When you add `\b` anchors, ALWAYS re-test the inflections the old substring form used to catch, in BOTH directions (innocent-must-be-clean AND flagged-must-still-match). A one-directional test suite will happily certify a recall regression.
4. Verify escape/anchor interaction for non-alphabetic entries (censor markers like `***` or `[__]`): `\b` does not apply where there are no word characters at the edges.

The compound list is an OPEN CLASS and any enumeration of it is incomplete by construction. Budget for that: document it as incomplete, and do NOT claim "so nothing is lost". In the run that produced this entry, the first attempt shipped exactly that claim with a three-item allowlist; an independent verifier then diffed old-matcher vs new-matcher over 131 strings and found 22 recall losses. Because the match fed a hard gate, the losses did not merely mislabel: windows that used to be gated to 0 became SELECTABLE. Trading a false-positive bug for a false-negative bug of the same size is not a fix.

**Two process lessons, both cheap:**
- Write the recall test in the SAME commit as the anchor change, enumerating the strings the old form caught.
- For any matching change, mechanically diff old vs new over a few hundred strings drawn from BOTH classes, rather than reasoning about which cases changed. Losses invisible to inspection are obvious to a diff.

## Enumerate Every Caller Before Claiming a Configured Limit Is Unreachable

When you find that an interface cannot command some configured limit (a max, a cap, a timeout), the FIX is usually right, but the JUSTIFICATION "this parameter is dead, it can never bind" is a far stronger claim than the evidence normally supports. It holds only if every caller of the underlying model goes through the interface you happened to be looking at.

Check it: grep for the parameter name AND for the model's entry point, then read each caller. A second path often reaches the limit already, typically an internal, scripted, or replay path that passes RAW physical units while the public path passes normalized values. Scope the claim to the interface you actually verified ("unreachable through the public/normalized interface") rather than to the parameter.

**Real case:** a normalized action space scaled a symmetric `[-1,1]` action by the acceleration limit on both signs, so a separately-modeled (larger) braking limit was unreachable for the agent-controlled entity. The commit message claimed the brake limit "could never bind"; a verifier found scripted non-agent entities reach the same kinematic model through a different, unnormalized path and clamp against that limit several times per episode. The defect was real; the sweeping claim was not. A reviewer who knows about the other caller reads the overreach as evidence you did not look.

**Related numpy/array corollary:** collapsing an elementwise expression to a Python scalar (`float(x)`, `int(x)`, `.item()`) purely to make a branch read nicely moves error detection UPSTREAM of the callee that validates shape, and replaces that callee's specific message with a generic conversion `TypeError`. Prefer a shape-agnostic elementwise form (`np.where(cond, a, b)`) so malformed input still reaches the validating callee and gets its real error.

## A Control-Character Escape in an Edit Can Turn the File Binary

Writing a regex character class such as `[\x00-\x1f]` into a file via an editing tool can emit the actual control bytes rather than the escape text. The file then counts as binary: `grep` stops printing matches (and `grep -c` prints nothing) for every pattern in that file, which reads as "my edit did not land" rather than "the file is now binary."

Two things follow:
1. If grep suddenly finds nothing in a file you just edited, run `grep -a` before re-editing.
2. Write control-character classes as `\u0000-\u001f` in JS source, which is plain ASCII in the file and means the same thing.

Check with:
```bash
python3 -c "d=open('FILE','rb').read(); print([(i,b) for i,b in enumerate(d) if b<9 or (10<b<32 and b!=13) or b==127][:5])"
```

## Adding a Config Passthrough Makes Every Previously-Harmless Typo a Live Value

A loader had been silently dropping several of a physics model's tunable limits. The fix forwarded them and coerced with `float()`. An independent verifier found that this made ONE case strictly worse than the bug it fixed.

PyYAML resolves `yes`/`no`/`on`/`off` to Python bools, and `float(True)` is `1.0`. So `max_accel: yes`, previously ignored, leaving a sane `4.0` default, now quietly installed a `1.0` limit. The passthrough converted a harmless typo into a live, wrong value with no error.

**Rule:** a passthrough and its validation must land in the SAME change. The moment a key starts being honored, every malformed value that was previously discarded becomes real. Ask specifically: what did this key do before I honored it, and is the new behavior worse for a typo?

Concrete checks for numeric config, all of which `float()` alone passes:
- **bool:** reject explicitly. `isinstance(x, bool)` must be tested BEFORE `float()`, because bool is a subclass of int and `float(True) == 1.0`. In YAML this is not exotic: yes/no/on/off/true/false all resolve to bools.
- **non-finite:** `'nan'`/`'inf'` parse fine and then propagate through arithmetic into state instead of failing. A nan limit poisons every downstream value rather than raising.
- **negative:** worse than useless where the value is used as a bound. `np.clip(v, -max_brake, max_accel)` with a negative `max_brake` has min > max; numpy returns the max, so a full-brake command comes back as full throttle and the vehicle SPEEDS UP.

The last one is a general numpy trap, not a config trap: `np.clip` does not error when min > max, it silently returns the max. Any clip whose bounds come from user input needs the bounds checked, not just the value.

Coerce and validate at the boundary, with an error naming the offending field and its location. The alternative is a type error surfacing much later and far from its cause: an un-coerced string reaching the model and dying inside numpy as `ufunc 'clip' did not contain a loop with signature matching types ... dtype('<U2')`, which points nowhere near the config line that caused it.

## Re-Verify an Absence Claim in a Backlog Item Before Implementing It

Carried-forward backlog notes (feature-idea logs, TODO lists, roadmap items) frequently assert an ABSENCE: "X has no indexes", "this path is untested", "there is no validation". Absence claims are the least reliable kind of backlog item because they are usually produced by a single grep of the file where the thing SHOULD be declared, not by searching every place it COULD be declared. Re-verify before spending a session on one.

Two instances from a single run:
- "this table has no indexes beyond the PK" was false: the ORM schema file declared no `index()`, which is what the note was based on, but the DB setup module creates the single-column FK and timestamp indexes in a raw DDL string, which the test-db factory also executes. The indexes existed; only the COMPOSITE variants were missing.
- "these three exported functions have zero direct test coverage" was false in a second repo the same day: the matching test file already had 11 direct tests across all three.

**Procedure:** for "no tests", grep the test dir for the symbol; do not infer from a coverage note. For "no indexes/constraints/migrations", grep for raw DDL and migration files, not just the ORM schema. For "no validation", read the route body, not the schema. If the premise turns out to be false, WRITE THE CORRECTION back into the backlog file with the `file:line` that disproves it, so the next session does not re-derive the same dead end. A stale absence claim otherwise survives indefinitely and burns one session each time it is picked up.

## A Fix Documented as a Property of One File Never Reaches Its Siblings

A behavioural fix (browser UA, unverifiable-status bucket, per-request `AbortController`) was made to one HTTP probe, its constants declared LOCAL to that file, and the rule written into CLAUDE.md under a heading naming that file. Weeks later, four sibling probes still had the bug, one of which silently deleted live records.

Two mechanisms, both fixable at the time of the original fix:
1. **HOIST THE CONSTANTS.** Constants living in the fixed file give the siblings nothing to import and no compile-time link. Move them to the shared module the siblings already import, and make the fixed file import them too. That is what makes the next divergence visible.
2. **NAME THE DOC SECTION AFTER THE BEHAVIOUR, NOT THE FILE.** "Link Checker (src/link-checker.js)" is a rule nobody applies to `link-validate.js`. "Probing third-party sites (every HEAD/GET against a page we do not own)", with the covered call sites enumerated, is.

**Corollary worth its own grep:** an unused-import lint error at a fix site is a signpost, not lint noise. "X is defined but never used" at the exact line a fix touched usually means that file stopped sharing something with its siblings. In this case the unused import had CI red on the default branch for weeks, starting with the fix commit itself. Reading only the LATEST failing run's date understates the outage; page back to the first failure before quoting a start date.

## A Display Tag Is Not a Handle: Persist the User ID

A bot's persisted job record stored the requester's *display tag* and no id. The tag renders fine in the completion notice, so nothing looked wrong for months. But the post-restart recovery path needs an *addressable* id to attribute an inbound reply, and a tag cannot drive session lookup, an authorization check, or a mention. With no id in the record the code fell through to a single-user env fallback, so every recovered job's reply was attributed to that one user regardless of who asked: correct by accident on a single-user deployment, and a silent identity swap the moment there are two requesters.

The general shape: a field chosen because it *displays* well silently fails the first time something needs to *act* on it, and a per-deployment fallback masks the gap for exactly as long as the deployment has one user. Two tells that a fallback is hiding a missing field rather than handling a real edge case:
1. The fallback is a single scalar configured per-deployment rather than derived per-record.
2. The comment justifying it explains a *structural* absence ("the recovery path has no user id in its job record") instead of a rare one.

**Fix:** persist both. Store the id at every record-write site (every record-write site), pass it through the consumer, and keep the env fallback only for records written before the change. Cover the resolution order explicitly: recorded id beats fallback, missing id uses fallback, neither present refuses rather than guessing at an identity.

## Turning a 500 into a Successful Empty Response Opens a Previously-Unreachable Client State

A server-side guard that converts an error into a valid empty response does not just fix a bug, it OPENS A CODE PATH the client has never executed. The client's zero-row rendering was dead code up to that moment, so it has never been exercised and may be worse than the error was.

Concrete case, from a React + Express feed app. A PR guarded `page[page.length - 1].review` so a filtered empty feed page returns `200 {reviews: []}` instead of a 500:

```
GET /api/feed?userId=...&category=books  ->  500  ("Cannot read properties of undefined (reading 'review')")
same request with the guard merged       ->  200  {"reviews":[], ...}
```

The client's fetch hook never calls `setAllReviews` on a REJECTED fetch, so while the endpoint 500s the stale non-empty list survives and the UI looks fine. The moment the response succeeds with an empty array, the empty list lands and the page renders its zero-row branch, which unmounted the filter toolbar and showed "Follow some reviewers" to a user who already follows people. **The error-to-success fix alone converted a 500 into a UI dead end.**

What to do when reviewing (or writing) a guard like this:
- Ask what the consumer does with the newly-possible value, and go read that branch. "It returns valid JSON now" is not the end of the change.
- Actually issue the request against both builds and diff the rendered output, not just the status code. Status 200 is not evidence the user is better off.
- If the client fix lives in a different PR, say so in BOTH PR descriptions and ask for them to be merged together. A reviewer merging only the server half ships a regression that neither PR's diff shows.

Generalises past HTTP: an exception that was silently swallowed, a null that was short-circuited, a retry that always failed, anything whose failure masked a downstream branch.

## A Range-to-Single-Label Formatter Must Compare the Enclosing Unit

A date-range formatter that special-cases a "single month" window by collapsing it to "Mon YYYY" tested only `periodStart.getMonth() === periodEnd.getMonth()`. That fires for ANY window whose endpoints fall in the same calendar month, including a 12-month anniversary-year period (Jun 15 2025 → Jun 14 2026), which then rendered as the single wrong label "Jun 2026": it implies a one-month window and shows the end year, hiding that the period began in 2025. It shipped live on both UI cards and reminder emails.

**Fix:** require the enclosing unit to match too (`&& getFullYear() === getFullYear()`) before collapsing; otherwise fall through to the range format.

**General shape:** a "single-unit" shortcut that keys on a sub-unit equality (month, day-of-week, hour) is wrong whenever the enclosing unit (year, week, day) differs across the range's endpoints, because a full-period window can share the sub-unit at both ends. When reviewing or writing any range formatter, list the period kinds that actually reach it (calendar-year, monthly, quarterly, semi-annual, anniversary-year) and hand-check the label for each, especially the ones whose length equals the sub-unit's cycle (a 12-month period starting mid-month lands start and end in the same month). A discriminating test constructs exactly that endpoints-share-the-sub-unit case and asserts the range form, not the collapsed form.
