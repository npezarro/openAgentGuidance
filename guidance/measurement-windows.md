<!-- Load when: auditing a logger/collector's coverage, or a metric whose denominator comes from a different source than its numerator -->
# Measurement Windows and Censored Denominators

A collector's coverage is `records / opportunities`. The numerator comes from the log. The denominator usually comes from somewhere else, such as a transcript, a database, or the thing being observed. Those two sources rarely share a start time. When they don't, the ratio is wrong in a way that looks like a behavioural finding.

## The rule

**Align the denominator to the collector's own observation window before you compute coverage.** The window starts at the first record in *the log you are reading*. It does not start when the collector was installed, and it does not start at the beginning of the observed unit's life.

```
window_start = min(ts) over the CURRENT log file
denominator  = opportunities where window_start <= ts <= window_end
```

Compute coverage both ways. If the uncorrected and corrected numbers differ, the gap comes from measurement, not behaviour. Explain it before you form any theory about the collector.

## Why the artifact is convincing

The bias is not random. It grows with how long the observed unit has been alive. A unit that predates the window adds its whole pre-window history to the denominator and nothing to the numerator, so the deficit concentrates in long-lived units.

Your segmentation variable may correlate with age. "Multi-turn vs single-turn", "active vs idle", "power user vs new user" and "long-running job vs one-shot" all do. When that happens, the artifact arrives looking like a plausible mechanism:

> "It fires reliably on the first event and unreliably after."

That sentence is what a censored denominator sounds like. Short units sit entirely inside the window and read 100%. Long units straddle it and read about 50%. No such mechanism exists.

## A rotation you performed yourself is still censoring

This is the trap that makes the bug hard to catch. You can *know* about the rotation and still get it wrong, because knowing about it answers a different question:

- "Did the rotation lose data?" No, it was archived on purpose.
- "Does the denominator start where the current log starts?" Nobody asked.

Ruling out log resets as a cause of *missing writes* does not rule them out as a cause of a *mis-specified denominator*. These are separate failures with the same name. Check the archives explicitly. If the "missing" records are in `*.v1.jsonl`, `*.archive` or the rotated file, the collector never failed.

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

Every event that happened before the log's window is a guaranteed miss, because the record that would have matched it is in the archive. Time-bound **both** sides of a per-unit join, or drop units whose record set is known to be truncated.

This matters most when a metric has an "if the number is low, abandon the plan" branch. Censoring only ever pushes the number down, so it produces false negatives and never false positives.

## Fix every direction, not just the flattering one

When you correct a censored join, check each metric separately for **which way its bias points**. The metrics will not agree. Applying one bound everywhere is how a rig quietly gets tuned toward the answer you want.

Example: two metrics that read the same event set.

| metric | correct bound | why |
|---|---|---|
| recall | per-unit floor (first surviving record) | fair to the retriever: only score events whose trigger this rig actually saw |
| demand ("was it ever wanted?") | the log's global window | a fact about the user, not the retriever; the stricter floor **under-counts** it |

The recall bound raises recall. Using the stricter floor for demand would lower demand. If the decision rule ships when demand is zero, tightening the demand bound pushes toward shipping on an artifact. **State each metric's bias direction out loud before you choose its bound.**

## The freeze protects the collector, not the scorer

"The rig is frozen" usually means *stop changing what gets recorded*. A scorer reads data that already exists. Correcting it re-reads the same records and cannot invalidate them.

Settle this with the fingerprint, not by argument. If your records carry a version hash, recompute it from its declared inputs and compare:

```python
h = sha256(collector_source + input_set_a + input_set_b + thresholds)
assert h.hexdigest()[:12] == recorded_rig     # scorer absent -> scorer is free
```

If the scorer is not an input, editing it changes no record and **does not restart the observation window**. If it *is* an input, treat it as part of the collector. In either case, print the pre-fix and post-fix readings side by side so the correction can be audited and the number doesn't silently move.

## Checklist

Before you report a coverage or recall figure:

1. What is the first timestamp in the log file I am actually reading?
2. Were there earlier log files? Are the "missing" records in them?
3. Is my denominator filtered to `[window_start, window_end]`?
4. Does the apparent deficit correlate with the observed unit's age or duration? If it does, suspect censoring before you suspect the collector.
5. In every per-unit join, are both sides bounded by the same window?
6. Are the remaining misses real events, or harness artifacts? (For prompt collectors: `/compact`, `/clear`, command-name expansions and continuation summaries appear as `type:user` but never fire `UserPromptSubmit`.)

## Worked example (shape only)

A prompt-hook audit reported coverage of 100% for single-turn sessions and 52% for multi-turn sessions. This was read as "the hook fires on a session's first prompt and unreliably after" and logged as a validity threat.

The log had been archived at a rig freeze. The denominator counted every prompt in each session's transcript, including prompts from days before the freeze. One session contributed 19 prompts and 1 record. Its other records were in the archived log files, and its first prompts came before the hook existed.

After correcting to the log's own window with a per-prompt timestamp join, coverage was 100% for single-turn and multi-turn sessions alike. The three remaining misses were one `/compact` operation: the command, its expansion and the continuation summary. There was no first-prompt bias.

The same censoring was also pushing down a recall metric, where half the opportunities came from the one archive-split session and could not be won by construction. The fix went into the scorer, with both readings printed. The collector was not touched. Recomputing the rig fingerprint proved that no record was invalidated and the window did not restart.

## Related failure modes

### Differencing a weighted aggregate whose weights are re-derived each period lets composition pose as movement

A level and a change need different estimators. Some weighted aggregates recompute their weights every period: a volume-weighted average price, a traffic-weighted latency, a headcount-weighted score. You cannot difference these across periods to measure what they average. The composition shift comes along for free, and it looks the same as real movement in the components.

Typical shape: a "price per unit is up 1%" claim built from a listing-count-weighted mean of sub-market medians. An expensive sub-market gained listings and a cheap one did not. Against the same snapshots, a fixed-weight version moved exactly 0.00%. The bias goes both ways: on other windows the mix shift *hid* a real decline.

Cheap diagnostic: what happens to this number if every component holds perfectly still and only the weights move? If the number moves, it cannot support a claim about the components.

Fix: use a fixed-weight (Laspeyres) index. Weight **both** endpoints by the same base-period weights and limit the calculation to components present in both periods, so only a component's own value can move the result. Keep the re-weighted aggregate for the **level**, where it is legitimate, and change only the **delta**. Traps:

1. Renaming the statistic does not fix it. A true pooled median differenced across periods has the same flaw, because the pool's composition also shifts.
2. Scope the fix by **measuring** sibling statistics, not by fixing them on principle. A sibling metric whose worst pure-mix swing is well under its reporting threshold can be left alone, with the reasoning written down.

Also: `Math.round()` on a small negative value returns `-0`, which fails `strictEqual` against `0`. Normalize before you return a rounded percentage.

### A scan's population list is unmaintained data, and nothing detects an item silently falling out of it

A "recent activity across all repos" digest is only as complete as the list it iterates. If that list is a hand-maintained inventory file and not a live query of what it claims to cover (such as `ls` over the actual directory), every scan built on it misses a new item until someone adds it by hand. Nothing in the output shows the gap: a scan missing an item looks the same as a scan that correctly found no activity in it. A stale-but-harmless config diff and a stale-and-broken one also produce the same `git status` output, so drift in the list gets filed as routine.

How to apply:

- For any pipeline whose population (repos, services, accounts, feeds) is a hand-maintained list, periodically diff the list against the live source of truth: `ls`, an API's list-all endpoint, or a directory glob.
- Prefer building the list at run time with an explicit **exclude**-list. An include-list fails silently closed, because new items are invisible by default. An exclude-list fails silently open, because new items are included by default, which is the safer direction for a coverage scan.
- If you can't convert the list right away, treat "does this list still match reality" as its own periodic check, separate from "is the list well-formed".

### A membership test can silently drop units even when the list is correct

A correct list can still be filtered wrong. Scripts that gate on `[ -d "$repo_dir/.git" ]` treat every git worktree as nonexistent, because in a worktree `.git` is a **file** (a `gitdir:` pointer). Those repos stay on the list but are invisible to every gate that uses the test, possibly for months. Fix: `-d` becomes `-e`, which is true for a directory or a gitdir file and still excludes non-repos.

In general, a filter predicate ("is a directory", "matches this regex") can encode an assumption about one subtype that a valid alternate subtype (worktree, symlink, bare repo) fails. Check that items are both **on** the list and **pass** its filter before you trust a scan's silence.

### A topic-shaped grep counts a confirmation line as if it were the event it confirms

If you count events by grepping a keyword that names the *topic* and not the *specific line template*, you double-count whenever the same subsystem also logs a separate line acknowledging the event. Example: grepping for "restart" matches both `recreating container` (the event) and `post-restart auth=ok` (an acknowledgement logged right after it). The inflated count was about 2x and still plausible, so it went uncorrected.

How to apply: before you report a count from `grep -c` (or similar), name the exact line template the pattern should match. Then check whether any **other** line logged around the same event would also match: an ack, a retry of the same attempt, or a summary that restates counts already logged. Match on a substring unique to the one line that fires exactly once per event. Sanity-check against an independent estimate, such as events divided by the log's day span: does the rate look plausible?

### A timeout that kills a scan mid-list produces partial data that reads as complete

`$(timeout N ./scan.sh || echo 'failed')` does **not** discard the killed process's output. Command substitution keeps whatever the process already wrote to stdout, then appends the fallback string. If the scan emits a list incrementally, the caller gets a well-formed list that stops wherever time ran out, with an easy-to-miss error line underneath.

This is worse than an empty result, because downstream logic treats absence from the list as a positive fact. For example, "not in the list" gets read as "has no open branches" in a do-not-duplicate-work gate. That is a clean slate asserted from truncated evidence.

Fail closed:

1. Have the producer emit a completion sentinel from exactly **one** place, as its final output (`<!-- SCAN_COMPLETE ... -->`).
2. Have the consumer **require** the sentinel and discard partial output entirely. Put an explicit "no data, here is how to get it yourself" block in its place. Never show partial results that look authoritative.
3. Report unreachable items as NOT SCANNED; don't skip them. A skipped item looks the same as a clean one. (Doing this tends to expose items, such as repos with no remote, that were counted as clean for a long time.)
4. Never compute a threshold decision (a cap, a quota, an alert) from an incomplete scan.
5. Make the scan faster (parallel fan-out) in preference to raising the timeout. Timeouts like this break because the input list grows, and it will keep growing.

Detection: a failure line at the **bottom** of a long block is easy to miss. A per-run "Nth consecutive failure" tally can also undercount badly, because each run only sees its own truncated evidence.

### A per-call blind map file overwrites the previous judge's mapping and silently inverts multi-judge results

If a blind-evaluation script truncates and **reshuffles** a single shared label map (`: > $MAP`) on every call while writing per-judge output files, judging one run with two judges destroys the first judge's mapping. Only the last call's mapping survives. Reading the surviving map against the first judge's scores can flip the winner. Nothing errors and nothing looks wrong: the file exists and parses.

Rule: any blind or randomised label map must be keyed by the same identifier as the output it decodes (for example `blind-map-<judge>.tsv`). To recover a map that was already overwritten, match each verdict's distinguishing claims to ground-truth features in the arm artifacts. Confirm each mapping with two independent features before you trust any score.

### A trailing-N-days loop that skips "yesterday", assuming a sibling section covers it, understates every trend by a day

A report built a "last 7 days, aggregated" table with `for i in $(seq 2 7)`, starting at two days ago on the theory that the "recent" block above it (today and yesterday) already covered day 1. It didn't. The recent block printed raw per-session lines, not the aggregated per-day rollup used for trends. A section labelled "last 7 days" really covered 6, and the most recent full day was missing from every 7-day rate. Fix: `seq 1 7`. Verify by running the loop body against live data before and after the change.

General rule: when a report computes "last N days" as two adjacent sections (detailed recent plus aggregated historical) that pull different data shapes, check the seam. Count how many iterations the loop actually performs. If the boundary day is claimed to be covered elsewhere, confirm it really is. A loop range that looks deliberate is easy to read as correct by design when it is really an unverified assumption.

### A `.jsonl` file is not guaranteed to be line-delimited

`tail -50 file.jsonl | jq -r ...` assumes one compact JSON object per line. If the writer pretty-prints (jq without `-c`, Python `json.dumps(indent=...)`), `tail -N` grabs a fragment cut mid-object, which never parses. The section then renders `(parse error)` on every run.

Fix: slurp and filter by timestamp, not by line count:

```bash
jq -s --arg cutoff "$CUTOFF" -r '[.[] | select(.timestamp >= $cutoff)] | .[] | ...' file.jsonl
```

`jq -s` parses the whole file as a stream of JSON values regardless of newlines, so it works for compact and pretty-printed writers. Filtering on `.timestamp` also makes a "last 7 days" label true. "Last 50 lines" is not a valid stand-in for "last N records" or "last N days" even in a properly line-delimited file, because record sizes vary.

Before you use any line-count slice on a JSON log, confirm the format: compare `wc -l` with a record count, or look at the raw file. Watch for `... || echo fallback` patterns that turn both an EMPTY result ("no data") and a PARSE ERROR ("tool broken") into the same quiet output.

### A per-call figure is not an optimization target until it is a share of total usage

A per-call number (for example, 45K tokens per call, mostly injected startup context) looks like a target on its own. First, sum the job over a real window and divide by total usage. A job that is large per call can turn out to be well under 1% of total tokens and cost, while one model tier accounts for half the spend. Dedupe transcript usage by message ID, weight by model price (cache reads around 0.1x, cache writes around 1.25x), and rank levers by each job's actual share, not by its per-call size.

Corollary: before routing a classifier to a smaller model, replay real production traffic. A small hand-picked golden set can show parity that a replay against real batches does not. A small eval set does not prove the real traffic mix behaves the same way.

### A primary/fallback host migration leaves the old host's local logs as a report's silent, stale source

If a report builds its input from local files on the host where the report job runs, and the workload it reports on fails over or migrates to another host, the report keeps reading the old host's files. Every run on the new host, including real violations and failures, never reaches the report. The stale section looks like a normal thin result, not an error. It gets caught only by inspecting the new host directly and diffing its logs against the report.

Rule: when a scheduled job's execution host can change, every job that reports on its output must read from wherever the job actually last ran (or from a centralized log), not from a fixed per-host path. A failover that correctly keeps the workload running can make every host-local report about it silently wrong.

### A failure logged with cost `0` is indistinguishable from a legitimate zero-cost event once summed

If a job that dies before producing a result (timeout, thrown error, credits exhausted) is logged as `{costUsd: 0, ok: false}`, a ledger that sums cost cannot tell "free" from "unknown". Total spend silently leaves out every failed job's real, possibly nonzero, cost, while the job still counts toward `jobs`. Spend is undercounted and no error appears.

Fix at the **write** site: log `costUsd: null, costUnknown: true` on every failure path. Have the aggregator count unknown-cost jobs separately, and don't coerce `null` back to `0` before summing. A read side that defends against `null` (`float(r.get("costUsd") or 0)`) doesn't help if the writer never emits `null`.

Generally: any ledger or metric that sums a numeric field (cost, duration, bytes) must separate "measured zero" from "never measured" where it is written. Logging a failure's natural zero value lets it join every future sum as if it really contributed nothing.
