<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

The failure mode is not that the model didn't know. The failure is that it answered anyway, and it decided when to check based on whether a domain *felt* fast-moving. A common pattern:

- An eligibility rule stated confidently from model memory that had since changed.
- A claim that was simply made up, and backwards.
- A stale local file trusted over the user's own statement about their own account.

Each of these mattered to a decision the user was about to make. Each one was corrected only after the user pushed back.

## The rule

**If a factual claim is (1) external to your own systems and (2) something the user can act on, verify it with a current search before you assert it. Do not judge for yourself how volatile the topic is.**

Covered claim classes (non-exhaustive):
- Credit card, bank and issuer rules: bonus eligibility, product-family language, credit stacking, application rules, offer amounts and deadlines
- Prices, fees, promotions, availability of products or services
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal, policy and immigration facts, program rules, published schedules

Not covered: anything about the user's own accounts, infrastructure, repos or history. Check those against the actual source instead (database, email, git, the user's own statement).

## Procedure: a fact-check pass

Before you post a research-type answer (recommendations, comparisons, eligibility, how-much or what-happens-if questions), run the draft through a fact-check pass. Use a skill or subagent if you have one. The pass:

1. Extracts each separate external, actionable claim from the draft.
2. Runs a web search per claim that includes the current year (run these in parallel).
3. Gives each claim a verdict: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED.
4. Requires you to revise the answer for anything not CONFIRMED, and to label UNVERIFIED claims as unverified in the final answer.

For a single claim mid-conversation, a direct web search with the current month and year in the query is an acceptable lighter version. The search must actually run before you post the claim.

## Precedence of sources

1. **The user's own statement about their own accounts and actions.** This beats everything for facts about whether something exists. If internal data disagrees, the data is stale: say so, check the real source, and fix the data.
2. **Current primary and web sources** (issuer terms pages, official docs, reputable specialist trackers). These are required for external rules and offers.
3. **Internal curated files** (notes, your knowledge base). These are authoritative only for what they own (benefit details, member numbers). They never decide external rules, and they never override the user.
4. **Model memory.** Never enough for a covered claim. It suggests the hypothesis; the search confirms it.

## Contradicting your own prior research

Suppose an earlier turn in the same conversation established a researched fact, and you are about to assert the opposite. Treat that as a red flag, not a correction. Search again and reconcile it out loud ("earlier I found X; the search now shows Y because Z"). Never flip silently.

## Deliverable URL liveness

Any URL you put in a deliverable that leaves your own systems (resume, portfolio, cover letter, social post, anything sent or published) is a fact someone else can check. Before writing it, curl the exact URL. Confirm it serves the intended public page: HTTP 200 and a real page, not a redirect to a login and not a bare API. Don't write the URL until the check passes. Don't ship a hedge like "confirm live status" about something you could check in seconds.

None of these prove a URL is live:
- The repo exists on disk.
- The service shows as running in the process manager. A running service with only `/api/*` routes serves no page anyone can browse.
- A memory or index line says "LIVE". Memories record one moment and often mean "deployed", not "public page exists". Read the full memory, then still curl the URL.

Lesson: a product was once listed in a resume as public based only on an index line and an `ls`. Its public path returned 404 because it was an internal, key-gated API.

### Private GitHub repo URLs return 404 anonymously: an auth artifact, not proof of breakage

An unauthenticated request (curl, a web fetch tool, a public link checker) to a `github.com/<org>/<private-repo>/blob/...` URL returns **404, not 403**. GitHub hides private repos from callers who can't see them. Unless you know to check with auth, that 404 looks exactly like a broken or renamed path. To verify a link into a private repo, use the authenticated API instead of anonymous curl:

```bash
gh api repos/<org>/<repo>/contents/<path>
```

A 200 with a `size` field means the file is live. A 404 from `gh api` (unlike one from curl) is a real miss. This is the mirror image of the login-wall case above: that one is a false positive (a 200 that is really dead behind auth); this one is a false negative (a 404 that is really alive behind auth).

## "Known / reputable brand" is a factual claim: verify provenance

Calling a brand "known", "established", "reputable" or "trusted" is a claim someone can check, not flavor text. Don't base it on marketplace star counts or review volume. Those are the fake-review signals a skeptic check is meant to catch; using them for credibility just launders them. Before you apply any such label, run one search (`who makes <brand>` / `<brand> company history`) and classify the brand:
- **Established:** an independent company with a history you can verify and distribution beyond a single marketplace.
- **Marketplace-native label:** an invented seller brand (often an all-caps or nonsense word) sold mainly on one or two big marketplaces with no independent history. Never call these "known brands". They can still be fine budget picks, but justify that with specific evidence, not borrowed reputation.

Don't contradict your own skeptic check. Warning readers about "no-name" products while presenting same-tier marketplace labels as "known brands" in the same guide is exactly the failure this rule prevents.

## Aggregator tables age, issuer pages block, some sites are unreachable

When researching crowd-sourced data (for example, which merchants trigger a card's category credit):

1. Aggregate tracker tables are often the best source, but individual data points can be years old. Always pull the date column, cite how old it is, and treat "works" / "does not work" as unproven rather than settled. Plain-text extraction plus grep often keeps dates that a summarizing fetch tool drops.
2. Issuer terms pages often return 403 to automated fetchers. If so, take the terms from two independent secondary sources, and say in the answer that you didn't read the issuer page directly.
3. Some forums are blocked to the search tool. Use an aggregator or a direct page reader for crowd data instead.

What this means in practice: recommend a test transaction before the user commits to anything that rests on one old data point, and list the evidence gaps in the deliverable.

## Eligibility on a marketing or FAQ page is not evidence: read the form

A library's public page may say out-of-area residents can apply online while the live application form says, word for word, that only residents can. A research pass that reads only marketing pages will report "eligible", and the agent will then submit a false eligibility claim. The same shape shows up with "no CAPTCHA" claims about signup pages that turn out to carry a reCAPTCHA field in shadow DOM.

Rule: for any signup, eligibility or enrollment task, the authoritative text is what the form you are about to submit shows, read in the browser after the page loads. Treat FAQ pages, marketing copy, guides and search snippets as leads to check, never as the finding. When they conflict with the form, the form wins and you stop.

Corollary: this is also the cheapest place to catch a subagent's overconfident research, so map the form BEFORE filling it in, not after a submit fails.

## Per-bucket minimum prices don't apply to a specific item

A "cheapest fare per day" table prices specific departures. If you later recommend one particular flight and carry the day's minimum across, the quote can be wrong. Carriers often run several price bands on one route on one day, keyed to departure time. The error is silent because the number came from your own verified research, so it carries authority it hasn't earned.

How to apply:
- Once a recommendation names a specific flight number or departure time, check that flight's own fare before quoting a price. Day-level tables are for day-level decisions.
- The same applies to hotels (the cheapest nightly rate is not the rate for the room you want) and to any per-bucket minimum.
- Fares can move by tens of percent within a day. If fare research is more than a day old and the user is about to book, pull it again. A stale price quoted confidently is worse than no price.

## A cited page may not carry the claim it was cited for

A plausible-looking source URL next to a claim reads as verified. Fetching the exact cited URL again is what separates "this site would know" from "this page says so". Aggregator pages often show only static data, while the live status sits on a different page.

How to apply: when you review or reuse someone else's cited claim, fetch the specific URL and confirm the fact appears on that page. If it doesn't, find the page that carries it, or say the claim has only one source. Give the same treatment to operating hours and enforcement windows that decide whether an action is safe or free. Being off by a few hours at one end of an enforcement window can turn a "free" recommendation into a charge.

## A number appearing in the source is not a claim check: verify the pairing

A generated answer can cite several prices from different retailers to a single source, and every number really does appear somewhere on that page (for example, historical highs on a single-retailer price-history page). A check that only asks "does this figure appear in a cited source" passes. What is false is the **pairing**: a price tied to a retailer the source never mentions.

How to apply: verify the claim, not just the number. For each cited sentence, check that:
1. every money amount appears in a cited source, AND
2. every entity the sentence attributes something to (retailer, vendor, venue, person) is actually mentioned by that same source.

A check that stops at (1) will pass plausible multi-entity sentences built by attaching real numbers to the wrong names.

## A cited issue number is not a verified issue: check state, closed_at and the LAST comment

A bug-tracker URL carries more authority than a blog post, so issue numbers get repeated with less scrutiny. Search summaries tend to reproduce the alarming top of a report (title, symptoms, repro steps) and drop the mundane end (it was the hardware / works as intended / duplicate / fixed in a later version). A whole configuration can get ruled out on the strength of a closed, unconfirmed issue whose reporter later traced the problem to a faulty cable.

Before you treat any tracker item as a constraint on a decision, fetch it and read four fields, none of which is the body:

```bash
curl -s https://api.github.com/repos/OWNER/REPO/issues/N | jq '{state,closed_at,labels:[.labels[].name],comments}'
curl -s https://api.github.com/repos/OWNER/REPO/issues/N/comments | jq -r '.[-1].body'
```

- `state` and `closed_at` tell you whether the issue is still live.
- The LAST comment tells you why it closed, which the body never can.
- Labels separate confirmed bugs from unconfirmed ones.
- For linked PRs, open, merged and closed-unmerged are three different facts. A closed-unmerged PR is often quoted as if the feature shipped.

Corollaries:
- Read the rest of the thread, not just the resolution. Other users may report a separate regression that is still unresolved, closed only because the original reporter's problem was fixed.
- If the dramatic objection collapses, rebuild the recommendation on the boring objections (power, thermals, cost) instead of quietly keeping the conclusion.

## Eliminating an option needs a primary source; ranking it can rest on a secondary one

Ranking an option wrong costs some accuracy in a comparison the reader can still see. Eliminating an option removes it from the reader's choices entirely, and they never learn what they didn't get to weigh. So elimination is the stronger claim and needs stronger evidence: a vendor compatibility matrix, official docs, release notes or a spec sheet, not a blog summary of one.

Two habits:
- Check whether the constraint matters at all before building on it. A "doesn't run in environment X" objection is irrelevant if the component never needed to run there (for example, a server reached over HTTP).
- When a correction lands, fix the error **where a reader hits it**. Edit the original paragraph and link forward. Don't rely on a rebuttal section further down; a reader going top to bottom gets the error first and the correction only if they keep reading.

## A benchmark number comes with its harness

A throughput figure is a property of a runtime, a build and a set of flags, not just the hardware. Switching inference runtimes or turning on features like speculative decoding can change results severalfold, more than the gap to the next hardware tier. Flags also interact and fail silently: one setting can multiply throughput only when a competing flag is off, and mismatched settings can quietly collapse performance with no error.

Rule: before reasoning from a throughput number, record which build, runtime and flags produced it. Prefer two numbers from the same harness over two numbers from the same vendor. When comparing options, a comparison from the same harness beats a newer mismatched one.

## A supplied parts list or spec sheet describes the past: reconcile it before costing work

Hardware gets upgraded after spec sheets are written. A different CPU or RAM amount can change a power budget or capacity plan the recommendation depends on.

Rule:
- Treat each line of a supplied inventory as a claim and check it against something measurable (`/proc/cpuinfo`, `free`, `nvidia-smi`, `lsblk`, `Get-CimInstance`).
- State which lines you confirmed, which you corrected, and which can't be checked in software (chassis and power supply usually can't). Don't let the unverifiable lines borrow credibility from the verified ones.
- On a power supply, the first hard limit is often the **connector count** rather than the wattage. No power limit or splitter fixes a missing connector, so read the connector table, not just the rating.

## A degraded search backend produces confident, cited fabrication

A retrieval pipeline whose search backend has quietly degraded (some engines suspended or CAPTCHA'd, leaving only a weak keyword matcher) will hand the synthesis model irrelevant results, such as category pages and dictionary definitions. The model then builds a fluent, internally consistent, cited answer from them, for example a price several times the real one, cited to an unrelated page. Grounding catches obvious mismatches but can't tell evidence that answers the question from evidence that merely looks like an answer. Citations prove where text came from, never that it is correct.

How to apply:
- A retrieval pipeline needs a HARD refusal signal for "my retrieval was degraded", separate from any informational degradation field. Every caller must refuse, or fall back to a different engine, when the signal fires, rather than ship a plausible-looking answer.
- Threshold: one dead search engine is routine flakiness. Two or more means the surviving results are just whatever happened to survive, not a real sample of the web.
- Check for two bugs that can hide degradation:
  - A dedup step that returns a NEW array can drop a degradation flag attached to the original array.
  - A client timeout tuned on a fast or small model can kill a slower model's synthesis mid-answer. The empty result then gets scored as "bad" rather than "failed".

## Document checklists that list COMBINATIONS: check each element

Official ID and eligibility lists often list document combinations ("foreign passport WITH valid visa + arrival record"). Visa-exempt nationals have no visa, so they satisfy no listed row literally, even if a regulatory catch-all covers them in practice at the clerk's discretion.

How to apply:
- When screening an eligibility or document checklist, expand every "A + B + C" row and confirm the person can produce EACH element.
- Flag any element that is structurally impossible for their category (visa-exempt, age-exempt, treaty national). Don't assume a catch-all will absorb it.
- Compare the strict list against any fallback or non-compliant product's list. The fallback is often much easier to obtain.

## Security scan summaries can silently drop a severity bucket

An automated audit sweep can report a repo as "1 critical, 0 high" when a direct `npm audit --json` run shows the critical finding AND a dozen high findings. Scanners that bucket by severity are most likely to lose a bucket exactly where critical and high findings occur in the same repo. A mismatch between the summary's header count and the number of entries listed is a visible fingerprint of the gap.

How to apply:
- When a scan's header count and listed-entry count disagree, check the repo whose findings are missing before trusting either number.
- When verifying severity bucketing, always re-run the real tool on every repo that has a critical finding, not just a sample.

## Negative claims about fast-moving products need a search from the same week

Before flagging a "this exists / this happened" claim in a deliverable as wrong, run a web search limited to the last 7 days, and state the date of any research file you use as evidence. A current-state inventory that is a few days old can miss an announcement made since, and a confident "correction" would replace a true sentence with a false one.

## Re-verify a second reviewer's liveness claims in both directions

When you merge an external review (another model's audit, a colleague's notes) into your own records, don't copy its liveness or outcome claims verbatim. A claim that a job posting is "filled" or "removed" may come from a stale or regional cache while the same posting is live and accepting applications. Apply the rule both ways: a live posting doesn't prove active candidacy, and a removed posting doesn't prove rejection. Re-verify any "filled / removed / no application found" claim before recording a negative. Outcomes delivered verbally (on a call) leave no email record, so a record with no email evidence may be genuinely unresolved rather than closed. Mark it as unresolved with a follow-up owed, not as dead.

## Government travel advisories differ in geographic scope: cite several together

Different governments' advisories for the same city can draw restricted zones very differently. One may restrict only named districts, another the whole city, another an entire region except airside transit. Each is an independent primary source, so none is "wrong". Citing only the most permissive one quietly drops the restricted areas in the others.

How to apply: when a trip includes a city under any regional advisory, quote at least the US, UK and Canadian advisories with their dates. Map the recommended hotel and airport area against each one, prefer itineraries with fewer nights in a flagged area, and note that some travel insurance excludes areas under "avoid" or "reconsider" advice.

## Mail search summaries can undercount a thread; check every address before claiming a reply is owed

A mail search tool's thread summary can report fewer messages than the thread contains, hiding a reply. A reply may also have gone to a contact's personal address, so a search limited to their company domain misses it.

How to apply: before claiming a thank-you, reply or nudge is owed, or that a process went silent:
- Open every candidate thread in full and judge from its newest message, not the search summary.
- Search sent mail by every known address for the contact, including personal ones, plus a full-name search.
- Exclude your own generated mail from company-name searches.
