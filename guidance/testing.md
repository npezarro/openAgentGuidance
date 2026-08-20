<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards that extend your core agent rules.

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

A fallback/waterfall (try A, else B, else C) is the highest-risk structure for a **silent miss**: if an early rung dies, a later rung catches everything and the end-to-end result still looks correct, so nothing appears broken. The dead layer is invisible until the day the layer below it also fails. A token refresh once ran at 0% success for weeks behind a fallback that kept the end state healthy.

- **Test each rung/branch on its own**, with an input it MUST handle, not just the end-to-end happy path. If rung 1 is supposed to handle server-rendered pages, prove it does with the *later rungs disabled* (a `--max-rung`/`--from-rung`-style flag, a forced-branch fixture, dependency stubs). End-to-end green is necessary but not sufficient.
- **Ship a canary** for any fallback you rely on: assert the winning rung, not just that content came back. If rung 1 stops winning on a case it owns, fail loudly.
- **Verify the actual artifact, run the real code path, never a reimplementation of it.** An isolated check once used `open(file)` while the real script read the same data from stdin; the paraphrase passed while the real path was dead (a `python3 - <<HEREDOC` invocation had shadowed stdin). Testing a rewrite of the logic gives false confidence; drive the shipped script/function itself.

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
// WRONG — hides type errors, triggers no-explicit-any lint warnings
const token = { access_token: "test" } as any;

// RIGHT — typed factory returns a complete object
function fakeOAuthToken(overrides?: Partial<OAuthToken>): OAuthToken {
  return { access_token: "test", refresh_token: "r", expires_at: Date.now() + 3600000, ...overrides };
}
const token = fakeOAuthToken();
```

## Testing Shell Scripts: Don't Stub a Binary on PATH, Stand Up the Real Sink

Shell scripts that alert (webhook, email, HTTP callback) need their alert path tested, and
the instinct is to drop a fake `curl` earlier on `PATH`. **This silently measures nothing** whenever
the script hardens its own `PATH`, which cron-safe scripts typically do:

```bash
export PATH="$(dirname "$(command -v node)"):$(dirname "$SOME_BIN"):$PATH"
```

That prepends `/usr/bin`, so the system `curl` wins the lookup and the stub is never called. The test
then passes for the wrong reason: zero alerts recorded, interpreted as "suppression works." Verified
live: the first harness for an auth-probe script reported all-pass while observing nothing at all.

**Instead, bind a real listener and point the script's own webhook variable at it.** It exercises the
actual `curl` invocation, actual JSON payload, and actual HTTP semantics:

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

- **Always add an `env -i PATH=/usr/bin:/bin HOME=$HOME` case.** Cron's PATH omits `/usr/local/bin`,
  and that presents as exit 127 *before* any logic runs. A suite that only runs under your
  interactive shell cannot see it.
- **Test the state-file upgrade path.** Changing a marker format (bare `touch` → structured) must be
  exercised against the OLD format, or the first deploy inherits broken behaviour during a live
  incident.
- **`curl ... || true` is untestable by construction and unsafe in production**: a revoked webhook
  fails identically to success. Capture the status instead and assert on it:
  `code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 ...)`.

## Making Node.js Servers Testable

When adding tests to a server-side repo, the server often needs minor changes to support isolated testing.

### Auto-Start Guard

Prevent `app.listen()` from firing when the file is imported by tests:

```javascript
// ESM — import.meta.url guard
if (process.argv[1] === fileURLToPath(import.meta.url)) {
  app.listen(PORT, () => console.log(`Listening on ${PORT}`));
}

// CJS — require.main guard
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
      // Dummy URL — db.ts throws at import time if DATABASE_URL is unset.
      // Tests only exercise pure functions and never open a connection.
      DATABASE_URL: "postgresql://test:test@localhost:5432/test",
    },
  },
});
```

**Why it matters:** Without this, CI stays red indefinitely even though the test logic is correct; the failure is at the import layer, not test execution. One project's CI sat red for over two weeks for exactly this reason.

### Factory Pattern for Dependency Injection

For servers with external dependencies (third-party APIs, webhooks), export a factory:

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
    branches: [main]        # or [master] — match the repo's default branch
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
- Pin Node.js to the current LTS (22). Node 20 reached EOL on April 30, 2026; repos still using Node 20 in CI should migrate. Don't use `node-version: 'lts/*'` as it can shift unexpectedly.
- Name the file `test.yml`, not `ci.yml`.
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
| Locations must have lat/lng | Pipeline creates locations | Route planner filters by `withCoords` | Pipeline creates locations without coords → route planner returns 0 plans |
| Price records must include unit | Pipeline ingests prices | UI formats as `$2.99/lb` | Missing unit → UI shows `$2.99` with no context |
| List items serialize to JSON | Frontend `setItems()` | Backend PATCH `/api/lists/:id` | Shape mismatch → silent data loss on save |
| API response includes source name | Backend joins tables | Frontend sparkline display | Missing join → UI shows price with no attribution |

### When to Write Invariant Tests

Write an invariant test whenever:
1. **You just fixed a cross-layer bug.** The fix goes in the code; the invariant test goes in the test suite. This is the regression test for the *class of bug*, not just the specific instance.
2. **One system produces data another consumes.** Pipeline → database → API → UI. Each boundary is an invariant.
3. **A filter or query depends on data shape.** If `WHERE lat IS NOT NULL` is used anywhere, test that the data producer always sets lat.
4. **Display formatting depends on API response shape.** If the UI expects `sourceName` in the response, test that the API actually returns it.

### How to Write Them

Invariant tests don't need a database. Test the **contract**, the shape and constraints of data flowing between layers:

```typescript
describe("Pipeline → Route Planner invariant", () => {
  it("pipeline-created locations must have coordinates", () => {
    // This is the shape the pipeline produces
    const loc = createPipelineLocation("acme", "94102");
    // This is the filter the route planner applies
    const visible = [loc].filter(s => s.lat != null && s.lng != null);
    expect(visible).toHaveLength(1); // Would have caught the bug
  });
});

describe("API → UI invariant", () => {
  it("price history response includes sourceName and unit", () => {
    const response = buildPriceHistoryResponse(priceRecord);
    expect(response).toHaveProperty("sourceName");
    expect(response).toHaveProperty("unit");
  });
});
```

### Naming Convention

Name invariant tests after the boundary they guard:
- `pipeline-locations.test.ts` — pipeline → database shape
- `price-display.test.ts` — API response → UI formatting
- `route-planner.test.ts` — database query assumptions

### Common Patterns Across Projects

These invariants recur in every full-stack project:

1. **Geocoding completeness:** Any entity with lat/lng that gets filtered by location queries must have coordinates populated at creation time.
2. **API response shape:** If the frontend destructures `response.sourceName`, the backend must include it in the SELECT/JOIN.
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

**When adding a new Zod-validated endpoint**, always include the ZodError catch. When auditing an existing codebase, check that *every* route using `.parse()` has this handling; it's easy to miss one (a single endpoint out of a dozen is the usual shape of this gap).

## Live Browser Testing

For testing web apps in a real browser during development, prefer driving a real browser session over headless-only tooling when the goal is to see what a user actually sees: real cookies, real session, real extensions.

**When to use:** Integration testing, debugging UI issues, verifying deployed changes, form fill testing, or any scenario where the rendered result matters more than the DOM assertion.

A minimal command vocabulary for any such harness:
```bash
tabs                            # check a tab is connected
navigate "http://localhost:3000"
state                           # read page: buttons, inputs, errors
click "Submit"                  # interact
assert-text "Success"           # verify
console                         # check for errors
```

**Key detail:** Keep commands synchronous (send + block for result) so a test reads top to bottom without sleep-and-hope.

## Don't Grep Test Output to Detect Pass/Fail

Parsing test runner output with `grep` to determine pass/fail is fragile. A test suite that passes but has a test _named_ "handles errors" or prints "0 failed" will match the wrong pattern and flip your result.

```bash
# WRONG — a passing test named "handles errors" matches the grep and RESULT=FAIL
if npm test 2>&1 | grep -qi "error\|fail"; then
  RESULT="FAIL"
fi

# RIGHT — use the actual exit code; output is only for human-readable detail
TEST_EXIT=0
TEST_OUTPUT=$(npm test 2>&1) || TEST_EXIT=$?
if [ "$TEST_EXIT" -ne 0 ]; then
  RESULT="FAIL"
fi
```

**Why:** a verification script once grepped test output for "FAIL" to detect failures. A refactor added error-handling tests with names containing "error", causing every subsequent verification run to false-positive as a build failure regardless of actual test results.

**Exception:** You can still grep output for metadata extraction (e.g., `grep -oP '\d+ passed'` to surface a human-friendly count in a log line), but never use output grep as the pass/fail gate.

## CI Workflow Gotchas

Two patterns cause repeated CI failures:

### Test Glob Quoting on GitHub Actions

Single-quoted globs like `'test/**/*.test.js'` do NOT expand on GitHub Actions because `globstar` is off by default. The shell passes the literal string to Jest/Node, which may not expand `**` the same way.

**Fix:** Use a flat glob (`test/*.test.js`) or let the test framework handle the pattern:
```yaml
# BAD — glob not expanded, tests silently skipped
run: npx jest 'test/**/*.test.js'

# GOOD — flat glob, works everywhere
run: npx jest test/*.test.js

# GOOD — let jest find tests via config
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

**Why:** An image lightbox component left focus on `document.body` after every close, silently breaking keyboard traversal of all surrounding cards. The bug went unnoticed until explicit close-path tests were written; none of the visual tests caught it.

## Boundary Validation: Non-Negative Quantities from External Sources

When validating numeric values parsed from external input (webhook payloads, API responses, database records, user data), `!x` and `x === 0` guards do NOT reject negative numbers; JS treats negatives as truthy.

```javascript
// WRONG — passes -100 through because !(-100) is false
function computePace(distanceM, durationSec) {
  if (!distanceM || !durationSec || distanceM === 0) return undefined;
  return durationSec / (distanceM / 1000);  // returns -12.5 for duration=-100
}

// RIGHT — rejects non-positive values for physical quantities
function computePace(distanceM, durationSec) {
  if (!distanceM || !durationSec || distanceM <= 0 || durationSec <= 0) return undefined;
  return durationSec / (distanceM / 1000);
}
```

**Self-review trigger:** Any numeric guard for a measured/physical quantity (distance, duration, speed, count, price) that comes from an external source: use `<= 0`, not `!x`/`=== 0`. Check that all adapters for the same domain use consistent guard forms.

**Test to write:** `expect(fn(1000, -100)).toBeUndefined()` — verify the negative case explicitly alongside the zero case.

**Why:** a pace helper returned `-12.5` for `computePace(8000, -100)` because the guard `!durationSec || durationSec === 0` passed the negative through. A malformed webhook payload could reach this path. A sibling adapter in the same file used `speed <= 0` correctly; the inconsistency between two adapters doing the same job was the tell.

## Batch Loop Resilience: Isolate Per-Item Failures

When a loop processes a batch (DB rows, files, API records) and each iteration runs an operation that can throw on bad data, an unguarded throw aborts the ENTIRE batch, not just the bad item.

**Two-layer defense:**
1. **Guard the throwing operation itself:** compile `new RegExp(external_pattern)` in a try/catch that returns null on SyntaxError; wrap `JSON.parse(external_file)` in try/catch; check for zero before dividing by an externally-sourced delta.
2. **Wrap each loop iteration** in try/catch + continue so one bad record is skipped, not fatal.

```javascript
// WRONG — one malformed regex aborts ALL detection
function detectAll(items, templates) {
  for (const tmpl of templates) {
    const re = new RegExp(tmpl.pattern);  // throws SyntaxError on bad pattern
    // ...
  }
}

// RIGHT — guard the throw; isolate per-item failures
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

**Why:** an auto-detection endpoint compiled `new RegExp(template.pattern)` from stored template strings inside a loop with no guard. One malformed pattern threw SyntaxError and 500'd the endpoint for ALL records. The same shape recurs with `JSON.parse` on metadata files and interpolation with zero-divisor timestamps.

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (you're compensating for missing integration tests; push coverage down the pyramid)
- Tests without a corresponding past incident (speculative tests have low ROI and high maintenance cost)

## Test a Statistic at Both Sample Parities or an Even-Length Median Bug Survives

A digest scanner computed a median as `sorted[Math.floor(len / 2)]` at five call sites. That is correct only for ODD-length samples; on an even-length sample it returns the upper-middle element instead of averaging the two middles, so the reported median is systematically **>= the true median and never below it**. Measured over 20k simulated pools: 41% of samples wrong, mean overstatement +0.54%, worst +3.42%, zero understatements.

**Why the existing tests did not catch it, two distinct failures, both worth copying into your own review:**

1. **Every test used an odd-length sample** (5 values), the exact case where the buggy and correct expressions agree. The parity of a sample is part of a statistic's input space, just like empty / single / unsorted. If you only test odd, an even-length off-by-one is invisible.

2. **Three tests DID use even-length samples but asserted the wrong thing.** They checked row counts, an average, and the mere presence of the substring `'median'` in rendered output, never the computed value. They passed against the wrong number and read as coverage. Asserting that a field is *present* is not asserting it is *correct*.

**One-sided error is worse than noisy error.** Because the biased median was also the yardstick a scoring function measured every item against (banded credit for being 'below median'), the inflation did not average out: it made everything look better than it was and pushed items over a selection threshold. A bug that errs in one direction only will bias every downstream decision the same way, so rank it above a symmetric rounding error, not below.

**Checklist when reviewing or writing any summary statistic (median, percentile, quartile, trimmed mean):**
- Test odd length, even length, single element, empty, and unsorted input.
- Assert the computed VALUE, not that the field rendered.
- Confirm the sort is numeric (`(a, b) => a - b`); `Array#sort`'s default is lexicographic, so `[90, 1000, 200]` sorts to `[1000, 200, 90]`.
- Check whether the helper mutates its input (in-place `.sort()` on a caller's array is a common silent side effect).
- If the statistic feeds a threshold or band, add a test at the DECISION level (does the item cross the gate?), not only at the helper level. That is the test that shows the bug matters.

## A Fix Proven on One App's Corpus Is NOT Proven for a Sibling App

Before sharing a module across sibling apps built from the same template, run it over the sibling's OWN stored production rows and read the diff by hand. "Same defect" does not mean "same data shape."

A preamble-stripping module was verified against one app's full corpus (118 documents, 104 split, 0 content lost) and both siblings had the identical defect, so a verbatim copy looked obvious. Measured against their corpora it would have been actively harmful twice over. Recall: the original's pattern list split only 20 of the sibling's 46 documents, because phrasings like "Here's the rundown" were never in the original's wording. Precision, the worse half: the original's preamble is pure editor monologue so peeling everything above the first heading is safe there, but the sibling mixes narration and real content in ONE paragraph, and the same peel buried a permanent-closure notice, the current time, stated assumptions, and a top-line recommendation.

- **Audit precision, not just recall.** Recall is easy to eyeball ("did it fire?"). Precision means reading what got REMOVED. Here the split-rate went up while the output got worse.
- **Change the shared module and re-verify the original to parity**, rather than forking it per app. The original was held to byte-identical output, proven by rendering all 61 shareable production documents on the old and new builds and diffing them (61/61 identical).
- **A guard that hides rather than deletes still needs this scrutiny.** "Nothing is discarded, it just moves to a collapsed disclosure" is what made the coarse version feel safe, and is exactly why the damage would have been invisible: the page still renders, the tests still pass, nothing logs an error.

## A Hand-Built Fixture Never Tests the Loader

When a config file gains a field, add at least one test that goes through the **real loader**: write a temp config, load it, assert the consumer sees the value. Testing the consumer with a hand-built object leaves the plumbing completely uncovered.

A billing config file gained a top-level `upgradePlan`. `validatePlans()` destructured it, validated it, then returned `{plans, defaultPlan}` **without it**. Every consumer therefore saw `undefined` and no upgrade button rendered anywhere in production. All four unit tests for the feature were green throughout, because each constructed the catalog object literally and handed it to the pure resolver, so nothing ever called the loader. The defect lived exactly in the seam the tests skipped, and it was found by curling the live endpoint after deploying.

This generalises to any parse/validate/transform layer. A dropped field is invisible to both the unit suite (which never runs the transform) and the type checker (the object is still structurally valid, just missing an optional property). At least one test must cross the boundary.

## A Measurement Rig Fails the Same Ways the Thing It Measures Does

Two failure modes, both in the rig rather than the subject.

1. **UNMEASURABLE BY CONSTRUCTION.** Candidates were selected for "never read in thousands of sessions", then the metric was "recall on reads". Expected observations in the two-week window: 0.00. Two weeks of empty logs would have read as "the retriever is safe" when all it proves is that you picked entries nothing reads. Before collecting, compute the EXPECTED number of observations under the null. If it rounds to zero, the metric is decoration.

2. **THE RIG IS A SYSTEM TOO.** Mid-audit a second demand signal appeared to justify cutting the candidate set, and the cut was applied before running a control. The control killed it: 91 of 99 matching blocks were inside tool results, i.e. a read file's own `[[wikilinks]]` echoed back in a staleness notice. It was a correlation with the measurement's own reads.

**CONSEQUENCE: version-stamp the rig.** Hash the matcher source + input sets + thresholds into every record, and make the scorer REFUSE to average across versions rather than silently mixing them. Without this, a rig that changed four times in one day produced a "0% recall" artifact, while the then-current matcher fired correctly on the exact prompt it was scored as missing.

**PROPORTIONALITY:** stop when rig effort exceeds the prize. Somewhere around the third rig correction, "let it collect and read it once" beats a fifth fix.

## A Metadata-Only Log Is Still Replayable: Rejoin It to the Transcripts

A shadow/telemetry log that deliberately omits sensitive fields looks untestable, and "I can't regression-test this until it collects the real thing" feels forced. Usually it is wrong: **the omitted field is often still sitting in a second store that kept it for an unrelated reason.**

Concrete case. A shadow log recorded, per prompt, which memories a matcher would have surfaced plus the prompt's **length**, never its text, by design, so the log carried nothing sensitive. That is exactly the field a replay needs. But the text was still in the session transcripts on disk, so the records rejoin on:

```
(session_id, |timestamp delta| <= 5s, exact character length)
```

That turned "wait 12 more days" into a 148-case regression test available the same afternoon, and it was the only way to prove a **copied** matcher was byte-identical to a frozen original that could not be imported.

Three rules that generalise:

- **Filter user-role entries down to real prompts.** Tool results arrive with the same role. A long tool output can coincidentally match a prompt's length and replay the wrong text into a test that then passes. Drop any content list containing a tool-result block; concatenate only text blocks.
- **Assert on exact values, not overlap.** Compare names *and* scores in order. A near-match hides precisely the drift the test exists to catch.
- **Report the recovery rate as part of the result.** 148 of 218 records replayed; the other 70 had no local transcript (headless sessions). Quoting "148/148 passed" without the denominator would imply coverage the test does not have. Where a transcript existed at all, recovery was 97%; that is the honest number, and it is the one that says whether the sample is worth trusting.

## Touch Drag Needs Pointer Events, and Raw CDP Touch in Tests Does Not Auto-Scroll

Two findings from building a drag-and-drop list as a static page.

**Building it:** HTML5 drag-and-drop (dragstart/dragover/drop) does not fire on touch, so a page built with it is dead on a phone while testing perfectly on a desktop. Use Pointer Events (pointerdown/pointermove/pointerup with `setPointerCapture`) instead, which cover mouse, touch, and pen in one code path. Give draggable elements `touch-action: none` or the browser will start a scroll and never deliver pointermove. Always ship a non-drag fallback (tap-to-select then tap-a-target, plus keyboard keys) because drag is the least accessible interaction on the page.

Also let a release over dead space fall back to the last real drop target hovered during that drag. Gutters between rows and sticky headers are not drop zones, so a release there silently reverts the drag and reads as a broken page.

**Testing it:** Playwright's `.tap()` and `.click()` auto-scroll the target into view, but raw CDP `Input.dispatchTouchEvent` does not. If either end of a simulated touch drag sits below the fold, the touch lands on nothing and the assertion fails for a reason that has nothing to do with the code. Scroll both ends into the viewport first and assert they are on screen before dispatching, so a layout change fails loudly instead of masquerading as a drag bug. Note that CDP `touchEnd` takes an empty `touchPoints` array; the coordinates come from the preceding `touchMove`.

## A Generated Page Passing `node --check` Proves Nothing About Whether the Chart Is Readable

Three real defects shipped past every automated check on a generated chart page: a colour ramp whose every data value landed in one half of the scale (scale was zero-based, data started at 40% of range), an axis label blind-truncated from "Summer (May to Sep)" to "Sum", and a 20-bar ranking chart whose bars spanned 1.2 percentage points and were visually identical. All three were found in the first 30 seconds of looking at a screenshot.

Screenshot it and look:

```bash
google-chrome --headless --disable-gpu --no-sandbox --screenshot=out.png file://$PWD/page.html
```

Then crop with PIL and read the PNG.

Related trap: a guarded try/except import (a data module importing a report config) silently swallows config errors, so the build exits 0 having skipped the new page entirely. Always confirm the build output literally names your file.

## A Bare URL in Body Text Overflows the Document Without Any Bounding Box Reporting It

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

## Test the Whole Field Set a Boundary Forwards, Not Just the Fields It Happens to Implement

A config/YAML loader built a physics model from two of its five tunable fields:

```python
model = VehicleModel(wheelbase=d.get('wheelbase', 2.8), max_speed=d.get('max_speed', 30.0))
```

The other three limits were accepted in the config, silently discarded, and untestable to notice: two entities declaring wildly different envelopes came back byte-identical on the stock defaults. It survived to production because the loader's tests covered exactly the two fields that WERE forwarded (`test_custom_wheelbase`, `test_custom_max_speed`) and read as coverage of "config overrides reach the model". They only ever proved it for the subset already implemented.

**Rule:** when a boundary (loader, serializer, DTO mapper, API adapter, ORM row builder) forwards a subset of a type's fields, assert the COMPLETE field set round-trips, not the fields you wrote code for. A field-by-field or "parsed == constructed" equality assertion catches the next dropped field for free; N single-field tests never will, because the missing test is exactly the one for the missing field.

Second, related trap in the same four lines: the loader repeated the model's own defaults (2.8 / 30.0) as fallbacks. That is a second source of truth that drifts silently the day someone retunes the model. Forward only the keys actually PRESENT in the config and let the type supply its own defaults:

```python
overrides = {k: float(d[k]) for k in FIELDS if k in d}
model = VehicleModel(**overrides)
```

This also makes "omitted key defers to the model" a testable contract (`parsed_with_no_overrides == Model()`).

Third: coerce at the boundary. The un-coerced path let a quoted config value survive as a `str` into the model, where it failed much later and far from its cause inside a numpy clip call. `float()` at parse time, raising an error that names the entity and the field, turns a baffling downstream type error into a message pointing at the config line.

## A Response That Narrates the Work Is Not the Work: Guard Output SHAPE, Not Just Error Strings

A research call spent its turns working, then emitted a final turn that only reported on itself: "All eight background research agents have now completed. The full guide was delivered above, no updates needed." That 380-char status report was stored as a COMPLETED answer under a green badge. There was no "above" (each follow-up is a separate call whose only output is that text) and the recommendation it named appears nowhere in the 27KB document it pointed at, which is exactly what the user reported missing.

Why every existing guard missed it, and the general lesson:

1. Guards were all keyed to ERROR STRINGS (`API Error:`, auth failures, usage limits) or to EMPTINESS. This output was neither: it was well-formed, confident, on-topic prose of normal-looking length. The failure mode is output that is structurally fine and semantically absent. Add a guard on the SHAPE of a valid answer, not only on the shapes of known failures.

2. The narration stripper that existed for this exact vocabulary could not help, because peeling the narration would have left an empty document. A splitter and a rejecter are different controls; having one does not give you the other.

3. A false positive on this kind of guard DELETES a real answer, so it needs several independent conditions rather than one heuristic. The shipped version requires all three: short residual after narration-stripping, a match on a process-narration or deferral wording FAMILY, and the absence of any substantive marker (link, price, list, heading, table). The substantive-marker test is what protects a legitimately terse answer.

4. Measure before believing the guard works. Running it over all 266 stored responses across three apps flagged exactly 1, the reported row, while 21 of the 22 other short candidates correctly passed. The same pass surfaced a second, much larger defect that no one had noticed: the narration stripper was wired only to the main response and never to follow-up answers, so 83% of one app's follow-ups had been rendering the model's monologue AS the answer since the feature shipped. A corpus sweep finds the bug you were not looking for.

Second, separate learning: a committed prompt change that requires a container rebuild is INERT until that rebuild runs. A fix was committed hours after the running container was built; grepping the live container's system prompt for the new rules returned 0 occurrences of all four distinctive strings. `git log` said shipped, the artifact said otherwise. Verify the ARTIFACT, not the commit.

## Ordering Tests Must Assert the Exact Sequence, Not Set Completeness

When fixing a non-total `ORDER BY` (a sort key with ties and no unique tiebreaker), the obvious test, "page 1 union page 2 covers all N rows exactly once", PASSES on the unfixed code and ships as fake coverage. Under a single stable query plan the pages are always complete; rows are only dropped/duplicated when the plan CHANGES between the two page requests (a migration adding an index, ANALYZE, VACUUM, a version bump). Measured on SQLite: same SQL, 25 tied rows, table-scan plan returns the tie group ascending by rowid and an ASC composite index returns it descending; serve page 1 under one and page 2 under the other and 5 of 25 become unreachable while 5 repeat.

Two ways to make the test discriminate:
1. Assert the EXACT returned sequence against the intended total order, with fixture ids chosen so the pre-fix order (insertion/rowid) provably differs from the post-fix order (e.g. insert in ascending id order, assert descending).
2. Model the plan change inside the test: fetch page 1, `CREATE INDEX ...` via raw SQL, fetch page 2, then assert no drops or duplicates.

Related blindness in the audit itself: a sweep for "every ORDER BY that needs a tiebreaker" cannot see the worse case, a truncated list (LIMIT, or a JS `.slice()` over an unordered select) with NO ORDER BY at all. Grep for `.limit(`/`LIMIT` and for slices over query results, not only for existing ORDER BY clauses.

Same family as: asserting a field is PRESENT is not asserting it is CORRECT.

## Re-Deriving a Metric Breaks Every Site That DIFFERENCES It Against a Source Still Computed the Old Way

Switching a cadence metric to a moving average (excluding a provider's stopped-sample 0 sentinel) correctly fixed one finding but silently broke a page's "delta vs. a compare record". That delta diffs the current record against a compare record whose streams are never loaded, so after the change the primary resolved cadence from the stream while the compare resolved it from the diluted provider summary. The delta then reported a difference in METHODOLOGY (a spurious 8 points on any sample crossing a gate) rather than a difference between the two records.

The failure mode: a same-file unit test cannot catch it, because both sides of the subtraction are individually correct. Before changing how a metric is derived, grep every consumer and ask which of them SUBTRACT, COMPARE, RANK, or THRESHOLD that metric against a value computed the old way, including a second call to the same function with different arguments (here `evaluate(record, streams)` vs `evaluate(compare, undefined)`). Deltas, sparklines, "vs last week", leaderboards and regression baselines are all this shape.

Related: the same investigation showed that reporting a range from a convenience sample is a distinct trap. 8 of 43 records gave a zero-fraction range of 0.7-7.2%, while the full 43 gave 0.36-53.96% (max understated 7.5x). Sample the population before quoting its bounds.

## A Push Gate Flagging a Dirty File During a Live Verifier Run May Be Flagging the UNFIXED Source

A push gate fired mid-session listing a worktree source file as uncommitted. That file was a verifier subagent's in-flight discrimination revert (`git show origin/main:<file> > <file>`), i.e. the UNFIXED source. Obeying the gate by committing would have shipped the bug the change was fixing.

Before obeying any push gate while a verifier or discrimination check is running, diff the working tree against the commit:

```bash
git show HEAD:<file> | diff - <file>
```

If HEAD has the fix and the working tree does not, the dirty state is the checker's, not yours. Wait for it to restore rather than committing. The pushed commit is immutable and unaffected by working-tree churn, so pushing is always safe; committing is not.

Related reporting rule: added test count is NOT the net suite delta. 10 new `it()` blocks with 2 pre-existing ones rewritten in place is net +8. Claiming "7 of the 8 new tests fail, the 3 that pass are guards" is arithmetically impossible. State added-vs-net separately.

## A Server-Rendered Default Is Invisible to JS-Rendered Markup

A template can define a default (a tagline, a label, any copy) and expose it through a server-side accessor, and that default will be correct everywhere the server prints. It will still come out blank wherever the markup is filled in by JavaScript, because the JS reads the JSON payload the server printed, and the payload was built from the raw stored value before the accessor ever ran.

Caught while exporting a set of themes: three of the designs paint their tagline from a global JS data object, the server accessor fell back to the constant correctly, and the rendered page showed an empty line. A `curl` of the front page passed (HTTP 200, markup present); only a browser that ran the script saw the blank.

The fix is to normalise the payload, not the accessor: apply defaults where the data array is assembled, so server and client read the same value by construction. The general rule: when the same value has two readers, put the fallback upstream of both, and test the reader that a `curl` cannot see.

## Test Design Variants Against Per-Variant Expectations, Not One Generic Assertion

When a deliverable is N variations of the same thing, a single shared assertion is the wrong test. It either fails variants that are behaving correctly or is weakened until it catches nothing.

A browser smoke test over eighteen themes reported 14/18 with one generic check (a filter row exists, images are decoded, clicking a card shows a title). All four failures were the test being wrong: one design is a text index that shows no images until hover and deliberately hides the detail header, one is a long scroll with no overlay at all, and three name their filter row something other than `#filters`. Relaxing the assertion until all eighteen passed would have removed its ability to detect a real break.

The fix is a declared expectation per variant (what to click, what must then be visible, how many images are due on load) so each is checked against what it actually is. The table doubles as documentation of how the variants differ. Reading the variant source to build that table is also what proves a "failure" is a design choice rather than a bug.

## Run a Throwaway WordPress Locally with the SQLite Drop-In, No MySQL Needed

WordPress themes and plugins can be tested end to end without a database server. WordPress core plus the official `sqlite-database-integration` plugin's `db.copy` drop-in, driven by wp-cli and served by PHP's built-in server, gives a real install in about two minutes.

Sequence: download `latest.tar.gz` and `wp-cli.phar`; unzip `sqlite-database-integration` into `wp-content/plugins`; copy its `db.copy` to `wp-content/db.php` and replace the two placeholders (`{SQLITE_IMPLEMENTATION_FOLDER_PATH}` and `{SQLITE_PLUGIN}`) with the absolute plugin path and `sqlite-database-integration/load.php`; write a `wp-config.php` with dummy `DB_*` constants and real salts; `php wp-cli.phar core install --url=http://127.0.0.1:PORT`; `php -S 127.0.0.1:PORT -t .` in the background.

Local prerequisites: `apt install php-cli php-sqlite3 php-mbstring php-xml php-curl php-zip`, plus `php-gd`, which any media import needs to make thumbnails. `wp-cli eval-file` is the way to drive plugin internals (an importer's batch functions, admin-screen render functions, meta save handlers) that a `curl` cannot reach, because wp-cli never loads wp-admin: `require ABSPATH . 'wp-admin/includes/admin.php'` and `wp_set_current_user(1)` first.

## A Hidden Filter Button Must Not Hide the Work: Split the List the UI Reads

When a taxonomy list feeds both a filter bar and something structural (section headings, a proportion strip, a grouping key), hiding a term from the bar by filtering that one list silently drops the items filed under it.

Emit two lists instead: the visible list the selection bar draws, and the full list everything structural reads. Then assert per consumer, in a browser, that hiding a term changes the bar and nothing else: same item count on the page, same number of sections, same number of segments, and reversible.

Seen in a multi-design export: 18 designs share one payload, 16 only draw the row, but one groups items under headings and another sizes a proportion strip from the counts. Filtering the single list would have made a hidden term take its items off the page in those two. Fix was emitting both `cats` and `catsAll` in the payload, build-time patches with assertions on the two affected variants, and a feature test checking all 18.

## `git show ref:file > file` Truncates the Target Before git Runs

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
