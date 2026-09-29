<!-- Load when: auditing a logger/collector's coverage, or a metric whose denominator comes from a different source than its numerator -->
# Measurement Windows and Censored Denominators

A collector's coverage is `records / opportunities`. The numerator comes from the log. The denominator usually comes from somewhere else, such as a transcript, a database, or the thing being observed. Those two sources rarely share a start time. When they don't, the ratio is wrong, and it looks like a behavioural finding.

## The rule

**Align the denominator to the collector's own observation window before you compute coverage.** The window starts at the first record in *the log you are reading*. It does not start when the collector was installed, and it does not start at the beginning of the observed unit's life.

```
window_start = min(ts) over the CURRENT log file
denominator  = opportunities where window_start <= ts <= window_end
```

Compute coverage both ways. If the uncorrected and corrected numbers differ, the gap comes from measurement, not behaviour. Explain it before you form any theory about the collector.

## Why the artifact is convincing

The bias is not random. It grows with how long the observed unit has been alive. A unit that predates the window adds its whole pre-window history to the denominator and nothing to the numerator, so the deficit concentrates in long-lived units.

Your segmentation variable may correlate with age. "Multi-turn vs single-turn", "active vs idle", "power user vs new user" and "long-running job vs one-shot" all do. When it does, the artifact shows up with a plausible mechanism already attached:

> "It fires reliably on the first event and unreliably after."

That sentence is what a censored denominator sounds like. Short units sit entirely inside the window and read 100%. Long units straddle it and read about 50%. No such mechanism exists.

## A rotation you performed yourself is still censoring

This trap is hard to catch because you can *know* about the rotation and still get it wrong. Knowing about it answers a different question.

- "Did the rotation lose data?" No, it was archived on purpose.
- "Does the denominator start where the current log starts?" Nobody asked.

Ruling out "log resets" as a cause of *missing writes* does not rule them out as a cause of a *mis-specified denominator*. These are separate failures that go by the same name. Check the archives explicitly. If the "missing" records are in `*.v1.jsonl`, `*.archive` or the rotated file, the collector never failed.

```bash
# The decisive check, and it is cheap. Do it FIRST.
for f in <log> <archives>; do
  echo "$f: $(grep -c "$UNIT_ID" "$f") records"
done
```

## The same censoring carries into any per-unit join

A metric that joins a full-lifetime event set against a window-truncated record set inherits the bug and hides it better:

```python
opened[sid]  # scanned from the WHOLE transcript, all of the unit's life
would[sid]   # built only from records in the CURRENT log
recall = len(opened & would) / len(opened)      # structurally unwinnable misses
```

Every event from before the log's window is a guaranteed miss, because the record that would match it is in the archive. Bound **both** sides of a per-unit join by time, or drop units whose record set you know is truncated.

This matters most when a metric has an "if the number is low, abandon the plan" branch. Censoring can only push the number down, so it produces false negatives and never false positives.

## Fix every direction, not just the flattering one

When you correct a censored join, check each metric separately for **which way its bias points**. The metrics will not agree. Applying one bound to all of them is how a rig gets quietly tuned toward the answer you want.

Example: two metrics reading the same event set.

| metric | correct bound | why |
|---|---|---|
| recall | per-unit floor (first surviving record) | fair to the retriever: only score events whose trigger this rig actually saw |
| demand ("was it ever wanted?") | the log's global window | a fact about the user, not the retriever; the stricter floor **under-counts** it |

The recall bound raises that number, and the demand bound raises its number too. In this case the decision rule shipped when demand was zero, so tightening the demand bound would have pushed toward shipping on an artifact. **State each metric's bias direction out loud before you choose its bound.**

## The freeze protects the collector, not the scorer

"The rig is frozen" usually means *stop changing what gets recorded*. A scorer reads data that already exists. Correcting it re-reads the same records and cannot invalidate them.

Settle this with the fingerprint, not by argument. If your records carry a version hash, recompute it from its declared inputs and compare:

```python
h = sha256(collector_source + input_set_a + input_set_b + thresholds)
assert h.hexdigest()[:12] == recorded_rig     # scorer absent -> scorer is free
```

If the scorer is not an input, editing it changes no record and **does not restart the observation window**. If the scorer *is* an input, treat it as part of the collector. In both cases, print the pre-fix and post-fix readings side by side so the correction can be audited, instead of leaving a number that silently changed.

## Checklist

Before you report a coverage or recall figure:

1. What is the first timestamp in the log file I am actually reading?
2. Were there earlier log files? Are the "missing" records in them?
3. Is my denominator filtered to `[window_start, window_end]`?
4. Does the apparent deficit correlate with the observed unit's age or duration? If yes, suspect censoring before you suspect the collector.
5. In every per-unit join, are both sides bounded by the same window?
6. Are the remaining misses real events or harness artifacts? (For prompt collectors: `/compact`, `/clear`, command-name expansions and continuation summaries appear as `type:user` but never fire `UserPromptSubmit`.)

## Worked example (generic)

A hook coverage report showed single-turn sessions at 100% and multi-turn sessions at about 52%. It was read as "the hook fires on a session's first prompt and fires unreliably after that."

The log had been archived when the rig was frozen, but the denominator counted every prompt in each session's transcript, including prompts from days earlier. One session contributed 19 prompts and only 1 record in the current log. Its other records were in the archived log files, and its first prompts came before the hook existed.

After correcting the denominator to the log's own window and joining on per-prompt timestamps, coverage was 100% for single-turn and multi-turn sessions alike. The few remaining "misses" were a single `/compact` operation: the command, its expansion and the continuation summary. There was no first-prompt bias.

The same censoring was also pulling down a recall metric, because half of its opportunities came from the one session split across archives and could never be won. The fix went into the scorer only, and both readings were printed. Recomputing the rig fingerprint showed that no record was invalidated and the window did not restart.

## Differencing a weighted aggregate whose weights are re-derived each period lets composition pass for the measurement

A level and a change need different estimators. You cannot difference a weighted aggregate across periods to measure what it averages if its weights are recomputed each period. Examples include a volume-weighted average price, a traffic-weighted latency and a headcount-weighted score. The difference includes the composition shift, and you cannot tell that shift apart from real movement in the components.

Typical failure: a report says "average price per unit is up 1%". The number is the difference of a mean of sub-group medians, weighted by each period's own item counts. The expensive sub-group added items while the cheap one did not. When the same data is weighted with fixed weights, the move is exactly 0%. The bias can go either way. In other windows, the mix shift can hide a real decline.

Cheap diagnostic question: *if every component holds perfectly still and only the weights move, does this number move?* If the answer is yes, the number cannot support a claim about the components.

Fix: use a fixed-weight (Laspeyres) index. Weight BOTH endpoints with the same base-period weights, and include only components present in both periods, so that only a component's own value can move the result. Keep the re-weighted aggregate for the LEVEL, where it is legitimate, and change only the DELTA. Two traps:

1. Renaming the statistic does not fix it. A true pooled median differenced across periods has exactly the same flaw, because the pool's composition also shifts.
2. Decide which sibling statistics to fix by MEASURING them, not on principle. A sibling metric may have the same shape while its worst pure-mix swing stays well under its reporting threshold. Leave that one alone and record the reasoning.

Also: `Math.round()` on a small negative value returns `-0`, which fails a strict equality check against `0`. Normalize before you return a rounded percentage.

## A scan's population list is unmaintained data too, and nothing detects an item silently falling out of it

A "recent activity across all X" digest is only as complete as the list of X it iterates. When that list is a separately maintained inventory file rather than a live query of what it claims to cover, a newly created item is invisible to every scan built on it until someone adds it by hand. Nothing in the output shows the gap. A scan that is missing an item looks identical to a scan that correctly found no activity in it.

This drift often hides as an ordinary-looking diff on a config file. A stale-but-harmless diff and a stale-and-broken one produce the same `git status` signature. Check whether the *content* of the drift is a coverage bug.

How to apply:

- For any pipeline whose population is a hand-maintained list (repos, services, accounts, feeds), periodically diff the list against the live source of truth, such as `ls`, an API's list-all endpoint or a directory glob.
- Prefer deriving the list at run time with an explicit exclude-list over maintaining an include-list by hand. An include-list fails silently closed: new items are invisible by default. An exclude-list fails silently open: new items are included by default, which is the safer direction for a coverage scan.
- If you inherit a hand-maintained list you can't convert right away, make "does this list still match reality?" its own periodic check, separate from "is the data in this list correctly formatted?"

## A category-shaped grep counts a confirmation line as if it were the event it confirms

Counting events in a log by grepping a keyword that names the *topic*, rather than the *specific line template*, double-counts whenever the same subsystem also logs a separate line acknowledging the event.

Typical failure: a restart count greps for restart-related lines. The pattern matches both the event line (`recreating container`) and the confirmation line logged right after it (`post-restart auth=ok`), so the count is roughly 2x too high. The inflated number still supports the qualitative story ("restarts happen often"), so nobody corrects it.

This produces the same kind of result as a censored denominator (the count looks like a fact about the system but is an artifact of the query), through a different mechanism: the log has more than one line PER event, and the pattern doesn't distinguish between them.

How to apply: before reporting a count from `grep -c` or an equivalent, name the exact line template the pattern is meant to match. Check whether any OTHER line logged near the same event would also match it, such as an ack, a retry of the same attempt, or a summary line that restates counts already logged individually. Match on a substring unique to the one line that fires exactly once per event. Sanity-check the result against an independent estimate, for example events divided by the log's span in days, compared with a plausible rate.

## A timeout that kills a scan mid-list gives partial data that reads as complete

`$(timeout N ./scan.sh || echo 'failed')` does NOT discard the killed process's output. Command substitution keeps whatever the process already wrote to stdout and then appends the fallback string. If the scan emits a list incrementally, the caller gets a well-formed list that stops wherever the clock ran out, with an easy-to-miss error line below it.

This is worse than an empty result, because downstream logic treats absence from the list as a positive fact. If the truncated list feeds a gate such as "do not duplicate any work listed below", then "not in the list" silently means "no existing work", and the gate asserts a clean slate that isn't real.

Fail closed:

1. Have the producer emit a completion sentinel from exactly ONE place, as its final output (for example `<!-- SCAN_COMPLETE ... -->`).
2. Have the consumer REQUIRE that sentinel and discard partial output WHOLE. Substitute an explicit "no data, here is how to get it yourself" block. Never show partial results that read as authoritative.
3. Report unreachable items as NOT SCANNED rather than skipping them. A skipped item is indistinguishable from a clean one.
4. Never compute a threshold decision (a cap, a quota, an alert) from an incomplete scan.
5. Make the scan faster (for example with parallel fan-out) rather than raising the timeout. Growth in the input list is what breaks these scans, and the list will keep growing.

Detection: a failure line at the BOTTOM of a long block is easy to miss. A per-run "Nth consecutive failure" tally can also badly undercount, because each run only sees its own truncated evidence.

## A per-call blind-map file overwrites the previous judge's mapping and silently inverts multi-judge results

If a blind-judging script truncates and reshuffles a single shared label-map file on every call, while writing each judge's output to its own per-judge file, then judging one run with two judges destroys the first judge's mapping. Only the last call's map survives. If the two calls drew opposite shuffles, reading the surviving map against the first judge's scores reports the winner as the loser. Nothing errors and nothing looks wrong: the file exists and parses.

Rule: any blind or randomized label map must be keyed by the same identifier as the output it decodes (for example `blind-map-<JUDGE_TAG>.tsv`).

Recovery for a map that was already overwritten: match each verdict's distinctive claims to ground-truth features in the arm artifacts (for example, which arm actually built a repro harness). Confirm each mapping with two independent features before you trust any score.

## A trailing-N-days loop that skips "yesterday" because a sibling section supposedly covers it drops a day from every trend

A report built a "last 7 days, aggregated" table with `for i in $(seq 2 7)`. It started at 2 days ago on the assumption that the "recent" block above (today and yesterday) already covered 1 day ago. It didn't. The recent block printed raw per-item lines, not the aggregated rollup the historical table computed. A section labeled "last 7 days" was really 6 days, and every 7-day rate computed from it silently left out the most recent full day. The fix was `seq 1 7`, verified by running the loop body against the live data before and after the change.

This applies well beyond one script. Any dashboard or report that builds "last N days" from two adjacent sections, a detailed "recent" block and an aggregated "historical" block, risks an off-by-one at the seam when the two sections use different data shapes. Before you trust a labeled window, count how many iterations the loop actually runs. Check whether the boundary day is claimed to be covered elsewhere or is actually dropped. A range that looks deliberate (`seq 2 7` rather than an obvious typo) is easy to read as correct by design when it is really an unverified assumption.

## A file named `.jsonl` is not guaranteed to be line-delimited

`tail -50 file.jsonl | jq -r '...'` assumes one compact JSON object per line. If the writer emits pretty-printed multi-line JSON, `tail -N` takes a fragment cut at arbitrary line boundaries in the middle of objects. That fragment is never valid JSON, so the consumer always fails to parse it, and a `|| echo "(parse error)"` fallback hides the failure in the report.

Fix: slurp and filter by timestamp instead of slicing by line count:

```bash
jq -s --arg cutoff "$CUTOFF" -r \
  '[.[] | select(.timestamp >= $cutoff)] | .[] | ...' "$FILE"
```

`jq -s` parses the whole file as a stream of JSON values and doesn't care about newlines between or within records, so it works with both compact and pretty-printed writers. Filtering on `.timestamp` also makes a "last 7 days" label true. "Last 50 lines" is an untested stand-in for "last N records or days" and miscounts even on properly line-delimited files, because records vary in size.

How to apply: before you use `tail -N | jq` or any other line-count slice on a JSON log, confirm the file really has one compact object per line. Compare `wc -l` with a record count, or just look at the raw file. A pretty-printing serializer anywhere upstream (`jq` without `-c`, `json.dumps(indent=...)`) breaks every line-based consumer. Two failure modes are easy to confuse: an EMPTY result looks like "no data", a PARSE ERROR looks like "the tool doesn't work", and a `... || echo fallback` pattern can swallow either one.

## A per-call figure is not an optimization target until you know its share of total usage

A per-call number, such as a large token count per call that is mostly injected startup context, looks like a target on its own. First sum the job over a real window and divide by total usage. A job that looks expensive per call can be well under 1% of total tokens and cost, while one class of sessions accounts for about half.

- Deduplicate transcript usage by `message.id`.
- Weight by model price, including cache pricing (cache reads cost about 0.1x the input price, cache writes about 1.25x).
- Rank optimization options by each job's actual share of total usage, not by its per-call size.

Corollary: before routing a classifier to a smaller model, replay real production traffic. A small hand-picked golden set can show parity that does not hold on a replay of real batches. A small eval set does not prove the real traffic mix behaves the same way.
