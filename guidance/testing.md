<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards for agents writing, running, and reviewing tests.

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

Before writing any new tests, classify the last 5-10 production incidents. For each, record:
- What broke (auth, rendering, data, config, race condition)
- Whether a test existed for that path
- If a test existed and passed, *why* it passed when prod was broken (mock drift, shallow assertion, wrong environment config)
- When it was caught (pre-deploy, post-deploy, user report)

A simple table with one row per incident and these four columns is enough. The output tells you exactly which testing layer to invest in.

### Layer 2: Contract Tests

If incidents trace back to "test passed with mocks but prod behaved differently," your mocks encode stale assumptions. Fix this with:
- Schema checks against real API responses recorded from staging
- Snapshot the actual response shape from a real endpoint, then validate mocks match that shape
- Update snapshots as part of the deploy pipeline

**When to use:** Any service boundary where you currently use mocks: external APIs, database queries, auth providers.

### Layer 3: Integration Tests with Real Dependencies

For backend logic failures (bad queries, broken migrations, auth provider interactions):
- Hit real databases, real auth providers, and real caches
- Control state setup explicitly: each test owns its fixtures
- Run in CI; deterministic if you own the fixture lifecycle
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

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (you're compensating for missing integration tests; push coverage down the pyramid)
- Tests without a corresponding past incident (speculative tests have low ROI and high maintenance cost)

## Rule Digest

One line per lesson. Each is a failure mode that has shipped green tests over broken code at least once.

- **Fallback chains hide dead rungs; test each branch in isolation**: In a waterfall (try A, else B, else C), if an early rung dies a later rung catches everything and the end-to-end result still looks fine. Force each rung to be the one that answers.
- **Testing shell scripts: don't stub a binary on PATH, stand up the real sink**: To test an alert path (webhook, email, HTTP callback), run a local listener and point the script at it rather than shadowing `curl` on `PATH`; a PATH trick can silently fail to take effect and the test still passes.
- **Making Node.js servers testable**: Guard auto-start (only listen when run directly), isolate tests via environment variables (port, DB path), and use a factory function so dependencies can be injected.
- **Test fixture schema drift**: Tests that embed their own DDL (`CREATE TABLE`) or data shapes silently drift from the real schema. Build fixtures from the real migrations or schema module.
- **CI test workflow**: Run tests on every push and PR to the default branch via a standard CI workflow file.
- **Mock fidelity**: Mocks that diverge from production are worse than no mocks; they give false confidence. Derive mock shapes from real responses.
- **Cross-layer invariant tests**: Identify properties that must hold across layers (e.g. every DB enum value has a UI label, every route has an auth check, every config key has a consumer) and write one test per invariant that enumerates the real sources on both sides. Name them so the invariant is obvious from the test name.
- **Zod validation in API routes**: Every API route that parses input with Zod must catch `ZodError` and return a 400, not let it surface as a 500.
- **Live browser testing**: For testing web apps in a real browser during development, drive an actual browser (Playwright, CDP, or a browser automation tool) rather than trusting server responses alone.
- **Don't grep test output to detect pass/fail**: Parsing runner output with `grep` is fragile. Use the runner's exit code or its machine-readable reporter (JSON/JUnit).
- **CI workflow gotchas**: Quote test globs so the shell doesn't expand them differently in CI; commit `package-lock.json` or `npm ci` fails; Vitest fails the whole file when any imported module throws at import time.
- **Accessibility: focus management after modal close**: When a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it. Test all three close paths.
- **Boundary validation: non-negative quantities from external sources**: `!x` and `x === 0` guards do NOT reject negative numbers. Validate explicitly with `x < 0` (and `Number.isFinite`) on values from webhooks, APIs, DB rows, or user input.
- **Batch loop resilience: isolate per-item failures**: An unguarded throw inside a batch loop aborts the entire batch, not just the bad item. Wrap each iteration, record the failure, continue, and test with one poisoned item in the middle.
- **Test a statistic at both sample parities**: A median (or any order statistic) must be tested with both odd- and even-length inputs, or an even-length bug survives.
- **A fix proven on one app's data is not proven for a sibling app**: Before sharing a module across apps built from the same template, run it over the sibling's own production data and read the diff by hand.
- **A hand-built fixture never tests the loader**: When a config file gains a field, add at least one test that writes a temp config, loads it through the real loader, and asserts the consumer sees the value.
- **A measurement rig fails the same ways the thing it measures does**: Before collecting data, confirm the rig can actually observe the effect by construction (a known-positive control produces a positive).
- **A metadata-only log is still replayable**: A telemetry log that omits sensitive fields can still be joined back to the source transcripts or records for regression testing; don't wait to "collect the real thing".
- **Touch drag needs Pointer Events, and raw CDP touch in tests does not auto-scroll**: Implement drag with Pointer Events, and don't assume synthesized touch in a test scrolls the page the way a real finger does.
- **A generated page passing a syntax check and a DOM-stub run proves nothing about readability**: For charts and visual output, take a screenshot and look at it.
- **A bare URL in body text can overflow without any bounding box reporting it**: Detect horizontal overflow by comparing `scrollWidth` to `clientWidth` per element, not by checking element rects.
- **Test the whole field set a boundary forwards**: When a layer passes data through, assert every field arrives, not just the ones that layer happens to use.
- **A response that narrates the work is not the work**: Guard the output shape (the artifact, the structured result), not just the absence of error strings.
- **Ordering tests must assert the exact sequence, not set completeness**: For a non-total `ORDER BY` (ties, no unique tiebreaker), "page 1 plus page 2 covers all rows once" passes on the unfixed code. Assert the exact order across repeated runs.
- **Re-deriving a metric breaks every site that differences it against a source still computed the old way**: When changing how a metric is computed, find every subtraction or comparison against it and update or test those too.
- **A push gate flagging a dirty file during a live verifier run may be flagging the unfixed source**: Confirm which version of the file the gate actually read before "fixing" it again.
- **A server-side-only default is invisible to client-rendered markup**: A default exposed through a server-side template accessor (e.g. a PHP function in a CMS theme) won't appear where JS renders the same element. Test both render paths.
- **Test design variants against per-variant expectations**: One generic assertion across all variants lets a variant-specific bug through.
- **Run a throwaway WordPress locally with the SQLite drop-in**: No MySQL needed for disposable integration tests.
- **A hidden filter button must not hide the work**: If the UI hides a control, make sure the list it reads is split so items aren't silently excluded.
- **`git show ref:file > file` truncates the target before git runs**: A bad ref leaves you with an empty file. Write to a temp file and move it only on success.
- **A filter, count badge, or search box over a capped list silently under-reports**: Compute counts and search against the full set, not the displayed page.
- **A ranking over a capped list is not a ranking**: Rank the full set, and check that clamped weights haven't collapsed distinct scores into ties.
- **A headless `claude --print` run inherits the host's CLAUDE.md and SessionStart hooks**: Isolate config (separate config dir, no hooks) before measuring model behavior.
- **Two mutation-testing traps for data-store write paths**: When testing a write (cancel, update, status change), assert the stored state changed to the expected value by re-reading the store, and assert the unaffected rows did not change; weaker forms pass over broken code.
- **A builder generating a deliverable from source lists must assert every entry appears exactly once** before writing the output.
- **A verdict parsed from a tool's stdout format can be inverted**: Confirm pass/fail against actual system state, not only the tool's printed summary.
- **A rotted live control is indistinguishable from a detector regression** unless a second, independent source is consulted.
- **Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes**: Assert on `textContent` instead.
- **A stale-tolerant cached health probe is correct for a sampler and wrong for an explicit user choice**: When the user picks a specific target, probe it fresh.
- **Stamp a per-request marker in the shared builder every path already calls**, not at each call site, so no path can skip it.
- **A worktree created inside the repo makes the test runner double-count every test file**: The baseline inflates exactly 2x. Create worktrees outside the repo or exclude them from test discovery.
- **A negative assertion passes vacuously when the harness never produced the positive**: Pair every "X does not appear" with a check that the harness actually ran and could have produced X.
- **A build that imports every module runs any script's top-level `process.exit`**: This silently skips the build's own later checks. Guard script entry points.
- **A config flag that alters generation behavior must be benchmarked on the hard case**, not the easy one where every setting looks the same.
- **Extracting a JSON array from an LLM response: match the first balanced array**, not greedily to the last `]`.
- **A `tsx` test script's delayed dynamic import cannot pull a type-only member out with `type X`**: Import types statically.
- **Headless-smoke-test a static prototype via raw CDP and Node 22's global `WebSocket`**: No puppeteer dependency needed.
- **Playwright input events leak across a same-page navigation**: A reload after an interaction must reopen in a fresh page or context.
- **An old CLI may accept a newer `--model` id and silently serve an older model**: Verify the model reported in the response, not the flag you passed.
