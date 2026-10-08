<!-- Load when: mandatory search-verification of external actionable claims (prices, eligibility rules, offers) before asserting -->
# Fact-Checking External Claims

## Why this exists

The usual failure is not that the model didn't know. The model answered anyway, from memory, with confidence. Whether to check was left to its own sense of whether a domain "felt fast-moving". Typical results:
- an issuer's bonus-eligibility rule stated from memory after the issuer had changed it;
- a rule about how credits apply that was invented and got the logic backwards;
- a stale local notes file trusted over the user's own statement about their own account.

Each error mattered to a real decision. Each was corrected only after the user pushed back.

## The rule

**If a factual claim is (1) external to your own systems and (2) something the user can act on, verify it with a current search before you assert it. Do not judge for yourself how volatile the topic is.**

Covered claim classes (not a complete list):
- Credit card, bank and issuer rules: bonus eligibility, product-family restrictions, credit stacking, application velocity rules, offer amounts and deadlines
- Prices, fees, promotions, and whether products or services are available
- API/SaaS pricing, rate limits, model names, deprecations
- Software versions, EOL dates, breaking changes
- Legal, policy and immigration facts, program rules, published schedules

Not covered: anything about the user's own accounts, infrastructure, repos or history. Verify those against the actual source instead (database, email, git, or the user's own statement).

## Procedure

Before posting a research-type answer (recommendations, comparisons, "am I eligible / how much / what happens if" questions), run a fact-check pass over the draft:

1. Pull out each separate external, actionable claim in the draft.
2. Run a web search per claim with the current year in the query (in parallel if you can).
3. Give each claim a verdict: CONFIRMED / OUTDATED / CONTRADICTED / UNVERIFIED.
4. Revise the answer for anything not CONFIRMED. Label UNVERIFIED claims as unverified in the final answer.

If you package this as a reusable skill or subagent, keep these four steps and these four verdicts.

For a single claim mid-conversation, one direct web search with the current month and year in the query is an acceptable lighter version. The search still has to happen before you post the claim.

## Precedence of sources

1. **The user's own statement about their own accounts or actions.** For facts about whether something exists, this beats everything. If internal data disagrees, the data is stale: say so, check the real source, and fix the data.
2. **Current primary and web sources** (issuer terms pages, official docs, reputable dedicated trackers). These are required for external rules and offers.
3. **Internal curated files** (notes, your knowledge base). Trust them only for what they own (benefit details, member numbers). Never trust them for external rules, and never over the user.
4. **Model memory.** Never enough for a covered claim. It produces the hypothesis; the search confirms it.

## Contradicting your own prior research

Suppose an earlier turn in the same conversation established a researched fact and you are about to assert the opposite. Treat that as a red flag, not a correction. Re-verify with a search and reconcile out loud ("earlier I found X; the search now shows Y because Z"). Never flip silently.

## Deliverable URL liveness

Treat any URL you put in a deliverable that leaves your environment (resume, portfolio, cover letter, social post, anything sent or published) as a fact someone outside can check. Before writing it, curl the exact URL and confirm it serves the intended public page: HTTP 200 and a real page, not a redirect to a login and not a bare API. Make the write depend on that check. Don't ship a hedge like "confirm live status" about something you could check in seconds.

None of these prove a URL is live:
- a repo exists on disk (`ls $HOME/<repo>` tells you nothing about a public URL);
- a process manager shows the service `online` (a running service with only `/api/*` routes serves no page a browser can open);
- a memory, note or index line says "LIVE" (notes are point-in-time and often mean "deployed", not "a public page exists"). Read the full note, then curl anyway.

Lesson: an internal API that served only authenticated `/api/*` routes was once listed in a resume as a public product, because an index note said "LIVE" and the repo existed. The path itself returned 404.

### Private GitHub repo URLs return 404 to anonymous requests; that is an auth artifact, not proof of breakage

An unauthenticated request (curl, a web fetch, a public link checker) to `github.com/<org>/<private-repo>/blob/...` returns **404, not 403**. GitHub does not reveal that a private repo exists to a caller who can't see it, so the response looks exactly like a broken or renamed path. To verify a link into a private repo, use `gh api repos/<org>/<repo>/contents/<path>` instead of anonymous curl. A 200 with a `size` field confirms the link works. A 404 from `gh api` (unlike one from curl) is a real miss. This is the mirror image of the login-wall case above: that one gives a false positive (a 200 for a page that is really dead behind auth); this one gives a false negative (a 404 for a page that is really alive behind auth).

## Calling a brand "known" or "reputable" is a factual claim: check where it comes from

"Known", "established", "reputable" and "trusted" are claims someone can check, not decoration. Don't base them on marketplace star counts or review volume. That is the exact fake-review signal a skeptic gate exists to catch, recycled into credibility. Before using any such label, run one search (`who makes <brand>` / `<brand> company history`) and classify the brand:
- **Established:** an independent company with a history you can verify and sales channels beyond a single marketplace.
- **Marketplace-native label:** an invented seller brand (often an all-caps or nonsense word) sold mainly on one or two big marketplaces, with no independent history. Never call these "known brands". They can still be fine budget picks, but justify that with specific evidence, not borrowed reputation.

Don't contradict your own skeptic gate. Warning readers off "no-name" products while presenting marketplace-native brands of the same tier as "known brands" in the same guide is the failure this rule exists to prevent.

## Domain-specific research traps

### Aggregator tables may be years stale; issuer pages and forums may be blocked

When you research which merchants trigger a card's category credit, or similar crowd-sourced data:
1. The best aggregate tables often hold data points that are years old. Extract the date column (a text-mode page reader plus grep keeps dates that summarising fetchers drop), cite the age, and treat "works / does not work" as unproven.
2. Issuer terms pages often return 403 to automated fetchers. Get the terms from two independent secondary sources, and say so instead of implying you read the issuer's page directly.
3. Some forum domains are blocked to search tools. Use aggregators or a page reader for crowd data instead.

What to do with the gaps: if a recommendation rests only on an old data point, suggest a test transaction first, and list the evidence gaps in the deliverable.

### Eligibility on a marketing or FAQ page is not evidence: read the sentence on the application form

A public page can say a group is eligible while the live application form says the opposite. A research pass that reads only marketing pages will report "eligible", and the agent will then submit a false claim. Research passes also misreport form mechanics (for example, calling a form CAPTCHA-free when the live page has a reCAPTCHA field inside a shadow DOM).

Rule: for any signup, eligibility or enrollment task, the authoritative quote is the one shown on the form you are about to submit, read in the browser after the page loads. Treat FAQ pages, marketing copy, guides and search-snippet quotes as leads, never as the finding. If they conflict, the form wins and you stop. This is also the cheapest place to catch a subagent's overconfident research, so map the form BEFORE you fill it, not after a failed submit.

### A per-day cheapest-fare table prices specific departures; re-verify once the recommendation names a flight

A "cheapest fare per day" table answers "what does this DAY cost". That's right for picking a day. Once the recommendation narrows to a specific flight, the number stops applying: carriers often run several price bands on one route on one day, keyed to departure time. The error is silent because the number came from your own verified research and so carries authority it hasn't earned.

How to apply:
- Once a recommendation names a flight number or departure time, re-verify that flight's own fare before quoting a price. The same goes for hotels (the cheapest nightly rate is not the rate for the room you want) and for any per-bucket minimum.
- Fares can move 30% or more in a day. If the fare research is more than a day old and the user is about to book, pull it again. A stale fare quoted confidently is worse than no fare.

### A cited page may not carry the claim it was cited for

A plausible source URL next to a claim reads as verified. An aggregator page might hold only static data and an Open/Closed flag, while the live status sits on a different page, or the primary source's URL 404s.

How to apply: when you review or reuse someone else's cited claim, re-fetch that exact URL and confirm the fact appears on that page. If it doesn't, find the page that does carry it, or say the claim has only one source. Give the same treatment to operating hours and enforcement windows that decide whether an action is allowed. A window that is off by a few hours can turn a "free" recommendation into a fine.

### Checking that a number appears is not checking the claim: verify the pairing

A sentence can cite several prices to one source where every number really does appear on that page (for example, a price-history page for one retailer). The claim is still false if it attaches those numbers to retailers the source never mentions. A check that only asks "does this figure appear in a cited source" passes it cleanly.

How to apply: the unit of verification is the claim, not the number. For each cited sentence, check (1) every money amount appears in a cited source, AND (2) every entity the sentence attributes something TO (retailer, vendor, venue, person) is actually mentioned in that same source. A pass that stops at (1) will let through sentences built by stapling real numbers onto the wrong names.

### A cited issue number is not a verified issue: check state, closed_at, and the LAST comment

A bug tracker URL carries more authority than a blog post, so issue numbers get repeated with less skepticism. Search summaries consistently reproduce the alarming top of a report (title, symptoms, repro steps) and drop the mundane end ("it was the cable", "works as intended", "duplicate", "fixed in v2"). An issue cited as proof of a software bug can turn out to be closed, labelled unconfirmed, with the reporter's last comment blaming faulty hardware.

Before you repeat any tracker item as a constraint on a decision, fetch it and read these fields, none of which is the body:

    curl -s https://api.github.com/repos/OWNER/REPO/issues/N | jq '{state,closed_at,labels:[.labels[].name],comments}'
    curl -s https://api.github.com/repos/OWNER/REPO/issues/N/comments | jq -r '.[-1].body'

`state` and `closed_at` tell you whether the issue is live. The LAST comment tells you why it closed, which the body never can. Labels separate confirmed bugs from unconfirmed ones. Apply the same discipline to a linked PR: open, merged, and closed-unmerged are three different facts (a closed-unmerged PR is often quoted as if the feature shipped).

Corollaries:
- Read the whole thread, not just the resolution. Other users may report a real, still-unresolved problem underneath a thread that was closed on the original reporter's cause.
- When the dramatic objection collapses, rebuild the recommendation on the boring objections (power, thermals, cost) instead of quietly keeping the conclusion.

### Eliminating an option needs a primary source; a secondary one can support a ranking

If you rank an option wrongly, the reader loses some accuracy in a comparison they can still see. If you eliminate an option, it disappears from the reader's choices, and they never learn what they didn't get to weigh. Elimination is the stronger claim and needs stronger evidence: a vendor compatibility matrix, official docs, release notes, a spec sheet. A blog summary of those is not enough.

Habits that catch this:
- Check whether the constraint actually matters before building on it. An objection like "it doesn't run in environment X" may be about one deployment choice, not about what the option can do (for example, if the service is reached over HTTP it never needed to run in X).
- When a correction lands, retract the claim WHERE A READER MEETS IT. Edit the original paragraph and link forward. A rebuttal section far below the false claim means someone reading in order gets the error first.

### A benchmark number carries its harness: check which runtime and flags produced it

A throughput figure is not a hardware ceiling. On the same hardware, the inference runtime and its flags (for example, speculative decoding) can change throughput by around 3x, which can be more than the next hardware tier up. Flags also interact and fail silently: a batch-size flag may help only when a competing flag is off, and mismatched cache-quantisation settings can make throughput collapse with no error.

Rule: before you reason from a throughput number, record which build, runtime and flags produced it. When comparing options, two numbers from the same harness are worth more than a newer number from a mismatched one.

### A supplied parts list or spec sheet describes the past: reconcile every line against the live system

Hardware gets upgraded after inventories are written, and the differences can change budgets your recommendation depends on (power, memory). Treat each line of a supplied inventory as a claim. Check it against something you can measure (`/proc/cpuinfo`, `free`, `nvidia-smi`, `lsblk`, `Get-CimInstance`), and state which lines were confirmed, which were corrected, and which software can't verify (chassis and power supply usually can't be). Don't let the unverifiable lines borrow credibility from the verified ones.

For power supplies, the first hard blocker is often the CONNECTOR COUNT, not the wattage. No power limit or splitter fixes a missing connector, so read the connector table, not just the rating.

### A degraded search backend produces confident, cited fabrication

If most of a retrieval pipeline's search engines are suspended or hit by CAPTCHAs, the survivors may return junk: category pages, dictionary definitions of words in the query. A synthesis model will build a fluent, internally consistent, cited answer out of whatever it receives, for example a price several times the real one, cited to an unrelated page. Grounding can catch evidence that is obviously unrelated. It can't tell evidence that answers the question from evidence that only looks like an answer. Citations prove where text came from, never that it is correct.

How to apply:
- A retrieval pipeline needs a HARD "retrieval was degraded" signal, separate from any informational degradation field. Every caller must refuse on that signal (or fall back to a different engine) instead of shipping a plausible answer.
- Threshold: one dead search engine is routine flakiness. Two or more means the remaining results are just whatever happened to survive, not a fair sample of the web.
- Check for two bugs that hide this kind of degradation: a dedup step that returns a NEW array and drops a flag attached to the original array; and a client timeout tuned on a fast, small model that kills a slower model mid-answer, so the empty result gets scored as "bad" instead of "failed".

### Checklists of document combinations: check every element against the person's status

Eligibility and ID checklists often list combinations ("passport + visa + entry record"). Someone whose nationality is visa-exempt can't produce the middle element, so they satisfy no listed row literally, even if a general catch-all clause covers them in practice. A catch-all like that is at the clerk's discretion, not a published path.

How to apply: when screening an eligibility or document checklist, expand every "A + B + C" row and confirm the person can produce EACH element. Flag any element that is structurally impossible for their category (visa-exempt, age-exempt, treaty national) instead of assuming a catch-all will absorb it. Also compare the strict list with the fallback or non-compliant list, which may be much easier to satisfy.

### Severity-bucketing scanners can drop a bucket when a repo has findings at several severities

A dependency-audit sweep can report a repo as "1 critical, 0 high" when a direct `npm audit --json` shows 1 critical AND many high findings. Repos with only one severity level match exactly, so the gap shows up only where severities co-occur. A tell you can spot without rerunning anything: the summary header's count doesn't match the number of entries listed.

How to apply: if a scan's header count and listed-entry count disagree, check the repo whose findings are missing before trusting either number. When validating a scanner's bucketing, rerun the real tool on every repo with a critical finding, not just on a sample.

### A negative claim about a fast-moving product needs a search from the same week

Before flagging any "this exists / this happened" claim in a deliverable as wrong ("X doesn't ship", "that merger isn't real"), run a web search limited to the last 7 days, and state the date of any research file you use as evidence. A current-state inventory a few days old can miss an announcement, and a confident "correction" would then replace a correct sentence with a wrong one.

### A reviewer's "posting is filled or removed" claim must be checked against the live page before you record it

When you merge an outside review into a tracking sheet, don't copy its liveness or outcome claims verbatim. A posting called "filled" may be a stale or regional cache while the same listing has been re-posted with an active apply button. Apply the rule in both directions: a live posting doesn't prove the candidacy is active, and a removed posting doesn't prove rejection. Re-verify a peer's "filled / removed / no application found" before recording a negative. Outcomes delivered verbally (on a call) leave no written verdict, so a row with no matching email may be genuinely unresolved rather than rejected. Mark it "verbal/unresolved, follow-up owed", not dead.
