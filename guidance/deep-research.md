<!-- Load when: research depth and methodology before producing guides or recommendations -->
# Deep Research Before Recommendations

When the user asks you to research a topic and produce a guide, recommendation, analysis, or buying decision, research thoroughly before you start writing. Surface-level research produces surface-level guides, and then the user has to do the real research themselves. That defeats the purpose.

## When This Applies

Any task where you produce a deliverable based on external research:
- Setup guides, how-to guides, tutorials
- Product or service comparisons and recommendations
- Buying guides and price optimization
- Technology evaluations and architecture decisions
- Troubleshooting guides for unfamiliar tools
- Any "research X and tell me what to do" request

Does NOT apply to: tasks where you already have deep knowledge, pure code implementation, or tasks that use only local or repo context.

## Minimum Research Standard

### 1. Source Diversity (at least 3 of these categories)
- **Official documentation**: the product's own docs, FAQ, setup guide
- **Community forums**: Reddit threads, Stack Overflow, GitHub issues, Discord servers
- **Recent blog posts and tutorials**: published within the last 12 months
- **Video content**: YouTube walkthroughs (check descriptions and comments for gotchas). **Read the transcript, not a third-party recap** (see below).
- **Comparison and review sites**: when evaluating alternatives

A guide built from 2-3 WebSearch results and their top links is not research. That's skimming.

### 1b. YouTube: pull the caption track, don't settle for a recap

Third-party blog recaps of a talk lose detail and often get the emphasis wrong. If a video matters to the answer, read what was actually said. Whisper transcription is the right tool when you need word-level timing (for example, on your own videos). For someone else's talk, captions are much faster; hours of video come down in seconds:

```bash
yt-dlp --skip-download --write-auto-subs --write-subs \
       --sub-langs "en.*" --sub-format vtt -o "%(id)s.%(ext)s" "<url>"
```

Two post-processing steps are mandatory, or the output is unusable:

1. **Dedupe.** Auto-caption VTT uses rolling display, so each cue repeats earlier lines and a naive strip gives you about 3x duplicated text. Strip the `<c>` karaoke tags, unescape HTML, drop any line that matches one of the last ~6 lines you emitted, then reflow into ~45s timestamped paragraphs so the chunks are readable and citable.
2. **Correct proper nouns.** Auto-captions mangle names badly and *will* lead you to misquote: speaker names come out as different, plausible-sounding names, and product names turn into common words ("cloud"/"quad"/"claw" for Claude, "grap" for grep). Captions also drop plurals. Correct names in your prose, but **keep quotes exactly as captured** so they can still be checked with grep, and say so in the deliverable.

**Then count terms.** Term frequency on a transcript is cheap and catches things reading misses. Run `grep -oic` for the 5-10 terms central to your question. Counting two competing terms across several talks by the same speaker can show their real conceptual vocabulary. One term used dozens of times and its rival used zero times can flip a recommendation. A zero count is a finding, not missing data.

**Verify delegated reads.** When subagents read long transcripts, require verbatim quotes with timestamps, then re-grep their key claims in the main thread before you publish. It's cheap insurance and makes every claim defensible.

### 2. Gotcha Hunting
Before recommending any setup or product, search for problems on purpose:
- Search "[product] problems [year]", "[product] not working", "[product] issues reddit"
- Read at least one negative or critical thread to understand how it fails
- Include known limitations and common pitfalls in your deliverable
- If something looks too easy, it probably has a catch you haven't found yet

### 3. Cross-Referencing
- Verify key claims (compatibility, pricing, feature availability) across 2+ independent sources
- If only one source says something, flag it as unverified or single-source
- When sources conflict, note the conflict and find out which one is current
- Check version numbers, URLs, and specific steps against official sources, not just blog posts

### 4. Version and Platform Disambiguation
- Identify which version, OS, hardware, or configuration the advice applies to
- Call out explicitly when different versions or platforms have different paths (e.g., two products sold under the same brand name can have completely different setup stories)
- Check whether the product has had recent major changes that make older guides wrong
- Note the date of your sources; a guide written before a major product update may be wrong

### 5. Completeness Audit
Before writing, list the questions a reader would have:
- What do I need before starting? (prerequisites, accounts, hardware)
- What are the decision points? (which path fits my situation)
- What can go wrong? (common errors, troubleshooting)
- What does "done" look like? (verification steps)
- What are the ongoing costs or maintenance needs?

If you can't answer one of these, you haven't researched enough. Go back and find the answer.

### 6. Recency Verification
- Check that the URLs you recommend are still live
- Verify that addon, plugin, and extension names and installation methods are current
- Look for deprecation notices, service shutdowns, or major migrations
- Prefer sources from the last 6 months; if you use older ones, verify the information still holds

## Research Workflow

1. **Scoping search** (2-3 queries): understand the landscape and identify key concepts and decision points
2. **Deep dive** (3-5 queries + fetches): read official docs, community threads, and recent tutorials in full
3. **Gotcha search** (1-2 queries): look explicitly for problems, limitations, and common mistakes
4. **Verification pass** (1-2 fetches): cross-check critical claims against primary sources
5. **Completeness check**: review against the audit questions above and fill gaps with targeted searches
6. **Write the deliverable**: only now

If you start writing after step 2, you skipped half the process.

## Quality Signals

A well-researched deliverable includes:
- Prerequisites and decision trees ("if you have X, do this; if Y, do that")
- Specific version numbers and dates for time-sensitive information
- Known limitations stated upfront, not buried
- A troubleshooting section with real common errors (not a generic "check your connection")
- Links to primary sources the user can check for updates

## Anti-Patterns

- Writing a guide from the first 3 search results
- Treating search snippets as verified facts without reading the full page
- Skipping community forums (where real users report real problems)
- Presenting one path when different situations call for different valid paths
- Leaving out known limitations to make the recommendation sound cleaner
- Not checking whether a free tool has gone paid, or the other way around
- Recommending a specific version without checking that it's still current
- **Giving up on a source at the first empty or blocked fetch.** Login walls, paywalls, and JS single-page apps can be worked around; they aren't dead ends. Escalate in order: plain fetch, then a headless page reader that renders JS, then feed or transcript tricks (RSS, caption tracks, AMP or print views), then an authenticated browser session, and only then fall back to search results. Auth-gated pages are exactly what the authenticated browser step is for.
- **Spawning research subagents that can only do a plain fetch on auth-gated or SPA sources.** They hit the same wall and quietly "resolve" it by writing a confident summary from search snippets. Give subagents the full escalation path, or retrieve the page in the main thread and pass the text down. Always label anything that came from search results as secondhand.

## Company-Specific Deliverables: No Invented Product Claims

When building materials ABOUT a specific product or company (interview memos, prototype decks, product analyses, competitive write-ups), include only product capabilities that are:

1. **Verified through public sources**: official docs, press releases, tech blog posts, shareholder letters, or news articles. Date-stamp and link the source.
2. **Confirmed in the user's own sketch or brief**: if the user described the feature, use their framing exactly.

Do NOT extrapolate, assume, or invent features that "seem like they should exist" or "fit the product vision."

**Why this matters:** to a hiring panel, client, or stakeholder, a made-up feature reads as an authoritative claim. When someone challenges it, it's harder to recover from than a gap in your knowledge. Invented features, targets, and product combinations in one prep deck can force a full ground-up rebuild.

**Self-check before submitting any company-specific deliverable:** for each product claim, ask "where is the public source for this?" If you can't point to one, mark it as assumed or cut it. Treat the user's own words as the floor for what's in scope.

## Verification Lessons

### Check that a job posting's flagship product is still on the market
A live job posting is marketing copy, and it can be months out of date about the company's own product. A posting can lead with a flagship product while the company site still shows a "Try it" button, even though the product's own domain says it was withdrawn from external users months earlier. That turns an apparent product role into something else entirely (for example, client delivery at a services firm), which is a different fit decision.

How to apply: when researching a company for a role, an investment, or a partnership, fetch the PRODUCT's own domain (and its status, pricing, or login page), not just the company marketing site and the job posting. Compare all three. A withdrawn product, a dead pricing page, or a login wall where a signup used to be changes what the job actually is.

Corollary: aggregator copies of postings drift from the original applicant tracking system (ATS) page, and salary figures can differ by tens of thousands. Treat the ATS page (Ashby, Greenhouse, Lever) as the source of truth and note the conflict rather than averaging it. The same goes for scraped company stats: a data aggregator can report headcount and revenue an order of magnitude off from the company's own profile.

### Price tiers can be non-monotonic: a shorter booking can cost more
Rental and subscription pricing is tiered, not linear, and a tier boundary can make a SHORTER booking cost MORE than a longer one. Never assume price rises steadily with duration, and never quote just the duration the user happened to mention without checking both sides of the tier boundary.

Observed on a live rental booking engine: a 27-day booking priced on the weekly tier cost about $129 more than a 28-day booking on the monthly tier, and days 29-30 added less than $1 total. The vendor's own long-term page put the monthly threshold at a different day count than the engine actually used. Vendor documentation about its own pricing tiers is a hypothesis, not a fact.

Rule: when researching any price tiered by duration (car rental, subscription, storage, cloud commitment), check both sides of the boundary by quoting N-1, N, and N+2 rather than only the requested N. Report the cliff explicitly, because "book one day longer and save money" is often the single most useful finding in the whole research pass.

### A successful WebFetch is not a faithful read: open the document when the answer is a specific limit
WebFetch retrieves a page or PDF, then answers your prompt about it using a small fast model. That summary step can fail SILENTLY and CONFIDENTLY on a document it retrieved correctly. A successful retrieval tells you nothing about whether the answer is right.

Observed: a summary of a vendor's own coverage terms PDF reported the wrong coverage cap (off by more than a week) and claimed the document had no region-specific pricing, when it printed two explicit regional price tiers. Both were the headline findings of the research.

WHAT CAUGHT IT: the same vendor's FAQ, fetched minutes earlier, gave the correct cap. **When two fetches of the same vendor's own material disagree, the likely explanation is a bad read, not an inconsistent vendor.** Don't average them or pick the more plausible one.

THE RULE: when the answer you need is a specific number, cap, limit, price, date, or eligibility threshold, and the source is authoritative (a vendor's own terms, policy PDF, spec, or contract), don't stop at the WebFetch summary. WebFetch saves binary content to a local path; Read it directly (the `pages` parameter handles PDFs). It costs one extra tool call.

This differs from the anti-patterns above, which cover fetches FAILING on blocked pages and subagents passing off search snippets as research. This is the harder case: a clean, plausible, wrong answer from a document that was really fetched. There's no error signal to notice.

### A "best alternative to X" search result can be the alternative's own SEO blog
In small product categories, the top results for "best alternative to X" are often blogs run by competing products, each naming itself the winner. The search summary presents that as a neutral finding. The live app store listing can then show an app with about 1K downloads and no rating: too immature to trust with sensitive permissions, yet presented as the top pick.

**Why:** in small categories, vendors can rank for their own comparison keywords cheaply, because nobody else writes the roundup. The search tool hides the link between the domain and the product, so vendor marketing looks like an independent review.

**How to apply:** when a search result recommends a product, check whether the recommending domain IS the product before repeating the claim. Then verify the install base on the primary listing (the app store or marketplace page), not the blog. Pull the rating, review count, download tier, price, "Contains ads" and "In-app purchases" flags, and the last-updated date. Download and review counts are the fastest maturity filter: a category leader has 100K+ downloads, while 1K+ with no rating is pre-release. The same check catches established products that have recently added ads or been delisted entirely.

### Stating a finding is not acting on it; verify dismissals; a vendor's page is not independent evidence
A buying guide recommended anonymous marketplace sellers in a category that has established brands. Rules meant to prevent this already existed, and all of them fired without effect. Three general lessons apply to any research agent:

1. **If a check's required output is a sentence, a sentence will satisfy it.** The rule said "if the field is all white-label, say so plainly, then go find the differentiated options." The guide said so plainly, then recommended a white-label unit anyway. Describing the problem is the cheap half of the instruction, so it's the half that gets done. When you write a rule, attach a consequence the sentence alone doesn't satisfy, and say explicitly that writing the sentence obliges the rest.

2. **No coverage in a channel is evidence about the channel, not the subject.** If you sweep design and gear press for a mundane hardware item that nobody covers there, the empty result isn't evidence that the category is a commodity. Send the search to the channel that actually covers the subject before you conclude anything from silence.

3. **A dismissal needs the same verification as a recommendation.** Writing "only sold commercially", "discontinued", or "not available to consumers" removes an option from the reader's choices, so it needs the same source check as a price. Never generalize from the most expensive SKU on a page that lists several tiers.

Related: **a source that sells a competing product is not independent evidence.** Manufacturer blogs and retailer buying guides show up most easily on exactly the searches that ask why a rival product type fails. Check the publisher (who owns the site, its own about or products page) before you rely on a page to rule out a whole category. Corroborate it independently or label the claim as vendor-sourced.

Testing note for rules written into prompt text: check that the rule is PLACED inside the template that actually reaches the model, not just that it exists somewhere in the file. A rule that drifts into a comment has stopped running, and grep can't tell the difference. Verify by mutation: break the rule and confirm a test fails.

### Match a scraped asset to an existing library by name, and refuse the ambiguous ones
If you re-import scraped assets into the site they came from, you duplicate the owner's own files under names the scrape invented (such as a content-hash prefix), and the names won't match the images.

Match against the existing library by file name. Strip the scrape's prefix and any suffix the platform added (WordPress, for example, serves a `-scaled` copy of an oversized upload, so the scraped name is never the stored name). Try exact candidates first, then one normalized key.

Refuse the normalized pass whenever it's ambiguous ON EITHER SIDE: two library files that reduce to one key, or two scraped paths that reduce to one key. A wrong match puts the wrong picture on the wrong item, which is worse than an extra file, so give up and download instead. Also strip platform-reserved suffixes (such as `-scaled`) from anything you store, or every file lands as `foo-scaled-1`.

Before running the import, prove it works against a test library set up to look like the real one. Assert that the total attachment count equals the image count (no duplicates), and that a second run changes nothing.

### A wide search that prints a narrow table is a narrow answer: measure the output funnel, not the search
A user reported that a research guide covered too narrow a range of options. The obvious diagnosis (it didn't search widely enough) was wrong, and the stored tool trace disproved it in one query: the run made over a hundred web searches touching about 30 brands, then printed a 12-row candidate table in which most of the researched brands appeared nowhere, not even as rejected rows. Most rows were one form factor, and half came from two brands. The research was wide; the OUTPUT funnel was narrow. Searching harder would have spent budget on the half that already worked.

Rules:

1. When a report reads as narrow, compare what was researched against what was PRINTED before you touch the search step. The two failures need opposite fixes, and only the trace tells them apart. If you keep no trace of tool calls, you can't tell them apart afterward, and you'll default to the wrong fix, because "search harder" is the obvious lever.

2. An option that was researched and silently dropped looks, to the reader, exactly like an option that was never considered. So a candidate table must include the losers with their reasons, not just the finalists. Diagnostic: if every rejected row is a near-duplicate of something shortlisted, the table is showing runners-up, not the field.

3. Check concentration in the output, not just whether items are identical. A field that is all one form factor, or dominated by one or two brands, means the answer was ranked within the first slice of options the sources offered and inherited that channel's house style. A sameness check asks whether items are identical; it never asks whether the set covers the range of options, so that needs its own explicit check.

4. When the user relaxes a constraint ("it doesn't have to be X", "any style", "open to alternatives"), that's an instruction to RE-OPEN the field. Re-running the original query with one word deleted returns the same channel's answer in the same house style, which is exactly what the user is complaining about.

5. A prompt rule that lives in a constant but is never inserted into a given code path reaches nobody, and grep can't tell that apart from a working rule. Test the ASSEMBLED prompt by running the real code path (with a fake model that echoes back what it received), not by reading the source text. Watch especially for fallback branches that drop instructions when a prompt file fails to load.

6. Watch for a whole conversational MODE that silently skips the quality controls. If follow-up answers bypass the editor pass and receive no research instructions, every editorial check you add to the main path does nothing on them. A control added to the main path hasn't been added to the product; list every mode and check each one.

### A multi-channel category needs the answer counted by link DOMAIN, not by candidate row
A used-vehicle guide was reported as "only constrained to one site". Counting the stored guide showed about half its links went to one aggregator, and every listing link was that aggregator's FILTERED SEARCH PAGE rather than a specific vehicle. The prose evidence cited 25 domains, so every existing breadth check passed: the candidate table had 14 rows across 5 types, and the research cited recalls, technical details, taxes, and incentives from independent sources. What was single-source was the INVENTORY.

Rules:
1. Where the same item is sold through competing channels (used and secondary-market goods, cars, refurbished electronics, appliances, tickets), the channel is part of the recommendation: price differs, and so do fees, return window, warranty, and recourse. A reader handed one channel can't tell whether it's the cheap one.
2. Count the links you're about to print BY DOMAIN. Breadth checks that count candidate rows by type and by brand miss this, because they measure the wrong axis. If one domain holds most of the links, the guide fails, even when the research was wide.
3. A filtered search-results URL is not a purchase link. Tomorrow it shows a different item, price, and seller, and it hands back the selection work the guide was supposed to do.
4. The channel the first search surfaces is the one that spends the most on SEO, not the one with the best price, and every later search inherits it. Fix this with one search PER CHANNEL TYPE (aggregators, fixed-price national retailers, manufacturer or certified programs, specialist dealers, private sellers) plus the category's independent valuation source, not with more searches of the same kind.
5. When a user asks you to "find more sources", they're complaining about channels, not search volume. Answering with more cited articles doesn't address it.

### Purchase-timing advice needs a check for statutory effective dates, not just price trends
A purchase recommendation built only on market direction (year-over-year and month-over-month price changes) can be overturned by a dated change in the law. In one case, a signed consumer-protection statute with a future effective date was about to give buyers a statutory right to cancel that didn't exist before that date. Waiting a few weeks turned an irreversible purchase into a cheap option to return, which was worth more than any discount reachable by negotiating.

Rules:
1. When advising WHEN to buy, sell, apply, or file, search for pending statutory or policy changes with an effective date, not just price and market trends. "Should I wait?" is a legal question as often as an economic one, and the legal answer is usually a hard date rather than a probability.
2. A signed bill with a future effective date doesn't show up in any price source. Check the legislature's own bill status page for bills that are signed but not yet in effect in the relevant jurisdiction.
3. State which parties the change does and doesn't affect. A new statutory minimum changes sellers who currently offer less, and changes nothing for retailers whose own policy already exceeds it. A blanket "wait for the new law" can be wrong for some channels.
4. Verify a dated legal claim against the primary source before it drives a recommendation. A vetoed bill can circulate as if it were law: a cap widely quoted from a bill that passed both houses and was then vetoed is not the cap in force.

### Re-check the mailbox at synthesis time: the user can book the thing you're researching mid-run
A long research run can be invalidated by the user acting while it runs. A run that recommends booking a rental car is obsolete on arrival if the user's own rental confirmation landed before the research finished; the real action becomes changing the existing reservation, not booking a second car.

Why: research reads the world as of its START, while the user may be acting on the same problem at the same time, and confirmation emails are the cheapest signal that they did. The failure is silent, because the report reads as authoritative and internally consistent.

How to apply: before writing the synthesis of any multi-step booking or logistics run, re-run the mailbox search for confirmations dated AFTER the run began, not just before. One query catches the whole class of error where a recommendation contradicts something already purchased. This applies to flights, hotels, cars, tickets, and reservations.

Corollary: a booking forwarded by a third party often carries no dates. Don't keep searching for a confirmation the user was never sent; say it can't be recovered from this account and name who holds it.

### Sweep the calendar, not just the mailbox, before synthesizing a plan: commitments constrain harder than purchases
A trip plan with several candidate travel days can be broken by calendar entries the research never checked: a dinner in the destination city that rules out one option entirely, a midday task that decides which morning flight works, or commitments set in a different city on a day the plan puts the user somewhere else.

Why: the mailbox shows what was PURCHASED; the calendar shows what was COMMITTED TO. Commitments constrain a plan harder than purchases, because a purchase can usually be changed for a fee while a commitment involves another person. Both sources can change during a long run.

How to apply: before writing the synthesis of any plan that schedules the user's days, sweep BOTH the mailbox and the calendar across the whole planned window, not just the days currently in play. Look specifically for (a) items created since the research began, and (b) items whose LOCATION contradicts where the plan puts the user. Also check the calendar before declaring a date unrecoverable from the mailbox, since it's the other place a date could be recorded.

### A "things to do in <city>" ask is an itinerary problem: resolve it against the calendar's real free windows before listing anything
A generic list of city suggestions is almost always wrong for the person asking, because their day is already half-committed. Pull the calendar and booking confirmations first and work out the actual free blocks, then filter candidates by those blocks AND by day-of-week closures (many good restaurants, and nearly every gallery, close on one specific weekday). A generic list silently violates two constraints. First, an international departure through US customs preclearance at the departure airport needs about 3 hours at the airport, which can wipe out the final evening entirely. Second, a venue open six days a week can be closed on exactly the day the traveler is free. State the deleted options out loud ("X is open only on Wednesdays, and Wednesday evening is your flight") rather than silently leaving them out.

### A higher model number can be a regional compliance variant, not a newer generation; find the real successor before pricing an "old" model
A product with the next model number up can be a regional compliance variant of the same hardware with features disabled, while the actual successor launched under a different naming scheme entirely.

**Why:** judging whether a discount is good requires knowing where the product is in its lifecycle. Reasoning from the model number alone gets both halves wrong: it invents an upgrade that is really a regional downgrade, and it misses the real generational break that should make discounts on the old model deepen over time.

**How to apply:** when assessing the price of a numbered product, search for its successor by generation and launch date, not by incrementing the number. Confirm what each neighboring model number actually is (regional SKU, colorway, capacity tier) before treating one as newer.

### A lazy-loaded gallery silently truncates to what's rendered, not what exists
Reading a photo album for metadata-based analysis can return only the first few dozen items of a much larger set. The grid renders thumbnails only as you scroll, and the read gives no "N of M" count or error to signal that the set is partial. A small early sample can be dominated by one subset (for example, one camera body) while the full set is dominated by another, which reverses both the analysis and any recommendation built on it.

**Why:** a subset that raises no error and looks internally consistent is the most dangerous failure here. There's no exception to catch, and a small early sample can look plausible while being systematically unrepresentative. This is the opposite of an EMPTY read mistaken for complete; here a NONZERO, plausible count is mistaken for complete.

**How to apply:** before analyzing any scraped UI collection (photo album, infinite-scroll feed, virtualized list), compare the item count you read against the UI's own stated total (an album count, a "showing X of Y" label, the source API's count) before drawing conclusions. If there's no stated total, scroll or page until the count stops growing, and say how many loads it took.
