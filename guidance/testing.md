<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards and the failure modes that make a green suite lie.

## When to Test

| Situation | Action |
|-----------|--------|
| Bug fix | Write a regression test that fails without the fix, passes with it |
| New function with logic | Unit test covering happy path + edge cases |
| API endpoint | Integration test covering request/response cycle |
| Refactor | Ensure existing tests still pass; add tests if coverage was lacking |
| Config/copy-only change | No new tests needed |
| Repo has no test infra | Don't add one unless asked |

## Test File Placement

- Match the repo's existing pattern. Common conventions:
  - `__tests__/ComponentName.test.js` (React/Jest)
  - `tests/test_module.py` (Python/pytest)
  - `*.spec.ts` next to the source file (Vitest, Mocha)
- If no convention exists, co-locate tests next to source files.

## Test Structure

```javascript
describe('functionName', () => {
  it('returns expected result for valid input', () => {
    // Arrange
    const input = 'valid';

    // Act
    const result = functionName(input);

    // Assert
    expect(result).toBe('expected');
  });

  it('throws on invalid input', () => {
    expect(() => functionName(null)).toThrow();
  });
});
```

## What to Test

- **Happy path:** Does the function work with typical input?
- **Edge cases:** Empty strings, zero, null/undefined, large numbers, special characters.
- **Error paths:** Does it fail gracefully with bad input?
- **Boundaries:** Off-by-one errors, array boundaries, date rollovers.

## Fallback Chains Hide Dead Rungs (test each branch in isolation)

A fallback/waterfall (try A, else B, else C) is the highest-risk structure for a **silent miss**: if an early rung dies, a later rung catches everything and the end-to-end result still looks correct. The dead layer is invisible until the day the layer below it also fails.

- **Test each rung on its own**, with an input it MUST handle, not just the end-to-end happy path. If rung 1 is supposed to handle server-rendered pages, prove it does with the *later rungs disabled* (a `--max-rung`/`--from-rung`-style flag, a forced-branch fixture, dependency stubs). End-to-end green is necessary but not sufficient.
- **Ship a canary** for any fallback you rely on: assert the *winning rung*, not just that content came back. If rung 1 stops winning on a case it owns, fail loudly.
- **Run the real code path, never a reimplementation of it.** A check that reads a file with `open(file)` can pass while the real script, reading the same data from stdin, is dead (for example because `python3 - <<HEREDOC` shadowed stdin). Drive the shipped script or function itself.

## What NOT to Test

- Implementation details (private methods, internal state).
- Third-party library behavior (trust that `lodash.get` works).
- Trivial getters/setters with no logic.
- UI layout pixel-by-pixel (use snapshot tests sparingly).

## Mocking Guidelines

- **Mock at boundaries:** HTTP clients, databases, file system, timers, `Date.now()`.
- **Don't mock the unit under test.** If you need to, the function is doing too much; refactor it.
- **Prefer dependency injection** over module-level mocking where possible.
- **Reset mocks between tests:** `beforeEach(() => jest.clearAllMocks())` or equivalent.
- **Use typed mock helpers instead of `as any`:** factory functions returning complete typed objects catch shape mismatches at compile time and eliminate lint warnings.

```typescript
// WRONG: hides type errors, triggers no-explicit-any lint warnings
const token = { access_token: "test" } as any;

// RIGHT: typed factory returns a complete object
function fakeOAuthToken(overrides?: Partial<OAuthToken>): OAuthToken {
  return { access_token: "test", refresh_token: "r", expires_at: Date.now() + 3600000, ...overrides };
}
const token = fakeOAuthToken();
```

## Testing Shell Scripts: Don't Stub a Binary on PATH, Stand Up the Real Sink

Shell scripts that alert (webhook, email, HTTP callback) need their alert path tested, and the instinct is to drop a fake `curl` earlier on `PATH`. **This silently measures nothing** whenever the script hardens its own `PATH`, as cron-safe scripts often do:

```bash
export PATH="$(dirname "$(command -v node)"):$(dirname "$CLAUDE_BIN"):$PATH"
```

That puts `/usr/bin` ahead of your stub, so the system `curl` wins and the stub is never called. The test passes for the wrong reason: zero alerts recorded, read as "suppression works."

**Instead, bind a real listener and point the script's own webhook variable at it.** This exercises the actual `curl` invocation, JSON payload, and HTTP semantics:

```bash
python3 - "$SINK" > "$T/port" 2>/dev/null <<'PY' &
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer
sink = sys.argv[1]
class H(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        open(sink, 'a').write(self.rfile.read(n).decode('utf-8', 'replace').replace('\n', ' ') + '\n')
        self.send_response(204); self.end_headers()
    def log_message(self, *a): pass
srv = HTTPServer(('127.0.0.1', 0), H)   # port 0 = never collides with a real service
print(srv.server_port, flush=True); srv.serve_forever()
PY
export WEBHOOK_VAR="http://127.0.0.1:$(cat "$T/port")/hook"
```

Companion rules for the same class of script:

- **Always add an `env -i PATH=/usr/bin:/bin HOME=$HOME` case.** Cron's PATH omits `/usr/local/bin`, which presents as exit 127 *before* any logic runs. A suite that only runs under your interactive shell cannot see it.
- **Test the state-file upgrade path.** Changing a marker format (bare `touch` → structured) must be exercised against the OLD format, or the first deploy inherits broken behaviour during a live incident.
- **`curl ... || true` is untestable by construction and unsafe in production**: a revoked webhook fails identically to success. Capture the status and assert on it: `code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 ...)`.

## Making Node.js Servers Testable

Server-side repos often need minor changes to support isolated testing.

### Auto-Start Guard

Prevent `app.listen()` from firing when the file is imported by tests:

```javascript
// ESM: import.meta.url guard
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  app.listen(PORT, () => console.log(`Listening on ${PORT}`));
}

// CJS: require.main guard
if (require.main === module) {
  app.listen(PORT);
}
```

Export `app` so tests can import it directly:
```javascript
export { app };
```

### Test Isolation via Environment Variables

Use env vars like `DATA_DIR` to point tests at a temp directory instead of production data:

```javascript
const DATA_DIR = process.env.DATA_DIR || path.join(__dirname, 'data');
```

Tests set `DATA_DIR` to a `tmp` directory and clean up after each run.

### Factory Pattern for Dependency Injection

For servers with external dependencies (GitHub API, webhooks), export a factory:

```javascript
export function createServer(deps = defaultDeps) {
  const app = express();
  // Use deps.octokit, deps.config, etc.
  return app;
}
```

Tests inject mocked dependencies without module-level patching. Guard auto-start behind the `import.meta.url` check so the factory can be imported without side effects.

## Test Fixture Schema Drift

When tests embed their own DDL (CREATE TABLE) or data shapes, they silently drift from the real schema. Tests pass against the stale fixture while production uses the real one.

**Signs:** Tests pass locally but the feature is broken in prod, or a batch of tests fail simultaneously after a migration adds columns.

**Prevention:**
- Import schema definitions from the application code rather than duplicating them in tests.
- If tests must define their own schema (e.g., SQLite in-memory), derive it from the same migration files the application uses.
- When adding a column or field to the real schema, search test files for the table name and update inline definitions.

## Running Tests

```bash
# JavaScript/TypeScript
npm test                    # run full suite
npx jest --watch            # watch mode during development
npx jest path/to/test.js    # run a single test file
npx jest --coverage         # check coverage

# Python
pytest                      # run full suite
pytest tests/test_file.py   # single file
pytest -x                   # stop on first failure
pytest --cov=src            # check coverage
```

## CI Test Workflow

Use a standard `.github/workflows/test.yml` that runs tests on every push and PR to the default branch.

**Standard template (Node.js):**
```yaml
name: CI
on:
  push:
    branches: [main]        # or [master]: match the repo's default branch
  pull_request:
    branches: [main]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          cache: npm
      - run: npm ci
      - run: npm test
```

**Python repos** use a similar pattern with `setup-python@v5`, `pip install`, and `pytest`.

**Key rules:**
- Pin Node.js to the current LTS (22 at time of writing; Node 20 reached EOL on April 30, 2026). Don't use `node-version: 'lts/*'`, it can shift unexpectedly.
- Branch trigger must match the repo's actual default branch (`main` vs `master`).
- When adding first tests to a repo, also add the CI workflow so tests run on every PR.

## CI Workflow Gotchas

### Test Glob Quoting on GitHub Actions

Single-quoted globs like `'test/**/*.test.js'` do NOT expand on GitHub Actions because `globstar` is off by default. The literal string is passed to the runner, which may not expand `**` the same way, and tests are silently skipped.

```yaml
# BAD: glob not expanded, tests silently skipped
run: npx jest 'test/**/*.test.js'

# GOOD: flat glob, works everywhere
run: npx jest test/*.test.js

# GOOD: let jest find tests via config
run: npx jest
```

### package-lock.json Must Be Committed for CI

`cache: npm` with `npm ci` requires `package-lock.json` in the repo. If it's gitignored, the cache step fails and `npm ci` refuses to run. Remove it from `.gitignore` and commit it; this also makes installs deterministic.

### Vitest Fails When Any Imported Module Throws at Import Time

If a module (e.g., `db.ts`, `prisma.ts`) runs `new PrismaClient()` or reads a required env var **at module load time**, any test file that imports it crashes the whole runner before any test executes, even if tests never open a connection. CI shows a cryptic initialization error (e.g. `PrismaClientInitializationError` before the first `describe()`) that reads as a build/config problem, and can stay red for weeks with no obvious cause.

**Fix:** set a dummy value in `vitest.config.ts`:
```typescript
export default defineConfig({
  test: {
    env: {
      // Dummy value: db.ts throws at import time if unset.
      // Tests only exercise pure functions and never open a connection.
      DATABASE_URL: "postgresql://test:test@localhost:5432/test",
    },
  },
});
```

Or in a `setupFiles` entry:
```typescript
process.env.DATABASE_URL = process.env.DATABASE_URL ?? 'file:./test.db';
```

## Don't Grep Test Output to Detect Pass/Fail

Parsing runner output with `grep` to determine pass/fail is fragile. A passing test *named* "handles errors", or a summary line "0 failed", matches the wrong pattern and flips your result.

```bash
# WRONG: a passing test named "handles errors" matches and RESULT=FAIL
if npm test 2>&1 | grep -qi "error\|fail"; then
  RESULT="FAIL"
fi

# RIGHT: use the exit code; output is only for human-readable detail
TEST_EXIT=0
TEST_OUTPUT=$(npm test 2>&1) || TEST_EXIT=$?
if [ "$TEST_EXIT" -ne 0 ]; then
  RESULT="FAIL"
fi
```

**Exception:** grepping output for metadata (e.g., `grep -oP '\d+ passed'` for a log line) is fine; never use it as the pass/fail gate.

Related: piping a build to `tail` (`npm run build | tail -2`) takes the exit code from `tail`, so a `&&` chain continues past a failure. Check exit codes unmasked.

## Coverage

- Don't chase 100% coverage. Aim for meaningful coverage of business logic.
- Uncovered code is fine if it's glue code, config, or error handling that's hard to trigger in tests.
- If the repo has a coverage threshold configured, respect it.

## Testing Pyramid Strategy

When a project has recurring quality issues (code ships that doesn't actually work), invest in this order. Each layer reduces the incidents the next needs to catch.

| Priority | Layer | What It Catches | Cost |
|----------|-------|-----------------|------|
| 1 | Failure audit | Tells you where to invest | Hours |
| 2 | Contract tests | Mock drift, API shape mismatches | Low |
| 3 | Integration tests (real deps) | Backend logic, migrations, auth bugs | Medium |
| 4 | Post-deploy smoke tests | Config drift, bad deploys | Low |
| 5 | Authenticated browser tests | Auth flows, full-stack integration | High |

**Start at the top.** Do not skip to browser tests without completing the lower layers first.

### Layer 1: Failure Audit

Before writing new tests, classify the last 5-10 production incidents. For each, record:
- What broke (auth, rendering, data, config, race condition)
- Whether a test existed for that path
- If a test existed and passed, *why* it passed when prod was broken (mock drift, shallow assertion, wrong environment config)
- When it was caught (pre-deploy, post-deploy, user report)

The output tells you which layer to invest in.

### Layer 2: Contract Tests

If incidents trace back to "test passed with mocks but prod behaved differently," your mocks encode stale assumptions:
- Schema-check against real API responses recorded from staging.
- Snapshot the actual response shape from a real endpoint, then validate mocks match it.
- Update snapshots as part of the deploy pipeline.

Use at any service boundary where you currently mock: external APIs, database queries, auth providers.

### Layer 3: Integration Tests with Real Dependencies

For backend logic failures (bad queries, broken migrations, auth provider interactions):
- Hit real databases, real auth providers, real caches.
- Each test owns its fixtures; control state setup explicitly.
- **Do not mock the database.** Mock/prod divergence is the #1 source of false-green tests.

### Layer 4: Post-Deploy Smoke Tests

Fast (under 30 seconds), non-browser checks against the deployed environment:
- Authenticate with a test account.
- Hit the 3-5 most critical endpoints.
- Assert HTTP 200 **and** basic response shape.
- Run automatically after every staging deploy.

### Layer 5: Authenticated Browser Tests (Use Sparingly)

Only if the failure audit shows incidents that ONLY a real browser would have caught (broken auth flows, CORS/CSP issues, token refresh failures).

- Maximum 5-8 scenarios. Start by reproducing a specific past incident.
- Dedicated test account with stable credentials, managed via secrets.
- Staging only, never production.
- Each test owns its state: setup creates what it needs, teardown removes it.
- Assert on intercepted API responses, not just DOM elements.
- Capture screenshots, network logs, and console errors on failure.

**Flakiness policy:** quarantine on the second consecutive flake into a non-blocking suite until fixed. A flaky test the team ignores is worse than no test.

**Tag every test** by the failure mode it guards (`@auth-flow`, `@regression-INCIDENT-42`).

## What NOT to Build

- Browser tests against production (test data leaks into real systems).
- More than 8-10 browser scenarios (you're compensating for missing integration tests; push coverage down the pyramid).
- Tests without a corresponding past incident (speculative tests have low ROI and high maintenance cost).

## Mock Fidelity

Mocks that diverge from production are worse than no mocks: they give false confidence.

- **Record real responses** from staging/production as fixtures. Re-record periodically.
- **Validate mock shape** against the real API schema on every CI run.
- **Never hand-write mock data** for external APIs; use recorded fixtures.
- **If a mock test passes but the feature is broken in prod**, the mock is the bug. Fix the mock.

### Test-Client Normalization Hides Untestable Guards

A hand-rolled test client that builds requests by hand (a `{ method, url, query, body }` object passed straight into a route handler) can normalize input into a shape the real framework parser never produces. Example: a helper that flattens repeated query params (`?page=1&page=2`) to a last-wins string, while Express's real parser produces an array. Every `typeof req.query.x === "string" ? ... : <default>` guard then looks tested, but its non-string branch is unreachable from any test using that client. Coverage reports won't flag it.

**How to apply:** when a route defends against a shape its framework can actually produce (array-valued query params from a duplicate key, `__proto__`-style keys, duplicate headers, arrays where a scalar is expected), check whether your harness can produce that shape at all. Drive that class of guard over a real `app.listen()` + `fetch` (or supertest). A real-listener test is also what reveals an *incomplete* fix (e.g. `?category=a&category=b` still returning the unfiltered feed) that "passed" against the hand-rolled client.

### A Hand-Built Fixture Never Tests the Loader

When a config file gains a field, add at least one test that goes through the **real loader**: write a temp config, load it, assert the consumer sees the value. A validator that destructures a new field, validates it, then returns an object *without* it leaves every consumer seeing `undefined`, while unit tests that hand the consumer a literal object stay green. The type checker won't catch it either: the object is still valid, just missing an optional property. At least one test must cross the parse/validate/transform boundary.

### Test the Whole Field Set a Boundary Forwards

A loader that builds a model from two of five config fields silently discards the rest, and per-field tests (`test_custom_wheelbase`, `test_custom_max_speed`) only ever cover the fields already implemented. The missing test is exactly the one for the missing field.

- When a boundary (loader, serializer, DTO mapper, API adapter, ORM row builder) forwards a subset of a type's fields, assert the COMPLETE field set round-trips (`parsed == constructed`).
- Don't repeat the model's defaults as loader fallbacks; that is a second source of truth. Forward only keys present and let the type supply defaults:
  ```python
  overrides = {k: float(d[k]) for k in FIELDS if k in d}
  model = VehicleModel(**overrides)
  ```
  This also makes "omitted key defers to the model" testable (`parsed_with_no_overrides == Model()`).
- Coerce at the boundary. `float()` at parse time, raising an error naming the entity and field, beats a baffling type error deep inside downstream numeric code.

## Cross-Layer Invariant Tests

The highest-value tests are often about **invariants between layers** that silently break when one layer changes without the other.

### What Are Invariants?

A property that must hold for the system to work, even though no single function enforces it:

| Invariant | Producer | Consumer | What Breaks |
|-----------|----------|----------|-------------|
| Stores must have lat/lng | Pipeline creates stores | Trip planner filters by `storesWithCoords` | Stores created without coords → planner returns 0 plans |
| Price records must include unit | Pipeline ingests prices | UI formats as `$2.99/lb` | Missing unit → UI shows `$2.99` with no context |
| List items serialize to JSON | Frontend `setItems()` | Backend PATCH `/api/lists/:id` | Shape mismatch → silent data loss on save |
| API response includes store name | Backend joins tables | Frontend display | Missing join → price shown with no attribution |

### When to Write Them

1. **You just fixed a cross-layer bug.** The fix goes in the code; the invariant test guards the *class* of bug.
2. **One system produces data another consumes.** Pipeline → database → API → UI; each boundary is an invariant.
3. **A filter or query depends on data shape.** If `WHERE lat IS NOT NULL` is used anywhere, test that the producer always sets lat.
4. **Display formatting depends on response shape.** If the UI expects `storeName`, test that the API returns it.

### How to Write Them

Invariant tests don't need a database. Test the **contract**:

```typescript
describe("Pipeline → Trip Planner invariant", () => {
  it("pipeline-created stores must have coordinates", () => {
    const store = createPipelineStore("kroger", "94102");
    const visible = [store].filter(s => s.lat != null && s.lng != null);
    expect(visible).toHaveLength(1);
  });
});

describe("API → UI invariant", () => {
  it("price history response includes storeName and unit", () => {
    const response = buildPriceHistoryResponse(priceRecord);
    expect(response).toHaveProperty("storeName");
    expect(response).toHaveProperty("unit");
  });
});
```

Name them after the boundary they guard: `pipeline-stores.test.ts`, `price-display.test.ts`, `trip-planner.test.ts`.

### Common Patterns Across Projects

1. **Geocoding completeness:** entities filtered by location must have coordinates populated at creation time.
2. **API response shape:** if the frontend destructures `response.storeName`, the backend must include it in the SELECT/JOIN.
3. **Serialization roundtrip:** data written to localStorage/database must survive `JSON.parse(JSON.stringify(data))` without losing fields.
4. **Auth-gated endpoints:** every endpoint behind `requireAuth` returns 401 for unauthenticated requests, not 500.
5. **Unit/format consistency:** if prices are stored as strings (`"2.99"`) but displayed as numbers, test the parseFloat boundary.
6. **LocalStorage hydration schema tolerance:** `JSON.parse` succeeds on structurally invalid values (older schema, manual edits, truncated writes, `null`). A try/catch only guards parse *throws*. Always normalize after parse (required fields exist with correct types, else defaults), and test with partial/stale schemas from prior app versions.

### Re-Deriving a Metric Breaks Every Site That Differences It

Changing how a metric is computed (e.g. switching to a moving average that excludes a sentinel value) can be correct in isolation and still break every consumer that *subtracts, compares, ranks, or thresholds* it against a value computed the old way, including a second call to the same function with different arguments (`evaluate(a, streams)` vs `evaluate(b, undefined)`). The delta then reports a difference in methodology, not between the two items. A same-file unit test cannot catch it because both sides are individually correct. Before changing a metric's derivation, grep every consumer: deltas, sparklines, "vs last week", leaderboards, regression baselines.

Related: don't quote a range from a convenience sample. A small sample can understate the max by several times; sample the population before quoting its bounds.

### A PHP-Only Default Is Invisible to JS-Rendered Markup

When a server-side accessor applies a default but the page also renders the same value client-side from a JSON payload built from the raw stored value, the JS-rendered copy comes out blank. `curl` passes (markup present); only a browser running the script sees it. Put the fallback upstream of both readers (where the payload is assembled), and test the reader curl cannot see. Same applies to any fix applied only to the server template when JS rebuilds the markup on refresh.

### Stamp a Per-Request Marker in the Shared Builder

When several paths (route, retry route, startup recovery, cron) produce the same outbound request, a new per-request field (routing marker, tenant id, model selector, trace header) belongs inside the ONE builder they all call, not at each call site. Otherwise three paths honour it and the fourth silently doesn't, and nothing distinguishes that from working (still HTTP 200, still plausible output).

1. Count call sites before choosing where to put the field. Three or more: find the choke point.
2. If the choke point can derive the value itself (from the row it already has), prefer that over a new parameter, which just moves the omission up a level.
3. A mirror of that function in another runtime needs the same change in the same commit, with a note on both.
4. The choke point now carries the guarantee, so give it its own tests, including the degraded case (a missing column must fall back, not throw).
5. If the receiver detects request type by a prefix, and the marker must sit adjacent to it, assert adjacency, not just presence.

### A Stale-Tolerant Cached Health Probe Is Wrong for an Explicit User Choice

A cached readiness probe that returns the last known state and refreshes in the background is fine for an automatic sampler or fallback: a miss lands silently in the other arm. Once a USER can select that dependency, the first request after a cold start or idle gap answers from a stale "unhealthy" value and tells the user their choice is unavailable while it is up. Staging rarely reproduces it because something has always warmed the cache.

1. When adding a user-facing selector in front of an internal fallback, re-audit every readiness check on that path.
2. The "must stay non-blocking" argument usually doesn't carry over: an explicit choice runs the probe only for callers who opted in. A few seconds of probing beats a wrong answer.
3. Keep both variants; the sampler still wants the cheap cached read.
4. Any downgrade on the explicit path must be DISCLOSED in the output.
5. Test that the dependency was reached on the FIRST request. A warm-cache test passes against the broken code.

## Zod Validation in API Routes

Every API route that parses input with Zod **must** catch `ZodError` and return 400. Otherwise validation failures surface as 500s and hide the real problem from the client.

```typescript
import { ZodError } from "zod";

try {
  const data = mySchema.parse(await req.json());
  // ... handle request
} catch (error) {
  if (error instanceof ZodError) {
    return NextResponse.json(
      { error: "Validation failed", details: error.errors },
      { status: 400 }
    );
  }
  throw error; // re-throw non-validation errors
}
```

When auditing a codebase, check that *every* route using `.parse()` has this handling; it's easy to miss one while all others are correct.

## Accessibility: Focus Management After Modal Close

When a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it. Leaving focus on `document.body` violates WCAG 2.4.3 (Focus Order).

```tsx
const triggerRef = useRef<HTMLElement | null>(null);

const handleOpen = (e: React.MouseEvent<HTMLElement>) => {
  triggerRef.current = e.currentTarget;
  setOpen(true);
};

// in useEffect cleanup or close handler:
triggerRef.current?.focus();
```

**Write 3 tests, one per close path**, each asserting `document.activeElement === trigger`:

```tsx
it('returns focus to trigger on Escape', async () => {
  const user = userEvent.setup();
  render(<MyModal />);
  const trigger = screen.getByRole('button', { name: /open/i });
  await user.click(trigger);
  await user.keyboard('{Escape}');
  expect(document.activeElement).toBe(trigger);
});
```

Visual tests never catch this; only explicit close-path tests do.

## Boundary Validation: Non-Negative Quantities from External Sources

`!x` and `x === 0` guards do NOT reject negatives; JS treats negatives as truthy.

```javascript
// WRONG: passes -100 through because !(-100) is false
function computePace(distanceM, durationSec) {
  if (!distanceM || !durationSec || distanceM === 0) return undefined;
  return durationSec / (distanceM / 1000);  // returns -12.5 for duration=-100
}

// RIGHT: rejects non-positive values for physical quantities
function computePace(distanceM, durationSec) {
  if (!distanceM || !durationSec || distanceM <= 0 || durationSec <= 0) return undefined;
  return durationSec / (distanceM / 1000);
}
```

**Self-review trigger:** any numeric guard on a measured quantity (distance, duration, speed, count, price) from an external source: use `<= 0`. Check sibling adapters for the same domain use the same guard form; an inconsistency between two is the tell.

**Test:** `expect(fn(1000, -100)).toBeUndefined()` alongside the zero case.

## Batch Loop Resilience: Isolate Per-Item Failures

When a loop processes a batch and an iteration can throw on bad data, an unguarded throw aborts the ENTIRE batch.

1. **Guard the throwing operation:** compile `new RegExp(external_pattern)` in try/catch returning null; wrap `JSON.parse(external_file)`; check for zero before dividing by a data-derived value.
2. **Wrap each iteration** in try/catch + continue.

```javascript
function safeCompile(pattern) {
  try { return new RegExp(pattern); } catch { return null; }
}

function detectAll(transactions, templates) {
  for (const tmpl of templates) {
    try {
      const re = safeCompile(tmpl.merchantPattern);
      if (!re) continue;
      // ...
    } catch (err) {
      console.warn(`Skipping template ${tmpl.id}:`, err.message);
      continue;
    }
  }
}
```

**Self-review trigger:** any `new RegExp(non-literal)`, `JSON.parse(file/network)`, or data-derived divisor inside a loop: "does one bad input abort the whole batch?" Compile invariant regexes once, before the loop.

## Extracting JSON from an LLM Response: First Balanced Array, Not Greedy

`result.match(/\[[\s\S]*\]/)` spans from the first `[` to the LAST `]` anywhere in the text. If the model wraps its answer in a fence or appends a note containing a bracket, the match overshoots, `JSON.parse` throws, and a catch that returns `[]` silently drops the whole batch even though a valid array was present.

**Fix:** try `JSON.parse` on the trimmed, fence-stripped text first; then fall back to a string-aware first-balanced-array scan (walk from the first `[`, track depth, skip characters inside `"..."` honoring `\"` escapes, stop when depth returns to 0). Identical on clean input, recovers from trailing noise.

**Self-review trigger:** any first-open-to-last-close regex (`/\[[\s\S]*\]/`, `/\{[\s\S]*\}/`) over free-form LLM/CLI output. Test fenced, prose-wrapped, and trailing-bracket inputs.

## Statistics: Test Both Sample Parities

`sorted[Math.floor(len / 2)]` is a correct median only for odd lengths; on even lengths it returns the upper-middle element, so the result is always >= the true median, never below. Suites miss this two ways: every test uses an odd-length sample (where buggy and correct agree), and even-length tests assert only that a "median" field *rendered*, not its value.

One-sided error is worse than noisy error: if the statistic is a yardstick for scoring or thresholds, the bias pushes every downstream decision the same way.

**Checklist for any summary statistic (median, percentile, quartile, trimmed mean):**
- Test odd, even, single, empty, and unsorted input.
- Assert the computed VALUE, not that the field exists.
- Confirm numeric sort (`(a, b) => a - b`); default `Array#sort` is lexicographic (`[90, 1000, 200]` → `[1000, 200, 90]`).
- Check whether the helper mutates its input (in-place `.sort()` on a caller's array).
- If the statistic feeds a threshold, add a DECISION-level test (does the item cross the gate?).

## Ordering Tests Must Assert the Exact Sequence

When fixing a non-total ORDER BY (ties with no unique tiebreaker), the test "page 1 ∪ page 2 covers all N rows once" PASSES on the unfixed code: under one stable query plan pages are complete. Rows drop or duplicate only when the plan changes between requests (new index, ANALYZE, VACUUM, version bump); a table scan and an index can return a tie group in opposite orders.

1. Assert the EXACT returned sequence against the intended total order, with fixture ids chosen so the pre-fix order provably differs (insert ascending, assert descending).
2. Or model the plan change: fetch page 1, `CREATE INDEX ...`, fetch page 2, assert no drops or duplicates.

An audit for "ORDER BY needing a tiebreaker" can't see the worse case: a truncated list (`LIMIT`, or `.slice()` over an unordered select) with NO ORDER BY. Grep for `LIMIT`/`.limit(` and slices over query results too.

## Capped Lists: Filters, Counts, Search, and Sorts

A list rendered with a cap of N is a rendering decision. A filter, count badge, or search wired to it treats N as a database limit. "No results" then reads as a statement about the database, not the page, and items past the cap can be misreported as removed.

1. Before shipping any control that outputs a COUNT or a "nothing found" verdict, run it against real production-scale data and print "N in full set vs M in rendered list" per query. Small fixtures pass trivially.
2. **Pick a fix by size:** PIN qualifying rows into the capped query when the set is known server-side and small; serve an UNCAPPED endpoint lazily when the query is client-side and arbitrary (same ORDER BY so clearing search restores an exact prefix).
3. Re-check caps whose data has grown since the constant was chosen.
4. A cap over a concatenation of two different kinds of list drops whichever is appended last. Cap each kind separately.

**Sorting has its own traps**, both of which look like working software because a sort shows no number to check:
- **The cap:** "best match" over the most-recent 100 rows is not "best match." Send the whole set and paginate the RENDER; keep the cap only as a runaway guard.
- **The clamp:** a score that clamps to a ceiling ties every strong item, and order among them falls back to the secondary key. Size weights so a perfect item lands EXACTLY on the ceiling (assert it), and on real data print the score histogram, not just min/max (e.g. "21 distinct scores over 328 rows, 6 at the ceiling").
- **Replay beats fixtures for a scorer:** replay against a COPY of production data (opening the DB may run migrations). Free-text comparisons (locations, titles) fail in ways fixtures never exercise.
- **Two score sources must stay distinguishable:** a missing score must not become 0 (it buries the whole pre-existing corpus), and a heuristic estimate must be capped BELOW the real model's range and marked in the UI. Don't store estimates tied to a profile that may change.

## Hidden Filter Buttons Must Not Hide the Work

When one taxonomy list feeds both a filter bar and something structural (section headings, a proportion strip, a grouping key), hiding a term by filtering that list silently removes its items from the page. Emit two lists: the visible one for the bar, and the full one for everything structural. Assert per consumer, in a browser, that hiding a term changes the bar and nothing else (same item count, sections, segments) and is reversible.

## Porting a Fix to a Sibling App

A module proven on one app's data is NOT proven for a sibling built from the same template. "Same defect" does not mean "same data shape." Before sharing it, run it over the sibling's OWN stored production rows and read the diff by hand.

- **Audit precision, not just recall.** Recall is "did it fire?"; precision means reading what got REMOVED. The hit rate can go up while output gets worse (e.g. a preamble stripper that is safe where preambles are pure narration buries real content where narration and content share a paragraph).
- **Change the shared module and re-verify the original to parity** rather than forking per app: render the original's full production corpus on old and new builds and diff for byte-identical output.
- **A guard that hides rather than deletes still needs this scrutiny.** "It just moves to a collapsed section" is why the damage is invisible: page renders, tests pass, nothing logs.

## A Response That Narrates the Work Is Not the Work

An LLM call can end on a turn that only reports on itself ("All research is complete, the full guide was delivered above") and get stored as a completed answer. Guards keyed to error strings or emptiness miss it: it is well-formed, confident, normal-length prose that is semantically absent.

1. Add a guard on the SHAPE of a valid answer, not only on known failure shapes.
2. A narration stripper is not a rejecter; peeling narration off such output leaves nothing.
3. A false positive deletes a real answer, so require several independent conditions: short residual after stripping, a match on a process-narration/deferral wording family, AND no substantive marker (link, price, list, heading, table).
4. Measure before trusting it: sweep the full stored corpus and check what gets flagged. A corpus sweep also finds bugs you weren't looking for (e.g. a stripper wired to the main response but never to follow-ups).

Related: a committed prompt change that requires a container rebuild is inert until the rebuild runs. Grep the live artifact for the new strings; verify the ARTIFACT, not the commit.

## Generated Deliverables: Assert Coverage and Uniqueness Before Writing

When a deliverable must cover every entry from source lists, hand-enumeration silently drops one, and nothing errors.

1. **Read the live artifact, not a cached intermediate.** A file on disk reflects what it held when last written.
2. **Assert before writing**, at the generation stage.
3. **Assert coverage and uniqueness independently**; they fail separately.
4. **Count the live source at run time**, not against a hard-coded expected total that drifts.

## Verdicts Scraped from stdout Can Be Confidently Wrong

A loop that grades each iteration by grepping a tool's output for a format the tool doesn't actually emit (e.g. a JSON `id` when it prints a bare id line) reports all failures on all successes. The natural recovery, re-running, creates duplicates.

**Rule:** before reporting failure or retrying, confirm against system state (list the folder, query the API, count rows). Read the tool's actual output contract first. A retry is only safe if the operation is idempotent; record creation generally isn't.

## Live Controls Rot: Triage Rot vs Regression with an Independent Source

A validation suite pins a known-LIVE control (a posting, a product, a URL) to catch a detector that has started answering "dead" everywhere. The control itself expires, and its failure is byte-identical to a real regression. The cheap guess ("control rotted") hides a genuine regression.

- Discriminate with a SECOND source the detector doesn't consult (e.g. the detector reads a JSON API; triage reads the public HTML, where a removed item redirects or renders a bare shell of very different size). Both say dead: ROTTED, repin. Second source still serves it: REGRESSION, don't touch the controls.
- Validate the triage on its own live/dead/garbage controls, and make failure messages name the cause and propose a replacement.
- Audit controls that PASS. A control built to prove "wrong input yields a confident wrong verdict" can go green because its target disappeared, and nothing prompts anyone to look.

## Mutation-Testing Traps for Data-Store Write Paths

1. **`indexOf` returns -1 for a missing needle, and -1 < every real index.** `writeAt < abortAt` passes for code that performs NO write. Assert existence first: `expect(log.indexOf('write')).toBeGreaterThanOrEqual(0)`.
2. **An exclusion assertion passes trivially against a pass that selects nothing.** "Cancelled row is not recovered" is vacuously true if recovery selects zero rows. Pair every exclusion with a positive control that normal rows ARE selected.

## A Negative Assertion Passes Vacuously When the Harness Produced Nothing

"X must NOT appear in output" passes whenever there is no output. Two common causes:

1. **The subject died before emitting anything.** Running old code under a harness that does `echo "COMPLETE=$VAR"` with `set -u` aborts when the old version never sets `VAR`. Use `${VAR:-unset}` in harnesses even if current code always sets it.
2. **The fixture ate the string.** `echo "- **repo**: \`branch-name\`"` inside double quotes runs the branch name as a command substitution. Escape backticks or single-quote; read the generated fixture file.

Rules:
- For every "X is absent" assertion, run a case where X SHOULD be present and confirm it fails.
- Print captured output on failure.

## Discrimination Checks (Proving a Test Fails Without the Fix)

- **`git show ref:file > file` truncates the target before git runs.** A bad ref (often `origin/main` on a `master` repo) leaves the file empty and your fix destroyed. Stage through a temp file:
  ```bash
  cp path/to/file /tmp/file.fixed.bak
  git show origin/master:path/to/file > /tmp/file.orig
  cp /tmp/file.orig path/to/file        # run tests: expect only the new tests to fail
  cp /tmp/file.fixed.bak path/to/file   # restore
  ```
  Resolve the default branch with `gh repo view <slug> --json defaultBranchRef -q .defaultBranchRef.name`. Verify the revert with `git diff --stat <ref> -- <path>` (empty = reverted). `git stash push` reverts to HEAD, not the merge base, so it stops discriminating once the fix is committed.
- **A push gate flagging a dirty file during a live verifier run may be flagging the UNFIXED source.** If a hook tells you to commit a file while a verifier has reverted it, check `git show HEAD:<file> | diff - <file>`. If HEAD has the fix and the working tree doesn't, wait for the verifier to restore it. Pushing an existing commit is safe; committing the reverted file ships the bug.
- **Report added vs net test counts separately.** 10 new tests with 2 existing ones rewritten in place is net +8.

## In-Repo Worktrees Double-Count Tests

If you create git worktrees inside the repo (e.g. `.claude/worktrees/<n>`), Vitest, Jest, pytest, and `go test ./...` discover every test file twice. The doubled run is fully green, so a baseline taken right after `git worktree add` is silently poisoned, and the honest count later looks like a massive regression.

Take baselines from a checkout OUTSIDE the repo tree:

```bash
git worktree add --detach /tmp/<name> <ref>
cd /tmp/<name> && ln -s /path/to/repo/node_modules node_modules
npx vitest run
```

Tripwire: compare the runner's reported file count with `find . -path ./node_modules -prune -o -name '*.test.*' -print | wc -l`. Any exact-2x ratio between two test counts is this bug until proven otherwise. Remove in-repo worktrees when done (`git worktree remove`).

## A Build That Imports Every Module Runs Any Script's Top-Level `process.exit`

A validator that imports every module will execute import-time code. A CLI script that runs at module scope and ends with `process.exit(0)` ends the build early: it prints the script's output and exits 0, having validated nothing.

- Guard every script's `main()` with `import.meta.url === pathToFileURL(process.argv[1] || '').href`.
- Have the validator ASSERT that guard exists in every file under `scripts/`. A convention nobody checks decays; verify the check by deliberately removing a guard.

## Benchmark Behavior-Changing Flags on the Hard Case

A config flag that alters generation/reasoning (e.g. enabling "thinking" on a small local model) can look free on one easy call (same tokens, same latency, because constrained decoding capped the output) and be badly worse across a full suite (fewer correct answers, ~24x median latency, timeouts), since the grammar caps the final answer but not the reasoning before it. Never promote such a change on a single hand-picked call; re-run the full benchmark and diff against the recorded baseline. The regression is invisible in any individual response.

## Measurement Rigs Fail Like the Things They Measure

1. **Check the metric is measurable by construction.** If you select candidates for "never used" and then measure "recall on use," the expected observations are zero, and empty logs will read as "safe." Compute the expected count under the null before collecting.
2. **Run a control before acting on a newly discovered signal.** An apparent second signal can be a correlation with your own actions (e.g. your own file reads echoed back in system notices).
3. **Version-stamp the rig.** Hash matcher source, inputs, and thresholds into every record, and make the scorer refuse to average across versions.
4. **Stay proportional.** When rig effort exceeds the prize, let it collect and read it once.

### A Metadata-Only Log Is Still Replayable

A telemetry log that deliberately omits sensitive fields (e.g. records prompt length, not text) looks untestable until it "collects the real thing." Usually the omitted field still exists in a second store (session transcripts, request logs), and records can be rejoined on something like `(session_id, |timestamp delta| <= 5s, exact length)`.

- Filter to real inputs: tool results can share the same record type as user prompts; drop any content containing tool-result blocks, concatenate only text blocks.
- Assert exact values (names and scores, in order), not overlap.
- Report the recovery rate with the result ("148 of 218 replayed"); a pass count without the denominator implies coverage you don't have.

## Headless `claude --print` Inherits Host Guidance; Isolate Before Measuring

Any `claude --print` subprocess loads the host user's `~/.claude/CLAUDE.md` and fires host SessionStart hooks, on top of the working directory's CLAUDE.md. A harness comparing prompts, personas, or rules is measuring host-guidance-plus-instruction-set, and an "empty" control arm isn't a control.

**Fix:** export `CLAUDE_CONFIG_DIR` pointing at a temp directory containing only `.credentials.json` (so auth works) and nothing else; remove it on exit. The workspace CLAUDE.md still loads, which is the half you want. Verify by asking the isolated CLI whether its context contains a string that exists only in your host guidance.

- If there's no credentials file to copy (API-key or keychain auth), fail loud and label results "host-guidance-plus-recipe."
- A judge in a multi-arm test needs the same isolation, or it grades against the host rules instead of the rubric.
- For a headless run that *generates or publishes* content, the leak is worse: host-injected context can land in the published artifact, and there is no control arm to catch it afterward. Isolate before the run.

## Browser and UI Testing

### Screenshot Generated Pages and Look

A generated chart page passing `node --check` and a DOM-stub run proves nothing about readability. Colour ramps that use half the scale, blind-truncated axis labels, and bars that are visually identical all pass automated checks and are obvious in a screenshot within seconds:

```bash
google-chrome --headless --disable-gpu --no-sandbox --screenshot=out.png file://$PWD/page.html
```

Crop if needed and look at the PNG. Related: a guarded try/except import of a config can swallow errors so the build exits 0 having skipped your page entirely; confirm the build output literally names your file.

### Detect Horizontal Overflow from Inline Text

A bare URL in body text can overflow the document while no element's bounding box exceeds the viewport, so the usual `getBoundingClientRect().right > clientWidth` sweep returns nothing. Compare per element instead:

```javascript
document.querySelectorAll('*').forEach(el => {
  if (el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0) report(el);
});
```

Fix with `overflow-wrap: anywhere` on text blocks, not container width changes. Re-test after any client-side re-render, and apply the wrap rule by default to any surface showing text you didn't write (CMS excerpts, user content, API descriptions).

### Touch Drag Needs Pointer Events

HTML5 drag-and-drop does not fire on touch: dead on phones, perfect on desktop. Use Pointer Events (`pointerdown`/`pointermove`/`pointerup` + `setPointerCapture`) with `touch-action: none` on draggables. Always ship a non-drag fallback (tap-to-select then tap-a-target, plus keyboard). Let a release over dead space (gutters, sticky headers) fall back to the last real drop target hovered during that drag.

Testing: Playwright `.tap()`/`.click()` auto-scroll, but raw CDP `Input.dispatchTouchEvent` does not. Scroll both ends into view and assert they're on screen before dispatching. CDP `touchEnd` takes an empty `touchPoints` array.

### Playwright Gotchas

- **`allInnerTexts()` returns empty strings for SVG `<text>`.** `innerText` is an HTMLElement property. Use `evaluateAll(els => els.map(e => e.textContent))`.
- **Input events leak across a same-page navigation.** Open a modal, dismiss it, then `goto()` the same URL on the same page, and the reopened modal may be spuriously dismissed by the leaked event. To test "interact, then reload/reopen," reopen in a fresh page (`context.newPage()`). If a fresh page behaves correctly, it's a test artifact, not an app bug.

### Headless Chrome via Raw CDP (No Puppeteer)

With `google-chrome` installed and Node 22's global `WebSocket`, you can drive headless Chrome with zero npm installs:

1. Launch `google-chrome --headless=new --no-sandbox --remote-debugging-port=N --user-data-dir=/tmp/... about:blank`.
2. Poll `http://127.0.0.1:N/json/version` for `webSocketDebuggerUrl` and open a WebSocket.
3. `Target.createTarget` + `Target.attachToTarget({flatten:true})` for a `sessionId`; send `Page.enable`/`Runtime.enable`.
4. Use `Runtime.evaluate({expression, returnByValue:true})` to click (`element.click()`) and read DOM state; subscribe to `Runtime.consoleAPICalled` (type `error`) and `Runtime.exceptionThrown` to assert zero JS errors.
5. Serve the directory with a tiny `node:http` static server so relative assets load.

Gotcha: CSS `:last-of-type` matches by TAG, not class. Use `[...document.querySelectorAll('.cls')].pop()`.

### Test Design Variants Against Per-Variant Expectations

When a deliverable is N variations of one thing (themes, layouts), a single shared assertion either fails variants behaving correctly or gets weakened until it catches nothing. Declare expectations per variant (what to click, what must then be visible, how many images load initially). Reading each variant's source to build that table is also what proves a "failure" is a design choice.

### Throwaway WordPress Locally with SQLite (No MySQL)

WordPress themes/plugins can be tested end to end without a database server in about two minutes:

1. Install prerequisites: `apt install php-cli php-sqlite3 php-mbstring php-xml php-curl php-zip php-gd` (gd is needed for media thumbnails).
2. Download `latest.tar.gz` and `wp-cli.phar`; unzip the official `sqlite-database-integration` plugin into `wp-content/plugins`.
3. Copy its `db.copy` to `wp-content/db.php` and replace `{SQLITE_IMPLEMENTATION_FOLDER_PATH}` and `{SQLITE_PLUGIN}` with the absolute plugin path and `sqlite-database-integration/load.php`.
4. Write `wp-config.php` with dummy `DB_*` constants and real salts.
5. `php wp-cli.phar core install --url=http://127.0.0.1:PORT ...`, then `php -S 127.0.0.1:PORT -t .` in the background.

`wp-cli eval-file` drives plugin internals curl can't reach (importer batch functions, admin render functions, meta save handlers); since wp-cli doesn't load wp-admin, `require ABSPATH . 'wp-admin/includes/admin.php'` and `wp_set_current_user(1)` first.

## `tsx` Test Scripts: Type Imports and Delayed Dynamic Imports

A `tsx` test script that sets an env var before `await import(...)` of a module that reads it at load time cannot destructure a type from that import: `const { fn, type Foo } = await import("../src/x")` fails with `Expected "}" but found "Foo"`. Hoist the type to a top-level `import type { Foo } from "../src/x"`; type-only imports are erased and carry no runtime side effects. Keep only runtime values in the dynamic-import destructure.
