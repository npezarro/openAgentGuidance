<!-- Load when: auditing a logger/collector's coverage, or a metric whose denominator comes from a different source than its numerator -->
# Measurement Windows and Censored Denominators

A collector's coverage is `records / opportunities`. The numerator comes from the log. The denominator usually comes from somewhere else, such as a transcript, a database, or the thing being observed. Those two sources rarely start at the same time. When they don't, the ratio is wrong, and the error looks like a behavioural finding.

## The rule

**Align the denominator to the collector's own observation window before computing coverage.** The window starts at the first record in *the log you are reading*. It does not start when the collector was installed, and it does not start at the beginning of the observed unit's life.

```
window_start = min(ts) over the CURRENT log file
denominator  = opportunities where window_start <= ts <= window_end
```

Compute coverage both ways. If the uncorrected and corrected numbers differ, the gap comes from measurement, not behaviour. Explain it before you form theories about the collector.

## Why the artifact is convincing

The bias is not random. It grows with how long the observed unit has been alive. A unit that predates the window adds its whole pre-window history to the denominator and nothing to the numerator, so the deficit concentrates in long-lived units.

Your segmentation variable may correlate with age. "Multi-turn vs single-turn", "active vs idle", "power user vs new user" and "long-running job vs one-shot" all do. When it does, the artifact shows up looking like a plausible mechanism:

> "It fires reliably on the first event and unreliably after."

That sentence is what a censored denominator sounds like. Short units sit entirely inside the window and read 100%. Long units straddle it and read about 50%. No such mechanism exists.

## A rotation you performed yourself is still censoring

What makes this hard to catch: you can *know* about the rotation and still get it wrong, because that knowledge answers a different question.

- "Did the rotation lose data?" No, it was archived on purpose.
- "Does the denominator start where the current log starts?" Nobody asked.

Ruling out "log resets" as a cause of *missing writes* does not rule them out as a cause of a *mis-specified denominator*. These are separate failures with the same name. Check the archives explicitly. If the "missing" records are in `*.v1.jsonl`, `*.archive` or the rotated file, the collector never failed.

```bash
# The decisive check, and it is cheap. Do it FIRST.
for f in <log> <archives>; do
  echo "$f: $(grep -c "$UNIT_ID" "$f") records"
done
```

## The same censoring propagates into any per-unit join

A metric that joins a full-lifetime event set against a window-truncated record set inherits the bug, and hides it better:

```python
opened[sid]  # scanned from the WHOLE transcript, all of the unit's life
would[sid]   # built only from records in the CURRENT log
recall = len(opened & would) / len(opened)      # structurally unwinnable misses
```

Every event from before the log's window is a guaranteed miss, because the record that would have matched it is in the archive. Bound **both** sides of a per-unit join by time, or drop units whose record set you know is truncated.

This matters most when a metric has a branch like "if the number is low, abandon the plan". Censoring only ever pushes the number down. It manufactures false negatives and never false positives.

## Fix every direction, not just the flattering one

When you correct a censored join, check each metric separately for **which way its bias points**. The metrics will not agree. Applying one bound to all of them is how a rig quietly gets tuned toward the answer you want.

Example: an experiment with two metrics that read the same event set:

| metric | correct bound | why |
|---|---|---|
| recall | per-unit floor (first surviving record) | fair to the retriever: only score events whose trigger this rig actually saw |
| demand ("was it ever wanted?") | the log's global window | a fact about the user, not the retriever; the stricter floor **under-counts** it |

The recall bound raises the number, and so does the demand bound. The decision rule shipped when demand was zero, so tightening the demand bound would have pushed toward shipping on an artifact. **State each metric's bias direction out loud before you choose its bound.**

## The freeze protects the collector, not the scorer

"The rig is frozen" usually means *stop changing what gets recorded*. A scorer reads data that already exists. Correcting it re-reads the same records and cannot invalidate them.

Settle this with the fingerprint, not by argument. If your records carry a version hash, recompute it from its declared inputs and compare:

```python
h = sha256(collector_source + input_set_a + input_set_b + thresholds)
assert h.hexdigest()[:12] == recorded_rig     # scorer absent -> scorer is free
```

If the scorer is not an input, editing it changes no record and **does not restart the observation window**. If it *is* an input, treat it as part of the collector. Either way, print the pre-fix and post-fix readings side by side so the correction can be audited and doesn't just look like a number that moved.

## Checklist

Before reporting a coverage or recall figure:

1. What is the first timestamp in the log file I am actually reading?
2. Were there earlier log files? Are the "missing" records in them?
3. Is my denominator filtered to `[window_start, window_end]`?
4. Does the apparent deficit correlate with the observed unit's age or duration? If yes, suspect censoring before you suspect the collector.
5. In any per-unit join, are both sides bounded by the same window?
6. Are the remaining misses real events, or artifacts of the harness? (For prompt collectors: `/compact`, `/clear`, command-name expansions and continuation summaries appear as `type:user` but never fire `UserPromptSubmit`.)

## Worked example

A prompt-hook collector reported single-turn coverage of 100% and multi-turn coverage of 52%. This was read as "the hook fires on a session's first prompt and unreliably after" and logged as a validity threat.

The log had been archived at a rig freeze. The denominator counted every prompt in each session's transcript, including prompts from days before the freeze. One session contributed 19 prompts and 1 record. Its other records were in the rotated archive files, and its first prompts came before the hook existed at all.

After correcting to the log's own window with a per-prompt timestamp join across all transcripts, coverage was 100% for single-turn and multi-turn sessions alike. The few remaining apparent misses were one `/compact` operation: the command, its expansion and the continuation summary. There was no first-prompt bias.

The same censoring was also pushing the recall metric down: half of its opportunities came from the one session split across archives, and those could never be matched. The fix went into the scorer, and both readings were printed. The collector was not touched. Recomputing the rig fingerprint from its declared inputs proved that no record was invalidated and that the window did not restart.

## Related failure modes

### Differencing a weighted aggregate whose weights are re-derived each period lets composition masquerade as the measurement

A level and a change need different estimators. Some weighted aggregates recompute their weights every period: a volume-weighted average price, a traffic-weighted latency, a headcount-weighted score. You CANNOT difference one of these across periods to measure the thing it averages. The difference includes the composition shift, which can't be told apart from real movement in the components.

Typical shape: a "price per unit is up 1%" claim that differences an average of sub-market medians, weighted by each period's own listing counts. When the expensive sub-market adds listings and the cheap one does not, the number rises while every component holds still. Measured against real daily snapshots, a fixed-weight version of that move can be exactly 0.00% while the shipped number says +1%. The bias does not run in one direction. On other windows, the mix shift can hide a real decline.

Diagnostic question, cheap to ask: **what happens to this number if every component holds perfectly still and only the weights move?** If the number moves, it cannot support a claim about the components.

Fix shape: a fixed-weight (Laspeyres) index. Weight BOTH endpoints by the same base-period weights and restrict to components present in both periods, so only a component's own value can move the result. Keep the re-weighted aggregate for the LEVEL, which is a legitimate use, and change only the DELTA. Two traps:

1. Renaming the statistic does not fix it. A true pooled median differenced across periods has the same flaw, because the pool's composition also shifts.
2. Scope the fix by MEASURING sibling statistics, not by fixing them on principle. A sibling metric with the same shape may have a worst-case mix swing well under its reporting threshold. Leave it alone in that case and record the reasoning.

Also: `Math.round()` on a small negative value returns `-0`, which fails `strictEqual` against `0`. Normalize before returning a rounded percentage.

### A scan's population list is itself unmaintained data, and nothing detects an item silently falling out of it

A "recent activity across all repos" digest is only as complete as the list of repos it iterates. If that list is a separately maintained inventory file, not a live query of what it claims to cover (for example `ls` over the actual directory), every scan built on it misses a new repo until someone adds it by hand. Nothing in the output shows the gap. A scan that is missing a repo looks the same as a scan that found no activity in it.

The drift can also hide in plain sight. A stale config diff that is harmless and a stale config diff that drops live projects from coverage produce the same `git status` signature, so both get filed as "routine drift".

How to apply:
- For any pipeline whose population is a hand-maintained list (repos, services, accounts, feeds), periodically diff the list against the live source of truth: `ls`, an API's list-all endpoint, or a directory glob.
- Prefer deriving the list at run time with an explicit exclude-list over maintaining an include-list by hand. An include-list fails silently closed (new things are invisible by default). An exclude-list fails silently open (new things are included by default), which is the safer direction for a coverage scan.
- If you inherit a hand-maintained list you can't convert right away, make "does this list still match reality" its own periodic check, separate from "is the data in this list formatted correctly".

### A membership test, not just the membership list, can silently drop units from a scan

A correct list can still be filtered wrong. A common case is gating on `[ -d "$repo_dir/.git" ]`. In a git worktree, `.git` is a FILE (a `gitdir:` pointer), so the test is false and the repo reads as nonexistent. A repo can sit on the list for months while its commits stay invisible to dedup gates and digests.

Fix: `-d` becomes `-e`. That is true for a directory OR a gitdir file, and it still excludes non-repos.

In general, a filter predicate ("is a directory", "matches this regex") can assume one subtype, and a valid alternate subtype (worktree, symlink, bare repo) can fail it. Before trusting a scan's silence, check that items are ON the list AND PASS its filter.

### A category-shaped grep counts a confirmation line as if it were the event it confirms

If you count an event by grepping a keyword that names the *topic* instead of the *specific line template*, you double-count whenever the same subsystem also logs a separate line acknowledging that event.

Typical shape: a restart count grepped for restart-related lines matches both `recreating container` (the event) and `post-restart auth=ok` (a different line logged right after, confirming the restart already counted). The result is about 2x the true count, and the inflated number is still plausible enough to go uncorrected.

This looks like a censored-denominator bug (the count reads as a fact about the system but is an artifact of the query), but the mechanism differs. Here the log has more than one line PER event, and the pattern can't tell which one it matched.

How to apply: before reporting a count from `grep -c` (or similar) over a log:
1. Name the exact line template the pattern is meant to match.
2. Check whether any OTHER line logged near the same event would also match: an ack, a retry of the same attempt, a summary line that restates counts already logged.
3. Match on a substring unique to the one line that fires exactly once per event.
4. Sanity-check against an independent estimate. Count divided by the log's day-span should give a plausible rate. A figure about 2x too high should stand out before it ships.

### A timeout that kills a scan mid-list yields partial data that reads as complete data

`$(timeout N ./scan.sh || echo 'failed')` does NOT discard the killed process's output. Command substitution keeps whatever the process already wrote to stdout and then appends the fallback string. If the scan emits a list incrementally, the caller gets a well-formed list that stops wherever the clock ran out, with an error line underneath that is easy to miss.

This is worse than an empty result, because downstream logic treats absence from the list as a positive fact. For example, a dedup gate that says "do not create work for anything listed below" will read "not in the list" as "has no open branches". A scan that has slowly grown past its timeout can make many briefings claim a clean slate that isn't true.

Fail closed instead:
1. Have the producer emit a completion sentinel from exactly ONE place, as its final output (`<!-- SCAN_COMPLETE ... -->`).
2. Have the consumer REQUIRE that sentinel. If it is missing, discard the partial output WHOLE and substitute an explicit "no data, here is how to get it yourself" block. Never show partial results that read as authoritative.
3. Report unreachable items as NOT SCANNED instead of skipping them. A skipped item looks the same as a clean one. Reporting them can surface items that have been broken for a long time, such as repos with no remote at all.
4. Never compute a threshold decision (a cap, a quota, an alert) from an incomplete scan.
5. Prefer making the scan faster (parallel fan-out can turn tens of seconds into a few) over raising the timeout. Growth in the input list is what breaks these, and it will grow again.

Detection: a failure line at the BOTTOM of a long output block is easy to miss. Also, a per-run "Nth consecutive failure" tally can badly undercount, because each run sees only its own truncated evidence.

### A per-call blind-map file clobbers the previous judge's mapping, silently inverting multi-judge results

Suppose a blind-judging script truncates and RESHUFFLES a single `blind-map.tsv` on every call, while its output is already written per judge (`result-<judge>.json`). Judging one run with two judges then destroys the first judge's mapping and keeps only the last call's. If the two calls drew opposite shuffles, decoding the first judge's scores with the surviving map flips the result: a layer that won by 5 reports as losing by 5. Nothing errors, and the file exists and parses.

Rule: any blind or randomised label map must be keyed by the same identifier as the output it decodes (`blind-map-<judge>.tsv`).

Recovery for a map that is already clobbered: match each verdict's distinguishing claims back to ground-truth features in the arm artifacts (for example, which arm actually built a repro harness). Confirm each mapping with two independent features before trusting any score.

### A trailing-N-days loop that skips "yesterday" because a sibling section supposedly covers it understates every trend by one day

A report builds a "last 7 days, aggregated" table with `for i in $(seq 2 7)`, starting at 2 days ago on purpose because a "recent" block above it covers today and yesterday. But the recent block prints raw per-item lines, not the aggregated per-day rollup the historical table computes. The section labeled "last 7 days" therefore covers only 6, and the most recent full day is missing from every 7-day rate built from it, on every run.

This applies beyond that one script. Any dashboard or report that computes "last N days" as two adjacent sections (a detailed "recent" block plus an aggregated "historical" block) can have an off-by-one at the seam if the two sections pull from different data shapes. Before trusting a labeled window:
- Count how many iterations the loop that builds it actually performs.
- Check whether the boundary day is claimed to be covered elsewhere, and whether it really is.
- A loop range that looks deliberate (`seq 2 7` instead of an obvious typo) is easy to read as correct by design. Treat it as an unverified assumption.

Verify a fix by re-running the loop body against live data before and after, and confirm the missing day now appears.

### A file named .jsonl is not guaranteed to be line-delimited; `tail -N | jq` cuts pretty-printed records in half

The `.jsonl` extension implies one compact JSON object per line. But if the writer pretty-prints (multi-line records), `tail -50 file.jsonl | jq -r '...'` grabs a fragment cut mid-object, which is never valid JSON. The section then always renders `(parse error)`, and a `|| echo fallback` can hide it.

Fix: slurp and filter by timestamp instead of by line count:

```bash
jq -s --arg cutoff "$CUTOFF" -r '[.[] | select(.timestamp >= $cutoff)] | .[] | ...' file.jsonl
```

`jq -s` parses the whole file as a stream of JSON values. It doesn't care about newlines between or within records, so it works whether the writer emits compact or pretty-printed JSON. Filtering on `.timestamp` also makes a "last 7 days" label true. Using "last 50 lines" as a proxy for "last N records or days" miscounts even on a properly line-delimited file, because record size varies.

Before using `tail -N | jq` or any other line-count slice on a JSON log, confirm the file really has one compact object per line: compare `wc -l` against a manual record count, or look at the raw file. If any writer pretty-prints (jq without `-c`, Python `json.dumps(indent=...)`), every line-based consumer breaks. Keep the two failure modes distinct: an EMPTY result looks like "no data", a PARSE ERROR looks like "the tool doesn't work", and a fallback can swallow both.

### A per-call figure is not an optimization target until it's a share of total usage

A per-call number looks like a target on its own, for example 45K tokens per call with about 95% of it injected session-start context. Before optimizing it, sum the job over a real window and divide by total usage. A pair of small-model triage jobs at that per-call size can come to under 1% of total tokens and cost, while a single heavy interactive model accounts for about half. Rank levers by each job's actual share, not by its per-call size.

Method: dedupe transcript usage by `message.id`, weight by model price (cache read about 0.1x, cache write about 1.25x), then rank.

Corollary: replay real production traffic before routing a classifier to a smaller model. A small hand-picked golden set can show parity that a replay against real batches does not. A small eval set does not prove that the real traffic mix behaves the same way.

### A primary/fallback host migration leaves the old host's local logs as a report's silent, stale source

A reporting job builds its summary from local files on whichever host it runs on. If the workload it reports on moves to a new primary host (with the old host kept only as a fallback) and the reporting job does not move, every run on the new host is invisible to the report. That includes runs that scored badly on real violations. The stale section renders as a normal thin result, not an error. You catch it only by checking the new host's logs and state directly and diffing them against the report's input.

When a scheduled job's execution host can fail over, every job that reports on its output must read from wherever the job actually last ran, not from a fixed per-host path. A failover that keeps the workload running correctly can also make every host-local report about it silently wrong, unless the reporting path moves with it or the logs are centralized.
