<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

An agent asserted, across several turns of a credit-card recommendation thread,
that bonus eligibility was per-product-variant (outdated: the issuer's family
language had been unified) and that statement credits were per-product rather
than per-card (fabricated, and backwards). Both were stated confidently from
model memory, both were material to a "should I apply for this card" decision,
and both were only corrected after the user pushed back. A third error came from
trusting a stale local file over the user's own statement about his own account.

The failure mode is NOT "the model didn't know." It's that the model answered
anyway, and that deciding when to check was left to the model's own judgment of
whether a domain felt "fast-moving."

## The rule

**If a factual claim is (1) external to your own systems and (2) actionable by
the user, verify it with a current search before asserting it. No
self-assessment of volatility.**

Covered claim classes (non-exhaustive):
- Credit card / bank / issuer rules: bonus eligibility, family language,
  credit stacking, application rules, offer amounts and deadlines
- Prices, fees, promotions, availability of products or services
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal/policy/immigration facts, program rules, published schedules

Not covered (verify against internal sources instead): anything about the user's
own accounts, infra, repos, or history. For those, the actual source (the
database, the mail account, git, the user's own statement) is the check.

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

1. **The user's own statement about their own accounts/actions**: beats
   everything for existence-type facts; if internal data disagrees, the data is
   stale: say so, verify at the real source, fix the data.
2. **Current primary/web sources** (issuer terms pages, official docs,
   reputable independent trackers): required for external rules and offers.
3. **Internal curated files** (your knowledge base, your private context repo):
   authoritative only for what they own (benefit detail, member numbers), never
   for external rules, and never over the user.
4. **Model memory**: never sufficient for a covered claim. It generates the
   hypothesis; the search confirms it.

## Contradicting your own prior research

If an earlier turn in the same conversation established a researched fact and
you are about to assert the opposite, that is a red flag, not a correction.
Re-verify with a search and explicitly reconcile ("earlier I found X; the search
now shows Y because Z"), never silently flip.

## Deliverable URL liveness

Any URL you write into a deliverable that leaves your systems (resume,
portfolio, cover letter, social post, anything sent or published) is an
externally-checkable fact. Before writing it, curl the exact URL and confirm it
serves the intended public page (HTTP 200 plus a real page, not a redirect to
login and not a bare API). Gate the write on the check; do not ship a hedge like
"confirm live status" about something you could verify in seconds.

These are NOT liveness signals, and each has burned a real deliverable:
- a repo exists on disk (`ls <repo-path>` says nothing about a public URL);
- a process manager reports the service `online` (a running service with only
  `/api/*` routes serves no browsable page);
- a memory or index line says "LIVE" (memories are point-in-time and often mean
  "deployed", not "public page exists": read the full memory, not just the
  one-line index, and then still curl it).

A real case: an internal-first API with only `/api/*` routes and a required
auth header was written into a resume and a portfolio as a public product page.
The path 404s. The author relied on an index line reading "LIVE" and a
repo-exists `ls`, neither of which proves public liveness.

## "Known / reputable brand" is a factual claim: verify provenance

Calling a brand "known", "established", "reputable", or "trusted" is an
externally-checkable claim, not flavor. Do not assert it from marketplace star
counts or review volume; that is the exact fake-review signal a skeptic gate is
supposed to catch, laundered into credibility. Before applying any such label,
run one search (`who makes <brand>` / `<brand> company history`) and classify:
- **Established**: an independent company with verifiable history and
  distribution beyond a single marketplace.
- **Marketplace-native label**: an invented seller brand (often an all-caps or
  nonsense word) sold mainly on one marketplace with no independent history.
  Never call these "known brands"; they can still be fine budget picks, but
  justify that on specific evidence, not borrowed reputation.

Never contradict your own skeptic gate: flagging "no-name" products as a trap
while presenting same-tier marketplace-native brands as "known brands" in the
same guide is the failure this rule exists to prevent.

## Aggregator tables carry dates; issuer pages block scrapers; some sites are unreachable

When researching which merchants trigger a card's category statement credit,
three constraints bite, and they generalise to most offer research:

1. The best aggregate source is often a community-maintained sortable table
   whose data points are years old. Always extract the date column (a text-only
   page reader plus grep beats a summarizing fetch, which tends to drop the
   dates), cite the age, and treat "Works" / "Does not work" as unproven rather
   than settled.

2. Issuer benefit-terms pages frequently return HTTP 403 to automated fetches.
   Issuer terms then have to come from two independent secondary sources, and
   the answer should say so rather than implying the issuer was read directly.

3. Some large community sites are blocked to search APIs entirely (including
   via an allowed-domains parameter). Crowd-sourced data points need an
   aggregator or a direct page reader instead.

Practical consequence: recommend a test transaction before committing to a
vendor whose behavior rests only on an old data point, and record the evidence
gaps explicitly in the deliverable.

## Eligibility on a marketing/FAQ page is not evidence: read the sentence printed on the form

A library system's public page said an out-of-region applicant could apply
online for a card. The live application form said the opposite, verbatim:
eCards are only available to residents of the service area. A research pass that
only reads marketing pages will report "eligible", and the agent will then
submit a false residency claim. Same session, same failure twice: a research
pass reported a signup page as CAPTCHA-free; the live page was shadow-DOM with a
`g-recaptcha-response` field present.

Rule: for any signup/eligibility/enrollment task, the authoritative quote is the
one rendered on the form you are about to submit, read via the browser after the
page loads. Treat FAQ, marketing, and search-snippet quotes as leads to verify,
never as the finding. When they conflict, the form wins and you stop.

Corollary: this is also the cheapest place to catch a subagent's overconfident
research, so map the form BEFORE filling it, not after a failed submit.

## A per-day cheapest-fare table prices specific departures, so re-verify once the recommendation names one

A research pack tabulated "cheapest nonstop per candidate day" for a route and
recorded one day at a given price. A later turn recommended a specific evening
departure and carried that price across. Re-scraping the live board showed that
departure was 32% more; the cheap fare applied only to three other departures.
The carrier was running three distinct price bands on one route on one day,
keyed to departure time.

Why: a per-day fare table answers "what does this DAY cost", which is right when
choosing a day. The moment the decision narrows to a specific flight, the
table's number stops applying. The error is silent because the number came from
your own verified research and so carries unearned authority.

How to apply: once a recommendation names a specific flight number or departure
time, re-verify that flight's own fare before quoting a price. Treat day-level
tables as scoped to day-level decisions. Same applies to hotels (a
cheapest-per-night figure is not the rate for the room you actually want) and to
any per-bucket minimum.

Second habit from the same re-scrape: fares moved measurably in ~24 hours (one
carrier's evening departure rose 37%). If prior fare research is more than a day
old and the user is about to book, re-pull rather than quote it. A stale fare
presented confidently is worse than no fare.

## A cited aggregator page may not carry the claim it was cited for

A prior answer asserted a trail-restriction status and cited a third-party trail
aggregator page. That page carried only static trail stats plus an Open/Closed
flag; the authoritative live conditions feed was on a different page entirely.
The assertion happened to be true, but the citation did not support it, and the
official trail-report URL 404s on every documented path, so the fact was one
aggregator deep.

Why: a plausible-looking source URL next to a claim reads as verified.
Re-fetching the exact cited URL is what separates "this site would know" from
"this page says so".

How to apply: when reviewing or reusing someone else's cited claim, re-fetch the
specific URL and confirm the asserted fact appears on that page. If it does not,
find the page that carries it, or state the claim is single-sourced.

Related: operating-hours and enforcement-window claims that gate an action
deserve the same treatment. An answer reading "parking is enforced 07:00-19:00,
so an evening visit costs you nothing" was off by four hours at the start of the
window (actual 03:00-19:00), which flipped a free recommendation into a charge
and hid a hard prerequisite.

## A cited issue number is not a verified issue: check state, closed_at, and the LAST comment

A hardware recommendation ruled out an entire configuration on the strength of
"upstream issue #NNNNN documents data corruption on this topology." The issue
number came from a web-search result summary, which faithfully quoted the bug
report's symptom section. The issue was CLOSED, labelled bug-unconfirmed, and
the reporter's own final comment named the root cause: a marginal riser cable
throwing bus drops. Swapping the cable took the failure rate from 6-in-15 to
0-in-3 on the identical build. The reporter's words: hardware-induced, not a
software bug.

Why this is its own failure mode: a bug tracker URL confers more authority than
a blog post, so an issue number gets repeated without the scepticism a random
site would attract. And search summaries systematically reproduce the alarming
top of a report (title, symptoms, repro steps) while dropping the mundane bottom
(it was the cable / works as intended / duplicate / fixed in v2). The summary is
not wrong about what the body says; it is silent about what happened next.

How to apply. Before repeating any tracker item as a decision constraint, fetch
it and read four fields, none of which is the body:

```bash
curl -s https://api.github.com/repos/OWNER/REPO/issues/N | jq '{state,closed_at,labels:[.labels[].name],comments}'
curl -s https://api.github.com/repos/OWNER/REPO/issues/N/comments | jq -r '.[-1].body'
```

`state` and `closed_at` tell you whether it is live. The LAST comment tells you
why it closed, which the body never can. Labels distinguish confirmed from
bug-unconfirmed. Same discipline for a linked PR: open, merged, and
closed-unmerged are three different facts (a closed-unmerged PR is often quoted
as if the feature shipped).

Two corollaries worth the extra minute:
- Read the rest of the thread, not just the resolution. In that case three OTHER
  users had a real, still-unresolved regression buried underneath, because the
  issue was closed on the original reporter's cable rather than on their
  problem. The retraction and the surviving finding were both in the same
  thread.
- When the dramatic objection collapses, rebuild the recommendation on the
  boring objections rather than quietly keeping the conclusion. Power draw,
  thermals, and buying the wrong axis still argued against that configuration;
  saying so is more useful, and more honest, than a scare that has been
  withdrawn.

## Eliminating an option needs a primary source; ranking it can survive on a secondary one

The same document ruled a hardware vendor out entirely on "this vendor's
consumer compute stack is Linux-only and the user's environment breaks it,"
sourced from one SEO-adjacent blog summary. The vendor publishes an official
compatibility matrix that lists the exact part under the current release with no
preview label and no caveat rows. The elimination was false; a correct ranking
(that vendor was ~30% slower on the metric that mattered) was available from
measurements and would have reached the same final recommendation without the
error.

The asymmetry is the point. Ranking an option wrong costs some accuracy in a
comparison the reader can still see. Eliminating an option deletes it from the
reader's decision space entirely, and they will never know what they did not get
to weigh. So elimination is the stronger claim and needs the stronger evidence:
a vendor compatibility matrix, official docs, release notes, a spec sheet, not a
summary of one.

Two habits that catch this:
- Check whether the constraint is even load-bearing before building on it. There
  the inference server is reached over HTTP, so it never needed to run inside
  the constrained environment at all; the whole objection was about a deployment
  choice, not a capability.
- When the correction lands, retract it AT THE POINT A READER HITS IT. A
  rebuttal section eighty lines below the false claim means an in-order reader
  gets the error first and the correction only if they keep going. Edit the
  original paragraph and link forward; do not rely on the later section to do
  the work.

## A benchmark number carries its harness: check which runtime and flags produced it

A hardware recommendation was built on a dense-model prefill throughput figure,
taken as a property of the card. The same model class on the same card under a
different inference runtime with speculative decoding was ~3x faster. Runtime
and flag choice was worth more than the next hardware tier up, and the
recommendation's central trade-off ("you get parameters OR speed") was an
artifact of the binary someone happened to benchmark with. Flags also interact
and fail silently: one batch-size flag gave a 5.5x prefill gain only when a
competing memory-fit flag was off, and a mismatched pair of KV-cache
quantisation types caused a silent 4-13x prefill collapse with no error.

Rule: before reasoning from a throughput number, record which build, which
runtime, and which flags produced it, and prefer two numbers from the same
harness over two numbers from the same vendor. When comparing options, a
same-harness comparison beats a more-recent mismatched one.

## A supplied parts list or spec sheet is a claim about the past; reconcile it against the live system

A build sheet supplied for a machine named one CPU and one RAM capacity; the
live system reported a different CPU and 2.5x the RAM, both having been upgraded
since the sheet was written. That mattered because the real CPU drew 54W more,
which tightened a power budget the recommendation depended on.

Rule: treat each line of a supplied inventory as a claim, reconcile it against
something measurable (`/proc/cpuinfo`, `free`, `nvidia-smi`, `lsblk`,
`Get-CimInstance`), and state explicitly which lines were confirmed, which were
corrected, and which are unverifiable in software (chassis and power supply
usually are). Do not let the unverifiable lines inherit the credibility of the
verified ones.

Second half of the same lesson: on a power supply the first hard blocker is
often the CONNECTOR COUNT rather than the wattage, and no power limit or
splitter fixes a missing connector, so read the connector table and not just the
rating.
