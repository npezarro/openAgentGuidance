<!-- Load when: verifying external, actionable claims (prices, eligibility rules, offers, versions) before asserting them -->
# Fact-Checking External Claims

## Why this exists

A recommendation thread once produced, across four turns, two confident
assertions that were both wrong: one stated an issuer's bonus-eligibility rule
that had been superseded by newer terms, and one inverted how a benefit
applied. Both were stated from model memory, both were material to a
"should I sign up for this" decision, and both were corrected only after the
user pushed back. A third error in the same thread came from trusting a stale
local file over the user's own statement about their own account.

The failure mode is NOT "the model didn't know." It's that the model answered
anyway, and that deciding when to check was left to the model's own judgment of
whether a domain felt "fast-moving."

## The rule

**If a factual claim is (1) external to your own systems and (2) actionable by
the user, verify it with a current search before asserting it. No
self-assessment of volatility.**

Covered claim classes (non-exhaustive):
- Financial product rules: bonus eligibility, benefit stacking, application
  rules, offer amounts and deadlines
- Prices, fees, promotions, availability of products or services
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal/policy/immigration facts, program rules, published schedules

Not covered (verify against internal sources instead): anything about the
user's own accounts, infra, repos, or history. For those, the actual source
(the database, the mailbox, git, the user's own statement) is the check.

## Procedure

Before posting a research-type answer (recommendations, comparisons,
eligibility/how-much/what-happens-if questions), run the draft through a
fact-check pass that:

1. Extracts the discrete external-actionable claims from the draft
2. Runs a current-year web search per claim (in parallel)
3. Returns per-claim verdicts: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED
4. Requires the answer to be revised for anything not CONFIRMED, and UNVERIFIED
   claims to be labeled as unverified in the final answer

For a single claim mid-conversation, a direct web search with the current
month/year in the query is an acceptable lightweight equivalent, but the search
must actually happen before the assertion is posted.

## Precedence of sources

1. **The user's own statement about their own accounts/actions** beats
   everything for existence-type facts; if internal data disagrees, the data is
   stale: say so, verify at the real source, fix the data.
2. **Current primary/web sources** (official terms pages, official docs,
   reputable independent trackers) are required for external rules and offers.
3. **Internal curated files** (your private context repo, your knowledge base)
   are authoritative only for what they own (your own account details, benefit
   notes), never for external rules, and never over the user.
4. **Model memory** is never sufficient for a covered claim. It generates the
   hypothesis; the search confirms it.

## Contradicting your own prior research

If an earlier turn in the same conversation established a researched fact and
you are about to assert the opposite, that is a red flag, not a correction.
Re-verify with a search and explicitly reconcile ("earlier I found X; the
search now shows Y because Z"); never silently flip.

## Deliverable URL liveness

Any URL you write into a deliverable that leaves your own systems (resume,
portfolio, cover letter, social post, anything sent or published) is an
externally-checkable fact. Before writing it, curl the exact URL and confirm it
serves the intended public page (HTTP 200 plus a real page, not a redirect to
login and not a bare API). Gate the write on the check; do not ship a hedge like
"confirm live status" about something you could verify in seconds.

These are NOT liveness signals, and each has burned a real deliverable:
- a repo exists on disk (`ls $HOME/<repo>` says nothing about a public URL);
- a process manager reports the service `online` (a running service with only
  `/api/*` routes serves no browsable page);
- a memory or index line says "LIVE" (memories are point-in-time and often mean
  "deployed", not "public page exists"; read the full memory, not just the
  one-line index, and then still curl it).

One project was written into a resume and a portfolio as a public product on the
strength of a "LIVE" index line plus a repo-exists `ls`. The path 404s: it is an
internal-first API that only serves `/api/*` and requires a header key. Curl the
exact public URL, every time.

## "Known / reputable brand" is a factual claim: verify provenance

Calling a brand "known", "established", "reputable", or "trusted" is an
externally-checkable claim, not flavor. Do not assert it from marketplace star
counts or review volume; that is the exact fake-review signal a skeptic gate is
supposed to catch, laundered into credibility. Before applying any such label,
run one search (`who makes <brand>` / `<brand> company history`) and classify:
- **Established**: an independent company with verifiable history and
  distribution beyond a single marketplace.
- **Marketplace-native label**: an invented seller brand (often an all-caps or
  nonsense word) sold mainly on one or two online marketplaces with no
  independent history. Never call these "known brands"; they can still be fine
  budget picks, but justify that on specific evidence, not borrowed reputation.

Never contradict your own skeptic gate: flagging "no-name" products as a trap
while presenting same-tier marketplace-native brands as "known brands" in the
same guide is the failure this rule exists to prevent.

## Field notes

### Aggregator tables carry stale rows: extract the date column
When researching which merchants trigger a card's category statement credit
(wireless, streaming, shipping), three constraints bite:

1. The best aggregate source is usually a community-maintained sortable table,
   but individual data points in it can be five or six years old. Always extract
   the date column (a text-only page reader plus grep beats a summarizing
   fetcher, which tends to drop the dates), cite the age, and treat
   "Works"/"Does not work" as unproven rather than settled when the row is old.
2. Some issuer benefit-terms pages return HTTP 403 to automated fetchers. Issuer
   terms then have to come from two independent secondary sources, and the
   answer should say so rather than implying the issuer was read directly.
3. Some large community sites are blocked to search APIs entirely (the search
   returns an error about the domain not being accessible to the user agent),
   including via an allowed-domains filter. Crowd-sourced data points then need
   an aggregator site or a direct page reader instead.

Practical consequence: recommend a small test charge before committing to a
provider whose coding rests only on an old data point, and record the evidence
gaps explicitly in the deliverable.

### Eligibility on a marketing/FAQ page is not evidence: read the sentence printed on the application form
A public library's information page stated that an out-of-area resident could
apply online for a digital card. The live application form said the opposite,
verbatim: eCards are only available to residents of the library's own county. A
research pass that only reads marketing pages will report "eligible", and the
agent will then submit a false residency claim.

Same session, same failure mode twice: a research pass reported a signup page as
CAPTCHA-free, but the live page rendered a shadow-DOM form with a reCAPTCHA
response field present.

Rule: for any signup/eligibility/enrollment task, the authoritative quote is the
one rendered on the form you are about to submit, read via the browser after the
page loads. Treat FAQ, marketing, library-guide and search-snippet quotes as
leads to verify, never as the finding. When they conflict, the form wins and you
stop.

Corollary: this is also the cheapest place to catch a subagent's overconfident
research, so map the form BEFORE filling it, not after a failed submit.
