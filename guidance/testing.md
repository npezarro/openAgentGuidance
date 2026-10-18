<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards for writing, structuring, and running tests.

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

Before writing any new tests, classify the last 5-10 production incidents. For each, record in a simple table:
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

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (you're compensating for missing integration tests; push coverage down the pyramid)
- Tests without a corresponding past incident (speculative tests have low ROI and high maintenance cost)

## Rule Digest

One line per lesson, in the order they were learned.

- **Fallback Chains Hide Dead Rungs (test each branch in isolation)**: A fallback/waterfall (try A, else B, else C) is the highest-risk structure for a **silent miss**: if an early rung dies, a later rung catches everything and the end-to-end result still looks fine. Test each rung on its own.
- **Testing Shell Scripts: Don't Stub a Binary on PATH, Stand Up the Real Sink**: Shell scripts that alert (chat webhook, email, HTTP callback) need their alert path tested, and the instinct is to drop a fake `curl` earlier on `PATH`. Instead, run a real local listener and point the script at it.
- **Making Node.js Servers Testable**: covers Auto-Start Guard (only `listen()` when run directly); Test Isolation via Environment Variables; Factory Pattern for Dependency Injection.
- **Test Fixture Schema Drift**: When tests embed their own DDL (CREATE TABLE) or data shapes, they silently drift from the real schema as the application evolves. Build fixtures from the real migrations/schema.
- **CI Test Workflow**: Use a standard `.github/workflows/test.yml` that runs tests on every push and PR to the default branch.
- **Mock Fidelity**: Mocks that diverge from production are worse than no mocks; they give false confidence.
- **Cross-Layer Invariant Tests**: covers What Are Invariants?; When to Write Invariant Tests; How to Write Them; Naming Convention; Common Patterns Across Projects.
- **Zod Validation in API Routes**: Every Next.js API route that parses input with Zod **must** catch `ZodError` and return a 400 response.
- **Live Browser Testing**: For testing web apps in a real browser during development, drive a real browser with an automation tool (Playwright, or raw CDP) rather than reasoning about the DOM from source.
- **Don't Grep Test Output to Detect Pass/Fail**: Parsing test runner output with `grep` to determine pass/fail is fragile. Use the runner's exit code or a machine-readable reporter.
- **CI Workflow Gotchas**: covers Test Glob Quoting on GitHub Actions; package-lock.json Must Be Committed for CI; Vitest Fails When Any Imported Module Throws at Import Time.
- **Accessibility: Focus Management After Modal Close**: When a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it.
- **Boundary Validation: Non-Negative Quantities from External Sources**: When validating numeric values parsed from external input (webhook payloads, API responses, database records, user data), `!x` and `x === 0` guards do NOT reject negative numbers. Check `x < 0` explicitly.
- **Batch Loop Resilience: Isolate Per-Item Failures**: When a loop processes a batch (DB rows, files, API records) and each iteration runs an operation that can throw on bad data, an unguarded throw aborts the ENTIRE batch, not just the bad item. Wrap each iteration and record the failure.
- **Test a statistic at both sample parities or an even-length median bug survives.**
- **A fix proven on one app's corpus is NOT proven for a sibling app**: Before sharing a module across sibling apps built from the same template, run it over the sibling's OWN stored production rows and read the diff by hand.
- **A hand-built fixture never tests the loader**: When a config file gains a field, add at least one test that goes through the **real loader**: write a temp config, load it, assert the consumer sees the value.
- **A measurement rig fails the same ways the thing it measures does; check it is measurable BY CONSTRUCTION before collecting.**
- **A metadata-only log is still replayable: rejoin it to the transcripts**: A shadow/telemetry log that deliberately omits sensitive fields looks untestable, and "I can't regression-test this until it collects the real thing" feels forced. Join it back to the source records by id and replay.
- **Touch drag needs Pointer Events, and raw CDP touch in tests does not auto-scroll.**
- **A generated page passing `node --check` and a DOM-stub run proves nothing about whether the chart is readable: screenshot it and look.**
- **A bare URL in body text overflows the document without any element's bounding box reporting it; compare `scrollWidth` to `clientWidth` per element.**
- **Test the whole field set a boundary forwards, not just the fields it happens to implement.**
- **A response that narrates the work is not the work: guard output SHAPE, not just error strings.**
- **Ordering tests must assert the exact sequence, not set completeness**: When fixing a non-total ORDER BY (a sort key with ties and no unique tiebreaker), the obvious test ("page 1 union page 2 covers all N rows exactly once") PASSES on the unfixed code. Assert the exact order.
- **Re-deriving a metric breaks every site that DIFFERENCES it against a source still computed the old way.**
- **A push gate flagging a dirty file during a live verifier run may be flagging the UNFIXED source.**
- **A PHP-only default is invisible to JS-rendered markup**: A WordPress theme can define a default (a tagline, a label, any copy) and expose it through a PHP accessor, and that default will be correct everywhere PHP prints but missing wherever JS renders the same field.
- **Test design variants against per-variant expectations, not one generic assertion.**
- **Run a throwaway WordPress locally with the SQLite drop-in, no MySQL needed.**
- **A hidden filter button must not hide the work, so split the list the UI reads.**
- **`git show ref:file > file` truncates the target before git runs, so a bad ref empties the file.**
- **A filter, count badge, or search box over a capped list silently under-reports: compute against the full set.**
- **A ranking over a capped list is not a ranking, and clamped weights collapse the ranking you did compute.**
- **A headless `claude --print` run inherits the host's CLAUDE.md and SessionStart hooks; isolate before measuring.**
- **Two mutation-testing traps for data-store write paths**: When mutation-testing a feature that writes to a data store (cancel, update, status change), assertions that only check the return value, or only check that "some row changed", produce green suites over broken code. Re-read the stored row and assert the specific field.
- **A builder generating a deliverable from source lists must assert every entry appears exactly once before writing.**
- **A verdict parsed from a tool's stdout format can report all-failures on all-successes; confirm against system state.**
- **A rotted LIVE control is indistinguishable from a detector regression unless a second, independent source is asked.**
- **Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes; assert on `textContent`.**
- **A stale-tolerant cached health probe is correct for a sampler and wrong for an explicit user choice.**
- **Stamp a per-request marker in the shared builder every path already calls, not at each call site.**
- **A worktree created inside the repo makes the test runner double-count every test file, inflating the baseline exactly 2x.**
- **A negative assertion passes vacuously when the harness never produced the positive.**
- **A build that imports every module runs any script's top-level `process.exit`, silently skipping its own checks.**
- **A config flag that alters generation behavior must be benchmarked on the hard case, not the easy one.**
- **Extracting JSON from an LLM response: match the first BALANCED run, not greedy to the LAST bracket, and not lazy to the FIRST bracket either (applies to objects `{}` too, not just arrays).**
- **A `tsx` test script's delayed dynamic import cannot pull a type-only member out with `type X`.**
- **Headless-smoke-test a static prototype via raw CDP + Node 22 global WebSocket (no puppeteer).**
- **Playwright input events leak across a same-page navigation, so a reload after an interaction must reopen in a fresh page/context.**
- **Prefer in-process route tests over a real loopback listener**: `server.listen(0, '127.0.0.1')` per test can hit `EPERM` in restricted sandboxes; drive the app via an in-process request helper, supertest, or `app.handle()` with mock req/res instead. But see Mock Fidelity: a hand-rolled req/query object that normalizes input can make real-parser edge cases silently untestable.
- **Desktop key-injection E2E must confirm the target window is foregrounded before every keystroke burst**: `GetForegroundWindow()` right after launching an app can return whatever the user already had focused (Windows foreground lock), not the new app, so keystrokes go to the user's live desktop instead of the test target.
- **A Playwright route handler that fulfills a redirect for a navigation doesn't route the follow-up request, and a `route.fetch` error can leak cookies into logs**: `isNavigationRequest()` handling needs a same-origin client-side redirect, not a fulfilled 3xx; log only the first line of a `route.fetch` error.
- **A packaged app's selftest passing on CI only proves the CI machine, not the shipped bundle**: check what the app reads from the machine (CA paths, fonts, codecs, PATH tools) at runtime and assert it comes from the bundle, not the build host.
- **A per-item filter tested against a SET built from other items' outcomes, not the item itself, flips for every item the moment any one item satisfies it**: a fallback gate that checks membership in already-matched names instead of re-testing the current entry will read "nothing left to match" for the whole list once any entry matches. An all-match or all-miss test list can't catch this; use a MIXED list (one hit, one miss) and confirm the fallback still runs on the miss.
- **Moving UI state (filter, sort, tab) into the URL breaks a test that mocks the router's `navigate()`, and makes a previously-unreachable value user-reachable**: drive the real router over its in-memory location so clicks really navigate and Back can be simulated, and give a hand-editable invalid value its own distinct UI state rather than letting it fall into the empty-results state.
- **An empty string reused as a wildcard/sentinel collides with `.includes('')` being vacuously true**: a condition shared across branches (`value.includes(x)`) that also lets an empty `x` mean "match anything" flips to always-true when unnegated, or always-false once negated and ANDed with a sibling term. Test what the comparison value's empty case does in EVERY branch that shares it, not just the one that already broke.
- **A stale-response guard keyed on query identity (user|filter) misses A->B->A**: a hook-level abort/ignore flag only protects state the hook itself sets, so a fetcher that sets component state in its own body must also check the signal after every await. A secondary in-flight request (e.g. infinite-scroll's next page) needs its own guard, and keying that guard on the query identity re-matches when the user returns to a prior query; bump a per-load counter instead. Test with manually-resolved deferreds and include the A->B->A case, which passes on a key-based guard despite being stale.
- **A SQL `LIKE ... ESCAPE` helper must escape the escape character itself, not just the wildcards**: escaping only `%`/`_` leaves the escape char (commonly `\`) live, so a literal occurrence of it in the query consumes whatever follows (false negative), degrades a `\n`-style sequence into a bare letter (false positive), or lets a leading `\%` re-enable a wildcard the escaping was supposed to neutralize (bypass). Fix is one self-including regex pass: `input.replace(/[\\%_]/g, (ch) => '\\' + ch)`. This bug recurs; grep for `ESCAPE` and check the helper's character class before trusting any hand-rolled one.
- **A dedup/merge cleanup must skip degenerate grouping keys and pick the keeper by surviving content, not recency**: a tool that groups duplicate records and deletes the losers can pass its own happy-path tests while losing data on real legacy rows. Group only on a valid, non-empty key (rows with no key at all are not a group), dedupe by primary id before grouping (a repeated id can land in both the keeper set and the drop set), and choose the keeper as the oldest row whose backing content actually exists, skipping the group entirely if none does. Pin timestamps in tests; same-millisecond saves make "oldest" ambiguous and mask the bug.
