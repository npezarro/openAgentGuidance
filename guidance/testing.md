<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

These are testing standards for any repo you work in.

## When to Test

| Situation | Action |
|-----------|--------|
| Bug fix | Write a regression test that fails without the fix and passes with it |
| New function with logic | Write a unit test covering the happy path and edge cases |
| API endpoint | Write an integration test covering the request/response cycle |
| Refactor | Make sure existing tests still pass; add tests if coverage was lacking |
| Config/copy-only change | No new tests needed |
| Repo has no test infra | Don't add one unless asked |

## Test File Placement

- Follow the repo's existing pattern. Common conventions:
  - `__tests__/ComponentName.test.js` (React/Jest)
  - `tests/test_module.py` (Python/pytest)
  - `*.spec.ts` next to the source file (Vitest, Mocha)
- If there is no convention, put tests next to the source files.

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

- **Happy path:** does the function work with typical input?
- **Edge cases:** empty strings, zero, null/undefined, large numbers, special characters.
- **Error paths:** does it fail gracefully on bad input?
- **Boundaries:** off-by-one errors, array boundaries, date rollovers.

## What NOT to Test

- Implementation details (private methods, internal state).
- Third-party library behavior (trust that `lodash.get` works).
- Trivial getters/setters with no logic.
- UI layout pixel by pixel (use snapshot tests sparingly).

## Mocking Guidelines

- **Mock at boundaries:** HTTP clients, databases, file system, timers, `Date.now()`.
- **Don't mock the unit under test.** If you feel you need to, the function is doing too much, so refactor it.
- **Prefer dependency injection** over module-level mocking where you can.
- **Reset mocks between tests:** `beforeEach(() => jest.clearAllMocks())` or equivalent.
- **Use typed mock helpers instead of `as any`:** write factory functions that return complete typed objects instead of casting partial objects. This catches shape mismatches at compile time and removes lint warnings.

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
- Uncovered code is fine if it is glue code, config, or error handling that is hard to trigger in tests.
- If the repo has a coverage threshold configured, respect it.

## Testing Pyramid Strategy

When a project keeps having quality problems (code ships that doesn't actually work), invest in testing in this order. Each layer cuts down the incidents the next layer has to catch.

| Priority | Layer | What It Catches | Cost |
|----------|-------|-----------------|------|
| 1 | Failure audit | Tells you where to invest | Hours |
| 2 | Contract tests | Mock drift, API shape mismatches | Low |
| 3 | Integration tests (real deps) | Backend logic, migrations, auth bugs | Medium |
| 4 | Post-deploy smoke tests | Config drift, bad deploys | Low |
| 5 | Authenticated browser tests | Auth flows, full-stack integration | High |

**Start at the top.** Don't jump to browser tests before the lower layers are done.

### Layer 1: Failure Audit

Before writing any new tests, classify the last 5-10 production incidents. For each one, record:
- What broke (auth, rendering, data, config, race condition)
- Whether a test existed for that path
- If a test existed and passed, *why* it passed while prod was broken (mock drift, shallow assertion, wrong environment config)
- When it was caught (pre-deploy, post-deploy, user report)

Use a simple table with one row per incident and one column per question above. The result tells you exactly which testing layer to invest in.

### Layer 2: Contract Tests

If incidents trace back to "the test passed with mocks but prod behaved differently," your mocks encode stale assumptions. To fix that:
- Check schemas against real API responses recorded from staging
- Snapshot the actual response shape from a real endpoint, then validate that the mocks match it
- Update the snapshots as part of the deploy pipeline

**When to use:** any service boundary where you currently use mocks: external APIs, database queries, auth providers.

### Layer 3: Integration Tests with Real Dependencies

For backend logic failures (bad queries, broken migrations, auth provider interactions):
- Hit real databases, real auth providers, and real caches
- Control state setup explicitly; each test owns its fixtures
- Run in CI; tests stay deterministic if you own the fixture lifecycle
- **Do not mock the database.** Divergence between the mock and prod is the #1 source of false-green tests

### Layer 4: Post-Deploy Smoke Tests

Lightweight, fast (under 30 seconds), non-browser checks against the deployed environment:
- Authenticate with a test account
- Hit the 3-5 most critical endpoints
- Assert HTTP 200 and the basic response shape (not just the status code)
- Run automatically after every staging deploy
- If a CDN or edge cache sits in front of the app, confirm the response is not a cached copy of the previous deploy (check the cache-status header or bypass the edge)

This catches environment config drift and bad deploys right away. It is deployment validation, not e2e testing.

### Layer 5: Authenticated Browser Tests (Use Sparingly)

Only go here if the failure audit shows incidents that ONLY a real browser would have caught (broken auth flows, CORS/CSP issues, token refresh failures).

**Constraints:**
- 5-8 scenarios at most. Start by reproducing a specific past incident, not by writing speculative tests
- Use a dedicated test account with stable credentials, managed through secrets
- Run against staging only, never production
- Each test owns its state: setup creates what it needs, teardown removes it
- Assert on intercepted API responses, not just DOM elements
- Capture screenshots, network logs, and console errors on failure

**Flakiness policy:** quarantine a test on its second consecutive flake. Move it to a non-blocking suite until it is fixed. A flaky test the team ignores is worse than no test.

**Tag every test** with the failure mode it guards against (`@auth-flow`, `@regression-INCIDENT-42`).

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (that means you are making up for missing integration tests; push coverage down the pyramid)
- Tests with no corresponding past incident (speculative tests have low ROI and high maintenance cost)

## Rule Digest

One line per lesson.

- **Fallback chains hide dead rungs (test each branch in isolation)**: in a fallback/waterfall (try A, else B, else C), an early rung can die while a later rung catches everything, and the end-to-end result still looks green. Test each rung alone and assert which rung produced the result.
- **Testing shell scripts: don't stub a binary on PATH, stand up the real sink**: scripts that alert (webhook, email, HTTP callback) need their alert path tested. Instead of putting a fake `curl` early on `PATH`, run a local listener and assert on what it actually received.
- **Making Node.js servers testable**: add an auto-start guard (only `listen()` when run directly), isolate tests through environment variables, and use a factory pattern so dependencies can be injected.
- **Test fixture schema drift**: when tests embed their own DDL (CREATE TABLE) or data shapes, those copies drift away from the real schema as the app changes. Build fixtures from the real migrations or schema.
- **CI test workflow**: give each repo a standard `.github/workflows/test.yml` that runs tests on every push and PR to the default branch.
- **Mock fidelity**: a mock that differs from production is worse than no mock, because it gives false confidence.
- **Cross-layer invariant tests**: find properties that must hold across layers (the DB, API and UI agree on a value, every enum value has a handler) and write tests that assert them directly, named for the invariant.
- **Zod validation in API routes**: every API route that parses input with Zod **must** catch `ZodError` and return a 400, not a 500.
- **Live browser testing**: during development, check web apps in a real, scriptable browser (Playwright or raw CDP), not just with unit tests.
- **Don't grep test output to detect pass/fail**: parsing runner output with `grep` is fragile. Use the runner's exit code or a structured reporter.
- **CI workflow gotchas**: quote test globs so the shell doesn't expand them differently on CI; commit `package-lock.json` or CI installs will fail or drift; Vitest fails the whole run when any imported module throws at import time.
- **Accessibility: focus management after modal close**: when a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must go back to the element that opened it. Test all three close paths.
- **Boundary validation: non-negative quantities from external sources**: `!x` and `x === 0` guards do NOT reject negative numbers parsed from webhooks, API responses, DB records, or user data. Check `x < 0` explicitly and test with a negative value.
- **Batch loop resilience: isolate per-item failures**: an unguarded throw inside a batch loop aborts the ENTIRE batch, not just the bad item. Wrap each iteration, record the failure, and continue; test with one bad item in the middle.
- **Test a statistic at both sample parities**, or an even-length median bug survives.
- **A fix proven on one app's data is NOT proven for a sibling app**: before sharing a module across sibling apps built from the same template, run it over the sibling's OWN stored production rows and read the diff by hand.
- **A hand-built fixture never tests the loader**: when a config file gains a field, add at least one test that goes through the **real loader**: write a temp config, load it, and assert the consumer sees the value.
- **A measurement rig fails the same ways the thing it measures does**: before collecting data, check that the result can be measured by construction.
- **A metadata-only log is still replayable: rejoin it to the transcripts**: a telemetry log that leaves out sensitive fields looks untestable, but it can often be joined back to the full records for regression testing.
- **Touch drag needs Pointer Events, and raw CDP touch in tests does not auto-scroll.**
- **A generated page passing `node --check` and a DOM-stub run proves nothing about whether a chart is readable**: screenshot it and look at it.
- **A bare URL in body text can overflow the document while no element's bounding box reports it**: compare `scrollWidth` to `clientWidth` for each element.
- **Test the whole field set a boundary forwards**, not just the fields it happens to implement.
- **A response that narrates the work is not the work**: guard the output SHAPE, not just error strings.
- **Ordering tests must assert the exact sequence, not set completeness**: when you fix a non-total ORDER BY (a sort key with ties and no unique tiebreaker), the test "page 1 plus page 2 covers all N rows exactly once" can PASS on the unfixed code. Assert the exact order.
- **Re-deriving a metric breaks every site that DIFFERENCES it against a source still computed the old way.**
- **A push gate that flags a dirty file during a live verifier run may be flagging the UNFIXED source.**
- **A server-side-only default is invisible to JS-rendered markup**: a default exposed only through a server-side template accessor is right wherever the server prints it and missing wherever client JS renders the same element. Test both render paths.
- **Test design variants against per-variant expectations**, not one generic assertion.
- **Run a throwaway WordPress locally with the SQLite drop-in**; no MySQL needed.
- **A hidden filter button must not hide the work**, so split the list the UI reads.
- **`git show ref:file > file` truncates the target before git runs**, so a bad ref leaves you with an empty file.
- **A filter, count badge, or search box over a capped list silently under-reports**: compute them against the full set.
- **A ranking over a capped list is not a ranking, and clamped weights collapse the ranking you did compute.**
- **A headless `claude --print` run inherits the host's CLAUDE.md and SessionStart hooks**: isolate it before you measure anything.
- **Two mutation-testing traps for data-store write paths**: when mutation-testing a feature that writes to a data store (cancel, update, status change), some assertion forms give a green suite over broken code. Assert the persisted state itself, read back from the store.
- **A builder that generates a deliverable from source lists must assert every entry appears exactly once** before it writes.
- **A verdict parsed from a tool's stdout format can report all failures on all successes**: confirm it against system state.
- **A rotted LIVE control looks the same as a detector regression** unless you ask a second, independent source.
- **Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes**: assert on `textContent`.
- **A stale-tolerant cached health probe is right for a sampler and wrong for an explicit user choice.**
- **Stamp a per-request marker in the shared builder every path already calls**, not at each call site.
- **A worktree created inside the repo makes the test runner count every test file twice**, so the baseline is inflated exactly 2x.
- **A negative assertion passes vacuously when the harness never produced the positive.** Assert that the positive case happened first.
- **A build that imports every module runs any script's top-level `process.exit`**, silently skipping its own checks.
- **A config flag that changes generation behavior must be benchmarked on the hard case**, not the easy one.
- **Extracting JSON from an LLM response: match the first BALANCED run**, not greedy to the LAST bracket and not lazy to the FIRST bracket (this goes for objects `{}` as well as arrays).
- **A `tsx` test script's delayed dynamic import cannot pull out a type-only member with `type X`.**
- **Headless-smoke-test a static prototype with raw CDP and Node 22's global WebSocket** (no puppeteer).
- **Playwright input events leak across a same-page navigation**, so a reload after an interaction must reopen in a fresh page/context.
- **Prefer in-process route tests over a real loopback listener**: `server.listen(0, '127.0.0.1')` per test can hit `EPERM` in restricted sandboxes. Drive the app with an in-process request helper, supertest, or `app.handle()` with mock req/res instead. But keep mock fidelity in mind: a hand-rolled req/query object that normalizes input can make real-parser edge cases impossible to test.
- **Desktop key-injection E2E must confirm the target window is in the foreground before every burst of keystrokes**: right after an app launches, `GetForegroundWindow()` can return whatever the user already had focused (Windows foreground lock), so keystrokes go to the user's live desktop instead of the test target.
- **A Playwright route handler that fulfills a redirect for a navigation doesn't route the follow-up request, and a `route.fetch` error can leak cookies into logs**: `isNavigationRequest()` handling needs a same-origin client-side redirect, not a fulfilled 3xx. Log only the first line of a `route.fetch` error.
- **A packaged app's selftest passing on CI only proves the CI machine, not the shipped bundle**: check what the app reads from the machine at runtime (CA paths, fonts, codecs, PATH tools) and assert it comes from the bundle, not the build host.
- **A per-item filter tested against a SET built from other items' outcomes flips for every item once any one item satisfies it**: a fallback gate that checks membership in already-matched results, instead of re-testing the current item, reads "nothing left to match" for the whole list once anything matches. An all-match or all-miss test list can't catch this. Use a MIXED list (one hit, one miss) and confirm the fallback still runs on the miss.
- **Moving UI state (filter, sort, tab) into the URL breaks a test that mocks the router's `navigate()`, and lets users reach a value they couldn't reach before**: drive the real router over its in-memory location so clicks really navigate and Back can be simulated. Give a hand-edited invalid value its own UI state instead of letting it fall into the empty-results state.
- **An empty string reused as a wildcard/sentinel collides with `.includes('')` being vacuously true**: if a condition shared across branches (`value.includes(x)`) also lets an empty `x` mean "match anything," it becomes always-true when not negated, or always-false once negated and ANDed with a sibling term. Test the empty case in EVERY branch that shares the comparison, not just the one that already broke.
- **A stale-response guard keyed on query identity (user|filter) misses A->B->A**: a hook-level abort/ignore flag only protects state the hook itself sets, so a fetcher that sets component state in its own body must also check the signal after every await. A secondary in-flight request (for example, infinite scroll's next page) needs its own guard, and keying that guard on the query identity matches again when the user returns to an earlier query, so bump a per-load counter instead. Test with manually resolved deferreds and include the A->B->A case, which passes on a key-based guard even though the response is stale.
