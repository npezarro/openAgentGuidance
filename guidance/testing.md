<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards for writing, structuring and running tests.

## When to Test

| Situation | Action |
|-----------|--------|
| Bug fix | Write a regression test that fails without the fix and passes with it |
| New function with logic | Unit test covering the happy path and edge cases |
| API endpoint | Integration test covering the request/response cycle |
| Refactor | Make sure existing tests still pass; add tests if coverage was lacking |
| Config/copy-only change | No new tests needed |
| Repo has no test infra | Don't add one unless asked |

## Test File Placement

- Match the repo's existing pattern. Common conventions:
  - `__tests__/ComponentName.test.js` (React/Jest)
  - `tests/test_module.py` (Python/pytest)
  - `*.spec.ts` next to the source file (Vitest, Mocha)
- If no convention exists, put tests next to the source files.

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
- UI layout pixel by pixel (use snapshot tests sparingly).

## Mocking Guidelines

- **Mock at boundaries:** HTTP clients, databases, file system, timers, `Date.now()`.
- **Don't mock the unit under test.** If you need to, the function is doing too much; refactor it.
- **Prefer dependency injection** over module-level mocking where possible.
- **Reset mocks between tests:** `beforeEach(() => jest.clearAllMocks())` or equivalent.
- **Use typed mock helpers instead of `as any`:** Write factory functions that return complete typed objects rather than casting partial objects. This catches shape mismatches at compile time and removes lint warnings.

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

When a project keeps having quality problems (code ships that doesn't actually work), invest in testing in this priority order. Each layer cuts down the incidents the next layer has to catch.

| Priority | Layer | What It Catches | Cost |
|----------|-------|-----------------|------|
| 1 | Failure audit | Tells you where to invest | Hours |
| 2 | Contract tests | Mock drift, API shape mismatches | Low |
| 3 | Integration tests (real deps) | Backend logic, migrations, auth bugs | Medium |
| 4 | Post-deploy smoke tests | Config drift, bad deploys | Low |
| 5 | Authenticated browser tests | Auth flows, full-stack integration | High |

**Start at the top.** Do not jump to browser tests before the lower layers are done.

### Layer 1: Failure Audit

Before writing any new tests, classify the last 5-10 production incidents. For each one, record:
- What broke (auth, rendering, data, config, race condition)
- Whether a test existed for that path
- If a test existed and passed, *why* it passed while prod was broken (mock drift, shallow assertion, wrong environment config)
- When it was caught (pre-deploy, post-deploy, user report)

A simple table with one row per incident and one column per question above is enough. The result tells you exactly which testing layer to invest in.

### Layer 2: Contract Tests

If incidents trace back to "the test passed with mocks but prod behaved differently," your mocks encode stale assumptions. Fix this with:
- Schema checks against real API responses recorded from staging
- Snapshot the actual response shape from a real endpoint, then validate that mocks match that shape
- Update snapshots as part of the deploy pipeline

**When to use:** Any service boundary where you currently use mocks: external APIs, database queries, auth providers.

### Layer 3: Integration Tests with Real Dependencies

For backend logic failures (bad queries, broken migrations, auth provider interactions):
- Hit real databases, real auth providers, and real caches
- Control state setup explicitly; each test owns its fixtures
- Run in CI; deterministic if you own the fixture lifecycle
- **Do not mock the database.** Mock/prod divergence is the #1 source of false-green tests

### Layer 4: Post-Deploy Smoke Tests

Lightweight, fast (under 30 seconds), non-browser checks against the deployed environment:
- Authenticate with a test account
- Hit the 3-5 most critical endpoints
- Assert HTTP 200 and basic response shape (not just status code)
- Run automatically after every staging deploy

This catches environment config drift and bad deploys right away. It is deployment validation, not e2e testing.

### Layer 5: Authenticated Browser Tests (Use Sparingly)

Only go here if the failure audit shows incidents that ONLY a real browser would have caught (broken auth flows, CORS/CSP issues, token refresh failures).

**Constraints:**
- Maximum 5-8 scenarios. Start by reproducing a specific past incident, not by writing speculative tests
- Dedicated test account with stable credentials, managed via secrets
- Run against staging only, never production
- Each test owns its state: setup creates what it needs, teardown removes it
- Assert on intercepted API responses, not just DOM elements
- Capture screenshots, network logs, and console errors on failure

**Flakiness policy:** Quarantine on the second consecutive flake. Move it to a non-blocking suite until fixed. A flaky test the team ignores is worse than no test.

**Tag every test** by the failure mode it guards against (`@auth-flow`, `@regression-INCIDENT-42`).

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (you're making up for missing integration tests; push coverage down the pyramid)
- Tests without a matching past incident (speculative tests have low ROI and high maintenance cost)

## Rule Digest

One line per lesson.

- **Fallback chains hide dead rungs (test each branch in isolation)**: A fallback/waterfall (try A, else B, else C) is the riskiest structure for a **silent miss**: if an early rung dies, a later rung catches everything and the end-to-end result still looks fine. Test each rung on its own.
- **Testing shell scripts: don't stub a binary on PATH, stand up the real sink**: Scripts that alert (webhook to your notification channel, email, HTTP callback) need their alert path tested. Rather than putting a fake `curl` earlier on `PATH`, run a local listener and assert on what it actually receives.
- **Making Node.js servers testable**: Add an auto-start guard (only call `listen` when run directly), isolate tests through environment variables (ports, DB paths), and use a factory function so dependencies can be injected.
- **Test fixture schema drift**: When tests embed their own DDL (CREATE TABLE) or data shapes, they quietly drift from the real schema as the app evolves. Build fixtures from the real migrations/schema.
- **CI test workflow**: A standard `.github/workflows/test.yml` that runs tests on every push and PR to the default branch.
- **Mock fidelity**: Mocks that diverge from production are worse than no mocks; they give false confidence.
- **Cross-layer invariant tests**: Identify invariants that must hold across layers (e.g. every value the UI sends is one the API accepts, every DB enum has a UI label), write tests that load both sides and compare them, and name them so they're recognisable as invariant tests.
- **Zod validation in API routes**: Every API route that parses input with Zod **must** catch `ZodError` and return a 400, not a 500.
- **Live browser testing during development**: Drive the app in a real browser (Playwright or raw CDP) to confirm behaviour, not only unit tests.
- **Don't grep test output to detect pass/fail**: Parsing runner output with `grep` is fragile. Use the runner's exit code or a machine-readable reporter.
- **CI workflow gotchas**: Quote test globs on GitHub Actions so the shell doesn't expand them differently; commit `package-lock.json` or `npm ci` fails; Vitest fails the whole file when any imported module throws at import time.
- **Accessibility: focus management after modal close**: When a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it. Test it.
- **Boundary validation: non-negative quantities from external sources**: When validating numbers parsed from external input (webhook payloads, API responses, DB records, user data), `!x` and `x === 0` guards do NOT reject negative numbers. Check `x < 0` explicitly and test with a negative value.
- **Batch loop resilience: isolate per-item failures**: When a loop processes a batch (DB rows, files, API records) and each iteration can throw on bad data, an unguarded throw aborts the ENTIRE batch, not just the bad item. Wrap each item, log, continue, and test with one bad item in the middle of a batch.
- **Test a statistic at both sample parities, or an even-length median bug survives.**
- **A fix proven on one app's data is NOT proven for a sibling app**: Before sharing a module across sibling apps built from the same template, run it over the sibling's own stored production rows and read the diff by hand.
- **A hand-built fixture never tests the loader**: When a config file gains a field, add at least one test that goes through the **real loader**: write a temp config, load it, assert the consumer sees the value.
- **A measurement rig fails the same ways the thing it measures does**: Check it is measurable by construction before collecting data.
- **A metadata-only log is still replayable**: A telemetry log that omits sensitive fields can still be regression-tested by rejoining it to the original transcripts or source records.
- **Touch drag needs Pointer Events, and raw CDP touch events in tests do not auto-scroll.**
- **A generated page passing `node --check` and a DOM-stub run proves nothing about whether a chart is readable**: Screenshot it and look.
- **A bare URL in body text can overflow the document without any element's bounding box showing it**: Compare `scrollWidth` to `clientWidth` per element.
- **Test the whole field set a boundary forwards, not just the fields it happens to implement.**
- **A response that narrates the work is not the work**: Guard output SHAPE, not just the absence of error strings.
- **Ordering tests must assert the exact sequence, not set completeness**: When fixing a non-total ORDER BY (a sort key with ties and no unique tiebreaker), the obvious test "page 1 plus page 2 covers all N rows exactly once" PASSES on the unfixed code. Assert the exact order.
- **Re-deriving a metric breaks every site that differences it against a source still computed the old way**: Find and test every consumer.
- **A push gate flagging a dirty file during a live verifier run may be flagging the unfixed source.** Check which version it actually scanned.
- **A server-side-only default is invisible to client-rendered markup**: A default exposed only through a server-side template accessor won't appear where JS renders the same element. Test both render paths.
- **Test design variants against per-variant expectations, not one generic assertion.**
- **Run a throwaway WordPress locally with the SQLite drop-in**: No MySQL needed for local tests.
- **A hidden filter button must not hide the work**: Split the list the UI reads so filtered-out items are still reachable.
- **`git show ref:file > file` truncates the target before git runs**, so a bad ref empties the file. Write to a temp file and move it.
- **A filter, count badge, or search box over a capped list silently under-reports**: Compute against the full set.
- **A ranking over a capped list is not a ranking, and clamped weights collapse the ranking you did compute.**
- **A headless `claude --print` run inherits the host's CLAUDE.md and SessionStart hooks**: Isolate the environment before measuring.
- **Two mutation-testing traps for data-store write paths**: When mutation-testing a feature that writes to a data store (cancel, update, status change), assertions that only check the return value or only check "something changed" produce green suites over broken code. Re-read the stored row and assert the exact field values.
- **A builder generating a deliverable from source lists must assert every entry appears exactly once before writing.**
- **A verdict parsed from a tool's stdout format can report all failures on all successes**: Confirm against system state.
- **A rotted live control looks the same as a detector regression** unless you ask a second, independent source.
- **Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes**: Assert on `textContent`.
- **A stale-tolerant cached health probe is right for a sampler and wrong for an explicit user choice.**
- **Stamp a per-request marker in the shared builder every path already calls**, not at each call site.
- **A worktree created inside the repo makes the test runner double-count every test file**, inflating the baseline exactly 2x. Exclude it or create worktrees outside the repo.
- **A negative assertion passes vacuously when the harness never produced the positive**: Prove the positive case fires first.
- **A build that imports every module runs any script's top-level `process.exit`**, silently skipping its own checks. Guard script entry points.
- **A config flag that changes generation behavior must be benchmarked on the hard case, not the easy one.**
- **Extracting JSON from an LLM response: match the first BALANCED run**, not greedy to the last bracket and not lazy to the first closing bracket either. This applies to objects `{}` as well as arrays.
- **A `tsx` test script's delayed dynamic import cannot pull a type-only member out with `type X`.**
- **Headless smoke-test a static prototype via raw CDP plus Node 22's global WebSocket**: No puppeteer needed.
- **Playwright input events leak across a same-page navigation**: A reload after an interaction must reopen in a fresh page or context.
- **Prefer in-process route tests over a real loopback listener**: `server.listen(0, '127.0.0.1')` per test can hit `EPERM` in restricted sandboxes. Drive the app with an in-process request helper, supertest, or `app.handle()` with mock req/res instead. But (see Mock fidelity) a hand-rolled req/query object that normalizes input can make real-parser edge cases untestable.
- **Desktop key-injection E2E must confirm the target window is foregrounded before every keystroke burst**: `GetForegroundWindow()` right after launching an app can return whatever the user already had focused (Windows foreground lock), so keystrokes go to the user's live desktop instead of the test target.
- **A Playwright route handler that fulfills a redirect for a navigation doesn't route the follow-up request, and a `route.fetch` error can leak cookies into logs**: Handle `isNavigationRequest()` with a same-origin client-side redirect, not a fulfilled 3xx; log only the first line of a `route.fetch` error.
- **A packaged app's selftest passing on CI only proves the CI machine, not the shipped bundle**: Check what the app reads from the machine at runtime (CA paths, fonts, codecs, PATH tools) and assert it comes from the bundle, not the build host.
- **A per-item filter tested against a SET built from other items' outcomes flips for every item once any one item satisfies it**: For example, a fallback gate that checks membership in already-matched names instead of re-testing the current entry reads "nothing left to match" for the whole list after the first deterministic match. All-match or all-miss test lists can't catch this; use a MIXED list (one hit, one miss) and confirm the fallback still runs on the miss.
