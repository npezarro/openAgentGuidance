<!-- Load when: writing and running tests, cross-layer invariants -->
# Testing Guidance

Detailed testing standards: when to test, how to structure tests, and lessons learned about tests that pass while the code is broken.

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
- What broke (auth, rendering, data, config, race condition, deploy)
- Whether a test existed for that path
- If a test existed and passed, *why* it passed when prod was broken (mock drift, shallow assertion, wrong environment config)
- When it was caught (pre-deploy, post-deploy, user report) and how long it took to fix

Then map each root-cause pattern to its fix:

| Pattern | Fix |
|---------|-----|
| Mock passed, prod failed | Contract tests (Layer 2) |
| No test existed for the path | Integration tests (Layer 3) |
| Test existed but was too shallow | Deeper assertions |
| Environment config mismatch | Post-deploy smoke tests (Layer 4) |
| Only visible in a real browser | Browser tests (Layer 5) |

Invest in this order: the highest-count category first, then the most common root-cause pattern, then automated detection for the longest time-to-fix incidents.

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

## What NOT to Build

- Browser tests against production (test data leaks into real systems)
- More than 8-10 browser test scenarios (you're compensating for missing integration tests; push coverage down the pyramid)
- Tests without a corresponding past incident (speculative tests have low ROI and high maintenance cost)

## Cross-Layer Invariant Tests

The highest-value tests are often not about individual functions; they are about **invariants between layers** that silently break when one layer changes without updating the other. An invariant is a property that must hold for the system to work even though no single function enforces it (e.g. "every entity a location query filters on has lat/lng set at creation", "the API response includes the field the UI destructures").

**Write one whenever:**
1. You just fixed a cross-layer bug. The fix goes in the code; the invariant test is the regression test for the *class* of bug.
2. One system produces data another consumes (pipeline, database, API, UI: each boundary is an invariant).
3. A filter or query depends on data shape (if `WHERE lat IS NOT NULL` exists anywhere, test that the producer always sets lat).
4. Display formatting depends on API response shape.

**How:** test the contract (the shape and constraints of data crossing the boundary), usually without a database:

```typescript
describe("Pipeline -> Planner invariant", () => {
  it("pipeline-created stores must have coordinates", () => {
    const store = createPipelineStore("chain", "00000");          // shape the producer emits
    const visible = [store].filter(s => s.lat != null && s.lng != null); // filter the consumer applies
    expect(visible).toHaveLength(1);
  });
});
```

Name invariant test files after the boundary they guard (`pipeline-stores.test.ts`, `price-display.test.ts`).

**Recurring invariants in full-stack projects:** geocoding completeness at creation time; API response shape matches what the frontend destructures; serialization round-trips survive `JSON.parse(JSON.stringify(x))`; every auth-gated endpoint returns 401 (not 500) when unauthenticated; string/number unit boundaries (`"2.99"` vs `2.99`) are parsed explicitly; localStorage hydration normalizes parsed values (a try/catch only guards parse *throws*, not valid JSON from an older schema that crashes later on `.length`; test with stale/partial schemas).

## Rule Digest

One entry per lesson, in the order they were learned.

- **Fallback chains hide dead rungs; test each branch in isolation.** In a try-A-else-B-else-C waterfall, a dead early rung is masked by a later one and end-to-end output still looks right. Force each rung with the later ones disabled, ship a canary that asserts *which* rung won, and drive the real shipped code path, never a reimplementation of it.
- **Testing shell scripts: don't stub a binary on PATH, stand up the real sink.** Scripts that harden their own PATH (common for cron-safe scripts) find the system `curl` before your stub, so the test observes nothing and passes. Bind a throwaway local HTTP listener on port 0 and point the script's webhook variable at it. Also add an `env -i PATH=/usr/bin:/bin HOME=$HOME` case (cron's PATH), test state-file format upgrades against the OLD format, and replace `curl ... || true` with a captured `%{http_code}` you assert on.
- **Making Node.js servers testable.** Guard `app.listen()` so importing doesn't start the server (`require.main === module`, or `process.argv[1] === fileURLToPath(import.meta.url)` in ESM) and export `app`; point data at a temp dir via an env var like `DATA_DIR`; export a `createServer(deps)` factory so tests inject dependencies without module patching.
- **Test fixture schema drift.** Tests that embed their own DDL or data shapes drift from the real schema. Import schema from app code or derive it from the same migrations; when adding a column, grep test files for the table name.
- **CI test workflow.** Add `.github/workflows/test.yml` running `npm ci && npm test` on push and PR to the repo's actual default branch (`main` vs `master`). Pin a specific current LTS Node version rather than `lts/*`. When adding a repo's first tests, add the workflow in the same change.
- **Mock fidelity.** Mocks that diverge from production are worse than no mocks. Record real responses as fixtures, re-record periodically, validate mock shape against the real schema in CI, never hand-write external API data. If a mocked test passes but prod is broken, the mock is the bug. The same applies to hand-rolled test *clients*: one that flattens duplicate query params (`?a=1&a=2`) makes array-valued input structurally unreachable, so guards against it look tested but aren't. Drive that class of guard through the framework's real parser (supertest or a real listener).
- **Cross-layer invariant tests.** See the section above.
- **Zod validation in API routes.** Every route that calls `.parse()` must catch `ZodError` and return 400 with the error details; otherwise validation failures surface as 500s. When auditing, check *every* route; it's easy to miss one.
- **Live browser testing.** For debugging UI during development, a driver attached to your real browser (real cookies, real session) shows exactly what the user sees; prefer it over headless for local verification, and keep headless for CI.
- **Don't grep test output to detect pass/fail.** A test *named* "handles errors" flips a `grep -i "error\|fail"` gate. Gate on the exit code (`OUT=$(npm test 2>&1) || EXIT=$?`); grep output only for human-readable metadata like pass counts.
- **CI workflow gotchas.** Single-quoted `'test/**/*.test.js'` globs aren't expanded on GitHub Actions (`globstar` off), so tests are silently skipped: use a flat glob or let the runner find tests. `npm ci` with `cache: npm` requires a committed `package-lock.json`. A module that throws at import time (e.g. `new PrismaClient()` or a required env var read at load) crashes the whole Vitest run before any test executes: set a dummy value in `vitest.config.ts` `test.env` or a setup file.
- **Accessibility: focus management after modal close.** When a modal/dialog/lightbox closes, return focus to the element that opened it (WCAG 2.4.3). Capture the trigger ref on open, restore it on close, and write one test per close path (Escape, close button, backdrop) asserting `document.activeElement === trigger`.
- **Boundary validation: non-negative quantities from external sources.** `!x` and `x === 0` don't reject negatives. For measured quantities (distance, duration, count, price) from external input use `<= 0`, keep sibling adapters' guards consistent, and test the negative case explicitly alongside zero.
- **Batch loop resilience: isolate per-item failures.** An unguarded throw inside a batch loop aborts the whole batch. Guard the throwing operation (`new RegExp(external)`, `JSON.parse(external)`, division by a data-derived value) and wrap each iteration in try/catch + continue. Compile invariant regexes once, outside the loop.
- **Test a statistic at both sample parities.** `sorted[Math.floor(len / 2)]` is wrong for even-length samples and biases the median upward only. For any median/percentile, test odd, even, single, empty and unsorted input; assert the computed VALUE, not that the field rendered; confirm numeric sort (`(a, b) => a - b`); check for in-place mutation of the caller's array; and add a test at the decision level if the statistic feeds a threshold. One-sided errors bias every downstream decision the same way; rank them above symmetric noise.
- **A fix proven on one app's corpus is NOT proven for a sibling app.** Before sharing a module across sibling apps, run it over the sibling's own production data and read the diff by hand. Audit precision (what got removed), not just recall (did it fire). Change the shared module and re-verify the original to byte parity rather than forking. A guard that "only hides, never deletes" still needs this scrutiny, because its damage is invisible.
- **A hand-built fixture never tests the loader.** When a config file gains a field, add at least one test that writes a temp config, runs the REAL loader, and asserts the consumer sees the value. A validator that destructures a field and then returns an object without it passes every unit test built on literal objects and the type checker.
- **A measurement rig fails the same ways the thing it measures does.** Before collecting, compute the expected number of observations under the null; if it rounds to zero, the metric is decoration. Run controls before acting on a new signal (it may be an echo of your own reads). Version-stamp the rig (hash matcher source, inputs, thresholds into every record) and make the scorer refuse to average across versions. Stop when rig effort exceeds the prize.
- **A metadata-only log is still replayable: rejoin it to the source.** A telemetry log that omits sensitive fields (e.g. stores only prompt length) can often be rejoined to another store that kept them, on keys like (session id, timestamp within a few seconds, exact length). Filter out lookalike records (tool results stored as user messages), assert exact values in order rather than overlap, and report the recovery rate as part of the result.
- **Touch drag needs Pointer Events, and raw CDP touch in tests does not auto-scroll.** HTML5 drag-and-drop doesn't fire on touch; use pointer events with `setPointerCapture` and `touch-action: none`, ship a tap/keyboard fallback, and let a release over dead space fall back to the last hovered target. In tests, raw `Input.dispatchTouchEvent` doesn't scroll into view: scroll both ends on-screen and assert they're visible before dispatching.
- **A generated page passing syntax checks and a DOM-stub run proves nothing about readability: screenshot it and look.** Broken colour scales, truncated labels and indistinguishable bars pass every automated check. Use headless Chrome (`google-chrome --headless --disable-gpu --screenshot=out.png file://$PWD/page.html`) and inspect the image. Also confirm the build output literally names the file you added; a guarded import can skip it while exiting 0.
- **A bare URL in body text overflows the page without any bounding box reporting it.** Compare `el.scrollWidth > el.clientWidth + 1` per element instead of checking `getBoundingClientRect().right`. Fix with `overflow-wrap: anywhere` on text blocks rendering third-party text, and re-test after any client-side re-render of the same markup.
- **Test the whole field set a boundary forwards.** A loader/serializer/mapper that forwards a subset of fields passes N single-field tests forever. Assert the complete field set round-trips (`parsed == constructed`). Forward only keys present and let the type supply its own defaults (don't duplicate them as fallbacks), and coerce types at the boundary with an error naming the entity and field.
- **A response that narrates the work is not the work: guard output SHAPE, not just error strings.** A well-formed, confident status report ("all agents completed, the guide was delivered above") can be stored as a completed answer while containing nothing. Add a guard on the shape of a valid answer, requiring several independent conditions (short residual after stripping narration, a narration/deferral phrasing match, no substantive markers like links, lists, tables) so it never deletes a real terse answer. Run it over the whole stored corpus before trusting it. Separately: a committed change that needs a rebuild is inert until the rebuild; verify the running artifact, not the commit.
- **Ordering tests must assert the exact sequence, not set completeness.** For a non-total `ORDER BY` (ties with no unique tiebreaker), "page 1 + page 2 cover every row once" passes on the unfixed code because drops only happen when the query plan changes between pages. Assert the exact sequence with fixtures whose insertion order differs from the intended order, or create an index between fetching page 1 and page 2. Also grep for `LIMIT`/`.slice()` over queries with NO `ORDER BY` at all.
- **Re-deriving a metric breaks every site that DIFFERENCES it against a source still computed the old way.** Before changing how a metric is derived, grep every consumer that subtracts, compares, ranks or thresholds it, including a second call to the same function with different inputs. Deltas, sparklines, "vs last week" and baselines all have this shape, and a same-file unit test cannot catch it. Also: don't quote a range from a convenience sample.
- **A push gate flagging a dirty file during a live verifier run may be flagging the UNFIXED source.** If a verifier is temporarily reverting files to prove discrimination, `git show HEAD:<file> | diff - <file>` before committing; if HEAD has the fix and the working tree doesn't, wait. Report added tests and net suite delta separately.
- **A server-side-only default is invisible to JS-rendered markup.** A default applied in a template accessor is missing wherever JS renders from the raw JSON payload. Apply defaults where the payload is assembled so every reader sees the same value, and test the reader that `curl` can't see.
- **Test design variants against per-variant expectations, not one generic assertion.** For N variations of one deliverable, declare per variant what to click, what must become visible, and what's expected on load. A shared assertion either fails correct variants or gets weakened until it catches nothing.
- **Run a throwaway WordPress locally with the SQLite drop-in, no MySQL needed.** WordPress core plus the official `sqlite-database-integration` plugin's `db.copy` (copied to `wp-content/db.php`, placeholders filled), `wp-cli` for `core install`, and `php -S 127.0.0.1:PORT` gives a real install in minutes. Needs `php-cli php-sqlite3 php-mbstring php-xml php-curl php-zip` (plus `php-gd` for media). Use `wp eval-file` to drive plugin internals, loading `wp-admin/includes/admin.php` and calling `wp_set_current_user(1)` first.
- **A hidden filter button must not hide the work, so split the list the UI reads.** When one taxonomy list feeds both a filter bar and structural rendering (section headings, proportion strips), emit a visible list for the bar and a full list for structure, then assert in a browser that hiding a term changes only the bar.
- **`git show ref:file > file` truncates the target before git runs, so a bad ref empties the file.** Back up the fixed file, stage the old version through a temp file, copy it in, run tests, restore. Verify with `git diff --stat <ref> -- <path>`. Note `git stash` reverts to HEAD, not the merge base.
- **A filter, count badge, or search box over a capped list silently under-reports: compute against the full set.** "No results" over a render cap reads as a statement about the database. Before shipping, print "N in full set vs M in rendered list" against real data. Pin qualifying rows into the capped query when the set is small and known server-side; serve a lazy uncapped endpoint (same `ORDER BY`) for arbitrary client-side search. Re-check caps as data grows, and cap different kinds of rows separately.
- **A ranking over a capped list is not a ranking, and clamped weights collapse the ranking you did compute.** Paginate the render, not the query. Size weights so a perfect item lands exactly on the ceiling and print the score histogram (count of distinct scores, count at the ceiling). Replay the scorer against a copy of real data. Keep model scores and heuristic estimates distinguishable: a missing score must not become 0, and estimates must be capped below the model's range.
- **A headless `claude --print` run inherits the host's global CLAUDE.md and SessionStart hooks; isolate before measuring.** Point `CLAUDE_CONFIG_DIR` at a temp dir containing only the credentials file, or your "empty" control arm isn't empty. If you can't isolate, label results as including host guidance. For generation runs, the same leak puts host context into published output, so exclude it before the run.
- **Two mutation-testing traps for data-store write paths.** `indexOf` returns -1 for a missing entry, so `writeAt < abortAt` passes when no write happened: assert existence first. An exclusion assertion ("cancelled row not selected") passes vacuously when the pass selects nothing: pair it with a positive control.
- **A builder generating a deliverable from source lists must assert every entry appears exactly once before writing.** Read the live source, not a cached intermediate; assert coverage and uniqueness separately; count the live source at run time rather than a hardcoded expected total.
- **A verdict parsed from a tool's stdout can report all-failures on all-successes; confirm against system state.** Read the tool's real output format first, then confirm failures by listing/querying the destination before reporting or retrying. A retry is only safe if the operation is idempotent.
- **A rotted LIVE control is indistinguishable from a detector regression unless a second, independent source is asked.** Controls whose expected verdict is perishable (live, in-stock, reachable) need automated rot-vs-regression triage using a signal the detector doesn't consult, and the failure message should name the cause. Also audit passing controls: one can go green for the wrong reason.
- **Playwright `allInnerTexts()` returns empty strings for SVG `<text>` nodes; assert on `textContent`.** `innerText` is HTML-only. Use `evaluateAll(els => els.map(e => e.textContent))`.
- **A stale-tolerant cached health probe is correct for a sampler and wrong for an explicit user choice.** When a user can pick a dependency that was previously only an internal fallback, re-audit its readiness checks: a cold cache answers "unavailable" on the first request. Keep the cheap cached variant for the sampler, do a blocking probe on the explicit path, disclose any downgrade in the output, and test that the FIRST request reaches the dependency.
- **Stamp a per-request marker in the shared builder every path already calls, not at each call site.** Count call sites first; three or more means find the choke point. Prefer deriving the value there over adding a parameter, mirror the change in any parallel implementation in the same commit, give the choke point its own tests including the degraded case, and assert ordering/adjacency if the receiver depends on it.
- **A worktree created inside the repo makes the test runner double-count every test file.** Runners that glob the working tree discover nested worktree copies, inflating counts exactly 2x while staying green. Take baselines from a worktree outside the repo (e.g. under `/tmp`), compare the runner's file count with `find . -path ./node_modules -prune -o -name '*.test.*' -print | wc -l`, and remove in-repo worktrees when done.
- **A negative assertion passes vacuously when the harness never produced the positive.** For every "X is absent" test, run a case where X should be present and confirm it fails. Print captured output on failure, use `${VAR:-default}` in harnesses (so `set -u` doesn't silently abort against old versions), and read generated fixture scripts for backticks, `$` and quotes interpreted at the wrong level.
- **A build that imports every module runs any script's top-level `process.exit`, silently skipping its own checks.** Guard every script's `main()` with `import.meta.url === pathToFileURL(process.argv[1] || '').href`, and have the validator assert that guard exists. Also: `cmd | tail` takes tail's exit code; check exit codes unmasked.
- **A config flag that alters generation behavior must be benchmarked on the hard case, not the easy one.** Never promote a flag on one hand-picked call. Re-run the full benchmark suite and diff accuracy and latency against the recorded baseline; regressions can be invisible in any single response.
- **Extracting JSON from an LLM response: match the first BALANCED run.** A greedy `/\[[\s\S]*\]/` (or `{...}`) overshoots to the last bracket when the model appends anything; a lazy `*?` stops at the first nested close. Try `JSON.parse` on fence-stripped text first, then scan from the first opener tracking depth and skipping characters inside string literals (honoring `\"`), returning when depth hits 0. Test fenced, prose-wrapped, trailing-noise and nested inputs.
- **A `tsx` test script's delayed dynamic import cannot pull a type-only member out with `type X`.** `const { fn, type Foo } = await import(...)` is a transform error. Hoist the type to a top-level `import type { Foo } from "..."` (erased at compile time, so no side effects) and keep only runtime values in the dynamic import.
- **Headless-smoke-test a static page via raw CDP and Node 22's global WebSocket, no puppeteer.** Launch `google-chrome --headless=new --remote-debugging-port=N --user-data-dir=/tmp/x about:blank`, read `webSocketDebuggerUrl` from `/json/version`, `Target.createTarget` + `Target.attachToTarget({flatten:true})`, then use `Runtime.evaluate` to click and read state and subscribe to `Runtime.consoleAPICalled`/`Runtime.exceptionThrown` to assert zero errors. Serve the directory with a tiny `node:http` server so relative assets load.
- **Playwright input events leak across a same-page navigation, so a reload after an interaction must reopen in a fresh page/context.** The last click or Escape before `goto()` can re-fire on the reloaded page. Reopen with `context.newPage()` to test "interact, then reload".
- **Desktop key-injection E2E must confirm the target window is foregrounded before every keystroke burst.** `GetForegroundWindow()` right after launch can return the user's existing window (foreground lock), sending keystrokes to their live desktop. Find the window by the launched PID, raise it, verify it's in front before each burst, and abort otherwise. Reconcile hotkey state against the OS key state rather than trusting press/release events to be complete.
- **A Playwright route handler that fulfills a redirect for a navigation doesn't route the follow-up request, and `route.fetch` errors can leak cookies into logs.** For `req.isNavigationRequest()`, fetch with `maxRedirects: 0` and fulfill a 200 page doing `location.replace(target)` so the next hop is routed. Log only `e.message.split('\n')[0]`. Use `'load'` plus a capped `networkidle` wait on pages that poll.
- **A packaged app's selftest passing on CI only proves the CI machine, not the shipped bundle.** For anything the app reads from the host at runtime (CA bundle paths, fonts, codecs, PATH tools), assert the resolved value comes from inside the bundle, not just that the operation succeeded. Example: a bundled Python's OpenSSL may look for a CA file that exists on CI runners but not on users' machines; set `SSL_CERT_FILE` to `certifi.where()` and assert the path.
- **A per-item filter tested against a SET built from other items' outcomes flips for every item once any one item satisfies it.** Re-test the current item, not membership in an aggregate of prior results. All-hit or all-miss fixtures can't catch this; use a MIXED list (one hit, one miss) and confirm the fallback still runs on the miss.
- **Moving UI state (filter, sort, tab) into the URL breaks tests that mock the router's `navigate()`, and makes invalid values user-reachable.** Drive the real router over an in-memory location so clicks really navigate and Back can be simulated. Give a hand-edited invalid value its own "doesn't exist" state instead of the empty-results state, clear stale content from the previous value, and make re-selecting the current value a no-op.
- **An empty string reused as a wildcard/sentinel collides with `.includes('')` being vacuously true.** It becomes always-true directly, or always-false once negated and ANDed with a sibling term. Test the empty case in EVERY branch sharing the comparison, and prefer rejecting empty values at creation time.
- **A stale-response guard keyed on query identity misses A->B->A.** A hook-level ignore flag only protects state the hook sets; a fetcher that sets component state itself must check the abort signal after every `await`, and secondary in-flight requests (next-page loads) need their own guard keyed on a per-load counter, not the query key. Test with manually resolved deferreds and include A->B->A.
- **A SQL `LIKE ... ESCAPE` helper must escape the escape character itself, not just the wildcards.** Escaping only `%`/`_` leaves `\` live, causing false negatives, false positives, and wildcard-injection bypass (`\_` re-enables `_`). Fix in one pass: `input.replace(/[\\%_]/g, (ch) => '\\' + ch)`. This recurs independently across codebases: grep for `ESCAPE` and check the helper's character class. The same applies to any hand-rolled escaper (shell, regex, CSV) where the escape character is legal input.
