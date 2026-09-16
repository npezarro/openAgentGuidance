<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

A recurring failure: across several turns of a credit-card recommendation thread, an agent asserted (a) that welcome-bonus eligibility was per-product-variant (outdated: the issuer had unified the variants under shared family language), and (b) that statement credits were per-product rather than per-card (fabricated, and backwards). Both were stated confidently from model memory, both were material to a "should I apply for this card" decision, and both were only corrected after the user pushed back. A third error in the same thread came from trusting a stale local notes file over the user's own statement about their own card.

The failure mode is NOT "the model didn't know." It is that the model answered anyway, and that deciding when to check was left to the model's own judgment of whether a domain felt "fast-moving."

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

Before posting a research-type answer (recommendations, comparisons, eligibility / how-much / what-happens-if questions), run the draft through a fact-check pass that:

1. Extracts the discrete external-actionable claims from the draft
2. Runs a current-year web search per claim (in parallel)
3. Returns per-claim verdicts: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED
4. Requires the answer to be revised for anything not CONFIRMED, and UNVERIFIED claims to be labeled as unverified in the final answer

A dedicated skill or subagent is the clean way to package this. For a single claim mid-conversation, a direct web search with the current month and year in the query is an acceptable lightweight equivalent, but the search must actually happen before the assertion is posted.

## Precedence of sources

1. **The user's own statement about their own accounts/actions.** Beats everything for existence-type facts; if internal data disagrees, the data is stale: say so, verify at the real source, fix the data.
2. **Current primary/web sources** (issuer terms pages, official docs, reputable specialist trackers). Required for external rules and offers.
3. **Internal curated files** (your private context repo, your knowledge base). Authoritative only for what they own (benefit detail, account numbers), never for external rules, and never over the user.
4. **Model memory.** Never sufficient for a covered claim. It generates the hypothesis; the search confirms it.

## Contradicting your own prior research

If an earlier turn in the same conversation established a researched fact and you are about to assert the opposite, that is a red flag, not a correction. Re-verify with a search and explicitly reconcile ("earlier I found X; the search now shows Y because Z"). Never silently flip.

## Deliverable URL liveness

Any URL you write into a deliverable that leaves your systems (resume, portfolio, cover letter, social post, anything sent or published) is an externally-checkable fact. Before writing it, curl the exact URL and confirm it serves the intended public page (HTTP 200 plus a real page, not a redirect to login and not a bare API). Gate the write on the check; do not ship a hedge like "confirm live status" about something you could verify in seconds.

These are NOT liveness signals, and each has burned a real deliverable:
- a repo exists on disk (`ls $HOME/<repo>` says nothing about a public URL);
- a process manager reports the service `online` (a running service with only `/api/*` routes serves no browsable page);
- a memory or index line says "LIVE" (memories are point-in-time and often mean "deployed", not "public page exists"; read the full memory, not just the one-line index, and then still curl it).

Origin pattern: a product was written into a resume and portfolio as a public page on the strength of a memory index line reading "LIVE <url>" plus a repo-exists `ls`. The path 404s: it is an internal-first API (only `/api/*`, requires an auth header). Neither signal proves public liveness.

### Private repo URLs 404 anonymously: that is an auth artifact, not proof of breakage

An unauthenticated request (curl, a fetch tool, a public link-checker) against a `github.com/<org>/<private-repo>/blob/...` URL returns **404, not 403**. GitHub does not reveal that a private repo exists to a caller who cannot see it. This is indistinguishable from a genuinely broken or renamed path unless you know to check authenticated. When verifying a link into a private repo, use:

```bash
gh api repos/<org>/<repo>/contents/<path>
```

A 200 with a `size` field confirms it is live; a 404 from `gh api` (unlike from anonymous curl) is a real miss. Mirror image of the login-wall false positive above: that one is a false positive (200 that is actually dead behind auth); this one is a false negative (404 that is actually alive behind auth).

## "Known / reputable brand" is a factual claim: verify provenance

Calling a brand "known", "established", "reputable", or "trusted" is an externally-checkable claim, not flavor. Do not assert it from marketplace star counts or review volume: that is the exact fake-review signal a skeptic gate is supposed to catch, laundered into credibility. Before applying any such label, run one search (`who makes <brand>` / `<brand> company history`) and classify:

- **Established.** An independent company with verifiable history and distribution beyond a single marketplace (a manufacturer founded decades ago, sold through multiple retail channels).
- **Marketplace-native label.** An invented seller brand (often an all-caps or nonsense word) sold mainly on one marketplace with no independent history. Never call these "known brands"; they can still be fine budget picks, but justify that on specific evidence, not borrowed reputation.

Never contradict your own skeptic gate: flagging "no-name" products as a trap while presenting same-tier marketplace-native brands as "known brands" in the same guide is the failure this rule exists to prevent.

## Research-source constraints worth knowing up front

Three constraints that bite repeatedly when researching issuer or merchant rules:

1. **Aggregator tables carry dates; extract them.** The best aggregate source for "which merchants trigger this category credit" was a sortable community table in which nearly every data point was six years old. Always extract the date column (a text-mode page reader plus grep beats a summarizing fetch, which tends to drop the dates), cite the age, and treat "Works" / "Does not work" as unproven rather than settled.
2. **Issuer benefit-terms pages often return HTTP 403 to automated fetchers.** When that happens, the answer must come from two independent secondary sources, and it should say so rather than implying the issuer was read directly.
3. **Some large community sites are blocked to search tooling** (returning an error that the domain is not accessible to the user agent), including via allowed-domain lists. Crowd-sourced data points need an aggregator or a direct page reader instead.

Practical consequence: recommend a cheap test (a small test charge, a trial request) before committing on a data point that rests only on an old observation, and record the evidence gaps explicitly in the deliverable.

## Eligibility on a marketing/FAQ page is not evidence: read the sentence printed on the form

A public library system's marketing page said an out-of-region applicant could apply online for a card. The live application form said the opposite, verbatim: cards are only available to in-region residents. A research pass that only reads marketing pages will report "eligible", and the agent will then submit a false residency claim.

Same failure shape twice in one session: a research pass reported a signup page as CAPTCHA-free, but the live page was shadow-DOM with a captcha response field present.

**Rule:** for any signup, eligibility, or enrollment task, the authoritative quote is the one rendered on the form you are about to submit, read via the browser after the page loads. Treat FAQ, marketing, guide pages and search-snippet quotes as leads to verify, never as the finding. When they conflict, the form wins and you stop.

**Corollary:** this is also the cheapest place to catch a subagent's overconfident research, so map the form BEFORE filling it, not after a failed submit.

## A per-day cheapest-price table prices specific departures

A research pack tabulated "cheapest nonstop per candidate day" for a route and recorded one day at CA$215. A later turn recommended a specific 19:05 departure and carried that CA$215 across. Re-scraping the live board showed the 19:05 was CA$283; the CA$215 applied only to the 06:00, 06:50 and 21:25 departures. The carrier ran three distinct price bands on one route on one day, keyed to departure time.

Why it is silent: a per-day fare table answers "what does this DAY cost", which is right when choosing a day. The moment the decision narrows to a specific flight, the table's number stops applying, and the number came from your own verified research, so it carries unearned authority.

**How to apply:** once a recommendation names a specific flight number or departure time, re-verify that flight's own fare before quoting a price. Treat day-level tables as scoped to day-level decisions. Same applies to hotels (a cheapest-per-night figure is not the rate for the room you actually want) and to any per-bucket minimum.

**Second habit from the same re-scrape:** fares moved measurably in ~24 hours (one carrier's evening departure went CA$164 to CA$224, +37%). If prior fare research is more than a day old and the user is about to book, re-pull rather than quote it. A stale fare presented confidently is worse than no fare.

## A cited page may not carry the claim it was cited for

An answer asserted a park-authority trail-restriction status and cited a third-party trail aggregator. That page carried only static trail stats plus an Open/Closed flag; the live authority condition feed was on a different page entirely. The assertion happened to be true, but the citation did not support it.

Why: a plausible-looking source URL next to a claim reads as verified. Re-fetching the exact cited URL is what separates "this site would know" from "this page says so."

**How to apply:** when reviewing or reusing someone else's cited claim, re-fetch the specific URL and confirm the asserted fact appears on that page. If it does not, find the page that carries it, or state the claim is single-sourced.

Operating-hours and enforcement-window claims that gate an action deserve the same treatment. An earlier answer's "parking is enforced 07:00-19:00, so an evening visit costs you nothing" was off by four hours at the start of the window (actual 03:00-19:00), which flipped a free recommendation into a $42 charge and hid a hard prerequisite.

## A numeric-presence check is not a claim check: verify the pairing

A retrieval-augmented answer cited three retailer prices to one URL: "$199.99 at retailer A, $229.99 at retailer B, $249.99 at retailer C [4]". Source 4 was a price-history site for retailer A only. It genuinely carries historical highs, so every number really is somewhere on that page, and a check that only asks "does this figure appear in a cited source" passes cleanly. What is false is the PAIRING: a price bound to a retailer the source never mentions at all. The real price was roughly $99.

This is a step past "a cited page may not carry the claim" above: there the fix is confirming the fact appears on the page at all; here the fact (the number) DOES appear, and the check still needs to fail, because what it is attached to is fabricated.

**How to apply:** the unit of verification is the claim, not the number. Per cited sentence, check (1) every money amount appears in a cited source, AND (2) every entity the sentence attributes something TO (retailer, vendor, venue, person) is actually mentioned by that same cited source. A verification pass that stops at (1) will wave through a plausible-looking multi-entity sentence built by stapling real numbers onto the wrong names.

## A cited issue number is not a verified issue: check state, closed_at, and the LAST comment

A hardware recommendation ruled out an entire configuration on the strength of "issue #NNNNN documents data corruption on this topology." The issue number came from a web-search result summary, which faithfully quoted the bug report's symptom section. The issue was CLOSED, labelled `bug-unconfirmed`, and the reporter's own final comment named the root cause: a marginal riser cable throwing bus drops. Swapping the cable took the workload from 6 of 15 garbled runs to 0 of 3 on the identical build. The reporter's words: hardware-induced, not a software bug.

Why this is its own failure mode: a bug-tracker URL confers more authority than a blog post, so an issue number gets repeated without the scepticism a random site would attract. And search summaries systematically reproduce the alarming top of a report (title, symptoms, repro steps) while dropping the mundane bottom (it was the cable / works as intended / duplicate / fixed in v2). The summary is not wrong about what the body says; it is silent about what happened next.

**How to apply.** Before repeating any tracker item as a decision constraint, fetch it and read four fields, none of which is the body:

```bash
curl -s https://api.github.com/repos/OWNER/REPO/issues/N | jq '{state,closed_at,labels:[.labels[].name],comments}'
curl -s https://api.github.com/repos/OWNER/REPO/issues/N/comments | jq -r '.[-1].body'
```

`state` and `closed_at` tell you whether it is live. The LAST comment tells you why it closed, which the body never can. Labels distinguish confirmed from `bug-unconfirmed`. Same discipline for a linked PR: open, merged, and closed-unmerged are three different facts (a closed-unmerged PR is often quoted as if the feature shipped).

Two corollaries worth the extra minute:
- **Read the rest of the thread, not just the resolution.** In this case three OTHER users had a real, still-unresolved regression buried underneath, because the issue was closed on the original reporter's cable rather than on their problem. The retraction and the surviving finding were both in the same thread.
- **When the dramatic objection collapses, rebuild the recommendation on the boring objections** rather than quietly keeping the conclusion. Power draw, thermals and buying the wrong axis still argued against that configuration; saying so is more useful, and more honest, than a scare that has been withdrawn.

## Eliminating an option needs a primary source; ranking it can survive on a secondary one

The same document ruled a GPU vendor out entirely on "consumer ROCm is Linux-only and WSL2 breaks it," sourced from one SEO-adjacent blog summary. The vendor publishes an official WSL compatibility matrix that lists the exact card under the current release with no preview label and no caveat rows. The elimination was false; a correct ranking (that vendor is ~30% slower on the metric that mattered) was available from measurements and would have reached the same final recommendation without the error.

The asymmetry is the point. Ranking an option wrong costs some accuracy in a comparison the reader can still see. Eliminating an option deletes it from the reader's decision space entirely, and they will never know what they did not get to weigh. So elimination is the stronger claim and needs the stronger evidence: a vendor compatibility matrix, official docs, release notes, a spec sheet, not a summary of one.

Two habits that catch this:
- **Check whether the constraint is even load-bearing before building on it.** Here the inference server is reached over HTTP, so it never needed to run inside WSL2 at all; the whole objection was about a deployment choice, not a capability.
- **When the correction lands, retract it AT THE POINT A READER HITS IT.** A rebuttal section eighty lines below the false claim means an in-order reader gets the error first and the correction only if they keep going. Edit the original paragraph and link forward; do not rely on the later section to do the work.

## A benchmark number carries its harness

A hardware recommendation was built on "a 27B dense model prefills at 437 t/s on this GPU", taken as a property of the card. The same model class on the same card under a different inference runtime with speculative decoding does 1,261 t/s. Runtime and flag choice was worth ~3x, more than the next hardware tier up, and the recommendation's central trade-off ("you get parameters OR speed") was an artifact of the binary someone happened to benchmark with.

Flags also interact and fail silently: one batch-size flag gave 5.5x prefill only when a competing memory-fit flag was off, and a mismatched pair of KV-cache quantisation types caused a silent 4-13x prefill collapse with no error.

**Rule:** before reasoning from a throughput number, record which build, which runtime, and which flags produced it, and prefer two numbers from the same harness over two numbers from the same vendor. When comparing options, a same-harness comparison beats a more-recent mismatched one.

## A supplied parts list or spec sheet is a claim about the past

A build sheet supplied for a machine named one CPU and one RAM capacity; the live system reported a different CPU and 2.5x the RAM, both having been upgraded since the sheet was written. That mattered because the real CPU drew 54W more, which tightened a power budget the recommendation depended on.

**Rule:** treat each line of a supplied inventory as a claim, reconcile it against something measurable (`/proc/cpuinfo`, `free`, `nvidia-smi`, `lsblk`, `Get-CimInstance`), and state explicitly which lines were confirmed, which were corrected, and which are unverifiable in software (chassis and power supply usually are). Do not let the unverifiable lines inherit the credibility of the verified ones.

Second half of the same lesson: on a power supply the first hard blocker is often the CONNECTOR COUNT rather than the wattage, and no power limit or splitter fixes a missing connector, so read the connector table and not just the rating.

## A degraded search backend produces confident, cited fabrication

A local retrieval-augmented research pipeline reported a sander at **$299-$349** (real price ~$99) and cited a **TV-series encyclopedia page**. The answer was fluent, internally consistent, and carried citations. Nothing about its shape signalled it was wrong, and it would have sent a reader to checkout expecting roughly triple the real price.

The cause was the search backend, not the model. The metasearch layer had one provider suspended and two CAPTCHA'd, leaving only a keyword-matching engine: asked for "best power sander for stripping thick dark wood finish under $150," it returned a retailer's category page and two dictionary definitions of "best." The synthesis model dutifully built an answer out of whatever it was handed. On a sibling task the SAME pipeline correctly refused ("the evidence is entirely unrelated to the query") when the mismatch was more obvious. The grounding discipline works; it just cannot distinguish evidence that answers the question from evidence that merely resembles an answer. Citations prove provenance, never correctness.

**How to apply:** a retrieval pipeline needs a HARD refusal signal for "my retrieval was degraded," separate from any informational degradation field, and every caller must refuse on it rather than ship a plausible-looking answer.

Threshold used here: **one dead search engine is routine flakiness; two or more means the surviving result set is only whatever happened to survive, not a real sample of the web.** Raising an `untrustworthyRetrieval` flag at that threshold let the caller fall through to a different engine instead of shipping the wrong price.

Two supporting bugs made the degradation invisible until then, and are worth checking for in any similar pipeline:
- a dedup step that returns a NEW array can silently drop a degradation flag attached to the pre-dedupe array;
- a client timeout calibrated on a fast/small model can kill a slower/larger model's synthesis mid-answer, surfacing as an empty result that a downstream quality measurement scores as "bad" rather than "failed."

## A visa-exempt nationality silently fails an ID checklist that assumes a visa foil

A U.S. state's REAL ID document list for non-citizens reads "foreign passport WITH valid U.S. Visa + I-94" (tracking 6 CFR 37.11(c)(1)(vi)). Some nationalities are visa-exempt and have no visa foil in the passport, so they satisfy no listed combination literally; the only visa-less variant published is reserved for a narrow treaty category. A substantive catch-all provision does cover them (I-94 and I-797 are verifiable DHS documents), which is why it works in practice, but that is counter-clerk discretion rather than a published path.

Why it matters: reading the eligibility list as satisfied because "they have a passport and an I-94" misses that the AND-term in the middle is unsatisfiable for that nationality. The same shape recurs anywhere a checklist enumerates document COMBINATIONS: check each conjunct against the person's actual nationality/status, not the row as a whole.

**How to apply:** when screening an eligibility or document checklist, expand every "A + B + C" row and confirm the subject can produce EACH element. Flag any element that is structurally impossible for their category (visa-exempt, age-exempt, treaty national) rather than assuming a catch-all will absorb it. Also compare the strict list against the fallback/non-compliant list: the same state's non-compliant licence list accepts a bare I-797 approval notice and passport+I-94 without a visa, so the fallback product is materially easier to obtain than the compliant one.

## A dependency-audit scan can drop a repo's high bucket when it also has a critical finding

A first-pass automated security scanner (npm-audit based, sweeping ~30 repos) reported one repo as "1 critical, 0 high" and omitted it entirely from the high-findings list. A direct re-run on the same repo showed critical=1 AND high=16. The high bucket was real but silently dropped. Every other audited repo's per-repo high count matched a direct re-run exactly (14 of 14 verified); only the one repo that ALSO carried a critical finding lost its high bucket.

The fingerprint was visible without re-running anything: the scan's own header said `HIGH_FINDINGS: 15` while its body listed 14 high entries.

**How to apply:**
- When a scan summary's header count and listed-entry count disagree, verify the repo whose findings are missing before trusting either number.
- When verifying a security scan's severity bucketing, re-run the real tool on any repo that has a critical finding, not just a sample. Critical+high co-occurrence in the same repo is exactly where a severity-bucketing scanner is most likely to lose a bucket.

```bash
npm audit --json | jq '.metadata.vulnerabilities'
```
