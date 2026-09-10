<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards that extend the core behavioral rules.

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
- **Verify the actual artifact, run the real code path, never a reimplementation of it.** An isolated check once used `open(file)` while the real script read the same data from stdin; the paraphrase passed while the real path was dead (a heredoc had shadowed stdin). Testing a rewrite of the logic gives false confidence; drive the shipped script/function itself.

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

Shell scripts that alert (webhook, email, HTTP callback) need their alert path tested, and the instinct is to drop a fake `curl` earlier on `PATH`. **This silently measures nothing** whenever the script hardens its own `PATH`, which cron-safe scripts typically do:

```bash
export PATH="$(dirname "$(command -v node)"):$PATH"
```

That prepends `/usr/bin`, so the system `curl` wins the lookup and the stub is never called. The test then passes for the wrong reason: zero alerts recorded, interpreted as "suppression works." Verified live: the first harness for an auth-probe script reported all-pass while observing nothing at all.

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

**Why it matters:** Without this, CI stays red indefinitely even though the test logic is correct; the failure is at the import layer, not test execution. A real project's CI stayed red for over two weeks for exactly this reason.

### Factory Pattern for Dependency Injection

For servers with external dependencies (third-party API clients, webhooks), export a factory:

```javascript
export function createServer(deps = defaultDeps) {
  const app = express();
  // Use deps.apiClient, deps.config, etc.
  return app;
}
```

Tests inject mocked dependencies without module-level patching. Guard auto-start behind the `import.meta.url` check so the factory can be imported without side effects.

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
    branches: [main]        # or [master], match the repo's default branch
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
- Pin Node.js to the current LTS (22 as of this writing). Node 20 reached EOL on April 30, 2026; repos still using Node 20 in CI should migrate. Don't use `node-version: 'lts/*'` as it can shift unexpectedly.
- Name the file `test.yml`, not `ci.yml`, and keep the name consistent across repos.
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

The output tells you exactly which testing layer to invest in.

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
- **Do not mock the database.** Mock/prod divergence is the #1 source of false-green tests

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

Mocks that diverge from production are worse than no mocks; they give false confidence.

- **Record real responses** from staging/production as mock fixtures. Re-record periodically
- **Validate mock shape** against the real API schema on every CI run
- **Never hand-write mock data** for external APIs; use recorded fixtures
- **If a mock test passes but the feature is broken in prod**, the mock is the bug: fix the mock, not the test

## Cross-Layer Invariant Tests

The highest-value tests are often not about individual functions; they're about **invariants between layers** that silently break when one layer changes without updating the other.

### What Are Invariants?

An invariant is a property that must hold for the system to work, even though no single function enforces it. Examples:

| Invariant | Producer | Consumer | What Breaks |
|-----------|----------|----------|-------------|
| Stores must have lat/lng | Pipeline creates stores | Trip planner filters by `storesWithCoords` | Pipeline creates stores without coords → trip planner returns 0 plans |
| Price records must include unit | Pipeline ingests prices | UI formats as `$2.99/lb` | Missing unit → UI shows `$2.99` with no context |
| List items serialize to JSON | Frontend `setItems()` | Backend PATCH `/api/lists/:id` | Shape mismatch → silent data loss on save |
| API response includes store name | Backend joins tables | Frontend sparkline display | Missing join → UI shows price with no store attribution |

### When to Write Invariant Tests

Write an invariant test whenever:
1. **You just fixed a cross-layer bug.** The fix goes in the code; the invariant test goes in the test suite. This is the regression test for the *class of bug*, not just the specific instance.
2. **One system produces data another consumes.** Pipeline → database → API → UI. Each boundary is an invariant.
3. **A filter or query depends on data shape.** If `WHERE lat IS NOT NULL` is used anywhere, test that the data producer always sets lat.
4. **Display formatting depends on API response shape.** If the UI expects `storeName` in the response, test that the API actually returns it.

### How to Write Them

Invariant tests don't need a database. Test the **contract**: the shape and constraints of data flowing between layers:

```typescript
describe("Pipeline → Trip Planner invariant", () => {
  it("pipeline-created stores must have coordinates", () => {
    // This is the shape the pipeline produces
    const store = createPipelineStore("acme-grocer", "94102");
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
- `pipeline-stores.test.ts`: pipeline → database shape
- `price-display.test.ts`: API response → UI formatting
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

Every Next.js API route that parses input with Zod **must** catch `ZodError` and return a 400 response. Without this, Zod validation failures bubble up as unhandled exceptions → 500 Internal Server Error, which hides the real problem from the client.

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

**When adding a new Zod-validated endpoint**, always include the ZodError catch. When auditing an existing codebase, check that *every* route using `.parse()` has this handling; it's easy to miss one (a single endpoint out of a dozen otherwise-correct ones is the typical shape of this gap).

## Live Browser Testing

For testing web apps in a real browser during development, prefer driving a real browser session over headless when the goal is to see what the user actually sees: real cookies, real session, real rendering.

**When to use:** Integration testing, debugging UI issues, verifying deployed changes, form fill testing.

A minimal command vocabulary worth having, whatever the driver:

```
tabs                                # confirm a tab is connected
navigate "http://localhost:3000"
state                               # read page: buttons, inputs, errors
click "Submit"
assert-text "Success"
console                             # check for errors
```

Make the commands synchronous (send + block for result) so a test script reads top to bottom.

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

**Why:** a verification script grepped test output for "FAIL" to detect failures. A refactor added error-handling tests with names containing "error", causing every subsequent verification run to false-positive as a build failure regardless of actual test results.

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

If a module (e.g., `db.ts`, `prisma.ts`) runs `new PrismaClient()` or reads a required env var **at module load time**, any test file that imports it will crash the entire vitest runner before any test executes. CI shows a cryptic initialization error rather than a test failure, and the repo CI can stay red for weeks with no obvious cause.

**Example:** a test file imports `db.ts`; `db.ts` calls `new PrismaClient()` at the top level; Prisma throws when `DATABASE_URL` is unset.

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

When a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it. Leaving focus on `document.body` is a WCAG 2.4.3 (Focus Order) violation; keyboard users lose their place in the tab order after every modal interaction.

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

**Why:** an image lightbox left focus on `document.body` after every close, silently breaking keyboard traversal of all surrounding cards. None of the visual tests caught it; explicit close-path tests did.

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

**Self-review trigger:** Any numeric guard for a measured/physical quantity (distance, duration, speed, count, price) that comes from an external source: use `<= 0`, not `!x`/`=== 0`. Check that all adapters for the same domain use consistent guard forms.

**Test to write:** `expect(fn(1000, -100)).toBeUndefined()`, verify the negative case explicitly alongside the zero case.

**Why:** a pace helper returned `-12.5` for `computePace(8000, -100)` because the guard `!durationSec || durationSec === 0` passed the negative through. A malformed webhook payload could reach this path. A sibling adapter in the same file used `speed <= 0` correctly; the inconsistency between two sibling adapters was the tell.

## Batch Loop Resilience: Isolate Per-Item Failures

When a loop processes a batch (DB rows, files, API records) and each iteration runs an operation that can throw on bad data, an unguarded throw aborts the ENTIRE batch, not just the bad item.

**Two-layer defense:**
1. **Guard the throwing operation itself:** compile `new RegExp(external_pattern)` in a try/catch that returns null on SyntaxError; wrap `JSON.parse(external_file)` in try/catch; check for zero before dividing by an externally-sourced delta.
2. **Wrap each loop iteration** in try/catch + continue so one bad record is skipped, not fatal.

```javascript
// WRONG: one malformed regex aborts ALL detection
function detectAll(items, templates) {
  for (const tmpl of templates) {
    const re = new RegExp(tmpl.pattern);  // throws SyntaxError on bad pattern
    // ...
  }
}

// RIGHT: guard the throw; isolate per-item failures
function safeCompile(pattern) {
  try { return new RegExp(pattern); } catch { return null; }
}

function detectAll(items, templates) {
  for (const tmpl of templates) {
    try {
      const re = safeCompile(tmpl.pattern);
      if (!re) continue;
      // ...
    } catch (err) {
      console.warn(`Skipping template ${tmpl.id}:`, err.message);
      continue;
    }
  }
}
```

**Self-review trigger:** Any `new RegExp(non-literal)`, `JSON.parse(file/network)`, or division by a data-derived value inside a loop → ask "does one bad input abort the whole batch?" Also: compile invariant regexes once before the loop, not per-iteration.

**Why:** an auto-detection endpoint compiled `new RegExp(template.pattern)` from stored template strings inside a loop with no guard. One malformed pattern threw SyntaxError and 500'd the endpoint for ALL records. Same shape recurs with `JSON.parse` on metadata files and interpolation with zero-divisor timestamps.

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (you're compensating for missing integration tests; push coverage down the pyramid)
- Tests without a corresponding past incident (speculative tests have low ROI and high maintenance cost)

### Test a statistic at both sample parities or an even-length median bug survives
A digest scanner computed a median as `sorted[Math.floor(len / 2)]` at five call sites. That is correct only for ODD-length samples; on an even-length sample it returns the upper-middle element instead of averaging the two middles, so the reported median is systematically **>= the true median and never below it**. Measured over 20k simulated pools: 41% of samples wrong, mean overstatement +0.54%, worst +3.42%, zero understatements.

**Why the existing tests did not catch it, two distinct failures:**

1. **Every test used an odd-length sample** (5 values), the exact case where the buggy and correct expressions agree. The parity of a sample is part of a statistic's input space, just like empty / single / unsorted. If you only test odd, an even-length off-by-one is invisible.

2. **Three tests DID use even-length samples but asserted the wrong thing.** They checked row counts, an average, and the mere presence of the substring `'median'` in rendered output, never the computed value. They passed against the wrong number and read as coverage. Asserting that a field is *present* is not asserting it is *correct*.

**One-sided error is worse than noisy error.** Because the biased median was also the yardstick a scoring function measured every item against (banded credit for being 'below median'), the inflation did not average out: it made everything look better than it was and pushed items over a selection threshold. A bug that errs in one direction only will bias every downstream decision the same way, so rank it above a symmetric rounding error, not below.

**Checklist when reviewing or writing any summary statistic (median, percentile, quartile, trimmed mean):**
- Test odd length, even length, single element, empty, and unsorted input.
- Assert the computed VALUE, not that the field rendered.
- Confirm the sort is numeric (`(a, b) => a - b`); `Array#sort`'s default is lexicographic, so `[90, 1000, 200]` sorts to `[1000, 200, 90]`.
- Check whether the helper mutates its input (in-place `.sort()` on a caller's array is a common silent side effect).
- If the statistic feeds a threshold or band, add a test at the DECISION level (does the item cross the gate?), not only at the helper level. That is the test that shows the bug matters.

## A fix proven on one app's corpus is NOT proven for a sibling app

Before sharing a module across sibling apps built from the same template, run it over the sibling's OWN stored production rows and read the diff by hand. "Same defect" does not mean "same data shape."

Porting a text-preamble stripper between two sibling apps: the module was verified against the first app's full corpus (118 documents, 104 split, 0 content lost) and both siblings had the identical defect, so a verbatim copy looked obvious. Measured against their corpora it would have been actively harmful twice over. Recall: the first app's pattern list split only 20 of the sibling's 46 documents, because the sibling's phrasings were never in the original's wording. Precision, the worse half: the first app's preamble is pure editor monologue so peeling everything above the first heading is safe there, but the sibling mixes narration and real content in ONE paragraph, and the same peel buried a permanent-closure notice, the current time, stated assumptions, and a top-line recommendation.

- **Audit precision, not just recall.** Recall is easy to eyeball ("did it fire?"). Precision means reading what got REMOVED. Here the split-rate went up while the output got worse.
- **Change the shared module and re-verify the original to parity**, rather than forking it per app. The original was held to byte-identical output, proven by rendering all 61 shareable production documents on the old and new builds and diffing them (61/61 identical).
- **A guard that hides rather than deletes still needs this scrutiny.** "Nothing is discarded, it just moves to a collapsed disclosure" is what made the coarse version feel safe, and is exactly why the damage would have been invisible: the page still renders, the tests still pass, nothing logs an error.

## A hand-built fixture never tests the loader

When a config file gains a field, add at least one test that goes through the **real loader**: write a temp config, load it, assert the consumer sees the value. Testing the consumer with a hand-built object leaves the plumbing completely uncovered.

A billing config gained a top-level `upgradePlan`. `validatePlans()` destructured it, validated it, then returned `{plans, defaultPlan}` **without it**. Every consumer therefore saw `undefined` and no upgrade button rendered anywhere in production. All four unit tests for the feature were green throughout, because each constructed the catalog object literally and handed it to the pure resolver, so nothing ever called the loader. The defect lived exactly in the seam the tests skipped, and it was found by curling the live endpoint after deploying.

This generalises to any parse/validate/transform layer. A dropped field is invisible to both the unit suite (which never runs the transform) and the type checker (the object is still structurally valid, just missing an optional property). At least one test must cross the boundary.

### A measurement rig fails the same ways the thing it measures does; check it is measurable BY CONSTRUCTION before collecting
Two failures from an experiment rig, both in the rig rather than the subject.

1. UNMEASURABLE BY CONSTRUCTION. Candidates were selected for 'never read in 4,225 sessions', then the metric was 'recall on reads'. Expected observations in the 14-day window: 0.00. Two weeks of empty logs would have read as 'the retriever is safe' when all it proves is that you picked entries nothing reads. Before collecting, compute the EXPECTED number of observations under the null. If it rounds to zero, the metric is decoration.

2. THE RIG IS A SYSTEM TOO. Mid-audit a second demand signal seemed to justify cutting the candidate set, and the cut was applied before running a control. The control killed it: 91 of 99 matching blocks were inside tool results, i.e. a read file's own `[[wikilinks]]` echoed back in a staleness notice. It was a correlation with the measurement's own reads.

CONSEQUENCE: version-stamp the rig. Hash the matcher source + input sets + thresholds into every record, and make the scorer REFUSE to average across versions rather than silently mixing them. Without this, a rig that changed 4x in one day produced a '0% recall' artifact while the then-current matcher fired correctly on the exact prompt it was scored as missing.

PROPORTIONALITY: stop when rig effort exceeds the prize. Somewhere around the third rig correction, "let it collect and read it once" beats a fifth fix.

## A metadata-only log is still replayable: rejoin it to the transcripts

A shadow/telemetry log that deliberately omits sensitive fields looks untestable, and "I can't regression-test this until it collects the real thing" feels forced. Usually it is wrong: **the omitted field is often still sitting in a second store that kept it for an unrelated reason.**

Concrete case. A shadow log records, per prompt, which memories a matcher would have surfaced plus the prompt's **length**, never its text, by design, so the log carries nothing sensitive. That is exactly the field a replay needs. But the text is still in the session transcripts on disk, so the records rejoin on:

```
(session_id, |timestamp delta| <= 5s, exact character length)
```

That turned "wait 12 more days" into a 148-case regression test available the same afternoon, and it was the only way to prove a **copied** matcher was byte-identical to a frozen original that could not be imported.

Three rules that generalise:

- **Filter `type:"user"` entries down to real prompts.** Tool results arrive as `type:"user"` too. A long tool output can coincidentally match a prompt's length and replay the wrong text into a test that then passes. Drop any content list containing a `tool_result` block; concatenate only `text` blocks.
- **Assert on exact values, not overlap.** Compare names *and* scores in order. A near-match hides precisely the drift the test exists to catch.
- **Report the recovery rate as part of the result.** 148 of 218 records replayed; the other 70 had no local transcript. Quoting "148/148 passed" without the denominator would imply coverage the test does not have. Where a transcript existed at all, recovery was 97%; that is the honest number, and it is the one that says whether the sample is worth trusting.

### Touch drag needs Pointer Events, and raw CDP touch in tests does not auto-scroll
Two findings from building a drag-and-drop list as a static page.

Building it: HTML5 drag-and-drop (dragstart/dragover/drop) does not fire on touch, so a page built with it is dead on a phone while testing perfectly on a desktop. Use Pointer Events (pointerdown/pointermove/pointerup with `setPointerCapture`) instead, which cover mouse, touch, and pen in one code path. Give draggable elements `touch-action: none` or the browser will start a scroll and never deliver pointermove. Always ship a non-drag fallback (tap-to-select then tap-a-target, plus keyboard keys) because drag is the least accessible interaction on the page.

Also let a release over dead space fall back to the last real drop target hovered during that drag. Gutters between rows and sticky headers are not drop zones, so a release there silently reverts the drag and reads as a broken page.

Testing it: Playwright's `.tap()` and `.click()` auto-scroll the target into view, but raw CDP `Input.dispatchTouchEvent` does not. If either end of a simulated touch drag sits below the fold, the touch lands on nothing and the assertion fails for a reason that has nothing to do with the code. Scroll both ends into the viewport first and assert they are on screen before dispatching, so a layout change fails loudly instead of masquerading as a drag bug. Note that CDP `touchEnd` takes an empty `touchPoints` array; the coordinates come from the preceding `touchMove`.

### A generated page passing a syntax check and a DOM-stub run proves nothing about whether the chart is readable: screenshot it and look
Three real defects shipped past every automated check on a generated chart page: a colour ramp whose every data value landed in one half of the scale (scale was zero-based, data started at 40% of range), an axis label blind-truncated from 'Summer (May to Sep)' to 'Sum', and a 20-bar ranking chart whose bars spanned 1.2 percentage points and were visually identical. All three were found in the first 30 seconds of looking at a screenshot. If headless Chrome is available:

```bash
google-chrome --headless --disable-gpu --no-sandbox --screenshot=out.png file://$PWD/page.html
```

then crop with PIL and read the PNG. Related trap: a guarded try/except import silently swallows config errors, so the build exits 0 having skipped the new page entirely; always confirm the build output literally names your file.

### A bare URL in body text overflows the document without any element's bounding box reporting it; compare scrollWidth to clientWidth per element
Symptom: at a 390px viewport, `documentElement.scrollWidth` was 638. The usual sweep (walk every element, flag any whose `getBoundingClientRect().right` exceeds `clientWidth`) returned an EMPTY list, because the overflowing content is inline text inside a normally-sized block, not an oversized box.

Detect it by comparing `el.scrollWidth` to `el.clientWidth` per element instead:

```javascript
document.querySelectorAll('*').forEach(el => {
  if (el.scrollWidth > el.clientWidth + 1 && el.clientWidth > 0) report(el);
});
```

That walks the chain straight to the culprit (here a CMS excerpt containing a bare `https://` URL with no break opportunity). Fix is `overflow-wrap: anywhere` on the text blocks, not a width or overflow change on the container.

Two follow-ons that are easy to miss:
- Re-test AFTER any client-side re-render. If JS rebuilds the same markup from an API (a live-refresh path), a fix applied only to the server-rendered template leaves the JS-rendered copy broken.
- Verbatim third-party text (CMS excerpts, user content, API descriptions) is where this comes from. Any surface rendering text you did not write needs the wrap rule by default.

### Test design variants against per-variant expectations, not one generic assertion
When a deliverable is N variations of the same thing, a single shared assertion is the wrong test. It either fails variants that are behaving correctly or is weakened until it catches nothing.

A browser smoke test over eighteen portfolio themes reported 14/18 with one generic check (a filter row exists, images are decoded, clicking a card shows a title). All four failures were the test being wrong: one design is a text index that shows no images until hover and deliberately hides the detail header, one is a long scroll with no overlay at all, and three name their filter row something other than `#filters`. Relaxing the assertion until all eighteen passed would have removed its ability to detect a real break.

The fix is a declared expectation per variant (what to click, what must then be visible, how many images are due on load) so each is checked against what it actually is. The table doubles as documentation of how the variants differ. Reading the variant source to build that table is also what proves a "failure" is a design choice rather than a bug.

### Run a throwaway WordPress locally with the SQLite drop-in, no MySQL needed
WordPress themes and plugins can be tested end to end without a database server. WordPress core plus the official `sqlite-database-integration` plugin's `db.copy` drop-in, driven by wp-cli and served by PHP's built-in server, gives a real install in about two minutes.

Sequence: download `latest.tar.gz` and `wp-cli.phar`; unzip `sqlite-database-integration` into `wp-content/plugins`; copy its `db.copy` to `wp-content/db.php` and replace the two placeholders (`{SQLITE_IMPLEMENTATION_FOLDER_PATH}` and `{SQLITE_PLUGIN}`) with the absolute plugin path and `sqlite-database-integration/load.php`; write a `wp-config.php` with dummy `DB_*` constants and real salts; `php wp-cli.phar core install --url=http://127.0.0.1:PORT`; `php -S 127.0.0.1:PORT -t .` in the background.

Local prerequisites: `apt install php-cli php-sqlite3 php-mbstring php-xml php-curl php-zip`, plus `php-gd`, which any media import needs to make thumbnails. `wp-cli eval-file` is the way to drive plugin internals (an importer's batch functions, admin-screen render functions, meta save handlers) that a curl cannot reach, because wp-cli never loads wp-admin: `require ABSPATH . 'wp-admin/includes/admin.php'` and `wp_set_current_user(1)` first.

### A PHP-only default is invisible to JS-rendered markup
A WordPress theme can define a default (a tagline, a label, any copy) and expose it through a PHP accessor, and that default will be correct everywhere PHP prints. It will still come out blank wherever the markup is filled in by JavaScript, because the JS reads the JSON payload the theme printed, and the payload was built from the raw stored value before the PHP accessor ever ran.

Caught while exporting eighteen portfolio designs to WordPress themes: three of the designs paint their tagline from a JS data object, the PHP accessor fell back to the theme constant correctly, and the rendered page showed an empty line. A curl of the front page passed (HTTP 200, markup present); only a browser that ran the script saw the blank.

The fix is to normalise the payload, not the accessor: apply defaults where the data array is assembled, so PHP and JavaScript read the same value by construction. The general rule: when the same value has two readers, put the fallback upstream of both, and test the reader that a curl cannot see.

### A hidden filter button must not hide the work, so split the list the UI reads
When a taxonomy list feeds both a filter bar and something structural (section headings, a proportion strip, a grouping key), hiding a term from the bar by filtering that one list silently drops the items filed under it.

Emit two lists instead: the visible list the selection bar draws, and the full list everything structural reads. Then assert per consumer, in a browser, that hiding a term changes the bar and nothing else: same item count on the page, same number of sections, same number of segments, and reversible.

Seen in a multi-design portfolio export: 18 designs share one payload, 16 only draw the row, but one groups projects under discipline headings and another sizes a proportion strip from the counts. Filtering the single categories list would have made a hidden discipline take its projects off the page in those two. Fix was `cats` plus `catsAll` in the payload, build-time patches with assertions on the two variants, and a feature test checking all 18.

### `git show ref:file > file` truncates the target before git runs, so a bad ref empties the file
When reverting a single file for a discrimination check, never redirect `git show` straight onto the file:

```bash
git show origin/main:server/routes/feed.ts > server/routes/feed.ts   # WRONG
```

The shell creates/truncates the redirect target BEFORE git executes. If the ref is wrong the command fails AFTER the file is already zero bytes, so the fix you were about to prove is silently destroyed and the failure message (`fatal: invalid object name`) looks like nothing happened. This is especially easy to hit because the wrong ref is usually `origin/main` on a repo whose default branch is `master` (resolve it with `gh repo view <slug> --json defaultBranchRef -q .defaultBranchRef.name`).

Safe form: stage through a temp file, and keep a backup of the fixed version first:

```bash
cp path/to/file /tmp/file.fixed.bak
git show origin/master:path/to/file > /tmp/file.orig
cp /tmp/file.orig path/to/file        # run tests: expect only the new tests to fail
cp /tmp/file.fixed.bak path/to/file   # restore
```

Verify the revert actually landed with `git diff --stat <ref> -- <path>` (empty output = reverted) rather than trusting the redirect's exit code. Related: `git stash push` reverts to HEAD, not the merge base, so it stops discriminating once the fix is committed.

### A filter, count badge, or search box over a capped list silently under-reports: compute against the full set
A rendered list capped at N is a rendering decision. A filter, search, or count control wired to that list treats N as a database limit, which it is not. The failure mode is worse than having no control: "No results match" reads as an authoritative statement about the database rather than about the page.

Measured in production: a dashboard capped at 100 rows held 328 visible rows. A "New" filter over the rendered list reported 19 of 33 actually-new rows; 14 fell past the cap and were silently absent, then reported as "no longer listed" because absence is how removal is detected. A fuzzy search over the same 100 rows under-reported on all 15 test queries (one term: 15 matches shown vs 45 in the full set).

Rules:
1. Before shipping any control whose output is a COUNT or a "nothing found" verdict, run it against REAL production data and print "N in the full set vs M in the rendered list" per query. Fixtures and small test accounts pass trivially; the defect only appears at real data volumes.
2. **Two fix shapes, pick by size.** PIN qualifying rows into the capped query when the qualifying set is known server-side and small (a "New" badge: `list(userId, alwaysInclude)` appends any rows the cap dropped). Serve an UNCAPPED endpoint lazily when the query is client-side and arbitrary (a fuzzy search: `GET /api/items?all=1`, invalidated when the primary list refreshes, using the same ORDER BY so clearing the search restores an exact prefix-superset).
3. Re-check any cap whose underlying data set has grown since the constant was chosen. A cap sized for a 50-row account that now holds 300 rows is wrong in a way that only appears at real scale and never fails a test.
4. A cap applied to a concatenation of two semantically different lists (new finds + carry-forwards) drops the kind appended last and silently manufactures false negatives. Cap each kind separately.

### A ranking over a capped list is not a ranking, and clamped weights collapse the ranking you did compute
Adding a sort to a list has failure modes that both look like working software, distinct from the filter/search trap above: a filter shows a COUNT that can be checked against another surface, but a sort shows no number at all and just presents the wrong row first.

1. **The cap.** A dashboard listed rows with `LIMIT 100` while the account had 328 live rows. Making "Best fit" the default sort over that slice means "best fit among the hundred found most recently" while reading as "your best matches." Fix: send the whole set (328 rows was ~130KB of JSON) and paginate the RENDER, not the query. Keep the cap only as a runaway guard.
2. **The clamp.** A heuristic score that clamps to a ceiling ties every strong item at the cap, and the order among tied items silently falls back to whatever the secondary key is (here, discovery order). The distribution looks fine in aggregate and every unit test passes. Fix: size the positive weights so a perfect item lands EXACTLY on the ceiling and assert that in a test, then verify on real data by printing the score histogram, not just min/max ("distinct scores: 21 over 328 rows, 6 at the ceiling" is the check that catches it).
3. **Replay beats fixtures for a scorer.** Two bugs were invisible to 35 passing unit tests and only appeared replaying a copy of the production database: free-text location comparison ("San Francisco Bay Area or remote (US), no relocation" vs "San Francisco, CA") failed in both directions and penalized entries in the user's own city; a strict contiguous-phrase title filter read a reordered title as a miss. Write the replay script alongside the tests and point it at a COPY (opening the DB runs migrations).
4. **Two sources of a score must stay distinguishable.** When some rows carry a real model judgement and others only an app-side estimate, a missing score must not resolve to 0 (that buries the entire pre-existing corpus at the bottom of the default sort forever), and the estimate must be capped BELOW the model's range so a heuristic can never outrank something that actually read the item. Mark the estimate in the UI; don't store it, since an estimate is only true of the inputs that produced it.

### A headless `claude --print` run inherits the host's CLAUDE.md and SessionStart hooks; isolate before measuring
Any `claude --print` subprocess loads the HOST user's `~/.claude/CLAUDE.md` and fires the host's SessionStart hooks, on top of whatever CLAUDE.md sits in its working directory. A harness that shells out to the CLI to compare prompts, personas, or rules is therefore measuring host-guidance-plus-instruction-set; a deliberately empty control arm is not a control at all.

Confirmed during a 6-way bakeoff on report writing: from a bare temp workspace the CLI answered YES to "does your context contain \<string present only in the host guidance\>", and NO once `CLAUDE_CONFIG_DIR` pointed at a throwaway directory. The rule under test was already live in the host guidance and reaching every arm; the control arm came back clean for the wrong reason.

**Fix:** export `CLAUDE_CONFIG_DIR` pointing at a temp directory that contains only `.credentials.json` (so auth still works) and nothing else (no CLAUDE.md, no rules). Remove it on exit. The workspace CLAUDE.md still loads under isolation; that is the half you want, only the host-global guidance is excluded.

Generalises beyond bakeoffs: any harness that shells out to `claude --print` to compare prompts (eval runners, A/B scripts, parity experiments) has this leak unless it isolates. If there is no credentials file to copy (API-key or keychain auth), fail loud and label the results "host-guidance-plus-recipe" rather than silently measuring the wrong baseline. The judge in a multi-arm test needs the same isolation for a separate reason: a judge that has read the host guidance grades against the rule's author instead of the rubric.

The consequence differs for a headless run that generates or publishes content rather than measures it: instead of an invalid experiment, the leak is host-injected context (journal entries, usage stats, digests) landing inside a published artifact. Any script that rewrites content for publication should isolate by construction, because a rewrite step, unlike a measurement, has no control arm to catch the leak after the fact; it has to be excluded before the run, not detected after.

### Two mutation-testing traps for data-store write paths
When mutation-testing a feature that writes to a data store (cancel, update, status change), two specific assertion forms produce green suites over broken code:

1. **`indexOf` returns -1 for a missing needle, and -1 < every real index.** An ordering assertion of the form `writeAt < abortAt` passes for code that performs NO write at all, because `indexOf('write')` on an empty log returns -1, which is less than any real write index. Assert the needle EXISTS before comparing positions: `expect(log.indexOf('write')).toBeGreaterThanOrEqual(0)`.

2. **An exclusion assertion passes trivially against a recovery pass that selects nothing.** A test that a cancelled row is invisible to recovery (the correct behavior) passes even if the recovery pass has a bug that selects ZERO rows: the cancelled row is not in the zero-row result, so the assertion is vacuously true. Always pair an exclusion assertion with a positive control asserting the normal rows ARE still selected.

### A builder generating a deliverable from source lists must assert every entry appears exactly once before writing

When a deliverable (a spreadsheet tab, a report, a batch of files) must cover every name from a set of source lists, hand-enumerating them will silently drop one, and the omission is invisible in review because nothing errors. Make the builder read the live source lists and assert that every entry appears exactly once in the output before writing anything.

Two failures caught this way: one source name missing from a 149-row output that had been hand-enumerated from 136 source names, and a stale intermediate JSON file (111 rows) whose live counterpart had been corrected to 106; the file on disk never reflected five later reclassifications.

**Rules:**
1. **Read the live artifact, not the cached intermediate.** The live sheet/database/endpoint reflects every correction; a file on disk reflects what it held when last written. When both exist, the live artifact is the authority.
2. **Assert before writing.** A post-hoc check flags the problem after duplicates or omissions are already baked in. The assertion belongs at the generation stage, before anything is written.
3. **Assert two properties independently:** coverage (every source entry appears in the output) and uniqueness (no source entry appears twice). These fail separately: a de-duplication bug leaves coverage passing while uniqueness fails; a missing row fails coverage while uniqueness holds.
4. **Count against the live source, not the last-counted total.** A constant like `EXPECTED_COUNT = 149` drifts as the source grows; the assertion must count the live source at run time and compare.

### A verdict parsed from a tool's stdout format can report all-failures on all-successes; confirm against system state
Uploading 14 documents via a script, a wrapper loop graded each upload by grepping its stdout for a JSON `id` field. The script actually prints a bare id and URL on two plain lines, not JSON; every grep missed, and the loop reported 14 failures and "uploaded: 0/14". All 14 had in fact been created; listing the destination showed exactly 14 items and no duplicates.

The failure mode: a parser mismatched to a tool's real output format produces a CONFIDENT WRONG verdict, and a false negative here is expensive, because the natural recovery is to re-run, which creates duplicates.

**Rule:** when a loop grades each iteration by scraping a tool's stdout, do not trust the tally. Confirm against the system's own state (list the folder, query the API, count the rows) before reporting failure or retrying. Read the tool's actual output contract first; two lines of `head` on the script would have shown the real format.

**Corollary:** a retry is only safe if the operation is idempotent. Creating a new record generally is not.

### A rotted LIVE control is indistinguishable from a detector regression unless a second, independent source is asked
A validation suite pins a known-LIVE control so a detector that has started answering "dead" everywhere is caught. But the control itself expires: the pinned item is removed at the source, the CTRL-LIVE row starts failing, and the output is byte-identical to a real regression. The operator then has to guess, and the cheap guess ("the control probably rotted") is the one that hides a genuine regression. Found in a liveness sweep: a control had rotted, the suite exited 1 with no diagnosis, and the controls file had carried a header comment telling the operator to work it out by hand since the file was written. Nobody had.

The discriminator is a SECOND source that the detector does not itself consult. If the detector reads a JSON API, have the triage read the public HTML instead, where a removed item may answer 200 and land on a root page carrying `?error=true`. Both saying dead means the item really was removed (ROTTED, repin it). HTML still serving the item while the API says 404 means the detector broke (REGRESSION, do not touch the controls). Some sources need a different independent signal because they serve live and removed items at the same 200 URL: there, a real item is server-rendered (58KB) and a removed one leaves the bare SPA shell (7KB).

Second failure in the same file: a CTRL-BADTOKEN control existed to prove that a wrong-but-real API token yields a confident wrong "dead". Its target had also been removed, so the row passed because the item was gone rather than because the token was wrong. It had stopped testing anything while still showing green.

How to apply: any control whose expected verdict is the PERISHABLE one (live, present, in-stock, reachable) needs automated rot-vs-regression triage, not a comment telling a human to check. Validate the triage on its own live/dead/garbage controls before trusting it, and make the failure message name the cause and hand back a replacement. Separately, audit controls that pass: a control can go green for the wrong reason, and unlike a red one, nothing prompts anyone to look.

### Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes; assert on textContent
Asserting that a label override reached an SVG-based artifact with `locator('svg text').allInnerTexts()` reports empty strings for every node, so a passing render looks like a failure.

Why: `innerText` is an HTMLElement property. `SVGElement` does not implement it, and Playwright's innerText helpers fall back to an empty string rather than throwing.

How to apply: read SVG copy with `evaluateAll(els => els.map(e => e.textContent))`. Same class of false negative as any case where the assertion mechanism fails rather than the product.

### A stale-tolerant cached health probe is correct for a sampler and wrong for an explicit user choice
A cached readiness probe that returns the last known state and refreshes in the BACKGROUND has a documented cost of "one request": the first call after a cold start or an idle gap answers from a stale value. That trade is correct while the only consumer is an automatic sampler or a fallback, because a miss lands silently in the other arm and nobody was promised anything.

The moment a USER can select that dependency, the same probe becomes a user-visible lie. Found while adding a picker between a hosted model and an on-device engine: the readiness cache initialises to `false`, so the FIRST on-device request after a restart or a 30s idle gap would answer from the hosted path and tell the user the engine they picked was unavailable, while the local gateway was up the whole time. Staging never reproduces it, because something has always warmed the cache by the time anyone looks.

Rules:
1. When you add a user-facing selector in front of an existing internal fallback, re-audit every readiness/health check on that path. The check was sized for a consumer that could not be disappointed; the new one can.
2. The "must stay non-blocking" argument usually does NOT carry over. It was justified by the probe running on EVERY request; an explicit choice runs it only on requests that asked for that dependency, and those callers already opted into a different path. One 4s probe beats a wrong answer about which engine ran.
3. Keep both variants rather than converting the shared one. The sampler still wants the cheap cached read.
4. Any downgrade on the explicit path must be DISCLOSED in the output. A silent downgrade is the worst outcome available: the control appears to work, the other engine answers, and nothing says so, so the user cannot tell the feature is broken from the feature being unhelpful.
5. Test it by asserting the dependency was reached on the FIRST request, not just that some request reached it. A warm-cache test passes against the broken code.

### Stamp a per-request marker in the shared builder every path already calls, not at each call site
When several code paths produce the same outbound request shape, a new per-request field (routing marker, tenant id, engine/model selector, trace header) must be stamped inside the ONE function they all already call, not prefixed at each call site.

Concrete case: a follow-up request is answered from four places (the main route, its retry route, a startup-recovery pass, and a 5-minute cron) and all four build their payload with the same context builder. Adding an `[ENGINE:hosted|local]` prefix at each would have been four edits with no shared assertion, which is exactly the shape where three paths honour the user's choice and the fourth quietly uses something else. Nothing in a diff, a test, or a health check distinguishes that from working: the answer is still HTTP 200 and still plausible prose. Putting the marker in the builder makes the field part of the contract instead of something each caller has to remember, and any future fifth path inherits it.

Rules:
1. Count the call sites BEFORE choosing where to put a new request field. Two is a judgement call; three or more means find the choke point.
2. If the choke point can derive the value itself (read it off the row it is already scoped to), prefer that over adding a parameter; a parameter still has to be passed correctly at N sites, so it only moves the omission one level up.
3. A plain-language mirror of that function in another runtime (a cron's plain-JS copy that cannot import from `src/`) needs the same change in the same commit, and a note on both saying so.
4. The choke point now carries the whole guarantee, so it needs its OWN tests rather than incidental coverage through one caller. Include the degraded case: reading a column that may not exist yet must fall back, not throw, or one un-migrated database takes down every path at once.
5. Ordering can be load-bearing. Here the marker had to lead AND stay adjacent to the prefix the receiver detects the request type by, because the receiver strips markers before classifying. Anything wedged between silently reclassifies the request: wrong mode, wrong cost, same 200. Assert adjacency, not just presence.

### A worktree created inside the repo makes the test runner double-count every test file, inflating the baseline exactly 2x
If you create worktrees at a path INSIDE the repo (e.g. `.claude/worktrees/<n>`), Vitest (and any runner that globs the working tree: jest, pytest, `go test ./...`) then discovers every test file TWICE, once in the real tree and once in the nested worktree copy.

Symptom: a baseline that is an exact 2x multiple of the truth. In one such session the first baseline read `34 test files / 988 tests`; the real number at the same commit was `17 / 494`. The branch's honest 505 would have been reported as a 483-test regression.

Two things make this hard to catch:
- The doubled run is fully GREEN, so nothing draws attention to it.
- It only appears once you create the worktree, so a baseline taken in the same breath as `git worktree add` is already poisoned. In one run the baseline command and the worktree-add ran in the same parallel batch, and the worktree won the race.

Rule: take baselines from a checkout OUTSIDE the repo tree.

```bash
git worktree add --detach /tmp/<name> <ref>
cd /tmp/<name> && ln -s /path/to/repo/node_modules node_modules
npx vitest run
```

Cheap tripwire: compare the reported TEST FILE COUNT against `find . -path ./node_modules -prune -o -name '*.test.*' -print | wc -l`. If the runner reports double, you are globbing a worktree. Any exact-2x ratio between two test counts is this bug until proven otherwise.

Corollary: remove the in-repo worktree when the session ends (`git worktree remove`), or every later session in that repo inherits the doubled count.

### A negative assertion passes vacuously when the harness never produced the positive
A test of the form "X must NOT appear in the output" passes trivially whenever the harness produced no output at all. Green means nothing until you have confirmed the harness can see a positive. Hit twice in one session, both times on the SAME test suite:

1. **The subject-under-test died before emitting anything.** The suite ran the OLD code path to prove discrimination. The old script never sets `DEDUP_COMPLETE`, so the harness's `echo "COMPLETE=$DEDUP_COMPLETE"` aborted the subshell under `set -u`, output was empty, and "timed-out scan does not leak its partial branch list" reported PASS against the very code whose bug it was written to catch. Fix: `${VAR:-unset}` in the harness, so a version lacking the variable entirely still gets its output inspected.

2. **The fixture silently ate the string being searched for.** A generated stub did ``echo "- **repo**: \`claude/auto-x\`"``, backticks inside double quotes, so the branch name ran as a command substitution and vanished. The "must not leak" assertion again passed, for the wrong reason. Fix: escape the backticks or single-quote the stub's echo.

Rules:
- For every "X is absent" assertion, run the harness against a case where X SHOULD be present and confirm it fails. A negative test with no matching positive test is not evidence.
- Print the captured output on failure. Both bugs were invisible until the harness echoed what it had actually captured.
- Use `${VAR:-default}` in test harnesses even when the code under test always sets VAR. The point of the harness is to run against versions that do not.
- When generating a fixture script from a shell string, check for backticks, `$`, and quotes that will be interpreted at the wrong level. Read the generated file, do not assume it says what you wrote.

Related: verify each regression test individually rather than trusting a green suite, and confirm which assertions actually discriminate versus merely guard existing behavior.

### A build that imports every module runs any script's top-level process.exit, silently skipping its own checks
A validator that imports every module to prove the wiring holds will also execute anything those modules do at import time. A CLI script under `scripts/` that ran its work at module scope and finished with `process.exit(0)` ended `npm run build` early: the build printed the script's output, exited 0, and validated nothing at all.

This is worse than a failing build, because it reports success. The signal is subtle: the build output looks wrong (it is the script's output, not the validator's) but the exit code is 0, so every automated caller treats it as passing.

Two-part fix, and the second part is the one that lasts:
- Guard every script's `main()` with `import.meta.url === pathToFileURL(process.argv[1] || '').href` so it is inert when imported.
- Have the validator ASSERT that guard exists in every file under `scripts/`. A convention nobody checks is a convention that decays; the check is three lines and it caught the regression immediately when tested by deliberately removing the guard.

Related trap in the same session: piping a build to `tail` (`npm run build | tail -2`) takes the exit code from `tail`, not the build, so a `&&` chain continues past a failure. Check exit codes unmasked before believing a build passed.

### A config flag that alters generation behavior must be benchmarked on the hard case, not the easy one
Enabling a "thinking" flag for a small local model was validated on a single easy classification call: 11 tokens and 0.37s either way, because grammar-constrained decoding capped the output length regardless of the flag. It looked strictly free.

Across the full 27-case suite it was not free at all: 23/27 correct dropped to 19/27, p50 latency went from 855ms to 20523ms, and two cases hit a 120s timeout outright. With thinking enabled the model reasons at length BEFORE emitting the constrained answer, and the grammar only caps what it finally writes, not the monologue before it. The one easy case was easy precisely because there was nothing to reason about, so it exercised the cheapest possible path through the change.

Rule: never promote a config/flag change on a single hand-picked call, especially one that alters generation/reasoning behavior rather than a fixed computation. Re-run the whole benchmark suite and diff against the recorded baseline instead of eyeballing whether the output looks right; the regression here was invisible in any individual response (every answer still looked fine), it only showed up as fewer correct answers taking 24x longer in aggregate.

### Extracting a JSON array from an LLM response: match the FIRST balanced array, not greedily to the LAST bracket
A batch categorizer parsed a model response with `result.match(/\[[\s\S]*\]/)` to pull out the JSON array the prompt asked for. That regex is greedy: it spans from the first `[` to the LAST `]` anywhere in the response. The model was asked for "ONLY a JSON array, no explanation" but occasionally wrapped it in a markdown fence or appended a trailing note; any bracketed character after the real array's close (a fence artifact, a stray `[done]`) pulled the match past the array's true end, `JSON.parse` threw on the corrupted string, and the catch path returned `[]`, silently dropping the entire batch (up to 100 records) with only a console log, no thrown error.

This is a distinct failure shape from "Batch Loop Resilience" above: there the batch is many independent items and one bad item kills the rest; here the "batch" is a single LLM response and the extraction regex itself overshoots, so the loss is total (0 recovered) even though a valid array was present in the text.

Fix: don't greedily regex-match to the last bracket. Try a direct `JSON.parse` of the trimmed/fence-stripped text first (works for clean output), then fall back to a string-aware first-balanced-array scan: walk from the first `[`, track bracket depth, and skip over characters inside `"..."` string literals (honoring `\"` escapes) so a `[` or `]` quoted inside a string value doesn't corrupt the depth count. Stop and return the substring the moment depth returns to 0. This is strictly more permissive than the greedy regex (identical result on clean input) and recovers the array from any noise trailing it.

**Self-review trigger:** any regex extracting a JSON array/object from free-form LLM or CLI text (`/\[[\s\S]*\]/`, `/\{[\s\S]*\}/`, or similar "first-open-to-last-close" patterns), ask "what happens if the model appends one more bracketed character after the real end?" This applies anywhere a CLI response is parsed for structured output outside a hard `--output-format json` mode.
