<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

The usual failure is not that the model didn't know something. It is that the model answered anyway, and the decision about when to check was left to its own sense of whether a domain "felt fast-moving." Typical errors:
- A confidently stated eligibility rule that was out of date.
- A rule about how benefits stack that was simply made up, and backwards.
- A stale local file trusted over the user's own statement about their own account.

Each of these was material to a decision, and each was corrected only after the user pushed back.

## The rule

**If a factual claim is (1) external to your own systems and (2) something the user could act on, verify it with a current search before asserting it. Do not decide for yourself whether the topic is volatile enough to check.**

Covered claim classes (not a complete list):
- Credit card, bank and issuer rules: bonus eligibility, product-family language, credit stacking, application rules, offer amounts and deadlines
- Prices, fees, promotions, and whether a product or service is available
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal, policy and immigration facts, program rules, published schedules

Not covered: anything about the user's own accounts, infrastructure, repos or history. For those, check the actual source instead (database, email, git, or the user's own statement).

## Procedure

Before posting a research-type answer (recommendations, comparisons, or "am I eligible / how much / what happens if" questions), run the draft through a fact-check pass. If you have a `fact-check` skill, use it. Otherwise:

1. Pull out each separate external, actionable claim in the draft.
2. Run a web search for each claim with the current year in the query (in parallel).
3. Give each claim a verdict: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED.
4. Revise the answer for every claim that is not CONFIRMED. In the final answer, label UNVERIFIED claims as unverified.

For a single claim mid-conversation, one direct web search with the current month and year in the query is enough. But the search has to happen before you post the claim.

## Precedence of sources

1. **The user's own statement about their own accounts or actions.** This beats everything for facts about whether something exists. If internal data disagrees, the data is stale: say so, check the real source, and fix the data.
2. **Current primary and web sources** (issuer terms pages, official docs, reputable deal and rule trackers). These are required for external rules and offers.
3. **Internal curated files** (your notes, your knowledge base). These are authoritative only for what they own (benefit details, member numbers). They never decide external rules, and they never override the user.
4. **Model memory.** Never enough for a covered claim. It produces the hypothesis; the search confirms it.

## Contradicting your own prior research

If an earlier turn in the same conversation established a researched fact and you are about to say the opposite, treat that as a red flag, not a correction. Search again and reconcile out loud ("earlier I found X; the search now shows Y because Z"). Never flip silently.

## Deliverable URL liveness

Any URL in a deliverable that leaves your systems (resume, portfolio, cover letter, social post, anything sent or published) is a fact someone outside can check. Before you write it, curl the exact URL and confirm it serves the intended public page: HTTP 200 and a real page, not a redirect to a login and not a bare API. Write the URL only after the check passes. Don't ship a hedge like "confirm live status" for something you could verify in seconds.

None of these prove a URL is live:
- the repo exists on disk;
- the process manager shows the service as online (a service with only `/api/*` routes has no page to browse);
- a memory or index line says "LIVE" (memories capture one moment and often mean "deployed", not "public page exists"; read the full note, then curl anyway).

Lesson: an internal API product was listed in a resume as a public product because a memory line said "LIVE" and the repo existed. The path returned 404; it only served authenticated `/api/*` routes.

### Private GitHub repo URLs return 404 to anonymous requests: that comes from auth, it doesn't prove the link is broken

An unauthenticated request (curl, a web fetch, a public link checker) to a `github.com/<org>/<private-repo>/blob/...` URL returns **404, not 403**. GitHub doesn't reveal that a private repo exists to anyone who can't see it. Unless you check while authenticated, this looks the same as a broken or renamed path. To verify a link into a private repo, use:

```bash
gh api repos/<org>/<repo>/contents/<path>
```

A 200 with a `size` field confirms the file exists. A 404 from `gh api` (unlike one from curl) is a real miss. This is the reverse of the login-wall case above: that one is a false positive (a 200 that is really dead behind auth); this one is a false negative (a 404 that is really alive behind auth).

## "Known / reputable brand" is a factual claim: verify where the brand comes from

Calling a brand "known", "established", "reputable" or "trusted" is a claim that can be checked, not decoration. Don't base it on marketplace star ratings or review counts. Those are exactly the fake-review signals a skeptic check should catch, and using them this way passes them off as credibility. Before using any such label, run one search (`who makes <brand>` / `<brand> company history`) and classify the brand:
- **Established:** an independent company with a verifiable history and sales outside a single marketplace.
- **Marketplace-native label:** a made-up seller brand (often an all-caps or nonsense word) sold mainly on one or two marketplaces, with no independent history. Never call these "known brands". They can still be fine budget picks, but justify that with specific evidence, not borrowed reputation.

Don't contradict your own skeptic check. Warning readers about "no-name" products while calling marketplace-native brands of the same tier "known brands" in the same guide is the exact failure this rule exists to prevent.

## Research source constraints

- **Aggregate tables are often old.** Community-maintained "does merchant X trigger credit Y" tables can be built mostly from data points that are years old. Always pull out the date column (a text-only page reader plus grep works better than a summarizing fetch, which tends to drop dates), cite how old each point is, and treat "works / doesn't work" as unproven.
- **Issuer pages may block automated fetches** (HTTP 403). In that case, get the terms from two independent secondary sources and say so; don't imply you read the issuer directly.
- **Some forums are blocked to web search tools.** Use aggregators or a direct page reader instead.
- When a recommendation rests on one old data point, suggest a small test transaction before the user commits, and list the evidence gaps in the deliverable.

## Eligibility on a marketing or FAQ page is not evidence: read the sentence on the application form

A public page can say someone is eligible while the live application form says the opposite, word for word. If a research pass reads only marketing pages, it will report "eligible", and the agent will then submit a false claim. A similar case: research reported a signup page as having no CAPTCHA, but the live page hid a reCAPTCHA field in its shadow DOM.

Rule: for any signup, eligibility or enrollment task, the authoritative quote is the one shown on the form you are about to submit, read in a browser after the page loads. Treat FAQs, marketing pages, guides and search snippets as leads to verify, never as findings. When they conflict, the form wins, and you stop.

The form is also the cheapest place to catch a subagent's overconfident research, so map the form BEFORE filling it, not after a failed submit.

## A per-day cheapest-price table prices particular options; check again once you name one

A table of "cheapest nonstop per day" answers "what does this DAY cost", which is the right question while choosing a day. Once the recommendation names a specific flight or departure time, the table's number no longer applies. A carrier can run several price bands on one route on one day, depending on departure time. The error is easy to miss because the number came from your own verified research, so it carries authority it hasn't earned.

How to apply:
- Once a recommendation names a specific flight number or departure time, check that flight's own fare before quoting a price. Use day-level tables only for day-level decisions.
- The same goes for hotels (the cheapest nightly rate is not the rate for the room you want) and for any minimum taken per bucket.
- Fares can move 30%+ in about a day. If fare research is more than a day old and the user is about to book, pull it again rather than quoting it. A stale fare stated confidently is worse than no fare.

## A cited page may not carry the claim it was cited for

A plausible-looking source URL next to a claim reads as verified. A common miss: an aggregator page that shows only static stats and an open/closed flag gets cited for a live condition status that is actually on a different page.

How to apply: when you review or reuse someone else's cited claim, fetch that exact URL again and confirm the fact appears on that page. If it doesn't, find the page that does carry it, or say the claim has a single source. Give claims about hours and enforcement windows that gate an action the same treatment. A window that is wrong by a few hours can turn a "free" recommendation into a real charge.

## Checking that a number appears is not checking the claim: verify what it's attached to

A cited sentence like "$X at Retailer A, $Y at Retailer B, $Z at Retailer C [4]" can cite a price-history page for only one retailer. Every number really does appear somewhere on that page, so a check that only asks "does this figure appear in a cited source" passes. What's false is the pairing: prices tied to retailers the source never mentions.

**How to apply:** verify the whole claim, not the number. For each cited sentence, check that (1) every money amount appears in a cited source, AND (2) every entity the sentence attributes something to (retailer, vendor, venue, person) is actually mentioned in that same source. A pass that stops at (1) will let through a plausible multi-entity sentence built by attaching real numbers to the wrong names.

## A cited issue number is not a verified issue: check state, closed_at, and the LAST comment

A bug tracker link carries more authority than a blog post, so people repeat issue numbers without the skepticism they'd apply to a random site. Search summaries consistently reproduce the alarming top of a report (title, symptoms, repro steps) and drop the mundane end (it was a hardware fault / works as intended / duplicate / fixed in a later version). The summary isn't wrong about the body; it just leaves out what happened next.

Before repeating any tracker item as a reason for a decision, fetch it and read these fields (none of them is the body):

```bash
curl -s https://api.github.com/repos/OWNER/REPO/issues/N | jq '{state,closed_at,labels:[.labels[].name],comments}'
curl -s https://api.github.com/repos/OWNER/REPO/issues/N/comments | jq -r '.[-1].body'
```

`state` and `closed_at` tell you whether the issue is still open. The LAST comment tells you why it closed, which the body never can. Labels separate confirmed bugs from unconfirmed ones. Apply the same discipline to a linked PR: open, merged and closed-unmerged are three different facts (a closed-unmerged PR is often quoted as if the feature shipped).

Corollaries:
- Read the rest of the thread, not just the resolution. An issue closed because of the original reporter's own cause can hide other users' real, still-unresolved problems.
- When the dramatic objection collapses, rebuild the recommendation on the boring objections instead of quietly keeping the conclusion. If cost, power or fit still argue against the option, say so; a withdrawn scare is no basis for a recommendation.

## Eliminating an option needs a primary source; ranking one can rest on a secondary source

Ranking an option wrong costs some accuracy in a comparison the reader can still see. Eliminating an option removes it from the reader's choices completely, and they'll never know what they didn't get to weigh. So elimination is the stronger claim and needs stronger evidence: a vendor compatibility matrix, official docs, release notes, a spec sheet. A blog's summary of one of those is not enough.

Two habits that catch this:
- Before building on a constraint, check whether anything actually depends on it. An objection about where a component "can run" doesn't matter if the design never needs it to run there.
- When you correct something, put the correction where the reader meets the claim. A rebuttal far below the false claim means a reader going in order gets the error first. Edit the original paragraph and link forward.

## A benchmark number comes with its setup: check which runtime and flags produced it

Throughput numbers often reflect the runtime and flags more than the hardware. A different inference runtime or a feature like speculative decoding can be worth about 3x on the same hardware, more than moving up a hardware tier. Flags also interact and can fail without any error: one flag's speedup may appear only when a competing flag is off, and mismatched settings can quietly cut throughput several times over.

Rule: before reasoning from a throughput number, record which build, runtime and flags produced it. Prefer two numbers from the same setup over two numbers from the same vendor. A comparison on the same setup beats a newer comparison on mismatched setups.

## A supplied parts list or spec sheet describes the past: check every line against the live system

Hardware gets upgraded after the sheet is written. A different CPU or RAM amount changes power budgets and the conclusions built on them.

Rule: treat each line of a supplied inventory as a claim. Check it against something measurable (`/proc/cpuinfo`, `free`, `nvidia-smi`, `lsblk`, `Get-CimInstance`) and state which lines were confirmed, which were corrected, and which software can't verify (the chassis and power supply usually can't be). Don't let the unverifiable lines borrow the credibility of the verified ones.

Related: with a power supply, the first hard limit is often the number of connectors, not the wattage. No power limit or splitter fixes a missing connector, so read the connector table, not just the rating.

## A degraded search backend produces confident, cited fabrication

A retrieval pipeline whose search backend has lost most of its engines (suspended, CAPTCHA'd) can fall back to a keyword-matching engine that returns category pages and dictionary definitions. The synthesis model then builds a fluent, internally consistent, cited answer from whatever it gets, including a price several times too high, cited to a completely unrelated page. Grounding catches obvious mismatches, but it can't tell evidence that answers the question from evidence that merely looks like an answer. Citations prove where text came from, never that it's correct.

**How to apply:**
- A retrieval pipeline needs a HARD refusal signal for "my retrieval was degraded", separate from any informational degradation field. Every caller must refuse on that signal (or fall through to a different engine) instead of shipping a plausible-looking answer.
- Threshold: one dead search engine is routine flakiness. Two or more means the remaining results are just whatever survived, not a real sample of the web.
- Check for two bugs that hide degradation: a dedup step that returns a NEW array can silently drop a degradation flag attached to the original array; and a client timeout tuned for a fast, small model can kill a slower model mid-answer. That shows up as an empty result, which downstream scoring rates as "bad" rather than "failed."

## Checklists of document combinations can be impossible for some categories of applicant

ID and eligibility checklists often list combinations like "foreign passport WITH valid visa + entry record". A visa-exempt national has no visa in their passport, so they literally meet no listed combination, even if a catch-all provision covers them in practice. The catch-all depends on the clerk's discretion; it isn't a published path.

How to apply: when screening a checklist of document combinations, expand every "A + B + C" row and confirm the person can produce EACH element. Flag any element that is impossible for their category (visa-exempt, age-exempt, treaty national) instead of assuming a catch-all will cover it. Also compare the strict list with any fallback or lower-tier product list; the fallback can be much easier to get.

## A security scan's severity counts can lose a bucket

A summarizing security scanner built on `npm audit` can report a repo as "1 critical, 0 high" when a direct `npm audit --json` run shows 1 critical and 16 high. The repos most likely to lose a bucket are the ones that have findings in several severities at once. A telltale sign: the summary header's count doesn't match the number of entries listed under it.

Rule: when a scan's header count and its listed-entry count disagree, check the repo whose findings are missing before trusting either number. When verifying severity counts, always run the real tool again on every repo with a critical finding, not just a sample.

## A negative claim about a fast-moving product needs a search from the same week

"X doesn't ship" or "that launch isn't real" can go out of date within days. A current-state inventory written a few days before an announcement will confidently call the announced feature false.

Rule: before flagging any "this exists / this happened" claim in a deliverable as wrong, run a web search limited to the last 7 days, and state the date of any research file you use as evidence.

## A second reviewer's "listing is filled / removed" claim must be checked against the live page

When you merge in an external review (for example, another model's audit of a job search or listing tracker), don't copy its claims about whether a listing is live or what the outcome was. A "filled" claim can come from a stale or regional cache while the listing has been reposted with an active apply button.

Apply the rule both ways: a live posting doesn't prove the candidacy is active, and a removed posting doesn't prove a rejection. Check a peer's "filled / removed / no application found" before recording a negative. Outcomes given verbally (on a call) leave no email record, so a row with no email verdict may be genuinely unresolved rather than rejected. Mark it "verbal/unresolved, follow-up owed", not dead.

## Government travel advisories cover different areas: cite the US, UK and Canada together

Independent government advisories for the same city can draw their restricted zones very differently. One may restrict only named districts, another may put the whole city at an elevated level, and a third may advise against all but essential travel to the wider region. None of them is wrong, but citing only the most permissive one quietly drops the others' restricted areas.

How to apply: when a trip includes a city under any regional advisory, quote all three (US State Department, UK FCDO, travel.gc.ca) with their dates. Check the recommended hotel and airport area against each one, prefer itineraries with the fewest nights in a flagged area, and note that some travel insurance excludes areas under "avoid" or "reconsider travel" advice.
