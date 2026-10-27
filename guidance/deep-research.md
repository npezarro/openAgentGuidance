<!-- Load when: research depth and methodology before producing guides or recommendations -->
# Deep Research Before Recommendations

When the user asks you to research a topic and produce a guide, recommendation, analysis, or buying decision, do the research thoroughly before you start writing. Surface-level research produces surface-level guides, and then the user has to do the real research themselves, which defeats the purpose.

## When This Applies

Any task where you produce a deliverable based on external research:
- Setup guides, how-to guides, tutorials
- Product or service comparisons and recommendations
- Buying guides and price optimization
- Technology evaluations and architecture decisions
- Troubleshooting guides for unfamiliar tools
- Travel, logistics, and itinerary planning
- Any "research X and tell me what to do" request

Does NOT apply to tasks where you already have deep knowledge, pure code implementation, or tasks that use only local or repo context.

## Minimum Research Standard

### 1. Source Diversity (at least 3 of these categories)
- **Official documentation**: the product's own docs, FAQ, setup guide
- **Community forums**: Reddit threads, Stack Overflow, GitHub issues, community chat servers
- **Recent blog posts and tutorials**: published within the last 12 months
- **Video content**: YouTube walkthroughs (check descriptions and comments for gotchas). **Read the transcript, not a third-party recap** (see 1b).
- **Comparison and review sites**: when evaluating alternatives

A guide built from 2-3 search results and their top links is not research. That's skimming.

### 1b. YouTube: pull the caption track, don't settle for a recap

Third-party blog recaps of a talk are lossy and often get the emphasis wrong. If a video matters to the answer, read what was actually said. Speech-to-text (for example Whisper) is the right tool when you need word-level timing on your own videos. For **someone else's** talk, captions are far faster; hours of video take seconds:

```bash
yt-dlp --skip-download --write-auto-subs --write-subs \
       --sub-langs "en.*" --sub-format vtt -o "%(id)s.%(ext)s" "<url>"
```

Two post-processing steps are mandatory, or the output is unusable:

1. **Dedupe.** Auto-caption VTT uses rolling display, so each cue repeats earlier lines and a naive strip gives you about 3x duplicated text. Strip `<c>` karaoke tags, unescape HTML, drop any line that matches one of the last ~6 emitted lines, then reflow into ~45s timestamped paragraphs so the chunks are readable and citable.
2. **Correct proper nouns.** Auto-captions mangle names badly and *will* make you misquote. Expect speaker names to come out as phonetic near-misses, and product names to become common words (an AI product name rendered as "cloud", "quad", or "claw"; "grep" rendered as "grap"). Captions also drop plurals. Correct names in your prose, but **keep quotes exactly as captured** so they stay grep-verifiable, and say so in the deliverable.

**Then count terms.** Term frequency on a transcript is cheap and catches things reading misses. Run `grep -oic` for the 5-10 terms central to your question. Counting one concept word against its near-synonym across several talks by the same speaker can show their real conceptual vocabulary (dozens of uses of one, zero of the other) and invert a recommendation. A zero count is a finding, not missing data.

**Verify delegated reads.** When subagents read long transcripts, require verbatim quotes with timestamps, then re-grep their key claims in the main thread before you publish. It's cheap insurance and makes every claim defensible.

### 2. Gotcha Hunting
Before recommending any setup or product, search explicitly for problems:
- Search "[product] problems [year]", "[product] not working", "[product] issues reddit"
- Read at least one negative or critical thread to understand how it fails
- Put known limitations and common pitfalls in your deliverable
- If something looks too easy, it probably has a catch you haven't found yet

### 3. Cross-Referencing
- Verify key claims (compatibility, pricing, feature availability) across 2+ independent sources
- If only one source says something, flag it as unverified or single-source
- When sources conflict, note the conflict and find out which one is current
- Check version numbers, URLs, and specific steps against official sources, not just blog posts

### 4. Version and Platform Disambiguation
- Identify which version, OS, hardware, or configuration the advice applies to
- Say explicitly when different versions or platforms have different paths (two products sharing a brand name can have completely different setup stories)
- Check whether the product has had recent major changes that make older guides wrong
- Note the date of your sources. A guide written before a major product update may be wrong.

### 5. Completeness Audit
Before writing, list the questions a reader would have:
- What do I need before starting? (prerequisites, accounts, hardware)
- What are the decision points? (which path fits my situation)
- What can go wrong? (common errors, troubleshooting)
- What does "done" look like? (verification steps)
- What are the ongoing costs or maintenance needs?

If you can't answer one of these, you haven't researched enough. Go back and find it.

### 6. Recency Verification
- Check that the URLs you recommend are still live
- Verify that addon, plugin, and extension names and install methods are current
- Look for deprecation notices, service shutdowns, or major migrations
- Prefer sources from the last 6 months. If you use older sources, verify the information still holds.

## Research Workflow

1. **Scoping search** (2-3 queries): understand the landscape and identify key concepts and decision points
2. **Deep dive** (3-5 queries plus fetches): read official docs, community threads, and recent tutorials in full
3. **Gotcha search** (1-2 queries): look explicitly for problems, limitations, and common mistakes
4. **Verification pass** (1-2 fetches): cross-check critical claims against primary sources
5. **Completeness check**: review against the audit questions above and fill gaps with targeted searches
6. **Re-check the user's own state** (see "Synthesis-Time Checks"): mailbox and calendar, if you have access
7. **Write the deliverable**: only now

If you're writing after step 2, you skipped half the process.

## Quality Signals

A well-researched deliverable includes:
- Prerequisites and decision trees ("if you have X, do this; if Y, do that")
- Specific version numbers and dates for time-sensitive information
- Known limitations stated up front, not buried
- A troubleshooting section with real common errors (not generic "check your connection")
- Links to primary sources the user can check for updates
- A working, specific link for every recommended option (see "Links")

## Anti-Patterns

- Writing a guide from the first 3 search results
- Treating search snippets as verified facts without reading the full page
- Skipping community forums, which is where real users report real problems
- Presenting one path when different situations call for different valid paths
- Leaving out known limitations to make the recommendation sound cleaner
- Not checking whether a free tool has gone paid, or the other way round
- Recommending a specific version without checking that it's still current
- **Giving up on a source after the first empty or blocked fetch.** Login walls, paywalls, and JS single-page apps can be worked around. Escalate through an access waterfall: plain fetch, then a headless page reader that renders JS, then feed or transcript tricks (RSS, caption tracks, API endpoints), then an authenticated browser agent using the user's session, then web search as a last resort. Auth-gated pages (professional networks, paid newsletters) are exactly what an authenticated browser is for.
- **Spawning research subagents that only have a plain fetch tool for auth-gated or SPA sources.** They hit the same wall and quietly "resolve" it by writing a confident summary from search snippets. Give subagents the whole waterfall, or retrieve the page in the main thread and pass the text down. Always label anything you got from search as secondhand.

## Reading Sources Faithfully

### A successful fetch is not a faithful read: open the document when the answer is a specific limit
Many fetch tools retrieve a page or PDF and then answer your prompt against it with a small, fast model. That summarizing step can fail **silently and confidently** on a document it retrieved correctly. A successful retrieval tells you nothing about whether the answer is right. In practice, a fetch summary of a vendor's own terms PDF has reported the wrong coverage cap and claimed that regional pricing tiers didn't exist, when the document printed them explicitly. Those were the headline findings of the research.

**When two fetches of the same vendor's own material disagree, the likely explanation is a bad read, not an inconsistent vendor.** Don't average them, and don't pick the more plausible one.

**Rule:** when the answer you need is a specific number, cap, limit, price, date, or eligibility threshold, and the source is authoritative (a vendor's own terms, policy PDF, spec, or contract), don't stop at the summary. Read the raw document yourself; if the fetch tool saves content to a local path, open that file directly (page-range reads work for PDFs). It costs one extra tool call. This is a harder case than a blocked fetch: you get a clean, plausible, wrong answer from a document that really was fetched, and nothing signals an error.

### A lazy-loaded collection silently truncates to what's rendered, not what exists
Infinite-scroll feeds, virtualized lists, and photo albums render items only as you scroll. A read can return a small, consistent subset with no "N of M" count and no error. If that early subset isn't representative (for example, mostly from one device, one period, or one category), conclusions drawn from it can be the exact opposite of what the full set shows, and so can any recommendation built on them.

A plausible nonzero count mistaken for the whole set is more dangerous than an empty read, because there's nothing to catch.

**How to apply:** before analyzing any scraped UI collection, compare the number of items you read against the UI's own stated total (an album count, a "showing X of Y" label, the source API's count). If there's no stated total, keep scrolling or paging until the count stops growing, and report how many loads it took.

### Pre-test a gated source's access method before fanning out
When a fan-out hits a login wall or SPA on first contact, each agent tends to report the source as "couldn't check" instead of anyone solving access once. Test each gated source's access method in the main thread first, then give agents the proven method, not just the URL. Confirm the test reached the **intended** page: a wrong code or ID can return a styled error page, or redirect to an unrelated listing that still looks like success. Add an adversarial verifier pass afterward. Availability of scarce resources (a room, an award seat, a ticket) can change within hours of the research pass.

## Source Independence

### A "best alternative to X" result can be the alternative's own SEO blog
In small categories, vendors rank cheaply for their own comparison keywords because nobody else writes the roundup. The search tool hides the domain's relationship to the product, so vendor marketing looks like independent review. A top-ranked "the only option that does all three" claim can come from the product's own blog, about an app with a tiny install base and no ratings.

**How to apply:** when a search result recommends a product, check whether the recommending domain **is** the product before you repeat the claim. Then check maturity on the primary listing (app store page, marketplace listing), not the blog: rating, review count, download tier, price, "Contains ads" or "In-app purchases" flags, and the last-updated date. Download and review counts are the fastest maturity filter. A category incumbent typically has 100K+ downloads; 1K+ with no rating is effectively pre-release. The same check catches incumbents that have since added ads and products that have been delisted entirely.

### A vendor's page is not independent evidence
Manufacturer blogs and retailer buying guides show up most easily on exactly the searches that ask why a rival product type fails. Check who publishes a page (who owns the site, its own about or products page) before you rely on it to rule out a whole category. Corroborate independently or label the claim vendor-sourced.

### Verify that a company's flagship product is still on the market
Job postings, company marketing sites, and investor pages are marketing copy and can be months out of date about the company's own product. A posting can lead with a flagship product that the product's own domain says was withdrawn from external users months earlier.

**How to apply:** when researching a company for a role, an investment, or a partnership, fetch the **product's** own domain (and its status, pricing, and login pages), not just the company site and the job posting, and compare all three. A withdrawn product, a dead pricing page, or a login wall where a signup used to be changes what the job or deal actually is.

**Corollary:** aggregator mirrors of postings drift from the canonical page. Treat the employer's applicant tracking system page as canonical and note conflicts (salary bands, titles) instead of averaging them. Scraped company stats (headcount, revenue) from data aggregators can be wildly off from the company's own profile; flag them as unverified.

## Company-Specific Deliverables: No Invented Product Claims

When you build materials ABOUT a specific product or company (interview memos, prototype decks, product analyses, competitive write-ups), include only product capabilities that are:

1. **Verified through public sources**: official docs, press releases, engineering blog posts, shareholder letters, or news articles. Date-stamp and link the source.
2. **Confirmed in the user's own sketch or brief**: if the user described the feature, use their framing exactly.

Do NOT extrapolate, assume, or invent features that "seem like they should exist" or "fit the product vision."

**Why this matters:** to a hiring panel, client, or stakeholder, an invented feature reads as an authoritative claim. When someone challenges it, the error is harder to recover from than a gap in knowledge, and invented features, targets, or programs can force a ground-up rebuild of the whole deliverable.

**Self-check before submitting any company-specific deliverable:** for each product claim, ask "where is the public source for this?" If you can't point to one, mark it as assumed or cut it. The user's own words set the minimum scope.

## Pricing and Product Lifecycle

### Price tiers can be non-monotonic: a shorter booking can cost more
Rental and subscription pricing is tiered, not linear, and a tier boundary can make a SHORTER booking cost MORE than a longer one. On a live rental booking engine, a 27-day rental priced in the weekly tier cost over $100 more than a 28-day rental priced in the monthly tier, and days 29-30 added well under $1 per day. The vendor's own published copy put the monthly threshold one day off from where the engine actually applied it. Vendor documentation about its own pricing tiers is a hypothesis, not a fact.

**Rule:** for any duration-tiered price (car rental, subscription, storage, cloud commitment), bracket the boundary by quoting N-1, N, and N+2, not just the N the user mentioned. Report the cliff explicitly. "Book one day longer and save $100+" is often the single most actionable finding of the whole research pass.

### A higher model number can be a regional compliance variant, not a newer generation
A model number one higher than the product you're pricing can be a regional-compliance SKU (same hardware with a feature disabled to meet local regulations), while the real successor launched under a completely different naming scheme.

**Why:** to judge whether a discount is good, you need to know where the product is in its lifecycle. Reasoning from model numbers alone gets both halves wrong: it invents an upgrade that is really a regional downgrade, and it misses the real generational break that should make the old model's discounts deepen over time.

**How to apply:** when assessing the price of a numbered product, search for the successor by generation and launch date, not by incrementing the number. Confirm what each adjacent model number actually is (regional SKU, colorway, capacity tier) before treating one as newer.

### Purchase-timing advice needs a check for statutory effective dates, not just price trends
A "be patient on price" recommendation built on market direction can be outranked by a signed law that takes effect in a few weeks. For example, a consumer-protection statute might create a right to cancel that doesn't exist today. Waiting until the operative date can turn an irreversible purchase into one you can return, which is worth more than any discount you could negotiate.

**Rules:**
1. When advising WHEN to buy, sell, apply, or file, search for pending statutory or policy changes with an effective date, not only price and market trends. "Should I wait?" is a legal question as often as an economic one, and the legal answer is usually a hard date, not a probability.
2. A signed bill with a future operative date is invisible to every price source. Check the legislature's own bill status page for law that has been chaptered but isn't yet operative in the relevant jurisdiction.
3. State which parties the change affects and which it doesn't. Sellers whose own policy already exceeds the new statutory floor are unaffected, so a blanket "wait for the new law" can be wrong for some channels.
4. Verify a dated legal claim against the primary source before it drives a recommendation. Vetoed bills circulate as if they were law, and a widely quoted figure (a fee cap, a threshold) can come from a bill that passed both houses and was then vetoed.

## Breadth of the Answer, Not Just the Search

### Stating a finding is not acting on it
A check whose required output is a sentence will be satisfied by a sentence. A rule like "if the field is all white-label, say so plainly, then find the differentiated options" gets the cheap half done: the guide says so plainly, then recommends a white-label unit anyway. When you write a rule, attach a consequence the sentence alone doesn't satisfy, and say explicitly that writing the sentence obliges the rest.

### Absence of coverage in a channel is evidence about the channel, not the subject
If you sweep design and gear press for a mundane hardware category, nobody has written about it, and the silence gets misread as "this category is a commodity." Route the search to the channel that actually covers the subject (trade suppliers, specialist retailers, professional forums) before you conclude anything from silence.

### A dismissal needs the same verification as a recommendation
Writing "only sold commercially", "discontinued", or "not available to consumers" removes an option from the reader's choices, so it needs the same source check as a price. Such dismissals are often contradicted by the very page being cited. Never generalize from the most expensive SKU on a page that lists several tiers.

### A wide search that prints a narrow table is a narrow answer
When a report reads as narrow, the intuitive diagnosis ("it didn't search widely enough") is often wrong. A run can make 100+ searches touching ~30 brands and then print a 12-row table in which most of the researched brands appear nowhere, not even as rejected rows. The research was wide; the OUTPUT was narrow. Searching harder spends budget improving the half that already worked.

**Rules:**
1. When a report reads as narrow, measure the ratio of what was researched to what was PRINTED before you touch the search step. The two failures need opposite fixes, and only a trace of tool calls tells them apart. Without a trace you'll default to "search harder", because that's the lever within reach.
2. An option that was researched and silently dropped looks exactly like one that was never considered. A candidate table must include the losers with their reasons, not just the finalists. Diagnostic: if every rejected row is a near-duplicate of something on the shortlist, the table shows runners-up, not the field.
3. Check concentration in the output, not just whether the items are identical. If the field is all one form factor or dominated by one or two brands, the answer was ranked inside the first slice of the solution space the sources offered and inherited that channel's house style. A homogeneity test asks whether the items are identical, never whether the set covers the space, so this needs its own explicit check.
4. Relaxing a constraint ("it doesn't have to be X", "any style", "open to alternatives") is an instruction to RE-OPEN the field. Re-running the original query with one word deleted returns the same channel's answer in the same house style, which is exactly what the user is complaining about.

### A multi-channel category needs links counted by DOMAIN, not by candidate row
A guide can pass every breadth check (many candidate rows across several types, prose citing two dozen domains) and still be single-source where it matters: about half its links can point to one aggregator, and every listing link can be a filtered search page instead of a specific unit.

**Rules:**
1. Where the same unit trades through competing channels (used and secondary-market goods, cars, refurbished electronics, appliances, tickets), the channel is part of the recommendation. Price differs, and so do fees, return window, warranty, and recourse. A reader given one channel can't tell whether it's the cheap one.
2. Count the links you're about to print BY DOMAIN. Breadth checks that count candidate rows by type and brand have the same defect one axis over and don't catch this. If one domain holds most of the links, the guide fails, even if the research was wide.
3. A filtered search-results URL is not a purchase link. Tomorrow it shows a different unit, price, and seller, and it hands back the selection work the guide was supposed to do.
4. The channel your first search surfaced is the one that spends the most on SEO, not the one with the best price, and every later search inherits it. Fix this with one search PER CHANNEL FAMILY (aggregators, fixed-price national retailers, manufacturer or certified programs, specialist dealers, private party) plus the category's independent valuation source, not with more searches of the same kind.
5. When a user says "find more sources", they're complaining about channels, not search volume. More cited articles don't fix it.

## Synthesis-Time Checks (when you have access to the user's mailbox and calendar)

### Re-check the mailbox at synthesis time: the user may book the thing mid-run
Research reads the world as of its START, while the user may be acting on the same problem at the same time. If a rental confirmation arrives during the run, a recommendation to "book a rental" is obsolete on arrival; the real action is to change the existing reservation. The failure is silent because the report reads as authoritative and internally consistent.

**How to apply:** before writing the synthesis of any multi-step booking or logistics run, re-run the mailbox search for confirmations dated AFTER the run began, not just before. One query catches recommendations that contradict something already purchased. This applies to flights, hotels, cars, tickets, and reservations.

**Corollary:** a booking forwarded by a third party often carries no dates. Don't keep searching for a confirmation the user was never sent; say it can't be recovered from this account and name who holds it.

### Sweep the calendar too: commitments constrain harder than purchases
The mailbox shows what was PURCHASED; the calendar shows what was COMMITTED TO. A purchase can usually be changed for a fee, but a commitment involves another person. A calendar sweep at synthesis time can show that one candidate travel day is impossible (a dinner in another city), that a midday task decides which flight works, or that commitments put the user in a different city than the plan assumes.

**How to apply:** before writing the synthesis of any plan that allocates the user's days, sweep BOTH the mailbox and the calendar across the whole planned window, not just the days currently in play. Look for (a) items created since the research began, and (b) items whose LOCATION contradicts where the plan puts the user. Also check the calendar before you declare a date unrecoverable from the mailbox, since it's the other place a date might be recorded.

### A "things to do in <city>" request is an itinerary problem
A generic city-suggestions list is almost always wrong for the person asking, because their day is already half-committed. Pull the calendar and booking confirmations first, work out the actual free blocks, then filter candidates by those blocks AND by day-of-week closures (many good restaurants, and nearly every gallery, close on one particular weekday). Watch for constraints a generic list silently violates: an international departure with US border preclearance needs about 3 hours at the airport, which can wipe out the final evening, and a venue open six days a week can be closed on exactly the day the traveller is free. Name the options you removed ("X is Wednesday-only and Wednesday evening is your flight") instead of silently leaving them out.

## Links

### Every recommended option needs a booking or click-through link
A recommended option without a link makes the reader research it again. For every recommended option (flights, hotels, award search, restaurants, activities, rentals), give the most specific working link: a deep link with dates, route, and guests prefilled is better than a generic homepage. For points redemptions, link both the award search and the transfer-partner page. Put each link inline next to its option, not in a list at the end. If a deep link isn't possible, link the closest search page and say what to enter. Verify that every link resolves.

## Testing Prompt-Text Rules (when research behavior is driven by a prompt you maintain)

- Check that a rule is PLACED inside the template that actually reaches the model, not just that it exists in the file. A rule that has drifted into a comment has stopped running, and grep can't tell the difference. Verify by mutation: break the rule and confirm a test fails.
- A rule that lives in a constant but is never spliced into a given code path reaches nobody. Test the ASSEMBLED prompt by driving the real code path (for example, a fake model that echoes back what it received), not the source text. Check fallback branches especially: a branch that runs when a prompt file fails to load can drop the instructions entirely while its sibling branches keep them.
- Watch for whole conversational MODES that silently skip the quality controls. If follow-up answers bypass the editor pass and the research instructions, every editorial check you add to the main path does nothing for them. A control added to the main path hasn't been added to the product until you've listed the modes and checked each one.
