<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards that extend your core agent rules.

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
- **Use typed mock helpers instead of `as any`:** Write factory functions that return complete typed objects instead of casting partial objects. This catches shape mismatches at compile time and removes lint warnings.

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

When a project keeps having quality problems (code ships that doesn't actually work), invest in testing in this order. Each layer cuts down the number of incidents the next layer has to catch.

| Priority | Layer | What It Catches | Cost |
|----------|-------|-----------------|------|
| 1 | Failure audit | Tells you where to invest | Hours |
| 2 | Contract tests | Mock drift, API shape mismatches | Low |
| 3 | Integration tests (real deps) | Backend logic, migrations, auth bugs | Medium |
| 4 | Post-deploy smoke tests | Config drift, bad deploys | Low |
| 5 | Authenticated browser tests | Auth flows, full-stack integration | High |

**Start at the top.** Don't skip to browser tests before the lower layers are done.

### Layer 1: Failure Audit

Before writing any new tests, classify the last 5-10 production incidents. For each one, record:
- What broke (auth, rendering, data, config, race condition)
- Whether a test existed for that path
- If a test existed and passed, *why* it passed when prod was broken (mock drift, shallow assertion, wrong environment config)
- When it was caught (pre-deploy, post-deploy, user report)

Put these in a simple table with one row per incident. The result tells you exactly which testing layer to invest in.

### Layer 2: Contract Tests

If incidents trace back to "the test passed with mocks but prod behaved differently," your mocks encode stale assumptions. Fix that with:
- Schema checks against real API responses recorded from staging
- A snapshot of the actual response shape from a real endpoint, with a check that the mocks match that shape
- Snapshot updates as part of the deploy pipeline

**When to use:** Any service boundary where you currently use mocks: external APIs, database queries, auth providers.

### Layer 3: Integration Tests with Real Dependencies

For backend logic failures (bad queries, broken migrations, auth provider interactions):
- Hit real databases, real auth providers, and real caches
- Set up state explicitly; each test owns its fixtures
- Run in CI; the tests stay deterministic if you own the fixture lifecycle
- **Don't mock the database.** Mock/prod divergence is the #1 source of false-green tests.

### Layer 4: Post-Deploy Smoke Tests

Lightweight, fast (under 30 seconds), non-browser checks against the deployed environment:
- Authenticate with a test account
- Hit the 3-5 most critical endpoints
- Assert HTTP 200 and the basic response shape (not just the status code)
- Run automatically after every staging deploy

This catches environment config drift and bad deploys right away. It is deployment validation, not e2e testing.

### Layer 5: Authenticated Browser Tests (Use Sparingly)

Only go here if the failure audit shows incidents that ONLY a real browser would have caught (broken auth flows, CORS/CSP issues, token refresh failures).

**Constraints:**
- 5-8 scenarios at most. Start by reproducing a specific past incident, not by writing speculative tests
- A dedicated test account with stable credentials, managed through secrets
- Run against staging only, never production
- Each test owns its state: setup creates what it needs, teardown removes it
- Assert on intercepted API responses, not just DOM elements
- Capture screenshots, network logs, and console errors on failure

**Flakiness policy:** Quarantine a test on its second consecutive flake and move it to a non-blocking suite until it's fixed. A flaky test the team ignores is worse than no test.

**Tag every test** with the failure mode it guards against (`@auth-flow`, `@regression-INCIDENT-42`).

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (past that, you're making up for missing integration tests; push coverage down the pyramid)
- Tests with no matching past incident (speculative tests cost a lot to maintain and rarely pay off)

## Rule Digest

One line per lesson, in the order they were learned.

- **Fallback chains hide dead rungs (test each branch in isolation)**: A fallback/waterfall (try A, else B, else C) is the riskiest structure for a **silent miss**. If an early rung dies, a later rung catches everything and the end-to-end result still looks fine. Test each rung on its own.
- **Testing shell scripts: don't stub a binary on PATH, stand up the real sink**: Shell scripts that send alerts (webhook, email, HTTP callback) need their alert path tested. The instinct is to put a fake `curl` earlier on `PATH`. Instead, run a local listener and assert what actually arrived.
- **Making Node.js servers testable**: Add an auto-start guard (only listen when run directly), isolate tests through environment variables, and use a factory pattern for dependency injection.
- **Test fixture schema drift**: When tests embed their own DDL (CREATE TABLE) or data shapes, those copies silently drift from the real schema as the app evolves. Load the real schema or migrations in tests.
- **CI test workflow**: Use a standard `.github/workflows/test.yml` that runs tests on every push and PR to the default branch.
- **Mock fidelity**: Mocks that diverge from production are worse than no mocks; they give false confidence.
- **Cross-layer invariant tests**: Find the invariants that must hold across layers (for example, the same value computed in the API and the UI must agree), write a test per invariant, name the tests consistently, and reuse common patterns across projects.
- **Zod validation in API routes**: Every Next.js API route that parses input with Zod **must** catch `ZodError` and return a 400.
- **Live browser testing**: To test a web app in a real browser during development, drive it with a browser automation tool (Playwright or CDP) instead of trusting unit tests for UI behavior.
- **Don't grep test output to detect pass/fail**: Parsing test runner output with `grep` to decide pass/fail is fragile. Use the runner's exit code or a structured reporter.
- **CI workflow gotchas**: Quote test globs on GitHub Actions; commit `package-lock.json` so CI can install; Vitest fails when any imported module throws at import time.
- **Accessibility: focus management after modal close**: When a modal, dialog, or lightbox closes (Escape, close button, backdrop click), focus must return to the element that opened it.
- **Boundary validation: non-negative quantities from external sources**: When you validate numbers parsed from external input (webhook payloads, API responses, database records, user data), `!x` and `x === 0` guards do NOT reject negative numbers. Check `x < 0` explicitly.
- **Batch loop resilience: isolate per-item failures**: When a loop processes a batch (DB rows, files, API records) and each iteration can throw on bad data, one unguarded throw aborts the ENTIRE batch, not just the bad item. Wrap each item, log, and continue.
- **Test a statistic at both sample parities, or an even-length median bug survives.**
- **A fix proven on one app's corpus is NOT proven for a sibling app**: Before sharing a module across sibling apps built from the same template, run it over the sibling's OWN stored production rows and read the diff by hand.
- **A hand-built fixture never tests the loader**: When a config file gains a field, add at least one test that goes through the **real loader**: write a temp config, load it, and assert the consumer sees the value.
- **A measurement rig fails the same ways the thing it measures does**: Check that it is measurable BY CONSTRUCTION before you collect data.
- **A metadata-only log is still replayable: rejoin it to the transcripts**: A shadow/telemetry log that deliberately leaves out sensitive fields looks untestable. Join it back to the source records by ID and replay instead of waiting to collect the full data.
- **Touch drag needs Pointer Events, and raw CDP touch in tests does not auto-scroll.**
- **A generated page passing `node --check` and a DOM-stub run proves nothing about whether the chart is readable**: Screenshot it and look.
- **A bare URL in body text can overflow the document without any element's bounding box reporting it**: Compare `scrollWidth` to `clientWidth` per element.
- **Test the whole field set a boundary forwards, not just the fields it happens to implement.**
- **A response that narrates the work is not the work**: Guard output SHAPE, not just error strings.
- **Ordering tests must assert the exact sequence, not set completeness**: When fixing a non-total ORDER BY (a sort key with ties and no unique tiebreaker), the obvious test ("page 1 plus page 2 covers all N rows exactly once") PASSES on the unfixed code. Assert the exact order.
- **Re-deriving a metric breaks every place that DIFFERENCES it against a source still computed the old way.**
- **A push gate flagging a dirty file during a live verifier run may be flagging the UNFIXED source.**
- **A server-side-only default is invisible to JS-rendered markup**: A WordPress theme can define a default (a tagline, a label, any copy) through a PHP accessor, and it will be correct everywhere PHP prints but missing wherever JavaScript renders the same element. Test both render paths.
- **Test design variants against per-variant expectations, not one generic assertion.**
- **Run a throwaway WordPress locally with the SQLite drop-in; no MySQL needed.**
- **A hidden filter button must not hide the work**: Split the list the UI reads so hidden items still exist.
- **`git show ref:file > file` truncates the target before git runs**: A bad ref empties the file. Write to a temp file and move it on success.
- **A filter, count badge, or search box over a capped list silently under-reports**: Compute against the full set.
- **A ranking over a capped list is not a ranking, and clamped weights collapse the ranking you did compute.**
- **A headless `claude --print` run inherits the host's CLAUDE.md and SessionStart hooks**: Isolate it before measuring anything.
- **Two mutation-testing traps for data-store write paths**: When mutation-testing a feature that writes to a data store (cancel, update, status change), assertions that only check the return value or only check "a write happened" produce green suites over broken code. Read the stored row back and assert its exact state.
- **A builder that generates a deliverable from source lists must assert every entry appears exactly once before writing.**
- **A verdict parsed from a tool's stdout format can report all failures on all successes**: Confirm against system state.
- **A rotted LIVE control is indistinguishable from a detector regression unless you ask a second, independent source.**
- **Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes**: Assert on `textContent`.
- **A stale-tolerant cached health probe is right for a sampler and wrong for an explicit user choice.**
- **Stamp a per-request marker in the shared builder every path already calls, not at each call site.**
- **A worktree created inside the repo makes the test runner double-count every test file**: The baseline inflates exactly 2x. Exclude the worktree directory from the runner.
- **A negative assertion passes vacuously when the harness never produced the positive**: Prove the positive case fires first.
- **A build that imports every module runs any script's top-level `process.exit`**: That silently skips the build's own checks. Guard script entry points.
- **A config flag that changes generation behavior must be benchmarked on the hard case, not the easy one.**
- **Extracting JSON from an LLM response: match the first BALANCED run**: Not greedy to the LAST bracket, and not lazy to the FIRST closing bracket either. This applies to objects `{}` as well as arrays.
- **A `tsx` test script's delayed dynamic import cannot pull out a type-only member with `type X`.**
- **Headless smoke-test a static prototype with raw CDP and Node 22's global WebSocket (no puppeteer needed).**
- **Playwright input events leak across a same-page navigation**: A reload after an interaction must reopen in a fresh page/context.
- **Prefer in-process route tests over a real loopback listener**: `server.listen(0, '127.0.0.1')` per test can hit `EPERM` in restricted sandboxes. Drive the app with an in-process request helper, supertest, or `app.handle()` with mock req/res. But see Mock fidelity: a hand-rolled req/query object that normalizes input can make real-parser edge cases silently untestable.
- **Desktop key-injection E2E must confirm the target window is in the foreground before every keystroke burst**: `GetForegroundWindow()` right after launching an app can return whatever the user already had focused (Windows foreground lock), so keystrokes go to the user's live desktop instead of the test target.
- **A Playwright route handler that fulfills a redirect for a navigation doesn't route the follow-up request, and a `route.fetch` error can leak cookies into logs**: Handle `isNavigationRequest()` with a same-origin client-side redirect, not a fulfilled 3xx, and log only the first line of a `route.fetch` error.
- **A packaged app's selftest passing on CI only proves the CI machine, not the shipped bundle**: Find what the app reads from the machine at runtime (CA paths, fonts, codecs, PATH tools) and assert it comes from the bundle, not the build host.
- **A per-item filter tested against a SET built from other items' outcomes flips for every item once any one item satisfies it**: A fallback gate that checks membership in "already matched" results instead of re-testing the current item will read "nothing left to match" for the whole list as soon as one item matches. An all-match or all-miss test list can't catch this. Use a MIXED list (one hit, one miss) and confirm the fallback still runs on the miss.
- **Moving UI state (filter, sort, tab) into the URL breaks tests that mock the router's `navigate()`, and makes a previously unreachable value reachable**: Drive the real router over its in-memory location so clicks really navigate and Back can be simulated. Give a hand-edited invalid value its own distinct UI state instead of letting it fall into the empty-results state.
- **An empty string reused as a wildcard/sentinel collides with `.includes('')` being vacuously true**: A condition shared across branches (`value.includes(x)`) that also lets an empty `x` mean "match anything" becomes always-true when unnegated, or always-false once negated and ANDed with a sibling term. Test the empty case in EVERY branch that shares the comparison, not just the one that already broke.
- **A stale-response guard keyed on query identity (user|filter) misses A->B->A**: A hook-level abort/ignore flag only protects state the hook itself sets, so a fetcher that sets component state in its own body must also check the signal after every await. A secondary in-flight request (for example, infinite scroll's next page) needs its own guard, and keying that guard on query identity re-matches when the user returns to an earlier query; bump a per-load counter instead. Test with manually resolved deferreds and include the A->B->A case, which passes on a key-based guard even though the response is stale.
- **A SQL `LIKE ... ESCAPE` helper must escape the escape character itself, not just the wildcards**: Escaping only `%`/`_` leaves the escape char (often `\`) live. A literal occurrence then eats whatever follows (false negative), turns a `\n`-style sequence into a bare letter (false positive), or lets a leading `\%` re-enable a wildcard the escaping was meant to neutralize (bypass). The fix is one self-including regex pass: `input.replace(/[\\%_]/g, (ch) => '\\' + ch)`. This bug recurs across codebases; grep for `ESCAPE` and check the helper's character class before trusting any hand-rolled one.
- **A dedup/merge cleanup must skip degenerate grouping keys and pick the keeper by surviving content, not recency**: A tool that groups duplicate records and deletes the losers can pass its happy-path tests and still lose data on real legacy rows. Group only on a valid, non-empty key (rows with no key are not a group). Dedupe by primary id before grouping (a repeated id can land in both the keeper set and the drop set). Choose the keeper as the oldest row whose backing content actually exists, and skip the group entirely if none does. Pin timestamps in tests; same-millisecond saves make "oldest" ambiguous and hide the bug.
- **A guard on ONE field doesn't make the record safe for consumers of any OTHER field**: Validating a collector's dedup key (for example, `title`) reads downstream like "records are clean", but every other field still passes through unguarded from the untrusted source. A consumer that dereferences a different field (for example, `platforms.toLowerCase()`) needs its own guard at its own dereference point. If that consumer sits inside a top-level orchestrator with no try/catch, one malformed record crashes the whole run instead of failing locally.
- **An unvalidated write endpoint can break a batch consumer for every row, not just the one it wrote**: A PATCH route that stores a field with no type check doesn't just corrupt that row. If a shared consumer (search/list) runs a type-specific call (`.toLowerCase()`, `.some()`) across every row, one bad write 500s that consumer for the WHOLE dataset. Validate types at the write boundary (return 400, write nothing) instead of defending every batch consumer separately. A write-time guard protects every future reader in one place, while the read-time guard above has to be repeated at each dereference and is easy to miss once. Test with a wrong-TYPE value (not just a missing one), and assert the batch consumer still works after the rejected write.
- **A green suite after a fix doesn't prove a new regression test discriminates: check the PRE-FIX failure per test, not just the total count**: Run `git stash push <source-file>` (keep the tests), run the affected tests, and confirm the failure count equals the number of tests you expect to discriminate. A test can also pass pre-fix if its fixture is too weak; add a DECOY input that the buggy code mishandles in the opposite direction. The next entry covers a second way a test can look properly isolated and still pass pre-fix.
- **A regression test can pass on buggy code when an earlier `||`/`&&`/`?.`/early-return branch short-circuits before the faulty one runs**: Seeing a new test pass pre-fix isn't enough unless you check WHY. A multi-branch condition (`url.includes(q) || title... || notes.toLowerCase().includes(q) || tags.some(...)`) only exercises the branch that matches first, so a query term found in the URL never reaches the crashing `notes` branch, even with a type-invalid `notes` value stored. Pick a query term that fails every earlier branch so evaluation reaches the one under test, and confirm the pre-fix failure happens at the EXPECTED branch, not just that something failed.
- **A page number moved into the URL makes "page past the end" reachable, and a clamped/OFFSET server returns 200 plus an empty list for it, not 400**: This is the sibling of the filter/sort/tab-in-URL lesson, but here the invalid value isn't rejected. `?page=N` past the last page gets a 200 with an empty list and `total > 0`, which the page shows as its genuine "no items" state, a false claim. Detect it as `items.length === 0 && total > 0 && page > totalPages` and show a distinct "no page N" state with a link to the last page; still mirror the server's 400 for values it does reject. Test with a fixture that returns empty only past `totalPages`, plus a genuinely empty control, so the two states can't be confused.
- **A backlog note's impact claim ("500, no partial write") is a hypothesis, not a fact**: Before scoping a fix from an earlier note's description of a bug's blast radius, reproduce the payload and check three things, not one: the HTTP status, the stored state (index rows, files on disk), and a downstream read across all rows. Such notes are often wrong once probed. For example, a falsy non-string `title` (`0`, `false`) can be stored with a 200 because the route only checked `!url`, and `e.title?.toLowerCase()` then throws on every search, because optional chaining only guards `null`/`undefined`, not other falsy values. Prefer `x != null && typeof x === 'string'` over `x?.method()` whenever stored data may be any JSON type.
- **A one-shot CLI that reuses a daemon's "since last run" function inherits a window baselined at import time, and module-mocked unit tests never run the real top-level dispatch**: Pass the window explicitly, and spawn the real process against scratch state to catch both the stale-window bug and a TDZ crash that mocked tests miss.
- **A regex/prefix guard used as a security boundary needs anchor-drop mutants in its own tests, not just valid/invalid inputs**: Testing plain traversal strings (`'..'`, `'../x'`, `'/tmp'`) against an allowlist regex passes even when the regex lacks its `^`/`$` anchors, because those inputs contain no valid-shaped substring for an unanchored pattern to match *inside*. The anchors only matter once a hostile string also contains something the pattern accepts, such as `'<uuid>/../..'`. Test valid-shaped input with a hostile suffix and prefix (`'<valid>/../..'`, `'../dir/<valid>'`), aimed at a target that actually exists, so dropping `^` or `$` fails a test.
- **Serving a built app from inside a `.claude/worktrees/` checkout 404s every SPA deep-link route, and looks exactly like a broken catch-all**: Express's `res.sendFile`/`send` (default `dotfiles: 'ignore'`) 404s any absolute path that contains a dot-segment directory like `.claude/`. A build run from a worktree serves `/` and static assets fine (relative `express.static` root) but 404s the SPA fallback route. Copy `dist/` to a plain path outside any dotfile directory before checking it in a browser.
- **After refactoring code you only tested ad hoc, rerun the earlier ad-hoc checks, or save them as a test file the first time**: A mock/stub test that only covers the branch the refactor didn't touch proves nothing about the branch it did touch.
- **A self-written synthetic test can share the bug's own assumption and still pass**: If it was built from a belief about the system instead of measured against it, the test agrees with the code instead of checking it. Ask what the test would do if your model were wrong; if the answer is "pass", it's an echo, not a check.
