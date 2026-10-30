<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

The typical failure looks like this. Across several turns of a recommendation thread, an agent states eligibility and benefit rules confidently from model memory. One rule is outdated and another is simply backwards. Both matter to the user's decision, and neither gets corrected until the user pushes back. A third error comes from trusting a stale local notes file over what the user said about their own account.

The problem is NOT that the model didn't know. The problem is that it answered anyway, and that it was left to decide for itself whether a domain felt "fast-moving" enough to check.

## The rule

**If a factual claim is (1) external to your own systems and (2) something the user can act on, verify it with a current search before you assert it. Do not judge for yourself how volatile the domain is.**

Covered claim classes (not a complete list):
- Credit card, bank and issuer rules: bonus eligibility, product-family language, credit stacking, application rules, offer amounts and deadlines
- Prices, fees, promotions, and whether a product or service is available
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal, policy and immigration facts, program rules, published schedules
- A price, availability window or status figure read from a browser, page reader or API call: quote the exact string or number you saw, inline, next to the claim. If you cannot quote it, you have not verified it.

Not covered (check against internal sources instead): anything about the user's own accounts, infrastructure, repos or history. For those, the real source (database, email, git, the user's own statement) is the check, not model memory and not a curated summary file.

## Procedure

Before posting a research-type answer (recommendations, comparisons, eligibility questions, "how much" or "what happens if" questions), put the draft through a fact-check pass. A skill is ideal if you have one. The pass:

1. Pulls out each discrete external, actionable claim in the draft
2. Runs a web search per claim that includes the current year (in parallel)
3. Gives each claim a verdict: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED
4. Requires you to revise anything not CONFIRMED, and to label UNVERIFIED claims as unverified in the final answer

For a single claim mid-conversation, a direct web search with the current month and year in the query is an acceptable lighter version. The search must still happen before you post the claim.

## Precedence of sources

1. **The user's own statement about their own accounts or actions** beats everything for facts about whether something exists. If internal data disagrees, the data is stale: say so, check the real source, and fix the data.
2. **Current primary and web sources** (issuer terms pages, official docs, established deal and rules trackers) are required for external rules and offers.
3. **Internal curated files** (notes, your knowledge base) are authoritative only for what they own (benefit details, member numbers). They never decide external rules and never override the user.
4. **Model memory** is never enough for a covered claim. It produces the hypothesis; the search confirms it.

## Contradicting your own prior research

If an earlier turn in the same conversation established a researched fact and you are about to assert the opposite, treat that as a red flag, not a correction. Search again and reconcile out loud ("earlier I found X; the search now shows Y because Z"). Never flip silently.

## Deliverable URL liveness

Any URL you put in a deliverable that leaves your own environment (resume, portfolio, cover letter, social post, anything sent or published) is a fact someone outside can check. Before writing it, curl the exact URL and confirm it serves the intended public page: HTTP 200 plus a real page, not a redirect to login and not a bare API. Only write it once the check passes. Do not ship a hedge like "confirm live status" for something you could verify in seconds.

None of these prove a URL is live:
- a repo exists on disk (that says nothing about a public URL);
- a process manager shows the service as `online` (a service with only `/api/*` routes has no page to browse);
- a memory or index line says "LIVE" (memories are snapshots and often mean "deployed", not "a public page exists"; read the full memory, then curl anyway).

Lesson: a path once went onto a resume as a public product when it was an internal API that 404s at the root and needs an auth header. The only evidence behind it was an index line and a directory listing.

### Private GitHub repo URLs 404 anonymously: an auth artifact, not proof of breakage

An unauthenticated request (curl, a fetch tool, a public link checker) to a `github.com/<org>/<private-repo>/blob/...` URL returns **404, not 403**. GitHub does not confirm a private repo exists to someone who can't see it, so the response looks exactly like a broken or renamed path. To check a link into a private repo, use `gh api repos/<org>/<repo>/contents/<path>` instead of anonymous curl. A 200 with a `size` field means it's live; a 404 from `gh api` (unlike from curl) is a real miss. This is the mirror image of the login wall: that one is a false positive (a 200 that is dead behind auth), this one is a false negative (a 404 that is alive behind auth).

## "Known / reputable brand" is a factual claim: verify provenance

Calling a brand "known", "established", "reputable" or "trusted" is a checkable claim, not decoration. Do not base it on marketplace star counts or review volume. Those are the exact fake-review signals a skeptic gate is meant to catch, and using them here turns them into borrowed credibility. Before using any such label, run one search (`who makes <brand>` / `<brand> company history`) and classify the brand:
- **Established:** an independent company with a history you can verify and distribution beyond one marketplace.
- **Marketplace-native label:** an invented seller brand (often an all-caps or nonsense word) sold mostly on one or two big marketplaces with no independent history. Never call these "known brands". They can still be fine budget picks, but justify that with specific evidence, not borrowed reputation.

Don't contradict your own skeptic gate. A guide that warns about "no-name" products as a trap and then lists same-tier marketplace labels as "known brands" is exactly the failure this rule is meant to prevent.

## Source-specific traps

### Aggregate tracker tables go stale; issuer pages block fetchers; some forums are blocked to search

When researching which merchants trigger a card's category statement credit:
1. Community-maintained aggregate tables are the best overall source, but individual data points can be many years old. Always extract the date column (a text-only page reader plus grep works better than a summarizing fetch tool, which tends to drop dates), cite how old the data is, and treat "works" / "does not work" as unproven.
2. Issuer benefit terms pages often return HTTP 403 to automated fetchers. If so, get issuer terms from two independent secondary sources, and say that you did, rather than implying you read the issuer directly.
3. Some forum domains are blocked to web search tools. Get crowd-sourced data points from an aggregator or a page reader instead.

In practice: recommend a test charge before the user commits to a merchant whose coding rests on one old data point, and list the evidence gaps in the deliverable.

### Eligibility on a marketing or FAQ page is not evidence: read the sentence on the application form

An institution's public page may say you are eligible while the live application form says the opposite, word for word. A research pass that only reads marketing pages will report "eligible", and the agent will then submit a false claim. The same goes for claims like "this signup has no CAPTCHA": the live page may have one inside shadow DOM.

Rule: for any signup, eligibility or enrollment task, the authoritative quote is what the form you are about to submit says, read in the browser after the page loads. Treat FAQ pages, marketing pages, guides and search snippets as leads, never as findings. If they conflict, the form wins and you stop.

Corollary: this is also the cheapest place to catch a subagent's overconfident research, so map the form BEFORE filling it, not after a failed submit.

### A per-day cheapest-fare table prices specific departures; re-verify once you name a flight

A "cheapest fare per day" figure answers "what does this DAY cost", which is the right question while choosing a day. Once the recommendation names a specific flight or departure time, that number no longer applies: carriers often run several price bands on one route on one day, tied to departure time. The mistake is quiet because the number came from your own verified research, so it carries authority it hasn't earned.

How to apply: once you name a specific flight number or departure time, check that flight's own fare before quoting a price. Keep day-level tables for day-level decisions. The same applies to hotels (a cheapest-per-night figure is not the rate for the room you want) and to any per-bucket minimum.

Also: fares can move 30%+ within a day. If your fare research is more than a day old and the user is about to book, pull it again rather than quoting it. A stale fare quoted confidently is worse than no fare.

### A cited aggregator page may not carry the claim it was cited for

A plausible source URL next to a claim looks verified. But the cited page may hold only static data while the live status sits on a different page, or the official source may 404 on every documented path, which leaves the fact resting on one aggregator.

How to apply: when you review or reuse someone else's cited claim, fetch that exact URL again and confirm the fact appears on that page. If it doesn't, find the page that does carry it, or say the claim has a single source. Claims about operating hours or enforcement windows that decide whether the user acts deserve the same check: a window that is wrong by a few hours can turn a "free" recommendation into a fine and hide a hard prerequisite.

### Finding the number in the source is not checking the claim: verify the pairing

An answer can cite several retailer prices to one URL where every number really does appear on that page (for example, historical highs on a single retailer's price-history page), so a check that only asks "is this figure in a cited source?" passes. What's false is the pairing: prices attached to retailers the source never mentions.

How to apply: you are verifying the claim, not the number. For each cited sentence, check (1) every money amount appears in a cited source, AND (2) every entity the sentence attributes something TO (retailer, vendor, venue, person) is actually mentioned by that same source. A pass that stops at (1) lets through plausible multi-entity sentences built by attaching real numbers to the wrong names.

### A cited issue number is not a verified issue: check state, closed_at, and the LAST comment

Bug-tracker URLs carry more authority than blog posts, so issue numbers get repeated without scrutiny. Search summaries reliably quote the alarming top of a report (title, symptoms, repro steps) and drop the mundane end (it was the hardware / works as intended / duplicate / fixed in a later version). An issue cited as proof of "data corruption on this setup" can turn out to be closed, labeled unconfirmed, with the reporter's last comment blaming a faulty cable.

Before you repeat a tracker item as a reason to rule something out, fetch it and read these fields (none of them is the body):

    curl -s https://api.github.com/repos/OWNER/REPO/issues/N | jq '{state,closed_at,labels:[.labels[].name],comments}'
    curl -s https://api.github.com/repos/OWNER/REPO/issues/N/comments | jq -r '.[-1].body'

`state` and `closed_at` tell you if it is live. The LAST comment tells you why it closed, which the body never can. Labels separate confirmed from unconfirmed. Apply the same discipline to a linked PR: open, merged and closed-unmerged are three different facts (closed-unmerged PRs are often quoted as if the feature shipped).

Corollaries:
- Read the whole thread, not just the resolution. Other users may report a real, unresolved problem that got buried when the issue closed on the original reporter's cause.
- When the dramatic objection falls apart, rebuild the recommendation on the dull objections (power, thermals, cost) instead of quietly keeping the conclusion.

### Ruling out an option needs a primary source; ranking it can rest on a secondary one

Ranking an option wrongly costs some accuracy in a comparison the reader can still see. Ruling an option out removes it from the reader's choices entirely, and they never learn what they didn't get to weigh. So ruling out is the stronger claim and needs stronger evidence: a vendor compatibility matrix, official docs, release notes or a spec sheet, not a blog's summary of one.

Habits that catch this:
- Check whether the constraint actually matters before building on it. If the component is reached over the network, it may never need to run in the constrained environment at all.
- When a correction comes in, retract the claim WHERE A READER MEETS IT. A rebuttal far below the false claim means someone reading top to bottom gets the error first. Edit the original paragraph and link forward.

### A benchmark number carries its harness

Throughput figures depend on the runtime, the build and the flags, and those can matter more than the next hardware tier (a 3x swing from runtime and decoding choices alone is realistic). Flags also interact and fail silently: one flag can give a big speedup only when another is off, and mismatched settings can collapse performance with no error. Rule: before reasoning from a throughput number, note which build, runtime and flags produced it. Two numbers from the same harness beat two numbers from the same vendor, and a same-harness comparison beats a newer mismatched one.

### A supplied parts list or spec sheet describes the past; reconcile it against the live system

A build sheet can be out of date because parts were upgraded later, and the difference can break a constraint (such as a power budget) that the recommendation depends on. Rule: treat every line of a supplied inventory as a claim, check it against something you can measure (`/proc/cpuinfo`, `free`, `nvidia-smi`, `lsblk`, `Get-CimInstance`), and state which lines you confirmed, which you corrected, and which software can't verify (chassis and power supply usually). Don't let the unverifiable lines borrow credibility from the verified ones. On a power supply, the first hard blocker is often the CONNECTOR COUNT rather than the wattage, and no power limit or splitter fixes a missing connector, so read the connector table, not just the rating.

### A degraded search backend produces confident, cited fabrication

A RAG pipeline whose metasearch backend has lost most of its engines (suspended, CAPTCHA'd) can return irrelevant results such as category pages, dictionary definitions or unrelated encyclopedia articles. The synthesis model then builds a fluent, cited answer from them, for example a price roughly three times the real one. Grounding can refuse evidence that is obviously unrelated, but it can't tell evidence that answers the question from evidence that only looks like an answer. Citations prove where something came from, not that it is correct.

How to apply: a retrieval pipeline needs a HARD refusal signal for "my retrieval was degraded", separate from any informational degradation field, and every caller must refuse on it (or fall back to another engine) rather than ship a plausible answer. Threshold: one dead search engine is routine flakiness. Two or more means the remaining results are just whatever survived, not a real sample of the web. Two supporting bugs to look for in similar pipelines: a dedup step that returns a NEW array can drop a degradation flag attached to the original array, and a client timeout tuned for a fast, small model can kill a slower model mid-answer, which shows up as an empty result that downstream scoring calls "bad" instead of "failed".

### A checklist that assumes a document can silently exclude a whole category of applicant

Official document lists often list COMBINATIONS (for example "foreign passport WITH valid visa + arrival record"). An applicant from a visa-exempt country has no visa foil, so they satisfy no listed row literally, even if a general catch-all clause covers them in practice. That catch-all is at the clerk's discretion, not a published path.

How to apply: when screening an eligibility or document checklist, break every "A + B + C" row apart and confirm the person can produce EACH element. Flag any element that is impossible for their category (visa-exempt, age-exempt, treaty national) rather than assuming a catch-all will cover it. Also compare the strict list against any fallback or non-compliant product; the fallback may be much easier to get.

### Security scan summaries can drop a severity bucket

An audit-based scanner can report a repo as "1 critical, 0 high" when a direct `npm audit --json` shows many high findings too. The bug shows up in repos that have BOTH critical and high findings. The giveaway is that the summary's header count and its listed entries disagree. When they do, check the repo whose findings are missing before trusting either number. When checking a scan's severity buckets, re-run the real tool on every repo with a critical finding, not just a sample.

### A negative claim about a fast-moving product needs a same-week search

Before marking a "this exists / this happened" claim in a deliverable as wrong, run a web search limited to the last 7 days, and give the date of any research file you use as evidence. A current-state inventory a few days old can miss an announcement made in between, and "correcting" a true sentence into a false one is worse than leaving it alone.

### A second reviewer's "posting filled / removed" claim needs a live check

When you merge an external review into your own records, don't copy its claims about whether a job posting is live or what happened verbatim. A "filled" claim may come from a stale or regional cache while the same posting has been re-listed with an active apply button. Check against the live careers page in BOTH directions: a live posting doesn't prove the candidacy is active, and a removed posting doesn't prove rejection. Outcomes given verbally on a call leave no email trail, so mark them "verbal/unresolved, follow-up owed", not dead.

### Government travel advisories differ in geographic scope: cite several together

Independent government advisories (for example US, UK and Canada) often draw their restricted zones differently for the same city. One may restrict only named districts while another covers the whole city or region. Quoting only the most permissive one quietly drops the others' restricted areas.

How to apply: when a trip includes a city under any regional advisory, quote all three advisories with their dates, map the recommended hotel or airport area against each, prefer itineraries with the fewest nights in a flagged area, and mention that some travel insurance excludes areas under "avoid" or "reconsider" advice.

### Email search summaries can undercount a thread; one address is not the whole contact

Thread search tools may report a message count that misses replies inside an older thread, and a sent-mail search by company domain misses mail sent to a contact's personal address. Either can make you claim a follow-up is owed when it was already sent.

How to apply: before claiming a thank-you, reply or nudge is owed, or that a process went silent, open every candidate thread in full and judge by its newest message (not the search summary). Search sent mail by every known address for the contact, including personal ones, and by full name. Exclude your own generated mail from company-name searches.
