<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards that extend your core agent rules.

## When to Test

| Situation | Action |
|-----------|--------|
| Bug fix | Write a regression test that fails without the fix and passes with it |
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

This catches environment config drift and bad deploys immediately. It is deployment validation, not e2e testing. If the app sits behind a CDN or edge cache, confirm the response was not served from cache (check the cache-status header) or the smoke test may validate the old deploy.

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

One line per lesson. Each is a failure mode that has actually shipped; check for it when writing or reviewing tests.

- **Fallback chains hide dead rungs; test each branch in isolation**: in a waterfall (try A, else B, else C), if an early rung dies a later rung catches everything and the end-to-end result still looks fine. Force each rung to be the one that answers, and assert which rung did.
- **Testing shell scripts: don't stub a binary on PATH, stand up the real sink**: for scripts that alert (webhook, email, HTTP callback), a fake `curl` on `PATH` tests your stub, not the script. Run a local listener and assert what it received.
- **Making Node.js servers testable**: guard auto-start (only `listen()` when run directly), isolate tests via environment variables (ports, data dirs), and use a factory function so dependencies can be injected.
- **Test fixture schema drift**: tests that embed their own DDL (`CREATE TABLE`) or data shapes silently drift from the real schema. Build fixtures from the real migrations or schema file.
- **CI test workflow**: use a standard workflow (for example `.github/workflows/test.yml`) that runs tests on every push and PR to the default branch.
- **Mock fidelity**: mocks that diverge from production are worse than no mocks; they give false confidence. Derive mock shapes from recorded real responses.
- **Cross-layer invariant tests**: identify invariants that must hold across layers (for example, every enum value the API accepts is rendered by the UI; every DB column the API writes exists in the migration), write a test that enumerates both sides and asserts they agree, and name it so it is obviously an invariant test.
- **Zod validation in API routes**: every API route that parses input with Zod must catch `ZodError` and return a 400, not a 500.
- **Live browser testing**: for real-browser checks during development, drive the app with a browser automation tool (Playwright or raw CDP) rather than guessing from source.
- **Don't grep test output to detect pass/fail**: parsing runner output is fragile. Use the runner's exit code or a machine-readable reporter (JSON/JUnit).
- **CI workflow gotchas**: quote test globs in CI so the shell does not expand them differently than locally; commit `package-lock.json` or `npm ci` fails; Vitest fails the whole run when any imported module throws at import time.
- **Accessibility: focus management after modal close**: when a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it. Test all three close paths.
- **Boundary validation: non-negative quantities from external sources**: `!x` and `x === 0` guards do not reject negative numbers. Validate `x >= 0` (and type) explicitly for anything parsed from webhooks, APIs, DB records, or user data.
- **Batch loop resilience: isolate per-item failures**: an unguarded throw in one iteration aborts the entire batch. Wrap each item, record the failure, continue, and test with one bad item in the middle of a good batch.
- **Test a statistic at both sample parities**: an even-length median bug survives a suite that only uses odd-length inputs.
- **A fix proven on one app's corpus is not proven for a sibling app**: before sharing a module across sibling apps built from the same template, run it over the sibling's own stored production rows and read the diff by hand.
- **A hand-built fixture never tests the loader**: when a config file gains a field, add at least one test that goes through the real loader: write a temp config, load it, assert the consumer sees the value.
- **A measurement rig fails the same ways the thing it measures does**: before collecting data, check the rig can actually observe the outcome by construction.
- **A metadata-only log is still replayable**: a telemetry log that omits sensitive fields can still drive regression tests by rejoining it to the original transcripts or records.
- **Touch drag needs Pointer Events, and raw CDP touch in tests does not auto-scroll**: scroll the target into view yourself before dispatching touch events.
- **A generated page passing `node --check` and a DOM-stub run proves nothing about whether a chart is readable**: screenshot it and look.
- **A bare URL in body text can overflow the document without any element's bounding box reporting it**: compare `scrollWidth` to `clientWidth` per element.
- **Test the whole field set a boundary forwards, not just the fields it happens to implement**: assert unknown or newly added fields pass through (or are rejected) deliberately.
- **A response that narrates the work is not the work**: guard output shape (the artifact, the structured result), not just the absence of error strings.
- **Ordering tests must assert the exact sequence, not set completeness**: when fixing a non-total `ORDER BY` (ties, no unique tiebreaker), "page 1 union page 2 covers all N rows once" can pass on unfixed code. Assert the exact order with fixtures that tie on the sort key.
- **Re-deriving a metric breaks every site that differences it against a source still computed the old way**: find every consumer that subtracts or compares it before changing the derivation.
- **A push gate flagging a dirty file during a live verifier run may be flagging the unfixed source**: confirm which version of the file the gate actually read.
- **A server-side-only default is invisible to JS-rendered markup**: a default exposed only through a server template accessor is correct wherever the server prints and missing wherever client JS renders. Test both render paths.
- **Test design variants against per-variant expectations**: one generic assertion across variants hides the variant that is wrong.
- **Run a throwaway WordPress locally with the SQLite drop-in**: no MySQL needed for local theme and plugin testing.
- **A hidden filter button must not hide the work**: split the list the UI reads so hidden items are still counted and reachable.
- **`git show ref:file > file` truncates the target before git runs**: a bad ref empties the file. Write to a temp file and move it only on success.
- **A filter, count badge, or search box over a capped list silently under-reports**: compute against the full set, not the first N.
- **A ranking over a capped list is not a ranking, and clamped weights collapse the ranking you did compute**: rank the full set and check score spread.
- **A headless `claude --print` run inherits the host's CLAUDE.md and SessionStart hooks**: isolate config before measuring its behavior.
- **Two mutation-testing traps for data-store write paths**: asserting only that the call succeeded, or reading back through the same cached object you wrote, both produce green suites over broken writes. Re-read from the store.
- **A builder generating a deliverable from source lists must assert every entry appears exactly once before writing**.
- **A verdict parsed from a tool's stdout format can report all failures on all successes**: confirm against system state, not output text.
- **A rotted live control is indistinguishable from a detector regression unless a second, independent source is asked**.
- **Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes**: assert on `textContent`.
- **A stale-tolerant cached health probe is correct for a sampler and wrong for an explicit user choice**: re-check live when the user picks explicitly.
- **Stamp a per-request marker in the shared builder every path already calls**, not at each call site, or one path will miss it.
- **A worktree created inside the repo makes the test runner double-count every test file**: the baseline inflates exactly 2x. Exclude the worktree directory or create worktrees outside the repo.
- **A negative assertion passes vacuously when the harness never produced the positive**: assert the positive case happens in the same harness first.
- **A build that imports every module runs any script's top-level `process.exit`**, silently skipping its own checks. Guard script entry points.
- **A config flag that alters generation behavior must be benchmarked on the hard case, not the easy one**.
- **Extracting JSON from an LLM response: match the first balanced run**: not greedy to the last bracket, and not lazy to the first closing bracket either. Applies to objects `{}` as well as arrays.
- **A `tsx` test script's delayed dynamic import cannot pull a type-only member out with `type X`**: import types statically.
- **Headless-smoke-test a static prototype via raw CDP + Node 22's global WebSocket**: no puppeteer needed.
- **Playwright input events leak across a same-page navigation**: a reload after an interaction must reopen in a fresh page or context.
- **Prefer in-process route tests over a real loopback listener**: `server.listen(0, '127.0.0.1')` per test can hit `EPERM` in restricted sandboxes. Drive the app via supertest, an in-process request helper, or `app.handle()` with mock req/res. But a hand-rolled req/query object that normalizes input can make real-parser edge cases untestable (see Mock fidelity).
- **Desktop key-injection E2E must confirm the target window is foregrounded before every keystroke burst**: right after launch, the foreground window may still be whatever the user had focused, so keystrokes go to their live desktop.
- **A Playwright route handler that fulfills a redirect for a navigation doesn't route the follow-up request, and a `route.fetch` error can leak cookies into logs**: use a same-origin client-side redirect, and log only the first line of a `route.fetch` error.
- **A packaged app's selftest passing on CI only proves the CI machine**: check what the app reads from the machine at runtime (CA paths, fonts, codecs, PATH tools) and assert it comes from the bundle, not the build host.
- **A per-item filter tested against a set built from other items' outcomes flips for every item once any one item satisfies it**: for example, a fallback gate that checks "already-matched names" instead of re-testing the current entry. All-hit or all-miss test lists can't catch this; use a mixed list (one hit, one miss) and confirm the fallback still runs on the miss.
- **Moving UI state (filter, sort, tab) into the URL breaks a test that mocks the router's `navigate()`, and makes a previously unreachable value user-reachable**: drive the real router over an in-memory location so clicks navigate and Back can be simulated, and give a hand-edited invalid value its own UI state rather than the empty-results state.
- **An empty string reused as a wildcard collides with `.includes('')` being vacuously true**: a shared condition flips to always-true unnegated, or always-false negated and ANDed. Test the empty case in every branch that shares the comparison.
- **A stale-response guard keyed on query identity misses A->B->A**: a hook-level ignore flag only protects state the hook sets, so a fetcher that sets state itself must check the signal after every await. A secondary in-flight request (for example the next infinite-scroll page) needs its own guard; key it on a per-load counter, not the query. Test with manually resolved deferreds and include A->B->A.
- **A SQL `LIKE ... ESCAPE` helper must escape the escape character itself**: escaping only `%`/`_` leaves `\` live, causing false negatives, false positives, or wildcard bypass. Use one self-including pass: `input.replace(/[\\%_]/g, (ch) => '\\' + ch)`. Grep for `ESCAPE` and check every hand-rolled helper's character class.
- **A dedup/merge cleanup must skip degenerate grouping keys and pick the keeper by surviving content, not recency**: group only on a valid non-empty key, dedupe by primary id before grouping, choose the oldest row whose backing content actually exists, and skip the group if none does. Pin timestamps in tests; same-millisecond saves make "oldest" ambiguous.
- **A guard on one field doesn't make the record safe for consumers of any other field**: every other field from an untrusted source is still unguarded. Guard at each dereference point, and remember a throw inside an orchestrator with no try/catch turns one malformed record into a whole-run crash.
- **An unvalidated write endpoint can break a batch consumer for every row**: if search/list calls a type-specific method (`.toLowerCase()`, `.some()`) on every row, one bad write 500s the whole dataset. Validate types at the write boundary (400, write nothing). Test with a wrong-type value, not just a missing one, and assert the batch consumer still works after the rejected write.
- **A green suite after a fix doesn't prove a new regression test discriminates**: `git stash push <source-file>` (keep the tests), run the affected tests, and confirm the failure count equals the number of tests you expect to discriminate. If one passes pre-fix, strengthen its fixture (add a decoy the buggy code mishandles).
- **A regression test can pass on buggy code when an earlier `||`/`&&`/`?.`/early-return branch short-circuits first**: in `a.includes(q) || b.toLowerCase().includes(q) || ...`, an input that matches `a` never reaches the crashing `b`. Pick input that fails every earlier branch, and confirm the pre-fix failure happens at the expected branch.
- **A page number in the URL makes "page past the end" reachable, and an OFFSET server returns 200 + empty for it, not 400**: detect `items.length === 0 && total > 0 && page > totalPages` and render a distinct "no page N" state with a jump to the last page. Test with a fixture empty only past `totalPages`, plus a genuinely empty control.
- **A backlog note's impact claim ("500, no partial write") is a hypothesis**: before scoping a fix, reproduce and check the HTTP status, the persisted state (rows, files on disk), and a downstream read across all rows. Note that `x?.method()` only guards `null`/`undefined`, not other falsy values like `0` or `false`; prefer `x != null && typeof x === 'string'` when stored data may be any JSON type.
- **A one-shot CLI that reuses a daemon's "since last run" function inherits a window baselined at import, and module-mocked unit tests never execute the real top-level dispatch**: pass the window explicitly, and spawn the real process against scratch state to catch both the stale window and import-order crashes.
- **A regex/prefix guard used as a security boundary needs anchor-drop mutants in its test suite**: plain traversal inputs (`'..'`, `'../x'`, `'/tmp'`) pass even without `^`/`$`. Test valid-shaped input with a hostile suffix and prefix (`'<valid>/../..'`, `'../dir/<valid>'`), aimed at a target that exists, so dropping either anchor fails a test.
- **Serving a built app from inside a dot-directory checkout (for example `.claude/worktrees/`) 404s every SPA deep-link route**: Express `res.sendFile` ignores paths with dotfile segments by default, so `/` and assets work but the fallback route 404s, looking like a broken catch-all. Copy `dist/` to a plain path before browser-checking.
- **After refactoring code you only tested ad hoc, rerun the earlier ad-hoc checks, or save them as a test file the first time**: a stub test covering only the branch the refactor didn't touch proves nothing.
- **A self-authored synthetic test can share the bug's own assumption and still pass**: ask what the test would do if your model of the system were wrong; if the answer is "pass", it is an echo, not a check.
- **A text-range splice keyed on the next section's header silently deletes everything between**: anchor the end of a splice on the target block's own terminator, or assert the span size before writing. A deleted test never fails, so after editing a test file compare the test count before and after, not just "tests pass".
