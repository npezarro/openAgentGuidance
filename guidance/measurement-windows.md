<!-- Load when: auditing a logger/collector's coverage, or a metric whose denominator comes from a different source than its numerator -->
# Measurement Windows and Censored Denominators

A collector's coverage is `records / opportunities`. The numerator comes from the log. The denominator usually comes from somewhere else, such as a transcript, a database, or the thing being observed. Those two sources almost never share a start time. When they don't, the ratio is wrong in a way that looks like a finding about behaviour.

## The rule

**Align the denominator to the collector's own observation window before computing coverage.** The window starts at the first record in *the log you are reading*. It does not start when the collector was installed, and it does not start at the beginning of the observed unit's life.

```
window_start = min(ts) over the CURRENT log file
denominator  = opportunities where window_start <= ts <= window_end
```

Compute coverage both ways. If the uncorrected and corrected numbers differ, the gap comes from measurement, not behaviour. Explain it before you form any theory about the collector.

## Why the artifact is convincing

The bias is not random. It grows with how long the observed unit has been alive. A unit that predates the window adds its whole pre-window history to the denominator and nothing to the numerator, so the deficit concentrates in long-lived units.

Your segmentation variable may correlate with age. "Multi-turn vs single-turn", "active vs idle", "power user vs new user" and "long-running job vs one-shot" all do. When that happens, the artifact comes with a plausible-sounding mechanism already attached:

> "It fires reliably on the first event and unreliably after."

A censored denominator produces exactly that sentence. Short units sit entirely inside the window and read 100%. Long units straddle it and read about 50%. The mechanism doesn't exist.

## A rotation you performed yourself is still censoring

This trap is hard to catch because you can *know* about the rotation and still get it wrong. Knowing about it answers a different question.

- "Did the rotation lose data?" No, it was archived deliberately.
- "Does the denominator start where the current log starts?" Nobody asked.

Ruling out log resets as a cause of *missing writes* doesn't rule them out as a cause of a *mis-specified denominator*. These are separate failures that go by the same name. Check the archives explicitly. If the "missing" records are in `*.v1.jsonl`, `*.archive` or the rotated file, the collector never failed.

```bash
# The decisive check, and it is cheap. Do it FIRST.
for f in <log> <archives>; do
  echo "$f: $(grep -c "$UNIT_ID" "$f") records"
done
```

## The same censoring propagates into any per-unit join

A metric that joins a full-lifetime event set against a window-truncated record set inherits the bug and hides it better:

```python
opened[sid]  # scanned from the WHOLE transcript, all of the unit's life
would[sid]   # built only from records in the CURRENT log
recall = len(opened & would) / len(opened)      # structurally unwinnable misses
```

Every event from before the log's window is a guaranteed miss, because the record that would have matched it is in the archive. Bound **both** sides of a per-unit join by time, or drop units whose record set is known to be truncated.

This matters most when a metric has a branch like "if the number is low, abandon the plan". Censoring only ever pushes the number down, so it creates false negatives and never false positives.

## Fix every direction, not just the flattering one

When you correct a censored join, check each metric separately for **the direction of its bias**. The metrics won't agree. Applying one bound to all of them is how a rig gets quietly tuned toward the answer you want.

Example: two metrics that read the same event set.

| metric | correct bound | why |
|---|---|---|
| recall | per-unit floor (first surviving record) | Fair to the retriever: score only events whose trigger this rig actually saw. |
| demand ("was it ever wanted?") | the log's global window | This is a fact about the user, not the retriever. The stricter floor **under-counts** it. |

The recall bound raises the number, and so does the demand bound. The decision rule ships when demand is zero, so tightening the demand bound would have pushed toward shipping on an artifact. **Before you choose a metric's bound, state out loud which way its bias points.**

## The freeze protects the collector, not the scorer

"The rig is frozen" usually means *stop changing what gets recorded*. A scorer reads data that already exists. Correcting it re-reads the same records and can't invalidate them.

Settle this with the fingerprint, not by argument. If your records carry a version hash, recompute it from its declared inputs and compare:

```python
h = sha256(collector_source + input_set_a + input_set_b + thresholds)
assert h.hexdigest()[:12] == recorded_rig     # scorer absent -> scorer is free
```

If the scorer is not an input, editing it changes no record and **does not restart the observation window**. If it *is* an input, treat it as part of the collector. In both cases, print the pre-fix and post-fix readings side by side. That makes the correction auditable, instead of a number that silently moved.

## Checklist

Before you report a coverage or recall figure:

1. What is the first timestamp in the log file I'm actually reading?
2. Were there earlier log files? Are the "missing" records in them?
3. Is my denominator filtered to `[window_start, window_end]`?
4. Does the apparent deficit correlate with the observed unit's age or duration? If yes, suspect censoring before suspecting the collector.
5. In every per-unit join, are both sides bounded by the same window?
6. Are the remaining misses real events or harness artifacts? For prompt collectors: `/compact`, `/clear`, command-name expansions and continuation summaries show up as `type:user` but never fire `UserPromptSubmit`.

## Worked example

A hook-coverage audit reported single-turn coverage of 102/102 (100%) and multi-turn coverage of 40/77 (52%). The result was read as "the hook fires on a session's first prompt and unreliably after" and logged as a threat to validity.

The log had been archived when the rig was frozen. The denominator counted every prompt in each session's transcript, including prompts from days before the archive. One session contributed 19 prompts and only 1 record. Its other records were in the archived log files, and its first 2 prompts came before the hook existed.

After correcting to the log's own window with a per-prompt timestamp join across all transcripts, coverage was **153/153 (100%)** for single-turn and multi-turn alike. The 3 apparent remaining misses were a single `/compact` operation: the command, its expansion and the continuation summary. There was no first-prompt bias.

The same censoring was also pulling down the recall metric. Half of its opportunities came from the one session split by the archive, so they could never be won. The scorer was fixed and both readings were printed; recall moved from 12% to 25%. The collector wasn't touched. Recomputing the rig fingerprint from its declared inputs proved that no record was invalidated and that the window did not restart.

## Differencing a weighted aggregate whose weights are recomputed each period lets composition pass for real movement

A level and a change need different estimators. Some aggregates recompute their weights each period, for example a volume-weighted average price, a traffic-weighted latency or a headcount-weighted score. You CANNOT difference such an aggregate across periods to measure what it averages. The difference includes the composition shift, and you can't tell that apart from real movement in the components.

The lesson came from a market report that claimed asking price per square foot was up 1%. The figure differenced a mean of several sub-market medians, weighted by each day's own listing counts. Over the window, the expensive sub-market gained listings and the cheap one didn't. Against real daily snapshots, the fixed-weight move was exactly 0.00%. Across many windows the shipped value was wrong on several, and the qualitative claim appeared or disappeared on some. The bias didn't always point the same way: on other windows, the mix shift HID a real decline.

A cheap diagnostic question: what happens to this number if every component holds perfectly still and only the weights move? If the number moves, it can't support a claim about the components.

Fix: use a fixed-weight (Laspeyres) index. Weight BOTH endpoints by the same base-period weights, and include only components present in both periods, so that only a component's own value can move the result. Keep the re-weighted aggregate for the LEVEL, which is a legitimate use, and change only the DELTA. Two traps:

1. Renaming the statistic doesn't fix it. A true pooled median differenced across periods has the same flaw, because the composition of the pool also shifts.
2. Decide which sibling statistics to fix by MEASURING them, not on principle. A sibling metric with the same shape was correctly left alone because its worst pure-mix swing was 1 unit against a 5-unit reporting threshold. Record that reasoning.

Also: `Math.round()` on a small negative value returns `-0`, which fails `strictEqual` against `0`. Normalize before you return a rounded percentage.

## A scan's population list is data that needs maintenance too, and nothing detects an item silently falling out of it

A "recent activity across all repos" digest is only as complete as the list of repos it goes through. If that list is a separately maintained inventory file instead of a live query of what it claims to cover (for example, `ls` over the actual directory), every scan built on it misses a new repo until someone adds it by hand. Nothing in the output shows the gap: a scan that is missing a repo looks the same as a scan that correctly found no activity in it.

In practice, a hand-maintained list like this can fall dozens of entries behind reality, including live projects under active development. Every digest in that period silently leaves them out. They are never filtered out; they are never queried at all. The drift can also hide as an ordinary-looking config diff that gets filed as "routine drift", because a stale-but-harmless diff and a stale-and-broken diff produce the same `git status` signature.

How to apply:

- For any pipeline whose population is a hand-maintained list (repos, services, accounts, feeds), regularly diff the list against the live source of truth (`ls`, an API's list-all endpoint, a directory glob). Don't trust that additions get remembered.
- Derive the list at run time with an explicit exclude-list, instead of hand-maintaining an include-list. An include-list fails silently closed: new things are invisible by default. An exclude-list fails silently open: new things are included by default, which is the safer direction for a coverage scan.
- If you inherit a hand-maintained list you can't convert right away, make "does this list still match reality" its own regular check, separate from "is the data in this list correctly formatted".

## A grep that matches a topic counts a confirmation line as if it were the event it confirms

Counting events in a log by grepping a keyword that names the *topic*, instead of the *specific line template*, silently double-counts whenever the same subsystem also logs a separate line acknowledging the event.

Example: a restart count came from grepping a log for restart-related lines and was roughly double the true number. The pattern matched both the line that performs the restart and a separate "post-restart OK" line logged right after it, so every restart was counted twice. The inflated number still supported the conclusion ("restarts happen often"), so nobody corrected it until the count was re-derived from the one unique line template.

The shape is the same as a censored denominator: the count looks like a fact about the system when it is really an artifact of the query. The mechanism is different, though. Here the log has more than one line PER event, and the pattern can't tell which one it's matching.

How to apply: before you report a count from `grep -c` (or similar) over a log, name the exact line template the pattern is meant to match. Then check whether any OTHER line logged around the same event would also match: an ack, a retry of the same attempt, or a summary line that repeats counts already logged individually. Match a substring unique to the one line that fires exactly once per event. Then check the result against an independent estimate. For example, dividing the count by the log's span in days and asking whether that rate is plausible would catch a 2x overcount before it ships.

## A timeout that kills a scan mid-list produces partial data that reads as complete

`$(timeout N ./scan.sh || echo 'failed')` does NOT discard the killed process's output. Command substitution keeps whatever the process already wrote to stdout, then appends the fallback string. If the scan emits a list incrementally, the caller gets a well-formed list that simply stops where the clock ran out, with an error line underneath that is easy to read past.

This is worse than an empty result, because downstream logic treats absence from the list as a positive fact. In one case, a truncated "open branches" list was injected into agent prompts under "DO NOT create work for anything listed below". A repo missing from the list therefore meant "no open branches", and many briefings asserted a clean slate that wasn't real. The scan had slowly grown past its timeout.

Fail closed instead:

1. Have the producer emit a completion sentinel from exactly ONE place, as its final output (`<!-- SCAN_COMPLETE ... -->`).
2. Have the consumer REQUIRE that sentinel and discard partial output ENTIRELY. Replace it with an explicit "no data; here is how to get it yourself" block. Never show partial results that read as authoritative.
3. Report unreachable items as NOT SCANNED instead of skipping them, because a skipped item looks the same as a clean one. Doing this can reveal items (for example, repos with no remote) that have been counted as clean for a long time.
4. Never compute a threshold decision (a cap, a quota, an alert) from an incomplete scan.
5. Prefer making the scan faster (for example, a parallel fan-out) over raising the timeout. These scans break because the input list grows, and it will keep growing.

Detection: a runner whose failure line appears at the BOTTOM of a long block is easy to miss by design. A per-run "Nth consecutive failure" tally can also badly undercount, because each run sees only its own truncated evidence.

## A blind-label map written once per call overwrites the previous judge's mapping and can invert multi-judge results

If a blind-judging script truncates and reshuffles a single shared label map (for example `blind-map.tsv`) on every call while its output files are per-judge, judging one run with two judges destroys the first judge's mapping. Only the last call's mapping survives. When the two calls drew opposite shuffles, reading the surviving map against the first judge's scores reversed the result: an arm that won by 5 appeared to lose by 5. Nothing errors and nothing looks wrong, because the file exists and parses.

Rule: key every blind or randomised label map by the same identifier as the output it decodes (for example `blind-map-<judge>.tsv`).

Recovery for a map that has already been overwritten: match each verdict's distinguishing claims to ground-truth features in the arm artifacts (for example, which arm actually built a repro harness). Confirm each mapping with two independent features before you trust any score.

## A trailing-N-days loop that skips the boundary day because a nearby section "already covers it" understates every trend by one day

A report built its "last 7 days, aggregated" table with `for i in $(seq 2 7)`. It started at 2-days-ago on purpose, on the theory that the "recent" block just above it (today and yesterday) already covered 1-day-ago. It didn't. The recent block printed raw per-session lines, not the aggregated per-day rollup the historical table computes for trend analysis. So the section labeled "last 7 days" really covered only 6 days, and the most recent full day's data was missing from every 7-day rate, on every run. The fix was `seq 1 7`. It was verified by running the loop body against the live data before and after, and confirming that the missing day now appeared with its real counts.

This applies well beyond one script. Any dashboard or report that builds "last N days" from two adjacent sections, a detailed "recent" block and an aggregated "historical" block, risks an off-by-one at the seam if the two sections draw on different data shapes. Before you trust a labeled window, count the iterations the loop actually performs. Then check whether the boundary day is really covered somewhere else or silently dropped. A range that looks intentional (a deliberate `seq 2 7`, not an obvious typo) is easy to read as correct by design when it is really an unchecked assumption.

## A file named `.jsonl` isn't guaranteed to be line-delimited; `tail -N | jq -r` cuts pretty-printed records in half

A report read an outcomes log with `tail -50 "$OUTCOME_FILE" | jq -r '...'`. The `.jsonl` extension implies one compact JSON object per line, but the writer actually emitted pretty-printed multi-line JSON (about 9 lines per record). `tail -50` took an arbitrary slice of the last few records, cut mid-object at line boundaries, and that slice is never valid JSON on its own. Every report showed the literal string "(parse error)" for that section, which quietly disabled the report's own "is the system producing value" check.

Fix: replace `tail -N | jq -r` with a slurp plus a timestamp filter:

```bash
jq -s --arg cutoff "$CUTOFF" -r '[.[] | select(.timestamp >= $cutoff)] | .[] | ...' "$OUTCOME_FILE"
```

`jq -s` parses the whole file as a stream of JSON values and doesn't care about newlines between or within records, so it works whether the writer emits compact or pretty-printed JSON. Filtering on the `.timestamp` field also makes a "last 7 days" label actually true. "Last 50 lines" is only an untested proxy for "last N records/days", and it miscounts even on a properly line-delimited file, because record size isn't constant.

How to apply: before you use `tail -N | jq` or any other line-count slice to sample the "last N" entries of a JSON log, confirm the file really has one compact object per line. Compare `wc -l` against a manual record count, or look at the raw file. If the writer ever serializes with pretty-printing on (`jq` without `-c`, Python `json.dumps` with `indent=`, and so on), every line-based reader of that file breaks. Two failure modes are easy to confuse here: an EMPTY result looks like "no data" and a PARSE ERROR looks like "the tool doesn't work". A `... || echo fallback` pattern can swallow either one silently and hide which of them happened.
