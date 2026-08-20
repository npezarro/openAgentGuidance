<!-- Load when: research depth and methodology before producing guides or recommendations -->
# Deep Research Before Recommendations

When you are asked to research a topic and produce a guide, recommendation, analysis, or buying decision, the research phase must be thorough before you start writing. Surface-level research produces surface-level guides, and the person who asked ends up doing the real research themselves. That defeats the purpose.

## When This Applies

Any task where you are producing a deliverable based on external research:
- Setup guides, how-to guides, tutorials
- Product/service comparisons and recommendations
- Buying guides and price optimization
- Technology evaluations and architecture decisions
- Troubleshooting guides for unfamiliar tools
- Any "research X and tell me what to do" request

Does NOT apply to: tasks where you already have deep knowledge, pure code implementation, or tasks using only local/repo context.

## Minimum Research Standard

### 1. Source Diversity (at least 3 of these categories)
- **Official documentation**: the product's own docs, FAQ, setup guide
- **Community forums**: Reddit threads, Stack Overflow, GitHub issues, chat communities
- **Recent blog posts/tutorials**: published within the last 12 months
- **Video content**: walkthroughs (check descriptions and comments for gotchas). **Read the transcript, not a third-party recap** (see below).
- **Comparison/review sites**: when evaluating alternatives

A guide built from 2-3 search results and their top links is not research. That's skimming.

### 1b. Video: pull the caption track, don't settle for a recap

Third-party blog recaps of a talk are lossy and often wrong about emphasis. If a video matters to the answer, read what was actually said. Whisper-style transcription is the right tool only when you need word-level timing on your own footage; for someone else's public talk, captions are far faster (hours of video in seconds):

```bash
yt-dlp --skip-download --write-auto-subs --write-subs \
       --sub-langs "en.*" --sub-format vtt -o "%(id)s.%(ext)s" "<url>"
```

Two mandatory post-processing steps, or the output is unusable:

1. **Dedupe.** Auto-caption VTT uses rolling display, so each cue repeats prior lines and a naive strip yields roughly 3x duplicated text. Strip `<c>` karaoke tags, unescape HTML, drop any line matching the last ~6 emitted lines, then reflow into ~45s timestamped paragraphs so chunks are readable and citable.
2. **Correct proper nouns.** Auto-captions mangle names badly and *will* make you misquote: personal names get replaced with unrelated common names, product names get replaced with near-homophones, and plurals get dropped. Correct names in your prose, but **keep quotes exactly as captured** so they stay grep-verifiable, and say so in the deliverable.

**Then count terms.** Term frequency on a transcript is cheap and catches what reading misses. Run `grep -oic` for the 5-10 terms central to your question. In one case, counting two near-synonymous roots across several talks by the same speaker (39 uses of one root and 0 of the other in a 112-minute talk) revealed the speaker's real conceptual vocabulary and inverted the recommendation. A zero-count is a finding, not an absence of data.

**Verify delegated reads.** When subagents read long transcripts, require verbatim quotes with timestamps, then re-grep their key claims yourself before publishing. Cheap insurance, and it makes every claim defensible.

### 2. Gotcha Hunting
Before recommending any setup or product, explicitly search for problems:
- Search "[product] problems [year]", "[product] not working", "[product] issues reddit"
- Read at least one negative/critical thread to understand failure modes
- Include known limitations and common pitfalls in your deliverable
- If something looks too easy, it probably has a catch you haven't found yet

### 3. Cross-Referencing
- Key claims (compatibility, pricing, feature availability) must be verified across 2+ independent sources
- If only one source says something, flag it as unverified or single-source
- When sources conflict, note the conflict and investigate which is current
- Version numbers, URLs, and specific steps should be verified against official sources, not just blog posts

### 4. Version and Platform Disambiguation
- Identify which version, OS, hardware, or configuration the advice applies to
- Explicitly call out when different versions/platforms have different paths (product lines often reuse a brand name across hardware generations that have completely different setup stories)
- Check whether the product has had recent major changes that invalidate older guides
- Note the date of your sources; a guide written before a major update may be wrong

### 5. Completeness Audit
Before writing, list the questions a reader would have:
- What do I need before starting? (prerequisites, accounts, hardware)
- What are the decision points? (which path for my situation)
- What can go wrong? (common errors, troubleshooting)
- What does "done" look like? (verification steps)
- What are the ongoing costs or maintenance needs?

If you can't answer one of these, you haven't researched enough. Go back and find it.

### 6. Recency Verification
- Check that URLs you're recommending are still live
- Verify addon/plugin/extension names and installation methods are current
- Look for deprecation notices, service shutdowns, or major migrations
- Prefer sources from the last 6 months over older ones; if using older sources, verify the information is still accurate

## Research Workflow

1. **Scoping search** (2-3 queries): Understand the landscape, identify key concepts and decision points
2. **Deep dive** (3-5 queries + fetches): Read official docs, community threads, and recent tutorials in full
3. **Gotcha search** (1-2 queries): Explicitly look for problems, limitations, and common mistakes
4. **Verification pass** (1-2 fetches): Cross-check critical claims against primary sources
5. **Completeness check**: Review against the audit questions above; fill gaps with targeted searches
6. **Write the deliverable**: Only now

If you're writing after step 2, you skipped half the process.

## Quality Signals

A well-researched deliverable includes:
- Prerequisites and decision trees ("if you have X, do this; if Y, do that")
- Specific version numbers and dates for time-sensitive information
- Known limitations stated upfront, not buried
- Troubleshooting section with actual common errors (not generic "check your connection")
- Links to primary sources the reader can reference for updates

## Anti-Patterns

- Writing a guide from the first 3 search results
- Treating search snippets as verified facts without reading the full page
- Skipping community forums (where real users report real problems)
- Presenting one path when multiple valid paths exist for different situations
- Omitting known limitations to make the recommendation sound cleaner
- Not checking whether a free tool has gone paid or vice versa
- Recommending a specific version without checking if it's still current
- **Giving up on a source at the first empty/blocked fetch.** Login walls, paywalls, and JS SPAs are *climbable*, not terminal: escalate through the page-access waterfall (plain fetch, then a headless text-extracting page reader, then feed/transcript tricks, then an authenticated browser agent, then falling back to search). Auth-gated pages (professional networks, paid newsletters) are exactly what an authenticated browser agent is for.
- **Spawning research sub-agents armed only with a plain fetch tool for auth-gated/SPA sources.** They hit the same wall and silently "resolve" by writing a confident summary from search snippets. Hand sub-agents the full waterfall (including the authenticated browser command), or retrieve the page yourself and pass the text down. Always label anything search-derived as secondhand.

### Verify a job posting's flagship product is still on the market before diligence: the product's own site can contradict the JD
A live job posting is marketing copy and can be months stale about the company's own product. In one case a Staff PM req led with "we are the team behind [coding agent]" and the company marketing site still showed a "Try it" CTA badged New, while the product's own domain stated plainly that it was no longer available to external users and was continuing as an internal tool. The flagship product had retreated from the market four months before the req was live.

How to apply: when researching a company for a role, an investment, or a partnership, fetch the PRODUCT's own domain (and its status/pricing/login page), not just the company marketing site and the ATS posting. Compare the three. A withdrawn product, a dead pricing page, or a login wall where a signup used to be changes what the job actually is. In that case it turned an apparent product-PM role into a client-delivery role at a services firm, which is a different fit decision.

Corollary: aggregator mirrors of postings drift from the canonical ATS page. A job board showed $240k for the same req the ATS page listed at $265k. Treat the ATS page (Ashby/Greenhouse/Lever) as canonical and note the conflict rather than averaging it. Same for scraped company stats: one data aggregator reported 553 employees and $60.8M revenue for a company whose own profile elsewhere said 22 employees.

### Price tiers can be non-monotonic: a shorter booking can cost more
Rental and subscription pricing is tiered, not linear, and the tier boundary can make a SHORTER booking cost MORE than a longer one. Never assume price rises monotonically with duration, and never quote a duration the user happened to mention without bracketing the tier boundary.

Observed on a major car rental booking engine (single branch, economy class, one driver age band):

```
27 days -> WEEKLY tier  -> $1,094.79
28 days -> MONTHLY tier -> $965.81   ($129 CHEAPER than 27 days)
30 days -> MONTHLY tier -> $966.74   (days 29-30 cost ~$0.47/day)
```

The vendor's own long-term page stated monthly rates begin at "more than 28 days". That published copy was wrong; the empirical trigger was exactly 28. Vendor documentation about its own pricing tiers is a hypothesis, not a fact.

Rule: when researching any duration-tiered price (car rental, subscription, storage, cloud commitment), bracket the boundary by quoting N-1, N, and N+2 rather than quoting only the requested N. Report the cliff explicitly, because "book one day longer and save $129" is often the single most actionable finding in the whole research pass.

## Company-Specific Deliverables: No Invented Product Claims

When building materials ABOUT a specific product or company (interview memos, prototype decks, product analyses, competitive write-ups), only include product capabilities that are:

1. **Verified via public sources**: official docs, press releases, tech blog posts, shareholder letters, or news articles. Date-stamp and link the source.
2. **Confirmed in the requester's own sketch or brief**: if they described the feature themselves, use their framing exactly.

Do NOT extrapolate, assume, or invent features that "seem like they should exist" or "fit the product vision."

**Why this matters:** Fabricated features read as authoritative claims to a hiring panel, client, or stakeholder. When challenged, the error is harder to recover from than a knowledge gap. In one case, final-panel prep for a large consumer streaming service required a full ground-up rebuild after agents invented a social viewing feature the product does not have, a device-penetration target that does not exist, and a kids-profile capability that was false. That cost a full session.

**Self-check before submitting any company-specific deliverable:** for each product claim, ask "where is the public source for this?" If you can't point to one, mark it as assumed or cut it. Treat the requester's own words as the floor for what's in scope.

### A successful fetch is not a faithful read: open the document when the answer is a specific limit
A fetch-and-summarize tool retrieves a page or PDF and then answers your prompt against it with a small fast model. That summarization step can fail SILENTLY and CONFIDENTLY on a document it read correctly; the retrieval succeeding tells you nothing about the answer being right.

In one research pass, a fetch of a card issuer's own rental-coverage terms PDF reported a 31-day coverage cap (the document says 42) and stated "the document does not contain distinct state-specific pricing" (the document prints two explicit state price tiers). Both errors were material: the correct 42 days and the state-specific price were the session's headline findings. Trusting the summary would have understated coverage by 11 days and lost the best number in the research.

WHAT CAUGHT IT: the same vendor's FAQ, fetched two minutes earlier, said 42 days. **When two fetches of the same vendor's own material disagree, the likely explanation is a bad read, not an inconsistent vendor.** Do not average them or pick the more plausible one.

THE RULE: when the answer you need is a specific number, cap, limit, price, date, or eligibility threshold, and the source is authoritative (a vendor's own terms, policy PDF, spec, or contract), do not stop at the fetch summary. Fetch tools persist binary content to a local path; read it directly (a page-range parameter handles PDFs). One extra tool call.

Distinct from the anti-patterns above: those cover a fetch FAILING on blocked/SPA pages, and sub-agents laundering search snippets. This is the harder case: a clean, plausible, wrong answer from a document that was genuinely fetched. There is no error signal to notice.

### A "best alternative to X" search result can be the alternative's own SEO blog
Searching "best [product] alternative for [platform]" returned two vendor blogs as top results, both recommending their own product as the winner. The search-result summary presented "[vendor] is currently the only option that ships all three together" as a neutral finding. The live app-store listing showed **1K+ downloads and no visible rating**: an app too immature to hand keyboard-level input access to, presented as the top pick.

**Why:** vendors in small categories rank for their own comparison keywords cheaply, because nobody else writes the roundup. The search tool strips the domain's relationship to the product, so vendor marketing arrives looking like independent review.

**How to apply:** when a search result recommends a product, check whether the recommending domain IS the product before repeating the claim. Then verify the install base from the primary listing rather than the blog: pull the store page as text and read the header block, which yields rating, review count, download tier, price, ads/in-app-purchase flags, and the "Updated on" date. Download count and review count are the fastest maturity filter: a category incumbent has 100K+; 1K+ with no rating is pre-release. The same check in that pass also caught that a well-known incumbent now carries "Contains ads" and that another named alternative was fully delisted (a store search for its name returned no such app). Same is-this-thing-still-alive discipline as the job-posting rule above.

### Stating a finding is not acting on it; verify dismissals; a vendor's page is not independent evidence

A buying guide recommended anonymous marketplace sellers in a category that has established brands. The prompt rules meant to prevent this already existed and all fired without biting. The three general lessons apply to any research agent, not just shopping.

1. **A check whose required output is a sentence will be satisfied with a sentence.** The rule said "if the field is all white-label, say so plainly, then go find the differentiated options." The guide said so plainly, then recommended a white-label unit anyway. Narrating the problem is the cheap half of the instruction, so it is the half that gets done. When writing a rule, attach a consequence that the sentence alone does not satisfy, and say explicitly that writing it obliges the rest.

2. **Absence of coverage in a channel is evidence about the channel, not the subject.** The sourcing sweep named design and gear press. Nobody writes design coverage of furniture leg caps, so the sweep came back empty and the silence was read as "this category is a commodity." Route the search to the channel that actually covers the subject before concluding anything from silence.

3. **A dismissal needs the same verification as a recommendation.** Writing "only sold commercially", "discontinued", or "not available to consumers" removes an option from the reader's choice set, so it needs the same source check as a price. In that case the dismissal was contradicted by the very page the guide cited. Never generalize from the most expensive SKU on a page listing several tiers.

Related: **a source that sells a competing product is not independent evidence.** Manufacturer blogs and retailer buying guides surface most readily on exactly the searches that ask why a rival product type fails. Check the publisher (who owns the site, its own about/products page) before leaning on a page to rule out a whole category. Corroborate independently or label the claim vendor-sourced.

Testing note for prompt-text rules: assert PLACEMENT inside the template that reaches the model, not just presence in the file. A rule that drifts into a comment has stopped running and a grep cannot tell the difference. Verify by mutation.

### Match a scraped asset to an existing library by name, and refuse the ambiguous ones
Re-importing scraped assets into the site they were scraped from duplicates the owner's own files under names the scrape invented (a content-hash prefix), which reads as "the names do not match the image".

Match against the existing library by file name, stripping the scrape's prefix and any platform-added suffix (a CMS often serves a resized copy of an oversized upload, so the scraped name is never the stored name). Try exact candidates first, then one normalised key.

The normalised pass must be refused whenever it is ambiguous ON EITHER SIDE: two library files reducing to one key, or two scraped paths reducing to one key. A wrong match puts the wrong picture on the wrong item, which is worse than an extra file, so give up and download instead. Also strip suffixes the platform reserves (for example a `-scaled` variant marker) from anything you do store, or every file lands as `foo-scaled-1`.

Prove it with a library seeded to look like the real one before running the import, and assert total attachment count equals the image count (no duplicates) plus idempotency on a second run.

### A wide search that prints a narrow table is a narrow answer: measure the output funnel, not the search
Someone reported that a research guide covered too narrow a range of options. The intuitive diagnosis (it did not search widely enough) was wrong, and the stored tool trace disproved it in one query: the run made 138 web searches touching ~30 brands, then printed a 12-row candidate table in which 24 of the researched brands appeared nowhere at all, not even as a rejected row. 7 of 12 rows were one form factor and 6 of 12 came from two brands. The research was wide. The OUTPUT funnel was narrow. Searching harder would have spent budget improving the half that already worked.

Rules:

1. When a report reads as narrow, measure the ratio of what was researched to what was PRINTED before touching the search step. The two failures need opposite fixes, and only the trace distinguishes them. If you keep no trace of tool calls, you cannot tell them apart after the fact and will default to the wrong one, because "search harder" is the available lever.

2. An option researched and dropped silently is indistinguishable, from the reader side, from an option never considered. A candidate table must therefore carry the losers with their reasons, not just the finalists. Diagnostic shape: if every rejected row is a near-duplicate of something shortlisted, the table is showing runners-up rather than the field.

3. Check concentration in the output, not only homogeneity of the items. A field that is all one form factor or dominated by one or two brands means the answer ranked inside the first slice of the solution space the sources offered, and inherited that channel house style. This is the same defect as an all-white-label shortlist one level up, and it needs its own explicit check because a homogeneity test asks whether items are identical, never whether the set spans the space.

4. Relaxing a constraint ("it does not have to be X", "any style", "open to alternatives") is an instruction to RE-OPEN the field. Re-running the original query with one word deleted returns the same channel answer in the same house style, which is exactly what the user is reporting.

5. A prompt rule that lives in a constant but is never spliced into a given code path reaches nobody, and grep cannot distinguish that from a working rule. Test the ASSEMBLED prompt by driving the real code path (a fake model echoing back what it received), not the source text. The same audit found a follow-up mode that ran with zero instructions whenever a system prompt file failed to load, because its fallback branch dropped the instruction entirely while every sibling branch kept theirs.

6. Watch for a whole conversational MODE that silently opts out of the quality controls. Follow-up answers there skipped the editor pass by design and also received no research instructions, so every editorial check added over the preceding weeks was inert on them. A control added to the main path is not added to the product; enumerate the modes and check each one.
