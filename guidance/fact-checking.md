<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

An agent asserted, across several turns of a credit-card recommendation thread, that welcome-bonus eligibility was per-product-variant (outdated: the issuer's family language had unified the variants) and that statement credits were per-product rather than per-card (fabricated, and backwards). Both were stated confidently from model memory, both were material to a "should I apply for this card" decision, and both were only corrected after the user pushed back. A third error came from trusting a stale local notes file over the user's own statement about his own card.

The failure mode is NOT "the model didn't know." It's that the model answered anyway, and that deciding when to check was left to the model's own judgment of whether a domain felt "fast-moving."

## The rule

**If a factual claim is (1) external to your own systems and (2) actionable by the user, verify it with a current search before asserting it. No self-assessment of volatility.**

Covered claim classes (non-exhaustive):
- Credit card / bank / issuer rules: bonus eligibility, family language, credit stacking, application rules, offer amounts and deadlines
- Prices, fees, promotions, availability of products or services
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal/policy/immigration facts, program rules, published schedules

Not covered (verify against internal sources instead): anything about the user's own accounts, infrastructure, repos, or history. For those, the actual source (the database, the mailbox, git, the user's own statement) is the check.

## Procedure

Before posting a research-type answer (recommendations, comparisons, eligibility/how-much/what-happens-if questions), run the draft through a fact-check pass:

1. Extract the discrete external-actionable claims from the draft
2. Run a current-year web search per claim (in parallel)
3. Assign per-claim verdicts: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED
4. Revise the answer for anything not CONFIRMED, and label UNVERIFIED claims as unverified in the final answer

Packaging this as a reusable skill or checklist is worth doing once you run it more than a few times. For a single claim mid-conversation, a direct web search with the current month and year in the query is an acceptable lightweight equivalent, but the search must actually happen before the assertion is posted.

## Precedence of sources

1. **The user's own statement about their own accounts/actions.** Beats everything for existence-type facts; if internal data disagrees, the data is stale: say so, verify at the real source, fix the data.
2. **Current primary/web sources** (issuer terms pages, official docs, reputable domain-specific trackers). Required for external rules and offers.
3. **Internal curated files** (your private context repo, your knowledge base). Authoritative only for what they own (benefit details, member numbers), never for external rules, and never over the user.
4. **Model memory.** Never sufficient for a covered claim. It generates the hypothesis; the search confirms it.

## Contradicting your own prior research

If an earlier turn in the same conversation established a researched fact and you are about to assert the opposite, that is a red flag, not a correction. Re-verify with a search and explicitly reconcile ("earlier I found X; the search now shows Y because Z"); never silently flip.

## Deliverable URL liveness

Any URL you write into a deliverable that leaves your control (resume, portfolio, cover letter, social post, anything sent or published) is an externally-checkable fact. Before writing it, curl the exact URL and confirm it serves the intended public page (HTTP 200 plus a real page, not a redirect to login and not a bare API). Gate the write on the check; do not ship a hedge like "confirm live status" about something you could verify in seconds.

These are NOT liveness signals, and each has burned a real deliverable:
- a repo exists on disk (`ls $HOME/<repo>` says nothing about a public URL);
- a process manager reports the service `online` (a running service with only `/api/*` routes serves no browsable page);
- a note or index line says "LIVE" (notes are point-in-time and often mean "deployed", not "public page exists"; read the full note, not just the one-line index, and then still curl it).

A real case: an internal-first API with only `/api/*` routes and a required auth header was written into a resume and a portfolio as a public product page. The path 404s. The author relied on an index line reading "LIVE" and a repo-exists `ls`, neither of which proves public liveness.

## "Known / reputable brand" is a factual claim: verify provenance

Calling a brand "known", "established", "reputable", or "trusted" is an externally-checkable claim, not flavor. Do not assert it from marketplace star counts or review volume; that is the exact fake-review signal a skeptic gate is supposed to catch, laundered into credibility. Before applying any such label, run one search (`who makes <brand>` / `<brand> company history`) and classify:

- **Established.** An independent company with verifiable history and distribution beyond a single marketplace.
- **Marketplace-native label.** An invented seller brand (often an all-caps or nonsense word) sold mainly on one or two marketplaces with no independent history. Never call these "known brands"; they can still be fine budget picks, but justify that on specific evidence, not borrowed reputation.

Never contradict your own skeptic gate: flagging "no-name" products as a trap while presenting same-tier marketplace-native brands as "known brands" in the same guide is the failure this rule exists to prevent. This one recurred across three separate buying-guide instruction sets before a brand-provenance gate was added to each.

## Aggregator research: check the date column, expect issuer 403s, expect blocked domains

When researching which merchants trigger a card issuer's category statement credit (or any similar crowd-sourced coding question), three constraints bite:

1. The best aggregate source is often a sortable community table where almost every data point is years old. Always extract the date column (a text-only page reader plus grep beats a summarizing fetch, which tends to drop the dates), cite the age, and treat "Works" / "Does not work" as unproven rather than settled. A six-year-old data point is a lead, not a finding.
2. Issuer benefit-terms pages frequently return HTTP 403 to automated fetchers. When that happens, the terms have to come from two independent secondary sources, and the answer should say so rather than implying the issuer was read directly.
3. Some large community sites are blocked to web search entirely (the search API returns an error such as "domains are not accessible to our user agent"), including via an allowed-domains parameter. Crowd-sourced data points then need an aggregator or a direct page reader instead.

Practical consequence: recommend a cheap test (for example, a small test charge) before committing to a vendor whose behavior rests only on an old data point, and record the evidence gaps explicitly in the deliverable.

## Eligibility on a marketing/FAQ page is not evidence: read the sentence printed on the form

A public library's information page said an out-of-region applicant could apply online for a card. The live application form said the opposite, verbatim: eCards are only available to residents. A research pass that only reads marketing pages will report "eligible", and the agent will then submit a false residency claim.

Same session, same failure mode twice: a research pass reported a signup page as CAPTCHA-free; the live page was shadow-DOM with a reCAPTCHA response field present.

Rule: for any signup/eligibility/enrollment task, the authoritative quote is the one rendered on the form you are about to submit, read via the browser after the page loads. Treat FAQ, marketing, guide-page and search-snippet quotes as leads to verify, never as the finding. When they conflict, the form wins and you stop.

Corollary: this is also the cheapest place to catch a subagent's overconfident research, so map the form BEFORE filling it, not after a failed submit.

## A per-bucket cheapest price does not price the specific item you recommend

A research pack tabulated "cheapest nonstop per candidate day" for a route and recorded one day at 215. A later turn recommended a specific 19:05 departure and carried that 215 across. Re-scraping the live board showed the 19:05 was 283; the 215 applied only to the 06:00, 06:50 and 21:25 departures. The carrier was running three distinct price bands on one route on one day, keyed to departure time.

Why it slips through: a per-day fare table answers "what does this DAY cost", which is right when choosing a day. The moment the decision narrows to a specific flight, the table's number stops applying. The error is silent because the number came from your own verified research and so carries unearned authority.

How to apply: once a recommendation names a specific item (a flight number, a departure time, a room type), re-verify that item's own price before quoting it. Treat bucket-level tables as scoped to bucket-level decisions. Same applies to hotels (a cheapest-per-night figure is not the rate for the room you actually want) and to any per-bucket minimum.

Second habit from the same re-scrape: fares moved measurably in about 24 hours (one carrier's evening departure rose 37%). If prior price research is more than a day old and the user is about to book, re-pull rather than quote it. A stale price presented confidently is worse than no price.

## A cited aggregator page may not carry the claim it was cited for

An answer asserted a national-park trail-restriction status and cited a third-party trail-info page. That page carried only static trail stats plus an Open/Closed flag; the live official condition feed was on a different page entirely. The assertion happened to be true, but the citation did not support it, and the official trail-report URL 404s on every documented path, so the fact was one aggregator deep.

Why it matters: a plausible-looking source URL next to a claim reads as verified. Re-fetching the exact cited URL is what separates "this site would know" from "this page says so".

How to apply: when reviewing or reusing someone else's cited claim, re-fetch the specific URL and confirm the asserted fact appears on that page. If it does not, find the page that carries it, or state the claim is single-sourced.

Related: operating-hours and enforcement-window claims that gate an action deserve the same treatment. An earlier answer's "parking is enforced 07:00 to 19:00, so an evening visit costs you nothing" was off by four hours at the start of the window (actual 03:00 to 19:00), which flipped a free recommendation into a real charge and hid a hard boarding prerequisite.
