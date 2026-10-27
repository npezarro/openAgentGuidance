<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards that extend the core agent rules.

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

When a project has recurring quality issues (code ships that doesn't actually work), invest in testing in this priority order. Each layer reduces the number of incidents the next layer has to catch.

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

A simple table with one row per incident and one column per question above is enough. The output tells you exactly which testing layer to invest in.

### Layer 2: Contract Tests

If incidents trace back to "test passed with mocks but prod behaved differently", your mocks encode stale assumptions. Fix this with:
- Schema checks against real API responses recorded from staging
- Snapshot the actual response shape from a real endpoint, then validate that mocks match that shape
- Update snapshots as part of the deploy pipeline

**When to use:** Any service boundary where you currently use mocks: external APIs, database queries, auth providers.

### Layer 3: Integration Tests with Real Dependencies

For backend logic failures (bad queries, broken migrations, auth provider interactions):
- Hit real databases, real auth providers, and real caches
- Control state setup explicitly; each test owns its fixtures
- Run in CI; deterministic if you own the fixture lifecycle
- **Do not mock the database.** Mock/prod divergence is the #1 source of false-green tests.

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
- More than 8-10 browser test scenarios (you're compensating for missing integration tests; push coverage down the pyramid)
- Tests without a corresponding past incident (speculative tests have low ROI and high maintenance cost)

## Rule Digest

One line per lesson, in the order they were learned.

- **Fallback chains hide dead rungs; test each branch in isolation**: in a waterfall (try A, else B, else C), if an early rung dies a later rung catches everything and the end-to-end result still looks green. Force each rung to be the one that answers and assert it did.
- **Testing shell scripts: don't stub a binary on PATH, stand up the real sink**: scripts that alert (webhook, email, HTTP callback) need the alert path tested. Instead of a fake `curl` earlier on `PATH`, run a local listener and assert what it received.
- **Making Node.js servers testable**: add an auto-start guard (only `listen()` when run directly), isolate tests via environment variables (ports, data dirs), and use a factory function to inject dependencies.
- **Test fixture schema drift**: tests that embed their own DDL (`CREATE TABLE`) or data shapes silently drift from the real schema. Build fixtures from the real migrations/schema.
- **CI test workflow**: a standard `.github/workflows/test.yml` that runs tests on every push and PR to the default branch.
- **Mock fidelity**: mocks that diverge from production are worse than no mocks; they give false confidence.
- **Cross-layer invariant tests**: identify properties that must hold across layers (e.g. every DB enum value has a UI label, every API field the client reads is one the server sends), write a test per invariant, and name it after the invariant it protects.
- **Zod validation in API routes**: every API route that parses input with Zod must catch `ZodError` and return a 400, not a 500.
- **Live browser testing during development**: drive the app in a real browser (Playwright or raw CDP) to confirm a UI change works, not just that unit tests pass.
- **Don't grep test output to detect pass/fail**: parsing runner output is fragile. Use the runner's exit code or a machine-readable reporter (JSON/JUnit).
- **CI workflow gotchas**: quote test globs on GitHub Actions so the shell doesn't expand them; commit `package-lock.json` or `npm ci` fails; Vitest fails the whole file when any imported module throws at import time.
- **Accessibility: focus management after modal close**: when a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it. Test all three close paths.
- **Boundary validation: non-negative quantities from external sources**: `!x` and `x === 0` guards do NOT reject negative numbers parsed from webhooks, API responses, or DB records. Check `x < 0` (and `Number.isFinite`) explicitly.
- **Batch loop resilience: isolate per-item failures**: an unguarded throw in one iteration aborts the ENTIRE batch, not just the bad item. Wrap per-item work, record the failure, continue.
- **Test a statistic at both sample parities**: an even-length median bug survives a suite that only uses odd-length inputs.
- **A fix proven on one app's corpus is NOT proven for a sibling app**: before sharing a module across sibling apps built from the same template, run it over the sibling's own stored production rows and read the diff by hand.
- **A hand-built fixture never tests the loader**: when a config file gains a field, add at least one test that writes a temp config, loads it through the real loader, and asserts the consumer sees the value.
- **A measurement rig fails the same ways the thing it measures does**: before collecting data, check that the quantity is measurable by construction.
- **A metadata-only log is still replayable**: a telemetry log that omits sensitive fields can be rejoined to the original transcripts/records by id to build a regression set; don't wait to "collect the real thing".
- **Touch drag needs Pointer Events, and raw CDP touch in tests does not auto-scroll**: implement drag on Pointer Events, and scroll targets into view yourself in tests.
- **A generated page passing `node --check` and a DOM-stub run proves nothing about readability**: screenshot the chart and look at it.
- **A bare URL in body text overflows the document without any element's bounding box reporting it**: detect overflow by comparing `scrollWidth` to `clientWidth` per element.
- **Test the whole field set a boundary forwards**: not just the fields the current implementation happens to use.
- **A response that narrates the work is not the work**: guard output SHAPE (the artifact, the structured result), not just the absence of error strings.
- **Ordering tests must assert the exact sequence, not set completeness**: for a non-total `ORDER BY` (ties, no unique tiebreaker), "page 1 union page 2 covers all rows exactly once" passes on the unfixed code. Assert the exact order across pages.
- **Re-deriving a metric breaks every site that differences it against a source still computed the old way**: grep for every consumer that subtracts or compares it and update them together.
- **A push gate flagging a dirty file during a live verifier run may be flagging the unfixed source**: confirm which version of the file the gate actually read before "fixing" it again.
- **A server-side-only default is invisible to JS-rendered markup**: a default exposed through a server-template accessor is correct wherever the server prints it and missing wherever client JS renders the same element. Test both render paths.
- **Test design variants against per-variant expectations**: not one generic assertion shared by all variants.
- **Run a throwaway WordPress locally with the SQLite drop-in**: no MySQL needed for theme/plugin tests.
- **A hidden filter button must not hide the work**: when a UI control is hidden, split the list the UI reads so items aren't silently excluded.
- **`git show ref:file > file` truncates the target before git runs**: a bad ref empties the file. Write to a temp file and move it on success.
- **A filter, count badge, or search box over a capped list silently under-reports**: compute against the full set, not the page or top-N.
- **A ranking over a capped list is not a ranking, and clamped weights collapse the ranking you did compute**: rank the full set and check that weights still discriminate after clamping.
- **A headless `claude --print` run inherits the host's CLAUDE.md and SessionStart hooks**: isolate the config (separate config dir, no hooks) before measuring anything.
- **Two mutation-testing traps for data-store write paths**: an assertion that only checks the return value, or only checks that some row changed, produces green suites over broken writes. Read back the specific record and assert the specific field.
- **A builder generating a deliverable from source lists must assert every entry appears exactly once before writing**.
- **A verdict parsed from a tool's stdout format can report all-failures on all-successes**: confirm against system state (exit code, files, rows), not the text.
- **A rotted LIVE control is indistinguishable from a detector regression unless a second, independent source is asked**.
- **Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes**: assert on `textContent`.
- **A stale-tolerant cached health probe is correct for a sampler and wrong for an explicit user choice**: when the user explicitly picks something, probe fresh.
- **Stamp a per-request marker in the shared builder every path already calls**: not at each call site, where one path will be missed.
- **A worktree created inside the repo makes the test runner double-count every test file**: an exact 2x baseline is the tell. Create worktrees outside the repo or exclude the path.
- **A negative assertion passes vacuously when the harness never produced the positive**: assert the positive case ran before trusting "X did not appear".
- **A build that imports every module runs any script's top-level `process.exit`**: this silently skips the build's own remaining checks. Guard script entry points.
- **A config flag that alters generation behavior must be benchmarked on the hard case**: not the easy one, where every setting looks equal.
- **Extracting JSON from an LLM response: match the first BALANCED run**: not greedy to the last bracket, not lazy to the first closing bracket. Applies to `{}` objects as well as arrays.
- **A `tsx` test script's delayed dynamic import cannot pull a type-only member out with `type X`**: import types statically.
- **Headless-smoke-test a static prototype via raw CDP + Node 22's global WebSocket**: no puppeteer dependency needed.
- **Playwright input events leak across a same-page navigation**: a reload after an interaction must reopen in a fresh page or context.
- **Prefer in-process route tests over a real loopback listener**: `server.listen(0, '127.0.0.1')` per test can hit `EPERM` in restricted sandboxes. Drive the app via supertest, an in-process request helper, or `app.handle()` with mock req/res. But per Mock Fidelity, a hand-rolled req/query object that normalizes input can make real-parser edge cases silently untestable.
- **Desktop key-injection E2E must confirm the target window is foregrounded before every keystroke burst**: `GetForegroundWindow()` right after launching an app can return whatever the user already had focused (Windows foreground lock), so keystrokes go to the user's live desktop instead of the test target.
- **A Playwright route handler that fulfills a redirect for a navigation doesn't route the follow-up request, and a `route.fetch` error can leak cookies into logs**: handle `isNavigationRequest()` with a same-origin client-side redirect, not a fulfilled 3xx; log only the first line of a `route.fetch` error.
- **A packaged app's selftest passing on CI only proves the CI machine, not the shipped bundle**: check what the app reads from the machine at runtime (CA paths, fonts, codecs, PATH tools) and assert it comes from the bundle, not the build host.
- **A per-item filter tested against a SET built from other items' outcomes flips for every item once any one item satisfies it**: e.g. an AI-fallback gate that checks membership in already-matched names instead of re-testing the current entry reads "nothing left to match" for the whole list after one deterministic match. All-match or all-miss fixtures can't catch this; use a MIXED list (one hit, one miss) and confirm the fallback still runs on the miss.
- **Moving UI state (filter, sort, tab) into the URL breaks tests that mock the router's `navigate()`, and makes previously unreachable values user-reachable**: drive the real router over an in-memory location so clicks really navigate and Back can be simulated, and give a hand-edited invalid value its own distinct UI state instead of letting it fall into the empty-results state.
- **An empty string reused as a wildcard collides with `.includes('')` being vacuously true**: a condition shared across branches that lets an empty value mean "match anything" becomes always-true when unnegated, or always-false once negated and ANDed with a sibling term. Test the empty case in EVERY branch that shares the comparison.
- **A stale-response guard keyed on query identity misses A->B->A**: a hook-level abort flag only protects state the hook itself sets, so a fetcher that sets component state in its own body must check the signal after every `await`. A secondary in-flight request (e.g. infinite scroll's next page) needs its own guard; keyed on query identity it re-matches when the user returns to a prior query, so bump a per-load counter instead. Test with manually resolved deferreds and include A->B->A, which passes a key-based guard despite being stale.
- **A SQL `LIKE ... ESCAPE` helper must escape the escape character itself**: escaping only `%`/`_` leaves `\` live, so a literal backslash consumes what follows (false negative), turns `\n`-style sequences into bare letters (false positive), or lets `\%` re-enable a wildcard (bypass). Use one self-including pass: `input.replace(/[\\%_]/g, (ch) => '\\' + ch)`. This recurs across codebases; grep for `ESCAPE` and check the helper's character class before trusting a hand-rolled one.
- **A dedup/merge cleanup must skip degenerate grouping keys and pick the keeper by surviving content, not recency**: group only on a valid non-empty key (rows with no key are not a group), dedupe by primary id before grouping (a repeated id can land in both keep and drop sets), and keep the oldest row whose backing content actually exists, skipping the group if none does. Pin timestamps in tests; same-millisecond saves make "oldest" ambiguous and mask the bug.
- **A guard on ONE field doesn't make the record safe for consumers of any OTHER field**: validating a dedup key reads as "records are clean", but every other field still passes through unguarded. A consumer that dereferences a different field (`platforms.toLowerCase()`) needs its own guard, and one inside a top-level orchestrator with no try/catch turns a single malformed record into a whole-run crash.
- **An unvalidated write endpoint can break a batch consumer for every row**: a PATCH that persists a field without a type check means any shared consumer (search/list) calling `.toLowerCase()` or `.some()` across all rows 500s for the WHOLE dataset. Validate types at the write boundary (400, write nothing); one write-time guard protects every future reader, where read-time guards must be replicated at each dereference. Test with a wrong-TYPE value, not just a missing one, and assert the batch consumer still works after the rejected write.
- **A green suite after a fix doesn't prove a new regression test discriminates; check the PRE-FIX failure per test**: `git stash push <source-file>` (keep the tests), run the affected tests, and confirm the failure count equals the number of tests meant to discriminate. A weak fixture can pass pre-fix too; add a DECOY input the buggy code mishandles in the opposite direction.
- **A regression test can pass on buggy code when an earlier `||`/`&&`/`?.`/early-return branch short-circuits first**: in `url.includes(q) || title... || notes.toLowerCase().includes(q) || tags.some(...)`, a query that matches the URL never reaches the crashing `notes` branch, so the test passes on unfixed code. Pick input that fails every earlier branch, and confirm the pre-fix failure happens at the EXPECTED branch, not just that it failed.
- **A page number moved into the URL makes "page past the end" reachable, and a clamped/OFFSET server returns 200 + empty, not 400**: the page then renders its genuine no-items state, a false claim. Detect `items.length === 0 && total > 0 && page > totalPages` and render a distinct "no page N" state with a jump to the last page; still mirror the server's 400 for values it does reject. Test with a fixture that is empty only past `totalPages`, plus a genuinely empty control.
- **A backlog note's impact claim ("500, no partial write") is a hypothesis**: before scoping a fix, reproduce the payload and check three things: HTTP status, persisted state (rows, files on disk), and a downstream read across all rows. Typical surprises: a falsy non-string value (`0`, `false`) stored with a 200 because the route only checked `!field`; and `x?.toLowerCase()` throwing on it later, because optional chaining only guards `null`/`undefined`. Prefer `x != null && typeof x === 'string'` over `x?.method()` whenever stored data may be any JSON type.
- **A one-shot CLI that reuses a daemon's "since last run" function inherits a window baselined at import, and module-mocked unit tests never execute the real top-level dispatch**: pass the window explicitly, and spawn the real process against scratch state to catch both the stale window and any TDZ crash the mocked tests missed.
- **A regex/prefix guard used as a security boundary needs anchor-drop mutants in its test suite**: plain traversal strings (`'..'`, `'../x'`, `'/tmp'`) are rejected even by a regex missing `^`/`$`, because they contain no valid-shaped substring. Test valid-shaped input with hostile suffixes and prefixes (`'<valid>/../..'`, `'../dir/<valid>'`), aimed at a target that actually exists, so dropping either anchor fails a test.
