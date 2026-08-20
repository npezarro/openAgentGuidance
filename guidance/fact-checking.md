<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

An agent answering a "should I sign up for this?" question asserted two rules about a financial product from memory: one was outdated (the issuer had unified the product family, changing eligibility), one was simply backwards. Both were stated confidently, both were material to the decision, and both were only corrected after the user pushed back. A third error came from trusting a stale local notes file over the user's own statement about their own account.

The failure mode is NOT "the model didn't know." It's that the model answered anyway, and that deciding when to check was left to the model's own judgment of whether a domain felt "fast-moving."

## The rule

**If a factual claim is (1) external to your own systems and (2) actionable by the user, verify it with a current search before asserting it. No self-assessment of volatility.**

Covered claim classes (non-exhaustive):
- Credit card / bank / issuer rules: bonus eligibility, product-family language, credit stacking, application rules, offer amounts and deadlines
- Prices, fees, promotions, availability of products or services
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal/policy/immigration facts, program rules, published schedules

Not covered (verify against internal sources instead): anything about the user's own accounts, infrastructure, repos, or history. For those, the actual source (the database, the mailbox, git, the user's own statement) is the check.

## Procedure

Before posting a research-type answer (recommendations, comparisons, eligibility / how-much / what-happens-if questions), run the draft through a fact-check pass:

1. Extract the discrete external-actionable claims from the draft
2. Run a current-year web search per claim (in parallel)
3. Assign per-claim verdicts: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED
4. Revise the answer for anything not CONFIRMED, and label UNVERIFIED claims as unverified in the final answer

For a single claim mid-conversation, a direct web search with the current month and year in the query is an acceptable lightweight equivalent, but the search must actually happen before the assertion is posted.

## Precedence of sources

1. **The user's own statement about their own accounts/actions**: beats everything for existence-type facts; if internal data disagrees, the data is stale. Say so, verify at the real source, fix the data.
2. **Current primary/web sources** (issuer terms pages, official docs, reputable independent trackers): required for external rules and offers.
3. **Internal curated files** (your own notes, your knowledge base): authoritative only for what they own (detail you recorded yourself, account numbers), never for external rules, and never over the user.
4. **Model memory**: never sufficient for a covered claim. It generates the hypothesis; the search confirms it.

## Contradicting your own prior research

If an earlier turn in the same conversation established a researched fact and you are about to assert the opposite, that is a red flag, not a correction. Re-verify with a search and explicitly reconcile ("earlier I found X; the search now shows Y because Z"); never silently flip.

## Deliverable URL liveness

Any URL you write into a deliverable that leaves your control (resume, portfolio, cover letter, social post, anything sent or published) is an externally-checkable fact. Before writing it, curl the exact URL and confirm it serves the intended public page (HTTP 200 plus a real page, not a redirect to login and not a bare API). Gate the write on the check; do not ship a hedge like "confirm live status" about something you could verify in seconds.

These are NOT liveness signals, and each has burned a real deliverable:
- a repo exists on disk (`ls $HOME/<repo>` says nothing about a public URL);
- a process manager reports the service `online` (a running service with only `/api/*` routes serves no browsable page);
- a memory or index line says "LIVE" (memories are point-in-time and often mean "deployed", not "public page exists"; read the full memory, not just the one-line index, and then still curl it).

Minimal check:

```bash
curl -sSL -o /dev/null -w '%{http_code} %{url_effective}\n' "<exact-url>"
```

A 200 that lands on a login URL is not a pass. Follow up by fetching the body and confirming the intended content is actually on the page.

## "Known / reputable brand" is a factual claim: verify provenance

Calling a brand "known", "established", "reputable", or "trusted" is an externally-checkable claim, not flavor. Do not assert it from marketplace star counts or review volume; that is the exact fake-review signal a skeptic gate is supposed to catch, laundered into credibility. Before applying any such label, run one search (`who makes <brand>` / `<brand> company history`) and classify:

- **Established**: an independent company with verifiable history and distribution beyond a single marketplace.
- **Marketplace-native label**: an invented seller brand (often an all-caps or nonsense word) sold mainly on one or two marketplaces with no independent history. Never call these "known brands"; they can still be fine budget picks, but justify that on specific evidence, not borrowed reputation.

Never contradict your own skeptic gate: flagging "no-name" products as a trap while presenting same-tier marketplace-native brands as "known brands" in the same guide is the failure this rule exists to prevent.

## Aggregator tables carry dates; extract them

When researching whether some rule or coding actually applies in practice, community aggregator tables are often the best available source, and often years stale.

- Extract the date column, not just the verdict. A plain-text page reader plus grep beats a summarizing fetch here, because summarizers drop the dates.
- Cite the age in the answer and treat "Works" / "Does not work" as unproven rather than settled when the data point is old.
- Some issuer and vendor terms pages return HTTP 403 to automated fetchers. When that happens, take the fact from two independent secondary sources and say in the answer that the primary was not readable, rather than implying you read it directly.
- Some large community sites are blocked to search tooling entirely. Crowd-sourced data points then need an aggregator or a direct page read instead.
- Practical consequence: recommend a cheap real-world test before committing, and record the evidence gaps explicitly in the deliverable.

## Eligibility on a marketing/FAQ page is not evidence: read the sentence on the form

A public information page said an applicant in a given category could apply online. The live application form said the opposite, verbatim, in a note above the submit button. A research pass that only reads marketing pages will report "eligible", and the agent will then submit a false claim on the user's behalf.

Same failure mode elsewhere: a research pass reported a signup page as CAPTCHA-free; the live page renders its CAPTCHA inside a shadow DOM, with the challenge field present.

Rule: for any signup / eligibility / enrollment task, the authoritative quote is the one rendered on the form you are about to submit, read via a browser after the page loads. Treat FAQ, marketing, help-center and search-snippet quotes as leads to verify, never as the finding. When they conflict, the form wins and you stop.

Corollary: this is also the cheapest place to catch a subagent's overconfident research, so map the form BEFORE filling it, not after a failed submit.

## A per-bucket minimum prices the bucket, not your pick

A research pack tabulated "cheapest nonstop per candidate day" for a route and recorded one day at a given price. A later turn recommended a specific evening departure and carried that price across. Re-scraping the live board showed that departure cost about 30% more; the tabulated price applied only to three other departures that day. The carrier was running three distinct price bands on one route on one day, keyed to departure time.

Why it bites: a per-day fare table answers "what does this DAY cost", which is right when choosing a day. The moment the decision narrows to a specific flight, the table's number stops applying. The error is silent because the number came from your own verified research and so carries unearned authority.

How to apply:
- Once a recommendation names a specific flight number or departure time, re-verify that flight's own fare before quoting a price.
- Treat day-level tables as scoped to day-level decisions. The same applies to hotels (a cheapest-per-night figure is not the rate for the room you actually want) and to any per-bucket minimum.
- If prior fare research is more than a day old and the user is about to book, re-pull rather than quote it. Fares moved measurably in about 24 hours in the observed case (one evening departure rose 37%). A stale fare presented confidently is worse than no fare.
