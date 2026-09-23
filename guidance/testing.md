<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards: when to test, how to structure tests, and the specific traps that produce green suites over broken code.

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

A fallback/waterfall (try A, else B, else C) is the highest-risk structure for a **silent miss**: if an early rung dies, a later rung catches everything and the end-to-end result still looks correct, so nothing appears broken. The dead layer is invisible until the day the layer below it also fails.

- **Test each rung/branch on its own**, with an input it MUST handle, not just the end-to-end happy path. If rung 1 is supposed to handle server-rendered pages, prove it does with the *later rungs disabled* (a `--max-rung`/`--from-rung`-style flag, a forced-branch fixture, dependency stubs). End-to-end green is necessary but not sufficient.
- **Ship a canary** for any fallback you rely on: assert the winning rung, not just that content came back. If rung 1 stops winning on a case it owns, fail loudly.
- **Verify the actual artifact; run the real code path, never a reimplementation of it.** An isolated check that reads data with `open(file)` can pass while the real script, which reads the same data from stdin, is dead (for example because `python3 - <<HEREDOC` shadowed stdin). Testing a rewrite of the logic gives false confidence; drive the shipped script/function itself.

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
- **Use typed mock helpers instead of `as any`:** Create factory functions that return complete typed objects rather than casting partial objects. This catches shape mismatches at compile time and eliminates lint warnings.

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

Shell scripts that alert (chat webhook, email, HTTP callback) need their alert path tested, and the instinct is to drop a fake `curl` earlier on `PATH`. **This silently measures nothing** whenever the script hardens its own `PATH`, which cron-safe scripts usually do:

```bash
export PATH="$(dirname "$(command -v node)"):$(dirname "$CLAUDE_BIN"):$PATH"
```

That prepends `/usr/bin`, so the system `curl` wins the lookup and the stub is never called. The test then passes for the wrong reason: zero alerts recorded, interpreted as "suppression works."

**Instead, bind a real listener and point the script's own webhook variable at it.** It exercises the actual `curl` invocation, actual JSON payload, and actual HTTP semantics:

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

- **Always add an `env -i PATH=/usr/bin:/bin HOME=$HOME` case.** Cron's PATH omits `/usr/local/bin`, and that presents as exit 127 *before* any logic runs. A suite that only runs under your interactive shell cannot see it.
- **Test the state-file upgrade path.** Changing a marker format (bare `touch` to structured) must be exercised against the OLD format, or the first deploy inherits broken behaviour during a live incident.
- **`curl ... || true` is untestable by construction and unsafe in production**: a revoked webhook fails identically to success. Capture the status instead and assert on it: `code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 ...)`.

## Making Node.js Servers Testable

When adding tests to a server-side repo, the server often needs minor changes to support isolated testing.

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

#### Vitest: dummy env vars for import-time DB checks

When a module runs a DB initialization check at **import time** (not call time), vitest fails to import it unless the env var is set, even if tests never open a real connection. Set a dummy value in `vitest.config.ts`:

```typescript
export default defineConfig({
  test: {
    env: {
      // Dummy URL: db.ts throws at import time if DATABASE_URL is unset.
      // Tests only exercise pure functions and never open a connection.
      DATABASE_URL: "postgresql://test:test@localhost:5432/test",
    },
  },
});
```

**Why it matters:** Without this, CI stays red indefinitely even though the test logic is correct; the failure is at the import layer, not test execution. This exact cause has kept a repo's CI red for weeks.

### Factory Pattern for Dependency Injection

For servers with external dependencies (GitHub API, webhooks), export a factory:

```javascript
export function createServer(deps = defaultDeps) {
  const app = express();
  // Use deps.octokit, deps.config, etc.
  return app;
}
```

Tests inject mocked dependencies without module-level patching. Guard auto-start behind `import.meta.url` check so the factory can be imported without side effects.

## Test Fixture Schema Drift

When tests embed their own DDL (CREATE TABLE) or data shapes, they silently drift from the real schema as the application evolves. Tests pass against the stale fixture schema while production uses the real one.

**Signs:** Tests pass locally but the feature is broken in prod, or a batch of tests fail simultaneously after a migration adds columns.

**Prevention:**
- Import schema definitions from the application code rather than duplicating them in tests
- If tests must define their own schema (e.g., SQLite in-memory), derive it from the same migration files the application uses
- When adding a column or field to the real schema, search test files for the table name and update inline definitions

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
- Pin Node.js to 22 (current LTS). Node 20 reached EOL on April 30, 2026; repos still using Node 20 in CI should migrate. Don't use `node-version: 'lts/*'` as it can shift unexpectedly.
- The file is named `test.yml`, not `ci.yml`.
- Branch trigger must match the repo's actual default branch (`main` vs `master`).
- When adding first tests to a repo, also add the CI workflow so tests run on every PR.

## Coverage

- Don't chase 100% coverage. Aim for meaningful coverage of business logic.
- Uncovered code is fine if it's glue code, config, or error handling that's hard to trigger in tests.
- If the repo has a coverage threshold configured, respect it.

## Testing Pyramid Strategy

When a project has recurring quality issues (code ships that doesn't actually work), apply this prioritized testing investment. Each layer reduces the number of incidents the next layer needs to catch.

| Priority | Layer | What It Catches | Cost |
|----------|-------|-----------------|------|
| 1 | Failure audit | Tells you where to invest | Hours |
| 2 | Contract tests | Mock drift, API shape mismatches | Low |
| 3 | Integration tests (real deps) | Backend logic, migrations, auth bugs | Medium |
| 4 | Post-deploy smoke tests | Config drift, bad deploys | Low |
| 5 | Authenticated browser tests | Auth flows, full-stack integration | High |

**Start at the top.** Do not skip to browser tests without completing the lower layers first.

### Layer 1: Failure Audit

Before writing any new tests, classify the last 5-10 production incidents. For each:
- What broke (auth, rendering, data, config, race condition)
- Whether a test existed for that path
- If a test existed and passed, *why* it passed when prod was broken (mock drift, shallow assertion, wrong environment config)
- When it was caught (pre-deploy, post-deploy, user report)

Record these in a simple table, one row per incident. The output tells you exactly which testing layer to invest in.

### Layer 2: Contract Tests

If incidents trace back to "test passed with mocks but prod behaved differently," your mocks encode stale assumptions. Fix this with:
- Schema checks against real API responses recorded from staging
- Snapshot the actual response shape from a real endpoint, then validate mocks match that shape
- Update snapshots as part of the deploy pipeline

**When to use:** Any service boundary where you currently use mocks: external APIs, database queries, auth providers.

### Layer 3: Integration Tests with Real Dependencies

For backend logic failures (bad queries, broken migrations, auth provider interactions):
- Hit real databases, real auth providers, and real caches
- Control state setup explicitly; each test owns its fixtures
- Run in CI, deterministic if you own the fixture lifecycle
- **Do not mock the database**: mock/prod divergence is the #1 source of false-green tests

### Layer 4: Post-Deploy Smoke Tests

Lightweight, fast (under 30 seconds), non-browser checks against the deployed environment:
- Authenticate with a test account
- Hit the 3-5 most critical endpoints
- Assert HTTP 200 and basic response shape (not just status code)
- Run automatically after every staging deploy

This catches environment config drift and bad deploys immediately. It is deployment validation, not e2e testing.

### Layer 5: Authenticated Browser Tests (Use Sparingly)

Only proceed here if the failure audit shows incidents that ONLY a real browser would have caught (broken auth flows, CORS/CSP issues, token refresh failures).

**Constraints:**
- Maximum 5-8 scenarios. Start by reproducing a specific past incident, not writing speculative tests
- Dedicated test account with stable credentials, managed via secrets
- Run against staging only, never production
- Each test owns its state: setup creates what it needs, teardown removes it
- Assert on intercepted API responses, not just DOM elements
- Capture screenshots, network logs, and console errors on failure

**Flakiness policy:** Quarantine on the second consecutive flake. Move to a non-blocking suite until fixed. A flaky test the team ignores is worse than no test.

**Tag every test** by the failure mode it guards against (`@auth-flow`, `@regression-INCIDENT-42`).

## Mock Fidelity

Mocks that diverge from production are worse than no mocks: they give false confidence.

- **Record real responses** from staging/production as mock fixtures. Re-record periodically
- **Validate mock shape** against the real API schema on every CI run
- **Never hand-write mock data** for external APIs; use recorded fixtures
- **If a mock test passes but the feature is broken in prod**, the mock is the bug; fix the mock, not the test

### Test-Client Normalization Hides Untestable Guards

A hand-rolled test client that builds requests by hand (a `{ method, url, query, body }` object passed straight into a route handler) can silently normalize input into a shape the real framework parser never produces, so a guard written against that input reads as covered while its actual failure mode is structurally unreachable. Example: a `request()` test helper flattened repeated query params (`?page=1&page=2`) to a single last-wins string via `searchParams.forEach`, so `req.query.page` was never an array inside a test even though Express's real parser produces one for a duplicate key. Every `typeof req.query.x === "string" ? ... : <default>` guard looked tested, but the non-string branch was invisible to any amount of new test-writing against that same client. It is not an uncovered branch a coverage report would flag, just an unreachable one.

**Why:** this is one layer out from Mock Fidelity: the divergence isn't in a stubbed dependency, it's in the CLIENT the test uses to drive the code under test. "Record real fixtures" doesn't catch it, because the test harness itself is the thing diverging from production.

**How to apply:** when a route defends against a shape its framework can actually produce (array-valued query params from a duplicate key, `__proto__`-style keys from a permissive query parser, duplicate headers, arrays where a scalar is expected), check whether your test harness can produce that shape at all before counting the guard as tested. Drive that class of guard over a real `app.listen()` + `fetch` (or supertest) so the framework's own parser is in the loop. A real-listener test can also reveal that a fix is INCOMPLETE (e.g. `?category=a&category=b` still returning an unfiltered result) even when the hand-rolled client says it passes.

## Cross-Layer Invariant Tests

The highest-value tests are often not about individual functions; they're about **invariants between layers** that silently break when one layer changes without updating the other.

### What Are Invariants?

An invariant is a property that must hold for the system to work, even though no single function enforces it. Examples:

| Invariant | Producer | Consumer | What Breaks |
|-----------|----------|----------|-------------|
| Stores must have lat/lng | Pipeline creates stores | Trip planner filters by `storesWithCoords` | Pipeline creates stores without coords, trip planner returns 0 plans |
| Price records must include unit | Pipeline ingests prices | UI formats as `$2.99/lb` | Missing unit, UI shows `$2.99` with no context |
| Shopping list items serialize to JSON | Frontend `setItems()` | Backend PATCH `/api/shopping-lists/:id` | Shape mismatch, silent data loss on save |
| API response includes store name | Backend joins tables | Frontend sparkline display | Missing join, UI shows price with no store attribution |

### When to Write Invariant Tests

Write an invariant test whenever:
1. **You just fixed a cross-layer bug.** The fix goes in the code; the invariant test goes in the test suite. This is the regression test for the *class of bug*, not just the specific instance.
2. **One system produces data another consumes.** Pipeline to database to API to UI. Each boundary is an invariant.
3. **A filter or query depends on data shape.** If `WHERE lat IS NOT NULL` is used anywhere, test that the data producer always sets lat.
4. **Display formatting depends on API response shape.** If the UI expects `storeName` in the response, test that the API actually returns it.

### How to Write Them

Invariant tests don't need a database. Test the **contract**: the shape and constraints of data flowing between layers:

```typescript
describe("Pipeline → Trip Planner invariant", () => {
  it("pipeline-created stores must have coordinates", () => {
    // This is the shape the pipeline produces
    const store = createPipelineStore("store-a", "94102");
    // This is the filter the trip planner applies
    const visible = [store].filter(s => s.lat != null && s.lng != null);
    expect(visible).toHaveLength(1); // Would have caught the bug
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

### Naming Convention

Name invariant tests after the boundary they guard:
- `pipeline-stores.test.ts`: pipeline to database shape
- `price-display.test.ts`: API response to UI formatting
- `trip-planner.test.ts`: database query assumptions

### Common Patterns Across Projects

These invariants recur in every full-stack project:

1. **Geocoding completeness:** Any entity with lat/lng that gets filtered by location queries must have coordinates populated at creation time.
2. **API response shape:** If the frontend destructures `response.storeName`, the backend must include it in the SELECT/JOIN.
3. **Serialization roundtrip:** Data written to localStorage/database must survive `JSON.parse(JSON.stringify(data))` without losing fields.
4. **Auth-gated endpoints:** Every endpoint behind `requireAuth` must return 401 for unauthenticated requests, not 500.
5. **Unit/format consistency:** If prices are stored as strings (`"2.99"`) but displayed as numbers (`2.99`), test the parseFloat boundary.
6. **LocalStorage hydration schema tolerance:** Any hook or util that reads state from localStorage must normalize/validate the parsed result. `JSON.parse` succeeds on structurally invalid values (older schema missing required fields, manual edits, truncated writes, non-object values like `null`). A try/catch only guards parse *throws*, not malformed-but-valid JSON that crashes later on `.length` or `.filter` access. Always normalize after parse: guarantee required fields exist and have correct types, fall back to defaults otherwise. Test with partial/stale schemas from a prior app version, not just the current structure.

## Zod Validation in API Routes

Every Next.js API route that parses input with Zod **must** catch `ZodError` and return a 400 response. Without this, Zod validation failures bubble up as unhandled exceptions (500 Internal Server Error), which hides the real problem from the client.

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

**When adding a new Zod-validated endpoint**, always include the ZodError catch. When auditing an existing codebase, check that *every* route using `.parse()` has this handling; it's easy to miss a single endpoint while all others are correct.

## Live Browser Testing in the User's Real Browser

If you have a tool that drives the user's real browser (for example a userscript plus relay plus CLI that sends commands to a live tab and returns results synchronously), prefer it over Playwright/headless for integration testing, debugging UI issues, and verifying deployed changes on the user's machine. It runs with real cookies and session, avoids CAPTCHA, and tests exactly what the user sees. The typical loop: confirm a tab is connected, navigate, read page state (buttons, inputs, errors), interact, assert on visible text, then check the console for errors.

## Don't Grep Test Output to Detect Pass/Fail

Parsing test runner output with `grep` to determine pass/fail is fragile. A test suite that passes but has a test _named_ "handles errors" or prints "0 failed" will match the wrong pattern and flip your result.

```bash
# WRONG: a passing test named "handles errors" matches the grep and RESULT=FAIL
if npm test 2>&1 | grep -qi "error\|fail"; then
  RESULT="FAIL"
fi

# RIGHT: use the actual exit code; output is only for human-readable detail
TEST_EXIT=0
TEST_OUTPUT=$(npm test 2>&1) || TEST_EXIT=$?
if [ "$TEST_EXIT" -ne 0 ]; then
  RESULT="FAIL"
fi
```

**Why:** a verification script that grepped test output for "FAIL" began false-positiving on every run as soon as a refactor added error-handling tests whose names contained "error", regardless of actual test results.

**Exception:** You can still grep output for metadata extraction (e.g., `grep -oP '\d+ passed'` to surface a human-friendly count in a log line), but never use output grep as the pass/fail gate.

## CI Workflow Gotchas

### Test Glob Quoting on GitHub Actions

Single-quoted globs like `'test/**/*.test.js'` do NOT expand on GitHub Actions because `globstar` is off by default. The shell passes the literal string to Jest/Node, which may not expand `**` the same way.

**Fix:** Use a flat glob (`test/*.test.js`) or let the test framework handle the pattern:
```yaml
# BAD: glob not expanded, tests silently skipped
run: npx jest 'test/**/*.test.js'

# GOOD: flat glob, works everywhere
run: npx jest test/*.test.js

# GOOD: let jest find tests via config
run: npx jest
```

### package-lock.json Must Be Committed for CI

GitHub Actions `cache: npm` with `npm ci` requires `package-lock.json` in the repo. If it's in `.gitignore`, the CI cache step fails and `npm ci` refuses to run (it requires a lockfile).

**Fix:** Remove `package-lock.json` from `.gitignore` and commit it. This also ensures deterministic installs across environments.

### Vitest Fails When Any Imported Module Throws at Import Time

If a module (e.g., `db.ts`, `prisma.ts`) runs `new PrismaClient()` or reads a required env var **at module load time**, any test file that imports it will crash the entire vitest runner before any test executes. CI shows a cryptic initialization error rather than a test failure, and CI can stay red for weeks with no obvious cause.

**Fix:** Set a dummy value in `vitest.config.ts`:
```typescript
// vitest.config.ts
export default defineConfig({
  test: {
    env: {
      DATABASE_URL: 'file:./test.db',  // keeps Prisma happy at import time
    },
  },
});
```

Or in a `setupFiles` entry:
```typescript
process.env.DATABASE_URL = process.env.DATABASE_URL ?? 'file:./test.db';
```

The error stack shows `PrismaClientInitializationError` (or similar) before the first `describe()`, so it reads as a build or config problem rather than a missing env var.

## Accessibility: Focus Management After Modal Close

When a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it. Leaving focus on `document.body` is a WCAG 2.4.3 (Focus Order) violation: keyboard users lose their place in the tab order after every modal interaction.

**Implementation (React):** capture the trigger element's ref before opening; restore it in the close handler or `useEffect` cleanup.

```tsx
const triggerRef = useRef<HTMLElement | null>(null);

const handleOpen = (e: React.MouseEvent<HTMLElement>) => {
  triggerRef.current = e.currentTarget;
  setOpen(true);
};

// in useEffect cleanup or close handler:
triggerRef.current?.focus();
```

**Write 3 tests, one per close path:** Escape key, close button, backdrop click. Each must assert `document.activeElement === trigger`:

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

**Why:** visual tests never catch this. A lightbox that leaves focus on `document.body` silently breaks keyboard traversal of everything around it until explicit close-path tests are written.

## Boundary Validation: Non-Negative Quantities from External Sources

When validating numeric values parsed from external input (webhook payloads, API responses, database records, user data), `!x` and `x === 0` guards do NOT reject negative numbers; JS treats negatives as truthy.

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

**Self-review trigger:** Any numeric guard for a measured/physical quantity (distance, duration, speed, count, price) that comes from an external source: use `<= 0`, not `!x`/`=== 0`. Check that all adapters for the same domain use consistent guard forms; an inconsistency between two sibling adapters (one using `<= 0`, the other `=== 0`) is the tell.

**Test to write:** `expect(fn(1000, -100)).toBeUndefined()`; verify the negative case explicitly alongside the zero case.

## Batch Loop Resilience: Isolate Per-Item Failures

When a loop processes a batch (DB rows, files, API records) and each iteration runs an operation that can throw on bad data, an unguarded throw aborts the ENTIRE batch, not just the bad item.

**Two-layer defense:**
1. **Guard the throwing operation itself:** compile `new RegExp(external_pattern)` in a try/catch that returns null on SyntaxError; wrap `JSON.parse(external_file)` in try/catch; check for zero before dividing by an externally-sourced delta.
2. **Wrap each loop iteration** in try/catch + continue so one bad record is skipped, not fatal.

```javascript
// WRONG: one malformed regex aborts ALL detection
function detectAllBenefits(transactions, templates) {
  for (const tmpl of templates) {
    const re = new RegExp(tmpl.merchantPattern);  // throws SyntaxError on bad pattern
    // ...
  }
}

// RIGHT: guard the throw; isolate per-item failures
function safeCompile(pattern) {
  try { return new RegExp(pattern); } catch { return null; }
}

function detectAllBenefits(transactions, templates) {
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

**Self-review trigger:** Any `new RegExp(non-literal)`, `JSON.parse(file/network)`, or division by a data-derived value inside a loop: ask "does one bad input abort the whole batch?" Also: compile invariant regexes once before the loop, not per-iteration.

**Why:** one malformed stored pattern compiled inside an unguarded loop is enough to 500 an endpoint for every record, not just the bad one.

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (you're compensating for missing integration tests; push coverage down the pyramid)
- Tests without a corresponding past incident (speculative tests have low ROI and high maintenance cost)

## Test a Statistic at Both Sample Parities

A median computed as `sorted[Math.floor(len / 2)]` is correct only for ODD-length samples; on an even-length sample it returns the upper-middle element instead of averaging the two middles, so the reported median is systematically **>= the true median and never below it**.

**Why tests miss it, two distinct failures:**

1. **Every test used an odd-length sample**, the exact case where the buggy and correct expressions agree. Parity is part of a statistic's input space, just like empty / single / unsorted.
2. **Tests that did use even-length samples asserted the wrong thing**: row counts, an average, the mere presence of the substring `'median'` in rendered output, never the computed value. Asserting that a field is *present* is not asserting it is *correct*.

**One-sided error is worse than noisy error.** If a biased statistic is also the yardstick a scoring function uses (e.g. credit for being "below median"), the bias does not average out: it pushes every downstream decision the same way. Rank it above a symmetric rounding error.

**Checklist for any summary statistic (median, percentile, quartile, trimmed mean):**
- Test odd length, even length, single element, empty, and unsorted input.
- Assert the computed VALUE, not that the field rendered.
- Confirm the sort is numeric (`(a, b) => a - b`); `Array#sort`'s default is lexicographic, so `[90, 1000, 200]` sorts to `[1000, 200, 90]`.
- Check whether the helper mutates its input (in-place `.sort()` on a caller's array is a common silent side effect).
- If the statistic feeds a threshold or band, add a test at the DECISION level (does the item cross the gate?), not only at the helper level.

## A Fix Proven on One App's Data Is Not Proven for a Sibling App

Before sharing a module across sibling apps built from the same template, run it over the sibling's OWN stored production rows and read the diff by hand. "Same defect" does not mean "same data shape." A text-cleanup module verified against one app's full corpus can have poor recall on a sibling (different wording it never matched) and, worse, poor precision (the sibling mixes the content to strip with real content in the same paragraph, so the same rule removes real information).

- **Audit precision, not just recall.** Recall is easy to eyeball ("did it fire?"). Precision means reading what got REMOVED. The fire-rate can go up while the output gets worse.
- **Change the shared module and re-verify the original to parity**, rather than forking it per app. Hold the original app to byte-identical output by rendering its production records on the old and new builds and diffing them.
- **A guard that hides rather than deletes still needs this scrutiny.** "Nothing is discarded, it just moves to a collapsed section" is exactly why the damage would be invisible: the page still renders, tests pass, nothing logs an error.

## A Hand-Built Fixture Never Tests the Loader

When a config file gains a field, add at least one test that goes through the **real loader**: write a temp config, load it, assert the consumer sees the value. Testing the consumer with a hand-built object leaves the plumbing completely uncovered.

Typical failure: a validator destructures a new field, validates it, then returns an object **without it**. Every consumer sees `undefined` in production while every unit test is green, because each test constructs the object literally and hands it to the pure function, so nothing ever calls the loader. The defect lives exactly in the seam the tests skip.

This generalises to any parse/validate/transform layer. A dropped field is invisible to both the unit suite (which never runs the transform) and the type checker (the object is still structurally valid, just missing an optional property). At least one test must cross the boundary.

## A Measurement Rig Fails the Same Ways the Thing It Measures Does

1. **Unmeasurable by construction.** If candidates are selected for "never used" and the metric is "recall when used", the expected number of observations is zero, and an empty log will read as "safe". Before collecting, compute the EXPECTED number of observations under the null. If it rounds to zero, the metric is decoration.
2. **The rig is a system too.** A newly "discovered" signal that justifies a change must survive a control before you act on it. It is common for such a signal to be a correlation with the measurement's own activity (e.g. your own file reads echoed back into the data you are measuring).

**Consequence: version-stamp the rig.** Hash the matcher source + input sets + thresholds into every record, and make the scorer REFUSE to average across versions rather than silently mixing them. A rig that changes several times in a day will otherwise produce artifacts (a "0% recall" that the current matcher does not reproduce).

**Proportionality:** stop when rig effort exceeds the prize. By the third rig correction, "let it collect and read it once" usually beats a fourth fix.

## A Metadata-Only Log Is Still Replayable: Rejoin It to the Source

A telemetry log that deliberately omits sensitive fields (e.g. records a prompt's length but never its text) looks untestable until it collects the real thing. Usually it is not: **the omitted field is often still sitting in a second store that kept it for an unrelated reason** (session transcripts, request logs). Rejoin on something like:

```
(session_id, |timestamp delta| <= 5s, exact character length)
```

That can turn "wait two weeks" into a regression test available the same afternoon, and it is a way to prove a copied function is byte-identical to a frozen original that cannot be imported.

Rules that generalise:

- **Filter the source down to genuine records of the kind you want.** In chat transcripts, tool results often share the same entry type as user prompts; a long tool output can coincidentally match a prompt's length and replay the wrong text into a test that then passes. Drop any entry containing a tool-result block; concatenate only text blocks.
- **Assert on exact values, not overlap.** Compare names *and* scores in order. A near-match hides precisely the drift the test exists to catch.
- **Report the recovery rate as part of the result.** "148/148 passed" without saying 148 of 218 records could be replayed implies coverage the test does not have.

## Touch Drag Needs Pointer Events, and Raw CDP Touch Does Not Auto-Scroll

Building it: HTML5 drag-and-drop (dragstart/dragover/drop) does not fire on touch, so a page built with it is dead on a phone while testing perfectly on a desktop. Use Pointer Events (pointerdown/pointermove/pointerup with setPointerCapture), which cover mouse, touch, and pen in one code path. Give draggable elements `touch-action: none` or the browser will start a scroll and never deliver pointermove. Always ship a non-drag fallback (tap-to-select then tap-a-target, plus keyboard keys). Let a release over dead space (gutters, sticky headers) fall back to the last real drop target hovered during that drag, or it silently reverts and reads as a broken page.

Testing it: Playwright's `.tap()` and `.click()` auto-scroll the target into view, but raw CDP `Input.dispatchTouchEvent` does not. If either end of a simulated touch drag sits below the fold, the touch lands on nothing. Scroll both ends into the viewport first and assert they are on screen before dispatching, so a layout change fails loudly instead of masquerading as a drag bug. CDP touchEnd takes an empty touchPoints array; the coordinates come from the preceding touchMove.

## A Generated Page Passing Syntax Checks Proves Nothing About Readability: Screenshot It

Syntax checks and a DOM-stub run will pass a chart page with a colour ramp whose data all lands in one half of the scale, a blind-truncated axis label, or a ranking whose bars span a sliver of range and look identical. All are visible in the first 30 seconds of looking at a screenshot. Take one with headless Chrome:

```bash
google-chrome --headless --disable-gpu --no-sandbox --screenshot=out.png "file://$PWD/page.html"
```

Then crop and actually look at the PNG. Related trap: a guarded try/except import in a build script silently swallows config errors, so the build exits 0 having skipped the new page entirely. Always confirm the build output literally names your file.

## Detecting Horizontal Overflow from Inline Text

A bare URL in body text can make `documentElement.scrollWidth` exceed the viewport while a sweep of `getBoundingClientRect().right` finds nothing, because the overflowing content is inline text inside a normally sized block. Compare scrollWidth to clientWidth per element instead:

```javascript
document.querySelectorAll('*').forEach(el => {
  if (el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0) report(el);
});
```

Fix with `overflow-wrap: anywhere` on text blocks, not a width or overflow change on the container.

- Re-test AFTER any client-side re-render. If JS rebuilds the same markup from an API, a fix applied only to the server-rendered template leaves the JS-rendered copy broken.
- Verbatim third-party text (CMS excerpts, user content, API descriptions) is where this comes from. Any surface rendering text you did not write needs the wrap rule by default.

## Test the Whole Field Set a Boundary Forwards

A loader that builds a model from two of its five tunable fields silently discards the rest, and tests covering exactly the two forwarded fields read as coverage of "config overrides reach the model".

```python
model = VehicleModel(wheelbase=d.get('wheelbase', 2.8), max_speed=d.get('max_speed', 30.0))  # drops 3 fields
```

- **Assert the COMPLETE field set round-trips** at any boundary (loader, serializer, DTO mapper, API adapter, ORM row builder). A field-by-field or "parsed == constructed" equality assertion catches the next dropped field for free; N single-field tests never will.
- **Don't repeat the type's defaults as fallbacks.** That is a second source of truth that drifts. Forward only keys actually present and let the type supply its own defaults; this also makes "omitted key defers to the model" testable (`parsed_with_no_overrides == Model()`):

```python
overrides = {k: float(d[k]) for k in FIELDS if k in d}
model = VehicleModel(**overrides)
```

- **Coerce at the boundary.** A quoted config value surviving as a string fails much later, far from its cause. `float()` at parse time, raising an error that names the entity and field, points straight at the config line.

## A Response That Narrates the Work Is Not the Work: Guard Output Shape

An LLM call can spend its turns working, then emit a final turn that only reports on itself ("All agents have completed; the full guide was delivered above"). That short status report gets stored as a completed answer when there is no "above".

1. **Guards keyed only to error strings or emptiness miss it.** The output is well-formed, confident, on-topic prose. Add a guard on the SHAPE of a valid answer, not only on known failure shapes.
2. **A narration stripper is not a rejecter.** Stripping narration from a pure-narration response leaves nothing; a splitter and a rejecter are different controls.
3. **A false positive DELETES a real answer, so require several independent conditions**: short residual after stripping, a match on a process-narration or deferral wording family, and the absence of any substantive marker (link, price, list, heading, table). The substantive-marker test protects legitimately terse answers.
4. **Measure the guard over the full stored corpus before believing it.** It should flag the reported case and pass the other short candidates. A corpus sweep also finds bugs you were not looking for (e.g. a cleanup step wired to the main response but never to follow-up answers).

Separately: a committed prompt change that requires a container or image rebuild is INERT until that rebuild runs. Grep the live artifact for the new strings; verify the ARTIFACT, not the commit.

## Ordering Tests Must Assert the Exact Sequence, Not Set Completeness

When fixing a non-total ORDER BY (a sort key with ties and no unique tiebreaker), the obvious test, "page 1 union page 2 covers all N rows exactly once", PASSES on the unfixed code. Under a single stable query plan the pages are always complete; rows are dropped/duplicated only when the plan CHANGES between page requests (a new index, ANALYZE, VACUUM, a version bump). On SQLite, a table scan and an ASC composite index can return a tie group in opposite orders.

Two ways to make the test discriminate:
1. Assert the EXACT returned sequence against the intended total order, with fixture ids chosen so the pre-fix order (insertion/rowid) provably differs from the post-fix order (e.g. insert ascending, assert descending).
2. Model the plan change inside the test: fetch page 1, `CREATE INDEX ...` via raw SQL, fetch page 2, then assert no drops or duplicates.

Audit blind spot: a sweep for "every ORDER BY that needs a tiebreaker" cannot see the worse case, a truncated list (LIMIT, or a JS `.slice()` over an unordered select) with NO ORDER BY at all. Grep for `.limit(`/`LIMIT` and slices over query results too.

## Re-Deriving a Metric Breaks Every Site That Differences It Against the Old Derivation

Changing how a metric is computed (e.g. switching to a moving average that excludes sentinel zeros) can correctly fix its direct consumer while silently breaking a delta elsewhere: if the current item is computed the new way (it has the detailed data loaded) and the comparison item the old way (it does not), the delta reports a difference in METHODOLOGY rather than a difference between items. A same-file unit test cannot catch it, because both sides of the subtraction are individually correct.

Before changing how a metric is derived, grep every consumer and ask which of them SUBTRACT, COMPARE, RANK, or THRESHOLD it against a value computed the old way, including a second call to the same function with different arguments (`evaluate(item, details)` vs `evaluate(compare, undefined)`). Deltas, sparklines, "vs last week", leaderboards, and regression baselines are all this shape.

Related: reporting a range from a convenience sample can understate the bounds by an order of magnitude. Sample the population before quoting its bounds.

## A Commit Gate Flagging a Dirty File During a Verifier Run May Be Flagging the Unfixed Source

If a verifier or discrimination check temporarily reverts a file to the pre-fix version, a "you have uncommitted changes" gate firing at that moment is pointing at the UNFIXED source. Committing to satisfy it ships the bug. Before obeying any such gate mid-verification, diff the working tree against the commit:

```bash
git show HEAD:<file> | diff - <file>
```

If HEAD has the fix and the working tree does not, the dirty state is the checker's; wait for it to restore. Pushing an existing commit is always safe; committing is not.

Reporting rule: added test count is NOT the net suite delta. Ten new tests with two pre-existing ones rewritten in place is net +8. State added vs net separately.

## A Default Applied Only on One Render Path Is Invisible to the Other

A server-side accessor that falls back to a default (a tagline, a label) is correct everywhere the server prints, and blank wherever the markup is filled in by JavaScript from a JSON payload built from the raw stored value. `curl` passes (HTTP 200, markup present); only a browser that runs the script sees the blank.

Normalise the payload, not the accessor: apply defaults where the data is assembled, so both readers get the same value by construction. When the same value has two readers, put the fallback upstream of both, and test the reader that curl cannot see.

## Test Design Variants Against Per-Variant Expectations

When a deliverable is N variations of the same thing (themes, layouts, templates), a single shared assertion either fails variants that behave correctly by design or gets weakened until it catches nothing. Declare an expectation per variant (what to click, what must then be visible, how many images are due on load, what the filter row is called) and check each against what it actually is. The table doubles as documentation, and reading each variant's source to build it proves a "failure" is a design choice rather than a bug.

## Run a Throwaway WordPress Locally with the SQLite Drop-In

WordPress themes and plugins can be tested end to end without a database server: WordPress core plus the official `sqlite-database-integration` plugin's `db.copy` drop-in, driven by wp-cli and served by PHP's built-in server.

1. Download `latest.tar.gz` and `wp-cli.phar`; unzip `sqlite-database-integration` into `wp-content/plugins`.
2. Copy its `db.copy` to `wp-content/db.php` and replace `{SQLITE_IMPLEMENTATION_FOLDER_PATH}` and `{SQLITE_PLUGIN}` with the absolute plugin path and `sqlite-database-integration/load.php`.
3. Write a `wp-config.php` with dummy `DB_*` constants and real salts.
4. `php wp-cli.phar core install --url=http://127.0.0.1:PORT ...`
5. `php -S 127.0.0.1:PORT -t .` in the background.

Prerequisites (Debian/Ubuntu): `apt install php-cli php-sqlite3 php-mbstring php-xml php-curl php-zip php-gd` (gd is needed for media import thumbnails). Use `wp eval-file` to drive plugin internals a curl cannot reach (importer batch functions, admin render functions, meta save handlers); since wp-cli never loads wp-admin, `require ABSPATH . 'wp-admin/includes/admin.php'` and call `wp_set_current_user(1)` first.

## Hiding a Filter Option Must Not Hide the Items

When a taxonomy list feeds both a filter bar and something structural (section headings, a proportion strip, a grouping key), hiding a term by filtering that one list silently drops the items filed under it from the structural views. Emit two lists: the visible list the bar draws, and the full list everything structural reads. Then assert per consumer, in a browser, that hiding a term changes the bar and nothing else: same item count on the page, same number of sections, same number of segments, and reversible.

## `git show ref:file > file` Empties the File on a Bad Ref

When reverting a single file for a discrimination check, never redirect `git show` straight onto the file:

```bash
git show origin/main:src/routes/feed.ts > src/routes/feed.ts   # WRONG
```

The shell truncates the redirect target BEFORE git runs. If the ref is wrong (commonly `origin/main` on a repo whose default is `master`; check with `gh repo view <slug> --json defaultBranchRef -q .defaultBranchRef.name`), the file is already zero bytes and your fix is gone. Safe form:

```bash
cp path/to/file /tmp/file.fixed.bak
git show origin/master:path/to/file > /tmp/file.orig
cp /tmp/file.orig path/to/file        # run tests: expect only the new tests to fail
cp /tmp/file.fixed.bak path/to/file   # restore
```

Verify the revert landed with `git diff --stat <ref> -- <path>` (empty output = reverted) rather than trusting the redirect's exit code. Note that `git stash push` reverts to HEAD, not the merge base, so it stops discriminating once the fix is committed.

## A Filter, Count, or Search over a Capped List Silently Under-Reports

A rendered list capped at N is a rendering decision. A filter, search, or count wired to that list treats N as a database limit. "No results" then reads as an authoritative statement about the data rather than about the page. At real data volumes this can mean a "New" filter showing about half the actually-new items, and search under-reporting on every query.

Rules:
1. Before shipping any control whose output is a COUNT or a "nothing found" verdict, run it against REAL production-scale data and print "N in the full set vs M in the rendered list" per query. Small fixtures pass trivially.
2. **Two fix shapes, pick by size.** PIN qualifying rows into the capped query when the qualifying set is known server-side and small (append any rows the cap dropped). Serve an UNCAPPED endpoint lazily when the query is client-side and arbitrary (e.g. `GET /api/items?all=1`, invalidated when the primary list refreshes, using the same ORDER BY so clearing the search restores an exact prefix-superset).
3. Re-check any cap whose underlying data has grown since the constant was chosen.
4. A cap applied to a concatenation of two semantically different lists drops the kind appended last and manufactures false negatives. Cap each kind separately.

## A Ranking over a Capped List Is Not a Ranking, and Clamped Weights Collapse It

A sort shows no number that can be checked; it just presents the wrong row first.

1. **The cap.** A "Best fit" default sort over `LIMIT 100` means "best among the 100 most recent" while reading as "your best matches". Send the whole set (a few hundred rows is small JSON) and paginate the RENDER, not the query. Keep the cap only as a runaway guard.
2. **The clamp.** A heuristic score that clamps to a ceiling ties every strong item at the cap, and order among tied items falls back to the secondary key. Size positive weights so a perfect item lands EXACTLY on the ceiling and assert that in a test, then verify on real data by printing the score histogram, not just min/max ("distinct scores: 21 over 328 rows, 6 at the ceiling").
3. **Replay beats fixtures for a scorer.** Free-text comparisons (locations, titles) that pass every unit test can fail in both directions on real data. Write a replay script alongside the tests and point it at a COPY of the production database (opening it may run migrations).
4. **Keep two sources of a score distinguishable.** When some rows carry a real model judgement and others only an app-side estimate, a missing score must not resolve to 0 (that buries the pre-existing corpus forever), and the estimate must be capped BELOW the model's range. Mark the estimate in the UI; don't store it, since it is only true of the profile that produced it.

## A Headless `claude --print` Run Inherits the Host's Guidance; Isolate Before Measuring

Any `claude --print` subprocess loads the host user's `~/.claude/CLAUDE.md` and fires the host's SessionStart hooks, on top of whatever CLAUDE.md sits in its working directory. A harness that shells out to the CLI to compare prompts, personas, or rules is therefore measuring host-guidance-plus-instruction-set; an "empty" control arm is not a control.

**Fix:** export `CLAUDE_CONFIG_DIR` pointing at a temp directory containing only `.credentials.json` (so auth still works) and nothing else. Remove it on exit. The workspace CLAUDE.md still loads under isolation, which is the half you want. Verify with a canary: ask whether the context contains a string present only in host guidance; it should answer yes without isolation and no with it.

If there is no credentials file to copy (API-key or keychain auth), fail loud and label results "host-guidance-plus-recipe" rather than silently measuring the wrong baseline. A judge in a multi-arm test needs the same isolation, or it grades against the host rules instead of the rubric. For a headless run that GENERATES or PUBLISHES content, the leak is host-injected context landing inside the published artifact; with no control arm to catch it afterwards, isolation must happen before the run.

## Two Mutation-Testing Traps for Data-Store Write Paths

1. **`indexOf` returns -1 for a missing needle, and -1 < every real index.** An ordering assertion `writeAt < abortAt` passes for code that performs NO write at all. Assert the needle exists first: `expect(log.indexOf('write')).toBeGreaterThanOrEqual(0)`.
2. **An exclusion assertion passes trivially against a pass that selects nothing.** "The cancelled row is not recovered" is vacuously true if recovery selects zero rows. Pair every exclusion assertion with a positive control asserting the normal rows ARE selected.

## A Builder Generating a Deliverable from Source Lists Must Assert Coverage Before Writing

When a deliverable (spreadsheet tab, report, batch of files) must cover every entry from a set of source lists, hand-enumeration silently drops one and nothing errors. Make the builder read the live source lists and assert before writing.

1. **Read the live artifact, not the cached intermediate.** A file on disk reflects what it held when last written; the live sheet/database/endpoint reflects every later correction.
2. **Assert before writing**, not after duplicates or omissions are baked in.
3. **Assert coverage and uniqueness independently.** A de-duplication bug passes coverage and fails uniqueness; a missing row does the reverse.
4. **Count the live source at run time.** A constant like `EXPECTED_COUNT = 149` drifts as the source grows.

## A Verdict Parsed from a Tool's Stdout Can Report All-Failures on All-Successes

A loop that grades each iteration by grepping stdout for a format the tool does not actually emit (e.g. a JSON `id` field when the tool prints a bare id and URL) will confidently report every operation failed while all of them succeeded. The natural recovery, re-running, then creates duplicates.

**Rule:** don't trust a stdout-scraped tally. Confirm against the system's own state (list the folder, query the API, count the rows) before reporting failure or retrying. Read the tool's actual output contract first. **Corollary:** a retry is only safe if the operation is idempotent; creating a record generally is not.

## A Rotted Live Control Looks Exactly Like a Detector Regression

A validation suite pins a known-LIVE control so a detector that has started answering "dead" everywhere is caught. But controls expire (a posting closes, a product goes away), and the failing output is byte-identical to a real regression. The cheap guess, "the control probably rotted", is the one that hides a genuine regression.

The discriminator is a SECOND source the detector does not itself consult (e.g. the public HTML page when the detector reads an API). Both say dead: the control ROTTED, repin it. The second source still shows it live while the detector says dead: REGRESSION, don't touch the controls. Some platforms need a different signal, such as the size or server-rendered content of a page that returns 200 either way.

Also audit controls that pass. A control proving "a wrong-but-valid token yields a confident wrong verdict" can go green because its target disappeared rather than because the token was wrong, and nothing prompts anyone to look.

How to apply: any control whose expected verdict is the PERISHABLE one (live, present, in-stock, reachable) needs automated rot-vs-regression triage, not a comment telling a human to check. Validate the triage on its own live/dead/garbage controls, and make the failure message name the cause and suggest a replacement.

## Playwright `allInnerTexts()` Returns Empty Strings for SVG `<text>`

`locator('svg text').allInnerTexts()` reports empty strings for every node, so a correct render looks like a failure. `innerText` is an HTMLElement property that SVGElement does not implement, and Playwright falls back to an empty string rather than throwing. Read SVG copy with `evaluateAll(els => els.map(e => e.textContent))`.

## A Stale-Tolerant Cached Health Probe Is Right for a Sampler and Wrong for a User Choice

A readiness probe that returns the last known state and refreshes in the background costs "one stale request" after a cold start or idle gap. That is fine while the only consumer is an automatic sampler or fallback. Once a USER can explicitly select that dependency, the first request after a restart answers from the stale "unavailable" value and tells the user their choice is down while it is up. Staging rarely reproduces it because something has always warmed the cache.

1. When you add a user-facing selector in front of an internal fallback, re-audit every readiness check on that path.
2. The "must stay non-blocking" argument usually doesn't carry over: an explicit choice runs the probe only on requests that asked for it. One short blocking probe beats a wrong answer.
3. Keep both variants; the sampler still wants the cheap cached read.
4. Any downgrade on the explicit path must be DISCLOSED in the output. A silent downgrade makes a broken feature look merely unhelpful.
5. Test by asserting the dependency was reached on the FIRST request. A warm-cache test passes against the broken code.

## Stamp a Per-Request Marker in the Shared Builder, Not at Each Call Site

When several code paths (route, retry route, startup recovery, cron) build the same outbound request, a new per-request field (routing marker, tenant id, model selector, trace header) belongs inside the ONE function they all already call. Stamping it at each call site invites the case where three paths honour it and the fourth silently doesn't, still returning HTTP 200 and plausible output.

1. Count call sites BEFORE choosing where to put a new request field. Three or more means find the choke point.
2. If the choke point can derive the value itself (from the row it is already scoped to), prefer that over adding a parameter, which just moves the omission one level up.
3. A mirror of that function in another runtime (e.g. a plain-JS copy a cron uses because it cannot import from the source tree) needs the same change in the same commit, with a note on both.
4. The choke point now carries the whole guarantee, so give it its OWN tests, including the degraded case: reading a column that may not exist yet must fall back, not throw.
5. Ordering can be load-bearing. If the receiver strips markers and then classifies by a prefix, anything wedged between the marker and that prefix reclassifies the request. Assert adjacency, not just presence.

## A Worktree Inside the Repo Makes the Test Runner Count Every Test Twice

If worktrees are created inside the repo (e.g. `.claude/worktrees/<n>`), Vitest and any runner that globs the working tree (jest, pytest, `go test ./...`) discover every test file TWICE. The symptom is a baseline that is an exact 2x multiple of the truth (e.g. `34 files / 988 tests` vs a real `17 / 494`), so an honest branch count looks like a huge regression. The doubled run is fully green, and a baseline taken in the same batch as `git worktree add` can already be poisoned.

Take baselines from a checkout OUTSIDE the repo tree:

```bash
git worktree add --detach /tmp/<name> <ref>
cd /tmp/<name> && ln -s /path/to/repo/node_modules node_modules
npx vitest run
```

Tripwire: compare the reported test FILE count against `find . -path ./node_modules -prune -o -name '*.test.*' -print | wc -l`. Any exact-2x ratio between two test counts is this bug until proven otherwise. Remove in-repo worktrees when the session ends (`git worktree remove`).

## A Negative Assertion Passes Vacuously When the Harness Produced No Positive

"X must NOT appear in the output" passes whenever there is no output at all. Two common ways this happens:

1. **The subject under test dies before emitting anything.** Running an OLD code path for discrimination, the harness does `echo "COMPLETE=$VAR"` under `set -u`; the old code never sets `VAR`, the subshell aborts, output is empty, and the "does not leak" test passes against the very bug it was written to catch. Use `${VAR:-unset}` in harnesses.
2. **The fixture eats the string being searched for.** A generated stub like ``echo "- **repo**: `claude/auto-x`"`` runs the backticked text as a command substitution inside double quotes, so the name vanishes. Escape backticks or single-quote the echo.

Rules:
- For every "X is absent" assertion, run the harness against a case where X SHOULD be present and confirm it fails.
- Print the captured output on failure.
- Use `${VAR:-default}` in harnesses even when the current code always sets VAR; the harness exists to run against versions that don't.
- When generating a fixture script from a shell string, check for backticks, `$`, and quotes interpreted at the wrong level. Read the generated file.

## A Build That Imports Every Module Runs Any Script's Top-Level `process.exit`

A validator that imports every module to prove the wiring holds also executes anything those modules do at import time. A CLI script that runs at module scope and ends with `process.exit(0)` terminates the build early: it prints the script's output, exits 0, and validates nothing. This is worse than a failure because it reports success.

- Guard every script's `main()` with `import.meta.url === pathToFileURL(process.argv[1] || '').href` so it is inert when imported.
- Have the validator ASSERT that guard exists in every file under `scripts/`. A convention nobody checks decays; test the check by deliberately removing a guard.

Related: `npm run build | tail -2` takes the exit code from `tail`, not the build, so a `&&` chain continues past a failure. Check exit codes unmasked (or use `set -o pipefail`).

## Benchmark a Generation-Behavior Flag on the Hard Cases, Not One Easy Call

A flag like enabling "thinking" on a small local model can look free on a single easy call (same tokens, same latency, because constrained decoding caps the final output) while across a full suite it drops accuracy and multiplies p50 latency by over 20x, with some cases timing out. The grammar caps what the model finally writes, not the reasoning before it; the easy case had nothing to reason about.

Rule: never promote a config/flag change on a single hand-picked call, especially one that alters generation or reasoning behavior. Re-run the whole benchmark suite and diff against the recorded baseline. The regression is often invisible in any individual response and only shows up in aggregate.

## Extracting JSON from an LLM Response: Match the First Balanced Array, Not Greedily to the Last Bracket

`result.match(/\[[\s\S]*\]/)` spans from the first `[` to the LAST `]` in the response. If the model wraps its array in a fence or appends a note containing any bracket, the match overshoots, `JSON.parse` throws, and a catch that returns `[]` silently drops the whole batch even though a valid array was present.

Fix: try `JSON.parse` on the trimmed, fence-stripped text first; fall back to a string-aware first-balanced-array scan: walk from the first `[`, track bracket depth, skip characters inside `"..."` literals (honoring `\"` escapes), and return the substring when depth returns to 0. This is identical on clean input and recovers the array from any trailing noise. Test fence-wrapped, prose-wrapped, and trailing-bracket-noise inputs.

**Self-review trigger:** any first-open-to-last-close regex (`/\[[\s\S]*\]/`, `/\{[\s\S]*\}/`) over free-form LLM or CLI text. Ask "what if the model appends one more bracketed character after the real end?"

## `tsx` Scripts: a Dynamic Import Cannot Destructure a `type` Member

Test scripts run under `tsx` (compiled to CJS, no top-level `await`) often delay a module's import with `await import(...)` inside `main()` so they can first set an env var the module reads at load time (e.g. `DB_PATH`). Writing `const { fn, type Foo } = await import("../src/lib/x")` fails with esbuild's `Expected "}" but found "Foo"`, because the `type` modifier is only valid in a static import statement.

Fix: hoist the type to a top-level `import type { Foo } from "../src/lib/x"`. Type-only imports are erased at compile time and carry no runtime side effects, so they are safe above the env-var setup. Keep only runtime values in the dynamic-import destructure.

## Headless-Smoke-Test a Static Page via Raw CDP (No Puppeteer)

If puppeteer isn't installed, you can still drive headless Chrome with zero npm installs using the DevTools Protocol and Node 22's global `WebSocket`:

1. Launch `google-chrome --headless=new --no-sandbox --remote-debugging-port=N --user-data-dir=/tmp/<dir> about:blank`.
2. Poll `http://127.0.0.1:N/json/version` for `webSocketDebuggerUrl` and open a WebSocket.
3. `Target.createTarget` then `Target.attachToTarget({flatten: true})` to get a sessionId; send `Page.enable` and `Runtime.enable`.
4. Use `Runtime.evaluate({expression, returnByValue: true})` to click (`element.click()`) and read DOM state.
5. Subscribe to `Runtime.consoleAPICalled` (type `error`) and `Runtime.exceptionThrown` to assert zero JS errors.

Serve the directory with a tiny `node:http` static server so relative CSS/JS load. Gotcha: CSS `:last-of-type` matches by TAG, not class, so `.msg:last-of-type` fails when the last div sibling has a different class; use `[...document.querySelectorAll('.msg')].pop()` instead.
