<!-- Load when: auditing a logger/collector's coverage, or a metric whose denominator comes from a different source than its numerator -->
# Measurement Windows and Censored Denominators

A collector's coverage is `records / opportunities`. The numerator comes from the log. The denominator usually comes from somewhere else, such as a transcript, a database, or the thing being observed. Those two sources almost never share a start time. When they don't, the ratio is wrong in a way that looks like a behavioural finding.

## The rule

**Align the denominator to the collector's own observation window before you compute coverage.** The window starts at the first record in *the log you are reading*. It does not start when the collector was installed, and it does not start at the beginning of the observed unit's life.

```
window_start = min(ts) over the CURRENT log file
denominator  = opportunities where window_start <= ts <= window_end
```

Compute coverage both ways. If the uncorrected and corrected numbers differ, the gap comes from measurement, not behaviour. Explain it before you build any theory about the collector.

## Why the artifact is convincing

The bias is not random. It grows with how long the observed unit has been alive. A unit that predates the window adds its whole pre-window history to the denominator and nothing to the numerator, so the deficit concentrates in long-lived units.

If your segmentation variable correlates with age, the artifact shows up looking like a plausible mechanism. "Multi-turn vs single-turn", "active vs idle", "power user vs new user" and "long-running job vs one-shot" all correlate with age. The result reads like this:

> "It fires reliably on the first event and unreliably after."

That sentence is what a censored denominator sounds like. Short units sit entirely inside the window and read 100%. Long units straddle it and read about 50%. No such mechanism exists.

## A rotation you performed yourself is still censoring

This trap is hard to catch because you can *know* about the rotation and still get it wrong. Knowing about it answers a different question:

- "Did the rotation lose data?" No, it was archived on purpose.
- "Does the denominator start where the current log starts?" Nobody asked.

Ruling out log resets as a cause of *missing writes* does not rule them out as a cause of a *mis-specified denominator*. These are two separate failures that go by the same name. Check the archives explicitly. If the "missing" records are in `*.v1.jsonl`, `*.archive`, or the rotated file, the collector never failed.

```bash
# The decisive check, and it is cheap. Do it FIRST.
for f in <log> <archives>; do
  echo "$f: $(grep -c "$UNIT_ID" "$f") records"
done
```

## The same censoring spreads into any per-unit join

A metric that joins a full-lifetime event set against a window-truncated record set inherits the bug and hides it better:

```python
opened[sid]  # scanned from the WHOLE transcript, all of the unit's life
would[sid]   # built only from records in the CURRENT log
recall = len(opened & would) / len(opened)      # structurally unwinnable misses
```

Every event from before the log's window is a guaranteed miss, because the record that would have matched it is in the archive. Bound **both** sides of a per-unit join by the same time window, or drop units whose record set is known to be truncated.

This matters most when a metric has a branch like "if the number is low, abandon the plan". Censoring only ever pushes the number down, so it produces false negatives and never false positives.

## Fix every direction, not just the flattering one

When you correct a censored join, check each metric separately for **which way its bias points**. The metrics will not agree. Applying one bound to all of them is how a rig quietly gets tuned toward the answer you want.

Example: two metrics read the same event set.

| metric | correct bound | why |
|---|---|---|
| recall | per-unit floor (first surviving record) | fair to the retriever: only score events whose trigger this rig actually saw |
| demand ("was it ever wanted?") | the log's global window | a fact about the user, not the retriever; the stricter floor **under-counts** it |

Both bounds raise their numbers. In this case the decision rule shipped when demand was zero, so the stricter bound on demand would have pushed toward shipping on an artifact. **Say each metric's bias direction out loud before you choose its bound.**

## The freeze protects the collector, not the scorer

"The rig is frozen" usually means *stop changing what gets recorded*. A scorer reads data that already exists. Correcting the scorer re-reads the same records and cannot invalidate them.

Settle this with the fingerprint, not by argument. If your records carry a version hash, recompute it from its declared inputs and compare:

```python
h = sha256(collector_source + input_set_a + input_set_b + thresholds)
assert h.hexdigest()[:12] == recorded_rig     # scorer absent -> scorer is free
```

If the scorer is not one of the inputs, editing it changes no record and **does not restart the observation window**. If it is an input, treat it as part of the collector. In both cases, print the pre-fix and post-fix readings side by side so the correction can be audited instead of being a number that quietly moved.

## Checklist

Before you report a coverage or recall figure:

1. What is the first timestamp in the log file I am actually reading?
2. Were there earlier log files? Are the "missing" records in them?
3. Is my denominator filtered to `[window_start, window_end]`?
4. Does the apparent deficit correlate with the observed unit's age or duration? If it does, suspect censoring before you suspect the collector.
5. In every per-unit join, are both sides bounded by the same window?
6. Are the remaining misses real events, or harness artifacts? (For prompt collectors: `/compact`, `/clear`, command-name expansions and continuation summaries show up as `type:user` but never fire `UserPromptSubmit`.)

## Worked example (generic)

An audit reported hook coverage of 100% for single-turn sessions and 52% for multi-turn sessions. The conclusion was that "the hook fires on a session's first prompt and unreliably after", and it was logged as a validity threat. In fact, the log had been archived at a rig freeze, and the denominator counted every prompt in each session's transcript, including prompts from days before the archive. In one session, most of the "missing" records were in the archived log files, and its first prompts came before the hook existed at all.

After the denominator was aligned to the log's own window with a per-prompt timestamp join, coverage was 100% for single-turn and multi-turn sessions alike. The few remaining gaps were all one `/compact` operation: the command, its expansion, and the continuation summary. There was no first-prompt bias. The same censoring was also pushing down a recall metric, because half of its opportunities came from the one session split across archives and could not be won. The fix went into the scorer only, and both readings were printed. Recomputing the rig fingerprint showed that no record was invalidated and the window did not restart.

## Related failure modes

### Differencing a weighted aggregate whose weights are recomputed each period lets composition pass for real movement

A level and a change need different estimators. Some aggregates recompute their weights each period, for example a volume-weighted average price, a traffic-weighted latency, or a headcount-weighted score. You CANNOT difference such an aggregate across periods to measure the thing it averages. The difference includes the composition shift, and that shift looks exactly like real movement in the components.

Typical shape: a "price per unit is up 1%" claim is computed by differencing a count-weighted mean of sub-market medians, with weights taken from each day's own counts. If an expensive sub-market gains listings while a cheap one doesn't, the aggregate rises even when every component holds still. The bias goes both ways: in other windows, a mix shift can hide a real decline.

Cheap diagnostic question: what happens to this number if every component holds perfectly still and only the weights move? If the number moves, it cannot support a claim about the components.

How to fix it: use a fixed-weight (Laspeyres) index. Weight BOTH endpoints by the same base-period weights, and include only components present in both periods, so the result moves only when a component's own value moves. Keep the re-weighted aggregate for the LEVEL, which is a legitimate use, and change only the DELTA. Two traps:
1. Renaming the statistic does not fix it. A true pooled median differenced across periods has the same flaw, because the pool's composition also shifts.
2. Decide which sibling statistics need the fix by MEASURING them, not on principle. If a sibling's worst pure-mix swing is well below its reporting threshold, leave it alone and record why.

Also: `Math.round()` on a small negative value returns `-0`, which fails `strictEqual` against `0`. Normalise before you return a rounded percentage.

### A scan's population list is itself unmaintained data, and nothing detects an item silently dropping out of it

A digest like "recent activity across all repos" is only as complete as the list it iterates over. Some lists are maintained by hand in a separate inventory file instead of being queried live from what they claim to cover (for example, `ls` over the actual directory). With a hand-maintained list, a new item is invisible to every scan built on it until someone adds it by hand. Nothing in the output shows the gap, because a scan that is missing an item looks the same as a scan that correctly found no activity there.

These lists can drift dozens of entries behind reality for days, including items under active development. The drift tends to show up only as an ordinary-looking `git status` diff on a config file. A stale-but-harmless config diff and a stale-and-broken one have the same `git status` signature, so a reviewer can file real coverage loss as "routine drift".

How to apply:
- For any pipeline whose population (repos, services, accounts, feeds) is a hand-maintained list, periodically diff the list against the live source of truth (`ls`, an API's list-all endpoint, a directory glob). Don't trust that additions get remembered.
- Prefer building the list at run time with an explicit exclude-list over maintaining an include-list by hand. An include-list fails silently-closed: new things are invisible by default. An exclude-list fails silently-open: new things are included by default, which is the safer direction for a coverage scan.
- If you inherit a hand-maintained list you can't convert right away, make "does this list still match reality?" its own periodic check, separate from "is the data in this list formatted correctly?".

### A membership test, not just the membership list, can silently drop units from a scan

A correct list can still be filtered wrong. A common case is gating on `[ -d "$repo_dir/.git" ]`. In a git worktree, `.git` is a FILE (a `gitdir:` pointer), so the test fails and the repo reads as nonexistent. Repos that are correctly on the list can then have months of commits invisible to dedup gates and activity digests. Fix: change `-d` to `-e`, which is true for a directory OR a gitdir file and still excludes non-repos.

General lesson: a filter predicate (`is a directory`, `matches this regex`) can build in an assumption about one subtype that a valid alternate subtype (worktree, symlink, bare repo) fails. Before you trust a scan's silence, check that items are both ON the list and PASS its filter.

### A topic-wide grep counts a confirmation line as if it were the event it confirms

Some greps count occurrences of an event by matching a keyword that names the *topic* instead of the *specific line template*. These double-count silently whenever the same subsystem also logs a separate line acknowledging the event.

Typical shape: a restart count is produced by grepping for restart-related lines. The pattern matches both the event line (`recreating container`) and a different line logged right after it (`post-restart auth=ok`). The result is about 2x too high, but it is still plausible enough ("restarts happen often") that nobody questions it.

This looks like a censored-denominator bug, because the count reads as a fact about the system when it is really an artifact of the query. The mechanism is different, though: the log has more than one line PER event, and the pattern can't tell which one it matched.

How to apply: before you report a count from `grep -c` (or something similar) over a log, name the exact line template the pattern should match. Then check whether any OTHER line logged near the same event would also match it: an ack, a retry of the same attempt, or a summary line that repeats counts already logged one by one. Match on a substring unique to the one line that fires exactly once per event. Sanity-check the result against an independent estimate. For example, events divided by the log's day-span gives a rate, and an implausible rate catches a 2x error before it ships.

### A timeout that kills a scan mid-list produces partial data that reads as complete

`$(timeout N ./scan.sh || echo 'failed')` does NOT discard the killed process's output. Command substitution keeps whatever the process already wrote to stdout and then appends the fallback string. If the scan writes its list incrementally, the caller gets a well-formed list that stops wherever the clock ran out, with an error line underneath that is easy to read past.

This is worse than an empty result, because downstream logic treats "not in the list" as a positive fact. If the truncated list feeds a gate like "do not duplicate any work listed below", then "not in the list" silently becomes "no open work exists", and the gate asserts a clean slate it never checked. These failures appear as the scan's input grows past the timeout.

Fail closed instead:
1. Have the producer emit a completion sentinel from exactly ONE place, as its final output (`<!-- SCAN_COMPLETE ... -->`).
2. Have the consumer REQUIRE that sentinel and discard partial output WHOLE. Replace it with an explicit "no data, here is how to get it yourself" block. Never show partial results that read as authoritative.
3. Report unreachable items as NOT SCANNED instead of skipping them. A skipped item looks the same as a clean one, and this habit tends to turn up items that were broken all along (for example, repos with no remote) but had been counted as clean.
4. Never compute a threshold decision (a cap, a quota, an alert) from an incomplete scan.
5. Make the scan faster (for example, with parallel fan-out) rather than raising the timeout. Input growth is what breaks these scans, and the input will keep growing.

Detection: a failure line at the BOTTOM of a long block is easy to miss. A per-run "Nth consecutive failure" tally can also badly undercount, because each run only sees its own truncated evidence.

### A per-call blind-map file overwrites the previous judge's mapping and can silently invert multi-judge results

Suppose a blind-judging script truncates and reshuffles a shared label map (for example, `blind-map.tsv`) on every call, while its scored output is already written per judge. Judging one run with two judges then destroys the first judge's mapping and leaves only the last one. If the two calls drew opposite shuffles, reading the first judge's scores against the surviving map reports the result backwards: a win becomes a loss of the same size. Nothing errors and nothing looks wrong, because the file exists and parses.

Rule: key any blind or randomised label map by the same identifier as the output it decodes (for example, `blind-map-<judge>.tsv`). To recover an already-overwritten map, match each verdict's distinguishing claims back to ground-truth features in the arm artifacts (which arm actually built a repro harness, which used a particular technique). Confirm each mapping with two independent features before you trust any score.

### A "trailing N days" loop that skips yesterday because a nearby section supposedly covers it understates every trend

Some reports build a "last 7 days, aggregated" table with `for i in $(seq 2 7)`, starting at two days ago on the theory that a "recent" block just above already covers yesterday. Usually it doesn't. The recent block prints raw lines, while the historical block computes the aggregated per-day rollup used for trend analysis. A section labelled "last 7 days" really covers 6, and the most recent full day is missing from every 7-day rate on every run.

How to apply: any dashboard or report that builds "last N days" from two adjacent sections, a detailed recent block plus an aggregated historical block, risks an off-by-one at the seam if the two sections use different data shapes. Before you trust a labelled window, count how many iterations the loop actually performs, and check whether the boundary day is truly covered elsewhere or silently dropped. A range that looks deliberate (`seq 2 7` rather than an obvious typo) is easy to read as correct by design when it is really an unchecked assumption. Verify a fix by re-running the loop body against live data before and after.

### A file named `.jsonl` is not guaranteed to be line-delimited

`tail -N file.jsonl | jq -r ...` assumes one compact JSON object per line. If the writer emits pretty-printed multi-line JSON, `tail -N` grabs a fragment cut at arbitrary line boundaries in the middle of objects. That fragment never parses, and the report section shows a permanent "(parse error)".

Fix: slurp and filter by a timestamp field instead of by line count:

```bash
jq -s --arg cutoff "$CUTOFF" -r '[.[] | select(.timestamp >= $cutoff)] | .[] | ...' file.jsonl
```

`jq -s` parses the whole file as a stream of JSON values. It doesn't care about newlines between or inside records, so it works whether the writer emits compact or pretty-printed JSON. Filtering on `.timestamp` also makes a "last 7 days" label true, instead of treating "last 50 lines" as an untested stand-in for it. Record size isn't constant, so a line-count slice would miscount even on a properly line-delimited file.

General lesson: before you treat `tail -N | jq` or any line-count slice as a safe way to sample the last N entries of a JSON log, confirm the file really has one compact object per line. Compare `wc -l` against a manual record count, or just look at the raw file. If the writer ever pretty-prints (jq without `-c`, Python `json.dumps(indent=...)`), every line-based consumer breaks. An EMPTY result (looks like "no data") and a PARSE ERROR (looks like "the tool is broken") can both be swallowed by a `... || echo fallback` pattern, which hides which one actually happened.

### A per-call figure is not an optimisation target until you know its share of total usage

A per-call number can look like a target on its own, for example 45K tokens per call with most of it injected session context. First, sum the job over a real window and divide by total usage. Small-model triage jobs with a large per-call size can turn out to be under 1% of tokens and cost, while a single large-model workload is about half. To compute shares, dedupe transcript usage by message ID, weight by model price (cache reads about 0.1x, cache writes about 1.25x), and rank levers by each job's actual share, not by per-call size.

Corollary: before you route a classifier to a smaller model, replay real production traffic through it. A small hand-picked golden set can show parity that a replay against real batches does not hold. A small eval set does not prove the real traffic mix behaves the same way.
