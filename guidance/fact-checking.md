<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

In a credit-card recommendation thread, an agent asserted across four turns that (a) welcome-bonus eligibility was per-product-variant (outdated: the issuer's family language had been unified), and (b) statement credits were per-product rather than per-card (fabricated, and backwards). Both were stated confidently from model memory, both were material to a "should I apply for this card" decision, and both were corrected only after the user pushed back. A third error came from trusting a stale local notes file over the user's own statement about his own card.

The failure mode is NOT "the model didn't know." It's that the model answered anyway, and that deciding when to check was left to the model's own judgment of whether a domain felt "fast-moving."

## The rule

**If a factual claim is (1) external to your own systems and (2) actionable by the user, verify it with a current search before asserting it. No self-assessment of volatility.**

Covered claim classes (non-exhaustive):
- Credit card / bank / issuer rules: bonus eligibility, family language, credit stacking, application rules, offer amounts and deadlines
- Prices, fees, promotions, availability of products or services
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal/policy/immigration facts, program rules, published schedules

Not covered (verify against internal sources instead): anything about the user's own accounts, infra, repos, or history. For those, the actual source (the database, the mailbox, git, the user's own statement) is the check.

## Procedure

Before posting a research-type answer (recommendations, comparisons, eligibility/how-much/what-happens-if questions), run the draft through a fact-check pass that:

1. Extracts the discrete external-actionable claims from the draft
2. Runs a current-year web search per claim (in parallel)
3. Returns per-claim verdicts: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED
4. Requires the answer to be revised for anything not CONFIRMED, and UNVERIFIED claims to be labeled as unverified in the final answer

For a single claim mid-conversation, a direct web search with the current month/year in the query is an acceptable lightweight equivalent, but the search must actually happen before the assertion is posted.

## Precedence of sources

1. **The user's own statement about their own accounts/actions:** beats everything for existence-type facts; if internal data disagrees, the data is stale: say so, verify at the real source, fix the data.
2. **Current primary/web sources** (issuer terms pages, official docs, reputable independent trackers): required for external rules and offers.
3. **Internal curated files** (your private context repo, your knowledge base): authoritative only for what they own (benefit detail, account numbers), never for external rules, and never over the user.
4. **Model memory:** never sufficient for a covered claim. It generates the hypothesis; the search confirms it.

## Contradicting your own prior research

If an earlier turn in the same conversation established a researched fact and you are about to assert the opposite, that is a red flag, not a correction. Re-verify with a search and explicitly reconcile ("earlier I found X; the search now shows Y because Z"); never silently flip.

## Deliverable URL liveness

Any URL you write into a deliverable that leaves your systems (resume, portfolio, cover letter, social post, anything sent or published) is an externally-checkable fact. Before writing it, curl the exact URL and confirm it serves the intended public page (HTTP 200 plus a real page, not a redirect to login and not a bare API). Gate the write on the check; do not ship a hedge like "confirm live status" about something you could verify in seconds.

These are NOT liveness signals, and each has burned a real deliverable:
- a repo exists on disk (`ls $HOME/<repo>` says nothing about a public URL);
- a process manager reports the service `online` (a running service with only `/api/*` routes serves no browsable page);
- a memory or index line says "LIVE" (memories are point-in-time and often mean "deployed", not "public page exists"; read the full memory, not just the one-line index, and then still curl it).

The concrete burn: a project was written into a resume and portfolio as a public product on the strength of a "LIVE" index line plus a repo-exists `ls`. The path 404s: it was an internal-first API (only `/api/*`, requiring an auth header). Neither signal proves public liveness. Curl it.

### Private repo URLs 404 anonymously, and that's an auth artifact, not proof of breakage

An unauthenticated request (curl, a fetch tool, a public link-checker) against a `github.com/<org>/<private-repo>/blob/...` URL returns **404, not 403**: GitHub does not reveal that a private repo exists to a caller who can't see it. This is indistinguishable from a genuinely broken or renamed path unless you know to check authenticated. When verifying a link into a private repo, use `gh api repos/<org>/<repo>/contents/<path>` instead of anonymous curl; a 200 with a `size` field confirms it's live, and a 404 from `gh api` (unlike from curl) is a real miss. Mirror image of the login-wall false positive above: that one is a false positive (200 that's actually dead behind auth); this one is a false negative (404 that's actually alive behind auth).

## "Known / reputable brand" is a factual claim, so verify provenance

Calling a brand "known", "established", "reputable", or "trusted" is an externally-checkable claim, not flavor. Do not assert it from marketplace star counts or review volume: that is the exact fake-review signal a skeptic gate is supposed to catch, laundered into credibility. Before applying any such label, run one search (`who makes <brand>` / `<brand> company history`) and classify:
- **Established:** an independent company with verifiable history and distribution beyond a single marketplace.
- **Marketplace-native label:** an invented seller brand (often an all-caps or nonsense word) sold mainly on one or two marketplaces with no independent history. Never call these "known brands"; they can still be fine budget picks, but justify that on specific evidence, not borrowed reputation.

Never contradict your own skeptic gate: flagging "no-name" products as a trap while presenting same-tier marketplace-native brands as "known brands" in the same guide is the failure this rule exists to prevent.

## Merchant-coding / benefits research: aggregator tables go stale, issuer pages block bots, some domains are unreachable

When researching which merchants trigger a card's category statement credit (wireless/streaming/shipping), three constraints bite:

1. The best aggregate source is usually a community-maintained sortable table, but a large share of its data points can be years old. Always extract the date column (a text-extracting page reader plus grep beats a summarizing fetch, which tends to drop the dates), cite the age, and treat "Works"/"Does not work" as unproven rather than settled when the data point is stale.

2. Issuer benefit-terms pages frequently return HTTP 403 to automated fetchers. Issuer terms then have to come from two independent secondary sources, and the answer should say so rather than implying the issuer was read directly.

3. Some high-signal community domains are blocked to search tooling entirely (an explicit "domains are not accessible to our user agent" error), including when passed as an allowed domain. Crowd-sourced data points then need an aggregator or a direct page reader instead.

Practical consequence: recommend a test charge before committing to a vendor whose coding rests only on an old data point, and record the evidence gaps explicitly in the deliverable.

## Eligibility on a marketing/FAQ page is not evidence: read the sentence printed on the application form

A public library's marketing page said an out-of-region applicant could apply online for a card. The live application form said the opposite, verbatim: cards are only available to in-region residents. A research pass that only reads marketing pages reports "eligible" and the agent then submits a false residency claim.

Same session, same failure mode twice: a research pass reported a signup page as CAPTCHA-free; the live page was shadow-DOM with a CAPTCHA response field present.

Rule: for any signup/eligibility/enrollment task, the authoritative quote is the one rendered on the form you are about to submit, read via the browser after the page loads. Treat FAQ, marketing, library-guide and search-snippet quotes as leads to verify, never as the finding. When they conflict, the form wins and you stop.

Corollary: this is also the cheapest place to catch a subagent's overconfident research, so map the form BEFORE filling it, not after a failed submit.

## A per-day cheapest-fare table prices specific departures, so re-verify once the recommendation names a flight

A research pack tabulated "cheapest nonstop per candidate day" for a route and recorded one day at a given fare. A later turn recommended a specific evening departure and carried that fare across. Re-scraping the live board showed the named flight was ~30% higher; the cheap fare applied only to three other departures. The carrier was running three distinct price bands on one route on one day, keyed to departure time.

Why: a per-day fare table answers "what does this DAY cost", which is right when choosing a day. The moment the decision narrows to a specific flight, the table's number stops applying. The error is silent because the number came from your own verified research and so carries unearned authority.

How to apply: once a recommendation names a specific flight number or departure time, re-verify that flight's own fare before quoting a price. Treat day-level tables as scoped to day-level decisions. Same applies to hotels (a cheapest-per-night figure is not the rate for the room you actually want) and to any per-bucket minimum.

Second habit from the same re-scrape: fares moved measurably in ~24 hours (one carrier's evening departure rose 37%). If prior fare research is more than a day old and the user is about to book, re-pull rather than quote it. A stale fare presented confidently is worse than no fare.

## A cited aggregator page may not carry the claim it was cited for

An answer asserted a park-authority trail-restriction status and cited a third-party trail-info site. That page carried only static trail stats plus an Open/Closed flag; the live conditions feed was on a different page entirely. The assertion happened to be true, but the citation did not support it, and the authority's own trail-report URL 404s on every documented path, so the fact was one aggregator deep.

Why: a plausible-looking source URL next to a claim reads as verified. Re-fetching the exact cited URL is what separates "this site would know" from "this page says so".

How to apply: when reviewing or reusing someone else's cited claim, re-fetch the specific URL and confirm the asserted fact appears on that page. If it does not, find the page that carries it, or state the claim is single-sourced. Operating-hours and enforcement-window claims that gate an action deserve the same treatment: an answer's "parking is enforced 07:00-19:00, so an evening visit costs you nothing" was off by four hours at the start of the window (actual 03:00-19:00), which flipped a free recommendation into a real charge and hid a hard prerequisite.

## A numeric-presence check is not a claim check: verify the pairing, not just that the number appears in the source

A retrieval-backed answer cited three retailer prices to one URL: "$199.99 at retailer A, $229.99 at retailer B, $249.99 at retailer C [4]". Source 4 was a single-retailer price-history site, which genuinely carries historical highs, so every number really was somewhere on that page, and a check that only asks "does this figure appear in a cited source" passes cleanly. What is false is the PAIRING: a price bound to a retailer the source never mentions at all. The real price was roughly $99.

This is a step past the "cited aggregator page may not carry the claim" pattern above: there the fix is confirming the fact appears on the page at all; here the fact (the number) DOES appear, and the check still needs to fail, because what it's attached to is fabricated.

**How to apply:** the unit of verification is the claim, not the number. Per cited sentence, check (1) every money amount appears in a cited source, AND (2) every entity the sentence attributes something TO (retailer, vendor, venue, person) is actually mentioned by that same cited source. A verification pass that stops at (1) will wave through a plausible-looking multi-entity sentence built by stapling real numbers onto the wrong names.

## A cited issue number is not a verified issue: check state, closed_at, and the LAST comment

A hardware recommendation ruled out an entire configuration on the strength of "upstream issue #N documents data corruption on this topology." The issue number came from a web-search result summary, which faithfully quoted the bug report's symptom section. The issue was CLOSED, labelled bug-unconfirmed, and the reporter's own final comment named the root cause: a marginal riser cable throwing bus drops. Swapping the cable took the workload from 6/15 garbled runs to 0/3 on the identical build. The reporter's words: hardware-induced, not a software bug.

Why this is its own failure mode: a bug tracker URL confers more authority than a blog post, so an issue number gets repeated without the scepticism a random site would attract. And search summaries systematically reproduce the alarming top of a report (title, symptoms, repro steps) while dropping the mundane bottom (it was the cable / works as intended / duplicate / fixed in v2). The summary is not wrong about what the body says; it is silent about what happened next.

How to apply. Before repeating any tracker item as a decision constraint, fetch it and read four fields, none of which is the body:

```bash
curl -s https://api.github.com/repos/OWNER/REPO/issues/N | jq '{state,closed_at,labels:[.labels[].name],comments}'
curl -s https://api.github.com/repos/OWNER/REPO/issues/N/comments | jq -r '.[-1].body'
```

`state` and `closed_at` tell you whether it is live. The LAST comment tells you why it closed, which the body never can. Labels distinguish confirmed from bug-unconfirmed. Same discipline for a linked PR: open, merged, and closed-unmerged are three different facts (a closed-unmerged PR is often quoted as if the feature shipped).

Two corollaries worth the extra minute:
- Read the rest of the thread, not just the resolution. In that case three OTHER users had a real, still-unresolved regression buried underneath, because the issue was closed on the original reporter's cable rather than on their problem. The retraction and the surviving finding were both in the same thread.
- When the dramatic objection collapses, rebuild the recommendation on the boring objections rather than quietly keeping the conclusion. Power draw, thermals and buying the wrong axis still argued against that configuration; saying so is more useful, and more honest, than a scare that has been withdrawn.

## Eliminating an option needs a primary source; ranking it can survive on a secondary one

The same document ruled a GPU vendor out entirely on "consumer support is Linux-only and the Windows subsystem breaks it," sourced from one SEO-adjacent blog summary. The vendor publishes an official compatibility matrix listing the exact card under the current release with no preview label and no caveat rows. The elimination was false; a correct ranking (that vendor is ~30% slower on the metric that mattered) was available from measurements and would have reached the same final recommendation without the error.

The asymmetry is the point. Ranking an option wrong costs some accuracy in a comparison the reader can still see. Eliminating an option deletes it from the reader's decision space entirely, and they will never know what they did not get to weigh. So elimination is the stronger claim and needs the stronger evidence: a vendor compatibility matrix, official docs, release notes, a spec sheet, not a summary of one.

Two habits that catch this:
- Check whether the constraint is even load-bearing before building on it. There, the inference server is reached over HTTP, so it never needed to run inside the Windows subsystem at all; the whole objection was about a deployment choice, not a capability.
- When the correction lands, retract it AT THE POINT A READER HITS IT. A rebuttal section eighty lines below the false claim means an in-order reader gets the error first and the correction only if they keep going. Edit the original paragraph and link forward; do not rely on the later section to do the work.

## A benchmark number carries its harness: check which runtime and flags produced it before treating it as a hardware ceiling

A hardware recommendation was built on "this model class prefills at 437 t/s on this GPU", taken as a property of the card. The same model class on the same card under a different inference runtime with speculative decoding does 1,261 t/s. Runtime and flag choice was worth ~3x, more than the next hardware tier up, and the recommendation's central trade-off ("you get parameters OR speed") was an artifact of the binary someone happened to benchmark with. Flags also interact and fail silently: one batch-size flag gave 5.5x prefill only when a competing memory-fit flag was off, and a mismatched pair of KV-cache quantisation types caused a silent 4-13x prefill collapse with no error.

Rule: before reasoning from a throughput number, record which build, which runtime, and which flags produced it, and prefer two numbers from the same harness over two numbers from the same vendor. When comparing options, a same-harness comparison beats a more-recent mismatched one.

## A supplied parts list or spec sheet is a claim about the past; reconcile every line against the live system

A build sheet supplied for a machine named one CPU and one RAM capacity; the live system reported a different CPU and 2.5x the RAM, both upgraded since the sheet was written. That mattered because the real CPU drew 54W more, which tightened a power budget the recommendation depended on.

Rule: treat each line of a supplied inventory as a claim, reconcile it against something measurable (`/proc/cpuinfo`, `free`, `nvidia-smi`, `lsblk`, `Get-CimInstance`), and state explicitly which lines were confirmed, which were corrected, and which are unverifiable in software (chassis and power supply usually are). Do not let the unverifiable lines inherit the credibility of the verified ones.

Second half of the same lesson: on a power supply the first hard blocker is often the CONNECTOR COUNT rather than the wattage, and no power limit or splitter fixes a missing connector, so read the connector table and not just the rating.

## A degraded search backend produces confident, cited fabrication

A local retrieval-augmented research pipeline reported a power tool at **$299-$349** (real price ~$99) and cited a **TV-series encyclopedia page**. The answer was fluent, internally consistent, and carried citations: nothing about its shape signalled it was wrong, and it would have sent a reader to checkout expecting roughly triple the real price.

The cause was the search backend, not the model. The metasearch layer had one provider suspended and two CAPTCHA'd, leaving only a keyword-matching engine: asked for "best power sander for stripping thick dark wood finish under $150," it returned a retailer category page and two dictionary definitions of "best." The synthesis model dutifully built an answer out of whatever it was handed. On a sibling task the SAME pipeline correctly refused ("the evidence is entirely unrelated to the query") when the mismatch was more obvious. The grounding discipline works; it just cannot distinguish evidence that answers the question from evidence that merely resembles an answer. Citations prove provenance, never correctness.

**How to apply:** a retrieval pipeline needs a HARD refusal signal for "my retrieval was degraded," separate from any informational degradation field, and every caller must refuse on it rather than ship a plausible-looking answer. Threshold used here: one dead search engine is routine flakiness, two or more means the surviving result set is only whatever happened to survive, not a real sample of the web. The fix was an `untrustworthyRetrieval` flag raised at the gateway, letting the caller fall through to a different engine instead of shipping the wrong price.

Two supporting bugs made the degradation invisible and are worth checking for in any similar pipeline:
- a dedup step that returns a NEW array can silently drop a degradation flag attached to the pre-dedupe array;
- a client timeout calibrated on a fast/small model can kill a slower/larger model's synthesis mid-answer, surfacing as an empty result that a downstream quality measurement scores as "bad" rather than "failed."

## A status-exempt category silently fails a checklist that assumes every row applies

A state ID document list for non-citizens read "foreign passport WITH valid visa + entry record" (tracking the federal rule). Nationals of a visa-exempt country have no visa foil in the passport, so they satisfy no listed combination literally; the only visa-less variant published was reserved for a different special category. A substantive catch-all provision does cover them (their entry record and approval notice are verifiable through the federal status-verification system), which is why it works in practice, but it is counter-clerk discretion rather than a published path.

Why: reading the eligibility list as satisfied because "he has a passport and an entry record" would have missed that the AND-term in the middle is unsatisfiable for his nationality. The same shape recurs anywhere a checklist enumerates document COMBINATIONS.

How to apply: when screening an eligibility or document checklist, expand every "A + B + C" row and confirm the subject can produce EACH element. Flag any element that is structurally impossible for their category (visa-exempt, age-exempt, treaty national) rather than assuming a catch-all will absorb it. Also compare the strict list against the fallback/non-compliant list: the non-compliant product accepted a bare approval notice plus passport and entry record with no visa, so the fallback was materially easier to obtain than the compliant one.

## A dependency-audit scan can drop a repo's high bucket when that repo also has a critical finding

A first-pass automated security sweep across ~30 repos reported one repo as "1 critical, 0 high" and omitted it entirely from the high-findings list. A direct `npm audit --json` re-run on the same repo showed critical=1 AND high=16; the high bucket was real but silently dropped. Every other audited repo's per-repo high count matched a direct re-run exactly (14/14 verified); only the one repo that ALSO carried a critical finding lost its high bucket.

The scan's own header ("HIGH_FINDINGS: 15") versus its body (14 listed high entries) was the fingerprint of the gap, visible without re-running anything.

How to apply: when a scan summary's header count and listed-entry count disagree, verify the repo whose findings are missing before trusting either number. When verifying a security scan's severity bucketing, always re-run the real tool on any repo that has a critical finding, not just a sample: critical+high co-occurrence in the same repo is exactly where a severity-bucketing scanner is most likely to lose a bucket.

## A negative claim about a fast-moving product needs a same-week search, not a days-old current-state file

Two independent critique sessions told a user that a claim in his draft about a just-announced product merge was false, both citing a current-state inventory file written the previous week. The announcement had landed two days before the critique, after the file was written.

Rule: before flagging any "this exists / this happened" claim in a deliverable as wrong, run a web search bounded to the last 7 days and state the date of any research file used as evidence. A wrong drop-in would have replaced a correct sentence in a submission to the company that made the announcement.

## A second reviewer's "posting is filled/removed" claim must be verified against the live source

When reconciling an external review into a tracking sheet, do NOT copy its liveness/outcome claims verbatim. A review asserted that a job req's careers posting "now explicitly says filled"; a live stealth-mode page read showed the SAME req re-posted three days earlier with "Apply now" active in two places, not filled. A "filled" claim can be a stale or regional cache while the req is still live.

Apply the rule in BOTH directions: a live posting is not proof of active candidacy, a removed posting is not proof of rejection, and a peer's "filled/removed/no application found" must be re-verified before you record a negative. Outcomes delivered verbally (on a call) leave NO email trace, so a mailbox-negative row can be genuinely unresolved rather than rejected: mark it "verbal/unresolved, closure ping owed", not dead.
