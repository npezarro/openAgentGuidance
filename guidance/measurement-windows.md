<!-- Load when: auditing a logger/collector's coverage, or a metric whose denominator comes from a different source than its numerator -->
# Measurement Windows and Censored Denominators

A collector's coverage is `records / opportunities`. The numerator comes from the log. The denominator usually comes from somewhere else, such as a transcript, a database, or the thing being observed. Those two sources almost never share a start time. When they don't, the ratio is wrong in a way that looks like a behavioural finding.

## The rule

**Align the denominator to the collector's own observation window before you compute coverage.** The window starts at the first record in *the log you are reading*. It does not start when the collector was installed, and it does not start at the beginning of the observed unit's life.

```
window_start = min(ts) over the CURRENT log file
denominator  = opportunities where window_start <= ts <= window_end
```

Compute coverage both ways. If the uncorrected and corrected numbers differ, the gap comes from measurement, not behaviour. Explain that gap before you build any theory about the collector.

## Why the artifact is convincing

The bias is not random. It grows with how long the observed unit has been alive. A unit that started before the window adds its whole pre-window history to the denominator and nothing to the numerator, so the deficit shows up mostly in long-lived units.

Many segmentation variables correlate with age: "multi-turn vs single-turn", "active vs idle", "power user vs new user", "long-running job vs one-shot". If yours does, the artifact comes with a plausible mechanism already attached:

> "It fires reliably on the first event and unreliably after."

That sentence is what a censored denominator sounds like. Short units sit entirely inside the window and read 100%. Long units straddle the window start and read about 50%. No such mechanism exists.

## A rotation you performed yourself is still censoring

This trap is hard to catch because you can *know* about the rotation and still get it wrong. Knowing about it answers a different question.

- "Did the rotation lose data?" No, it was archived on purpose.
- "Does the denominator start where the current log starts?" Nobody asked.

Ruling out log resets as a cause of *missing writes* does not rule them out as a cause of a *mis-specified denominator*. These are two separate failures that share a name. Check the archives directly. If the "missing" records are sitting in `*.v1.jsonl`, `*.archive`, or the rotated file, the collector never failed.

```bash
# The decisive check is cheap. Do it FIRST.
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

This matters most when a metric has an "if the number is low, abandon the plan" branch. Censoring only ever pushes the number down, so it produces false negatives and never false positives.

## Fix every direction, not just the flattering one

When you correct a censored join, check each metric separately for **which way its bias points**. The metrics will not agree. Applying one bound to all of them is how a measurement rig quietly gets tuned toward the answer you want.

Example: two metrics read the same event set.

| metric | correct bound | why |
|---|---|---|
| recall | per-unit floor (first surviving record) | fair to the retriever: score only the events whose trigger this rig actually saw |
| demand ("was it ever wanted?") | the log's global window | this is a fact about the user, not the retriever; the stricter floor **under-counts** it |

Both bounds raise their numbers. But the decision rule shipped the feature when demand was zero, so using the stricter bound on demand would have pushed toward shipping on an artifact. **State each metric's bias direction out loud before you choose its bound.**

## The freeze protects the collector, not the scorer

"The rig is frozen" usually means *stop changing what gets recorded*. A scorer reads data that already exists. Correcting the scorer re-reads the same records and cannot invalidate them.

Settle this with a fingerprint, not an argument. If your records carry a version hash, recompute it from its declared inputs and compare:

```python
h = sha256(collector_source + input_set_a + input_set_b + thresholds)
assert h.hexdigest()[:12] == recorded_rig     # scorer absent -> scorer is free
```

If the scorer is not one of the inputs, editing it changes no record and **does not restart the observation window**. If it *is* an input, treat it as part of the collector. Either way, print the pre-fix and post-fix readings side by side, so the correction can be audited and the number doesn't just move silently.

## Checklist

Before you report a coverage or recall figure:

1. What is the first timestamp in the log file I am actually reading?
2. Were there earlier log files? Are the "missing" records in them?
3. Is my denominator filtered to `[window_start, window_end]`?
4. Does the apparent deficit correlate with the observed unit's age or duration? If it does, suspect censoring before you suspect the collector.
5. In every per-unit join, are both sides bounded by the same window?
6. Are the remaining misses real events or harness artifacts? (For prompt collectors: `/compact`, `/clear`, command-name expansions, and continuation summaries show up as `type:user` but never fire `UserPromptSubmit`.)

## Worked example

A prompt hook's reported coverage was 100% for single-turn sessions and 52% for multi-turn sessions. This was read as "the hook fires on a session's first prompt and fires unreliably after that", and it was logged as a threat to validity.

The log had been archived when the rig was frozen. The denominator still counted every prompt in each session's transcript, including prompts from days before the archive. One session contributed 19 prompts and only 1 record. Its other records were in the archived log files, and its first 2 prompts were older than the hook itself.

After correcting to the log's own window with a per-prompt timestamp join across all transcripts, coverage was 100% for single-turn and multi-turn sessions alike. The 3 remaining misses were all one `/compact` operation: the command, its expansion, and the continuation summary. There was no first-prompt bias.

The same censoring was also pulling down the recall metric. Half of its opportunities came from the one session split across archives, so they could never be won. The fix went into the scorer, and the before and after readings were printed together. The collector was not touched. Recomputing the rig fingerprint from its declared inputs proved that no record was invalidated and the window did not restart.

## Related measurement failure modes

### Differencing a weighted aggregate whose weights are recomputed each period lets composition pass for real change

A level and a change need different estimators. Some aggregates recompute their weights every period: a volume-weighted average price, a traffic-weighted latency, a headcount-weighted score. You CANNOT difference these across periods to measure the thing they average. The difference includes the composition shift, and that shift looks exactly like real movement in the components.

Example: a daily market report said "asking price per square foot is up 1%". The number was the difference between two means of sub-market medians, each weighted by that day's listing counts. During the window, the expensive sub-market added listings and the cheap one did not. With fixed weights, the move was exactly 0.00%. Across many windows the shipped value was wrong on several, and the qualitative claim appeared or disappeared on some. The bias went both ways: on other windows the mix shift hid a real decline.

Diagnostic question (cheap to ask): if every component holds perfectly still and only the weights change, does this number move? If yes, the number cannot support a claim about the components.

Fix: use a fixed-weight (Laspeyres) index. Weight BOTH endpoints by the same base-period weights, and include only components present in both periods, so only a component's own value can move the result. Keep the re-weighted aggregate for the LEVEL, where it is legitimate, and change only the DELTA. Two traps:
1. Renaming the statistic does not fix it. A true pooled median differenced across periods has the same flaw, because the pool's composition also shifts.
2. Decide which sibling statistics need the fix by MEASURING them, not by comparing an error's size to a threshold's size. Consider a 1-unit error against a 5-unit reporting threshold applied with a sharp cutoff on rounded integers. A 1-unit error is exactly enough to cross that threshold when the true value sits next to it. In the example, a sibling metric was judged immaterial on that reasoning, and the error flipped the shipped advice on some real days.

Also: `Math.round()` on a small negative value returns `-0`, which fails `strictEqual` against `0`. Normalize before you return a rounded percentage.

### A scan's population list is unmaintained data, and nothing detects an item silently falling out of it

A digest of "recent activity across all repos" is only as complete as the list of repos it loops over. If that list is a hand-maintained inventory file instead of a live query (for example `ls` over the actual directory), new repos are invisible to every scan built on it until someone adds them by hand. The output gives no sign of the gap: a scan that is missing a repo looks the same as a scan that correctly found no activity there.

Example: an inventory list drifted dozens of repos behind the real directory, including several under active development. Every digest silently left them out. They weren't filtered out; they were never queried. The drift appeared as an ordinary-looking `git status` diff on a config file. Earlier sessions filed it as routine drift without checking whether the diff's content was a coverage bug. A stale-but-harmless config diff and a stale-and-broken one have the same `git status` signature.

How to apply:
- For any pipeline whose population is a hand-maintained list (repos, services, accounts, feeds), periodically diff the list against the live source of truth: `ls`, an API's list-all endpoint, or a directory glob.
- Prefer deriving the list at run time with an explicit exclude-list over maintaining an include-list. An include-list fails silently-closed (new things are invisible by default). An exclude-list fails silently-open (new things are included by default). Open is the safer direction for a coverage scan.
- If you inherit a hand-maintained list you can't convert right away, treat "does this list still match reality" as its own periodic check, separate from "is the data in this list correctly formatted".

### A membership test, not just the membership list, can silently drop units from a scan

A correct list can still be filtered wrong. Scripts that gated on `[ -d "$repo_dir/.git" ]` treated every git worktree as nonexistent, because in a worktree `.git` is a FILE (a `gitdir:` pointer). Repos that were on the list the whole time had months of commits invisible to a duplicate-work gate and an activity digest. The fix was `-d` to `-e`, which is true for a directory OR a gitdir file and still excludes non-repos.

A filter predicate ("is a directory", "matches this regex") can encode an assumption about one subtype that a valid alternate subtype (worktree, symlink, bare repo) fails. Before trusting a scan's silence, check that each item is ON the list and also PASSES the filter.

### A topic-shaped grep counts a confirmation line as if it were the event it confirms

If you count events in a log by grepping a keyword that names the *topic* instead of the *specific line template*, you will double-count whenever the same subsystem also logs a separate line confirming the event.

Example: a restart count came back roughly twice the true value. The pattern matched both the line that performs the restart (`recreating container`) and a different line logged right after it to confirm the restart (`post-restart auth=ok`). The inflated number still supported the qualitative story ("restarts happen often"), so it went uncorrected until someone re-derived it from the one unique line template.

The result looks like a fact about the system, the same as with a censored denominator, but the mechanism here is different: the log has more than one line PER event, and the pattern doesn't distinguish between them.

How to apply: before you report a count from `grep -c` (or equivalent), name the exact line template the pattern is supposed to match. Check whether any OTHER line logged near the same event would also match: an ack, a retry of the same attempt, a summary line that restates counts already logged. Match on a substring unique to the one line that fires exactly once per event. Sanity-check the result against an independent estimate, such as count divided by the log's span in days, to see whether the rate is plausible.

### A timeout that kills a scan mid-list produces partial data that reads as complete data

`$(timeout N ./scan.sh || echo 'failed')` does NOT discard the killed process's output. Command substitution keeps whatever the process already wrote to stdout, then appends the fallback string. If the scan writes its list incrementally, the caller gets a well-formed list that stops wherever time ran out, with an easy-to-miss error line underneath.

This is worse than an empty result, because downstream logic treats absence from the list as a positive fact. Example: a dedup gate injected the truncated list under "DO NOT create PRs for any work listed below". "Repo not in the list" then silently meant "repo has no open branches". The scan had grown past its timeout, every briefing was affected, and several briefings showed a clean slate that wasn't real.

Fail closed instead:
1. Have the producer emit a completion sentinel from exactly ONE place, as its final output (`<!-- SCAN_COMPLETE ... -->`).
2. Have the consumer REQUIRE the sentinel. If it's missing, discard the whole partial output and substitute an explicit "no data, here is how to get it yourself" block. Never show partial results that read as authoritative.
3. Report unreachable items as NOT SCANNED instead of skipping them. A skipped item looks the same as a clean one. (Doing this can surface items that have been counted as clean for months, such as repos with no remote.)
4. Never compute a threshold decision (a cap, a quota, an alert) from an incomplete scan.
5. Make the scan faster (parallel fan-out) instead of raising the timeout. These scans break because the input list grows, and it will keep growing.

Detection: a failure line at the BOTTOM of a long block is easy to miss. A per-run "Nth consecutive failure" tally can also undercount badly, because each run only sees its own truncated evidence.

### A per-call blind-map file overwrites the previous judge's mapping and can silently invert multi-judge results

A blind-judging script truncated and RESHUFFLED its arm-label map on every call. The judge output files were already named per judge, but the map that DECODES them was not. Judging one run with two judges therefore destroyed the first judge's mapping and kept only the last call's. In one run the two calls drew opposite shuffles: reading the surviving map against the first judge's scores would have reported an arm LOSING by 5 when it actually WON by 5. Nothing errored, and nothing looked wrong; the file existed and parsed.

Rule: key any blind or randomized label map by the same identifier as the output it decodes (for example `blind-map-<JUDGE>.tsv`).

Recovering an already-overwritten map: match each verdict's distinguishing claims to ground-truth features in the arm artifacts (for example, which arm actually built a repro harness). Confirm each mapping with two independent features before trusting any score.

### A trailing-N-days loop that skips "yesterday" because a sibling section supposedly covers it understates every trend by one day

A report built its "last 7 days, aggregated" table with `for i in $(seq 2 7)`. It started at 2 days ago on the theory that the "recent" block above it (today and yesterday) already covered day 1. It didn't: the recent block printed raw per-session lines, not the aggregated per-day rollup used for trend analysis. A section labeled "last 7 days" was really 6 days, and the most recent full day was missing from every 7-day rate, every run. The fix was `seq 1 7`. It was verified by running the loop body against the live data before and after the change.

Any report that builds "last N days" from two adjacent sections (a detailed "recent" block plus an aggregated "historical" block) is at risk of an off-by-one at the seam when the two sections use different data shapes. Before you trust a labeled window, count how many iterations the loop actually runs. Check whether the boundary day is claimed to be covered elsewhere or is simply dropped. A range that looks deliberate (`seq 2 7` rather than an obvious typo) is easy to read as correct by design when it is really an unverified assumption.

### A file named `.jsonl` is not guaranteed to be line-delimited

`tail -50 outcomes.jsonl | jq -r '...'` assumes one compact JSON object per line. If the writer emits pretty-printed JSON (several lines per record), `tail -N` cuts records in the middle, which is never valid JSON, and the section renders "(parse error)" every time.

Fix: `jq -s --arg cutoff "$CUTOFF" -r '[.[] | select(.timestamp >= $cutoff)] | .[] | ...'`. Slurp mode parses the file as a stream of JSON values regardless of newlines, so it works for both compact and pretty-printed writers. Filtering on the timestamp field also makes a "last 7 days" label true. "Last 50 lines" is an untested proxy that would miscount even on a properly line-delimited file, because record size isn't constant.

Before using `tail -N | jq` or any line-count slice to sample the last N entries of a JSON log, confirm the file really has one compact object per line: compare `wc -l` against a record count, or look at the raw file. Any writer with indentation turned on (`jq` without `-c`, `json.dumps(indent=...)`) breaks every line-based consumer. An EMPTY result ("no data") and a PARSE ERROR ("tool broken") can both be swallowed by a `... || echo fallback` pattern, which hides which one happened.

### A per-call figure is not an optimization target until it is a share of total usage

A per-call number (for example, 45K tokens per call, most of it injected startup context) looks like a target on its own. First sum the job over a real window and divide by total usage. In one audit, two small-model triage jobs at that per-call size were under 1% of 30-day tokens and cost, while sessions on the largest model were about half of total usage. Dedupe transcript usage by message ID, weight by model price (cache reads are about 0.1x, cache writes about 1.25x), and rank levers by each job's actual share, not its per-call size.

Corollary: replay real production traffic before you move a classifier to a smaller model. A small hand-picked golden set showed parity that a replay against real traffic did not hold up. A small eval set does not prove the real traffic mix behaves the same way.

### A failover between hosts leaves the old host's local logs as a report's silent, stale source

A reporting job built its prompt from log files local to the host it ran on. The workload it reported on moved its primary execution to a new host, with the old host kept as fallback, but the reporting job stayed where it was. From then on every run, including one that scored 0% on a real violation, executed and was scored on the new host, and none of it reached the report. The report kept showing stale pre-migration runs, which rendered as a normal thin result, not an error. It was caught only by checking the new host's logs directly and diffing them against the report's input.

When a scheduled job's execution host can fail over, every job that reports on its output must read from wherever the job actually last ran, or from a centralized log, never from a fixed per-host path. A failover that correctly keeps the workload running can make every host-local report about it silently wrong.

### A failure logged with cost `0` looks the same as a real zero-cost event once summed

A shared service template logged every job that died before producing a result (timeout, thrown error, credits exhausted) as `{costUsd: 0, ok: false}` in a spend ledger that a monitor summed. Once summed, a `0` from a genuinely free call and a `0` meaning "cost unknown" are identical. Total spend silently left out the real, possibly nonzero, cost of every failed job, while those jobs still counted toward the job total.

Fix: on every failure path, log `costUsd: null, costUnknown: true`. Have the aggregator tally `unknownCostJobs` separately instead of coercing `null` back to `0` before summing. A read side that already handles `null` (`float(r.get("costUsd") or 0)`) doesn't help if the write side never produces `null`.

Any ledger or metric that sums a numeric field (cost, duration, bytes) must distinguish "measured zero" from "never measured" where the value is written, not just where it is read. A failure logged with its natural zero value takes part in every future sum as if it really contributed nothing.
