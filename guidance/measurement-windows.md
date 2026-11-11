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

The bias is not random. It grows with how long the observed unit has been alive. A unit that predates the window adds its whole pre-window history to the denominator and nothing to the numerator, so the deficit piles up in long-lived units.

Your segmentation variable may correlate with age. "Multi-turn vs single-turn", "active vs idle", "power user vs new user" and "long-running job vs one-shot" all do. When that happens, the artifact arrives already dressed up as a plausible mechanism:

> "It fires reliably on the first event and unreliably after."

That sentence is what a censored denominator sounds like. Short units sit entirely inside the window and read 100%. Long units straddle it and read about 50%. No such mechanism exists.

## A rotation you performed yourself is still censoring

This trap is hard to catch because you can *know* about the rotation and still get it wrong. Knowing about it answers a different question:

- "Did the rotation lose data?" No, it was archived deliberately.
- "Does the denominator start where the current log starts?" Nobody asked.

Ruling out "log resets" as a cause of *missing writes* does not rule them out as a cause of a *mis-specified denominator*. These are separate failures that get described with the same words. Check the archives explicitly. If the "missing" records are in `*.v1.jsonl`, `*.archive` or the rotated file, the collector never failed.

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

This matters most when a metric has a branch like "if the number is low, abandon the plan". Censoring only ever pushes the number down. It manufactures false negatives, never false positives.

## Fix every direction, not just the flattering one

When you correct a censored join, check each metric separately for **which way its bias points**. The metrics will not agree. Applying one bound to all of them is how a test rig quietly gets tuned toward the answer you want.

Example: two metrics that read the same event set.

| metric | correct bound | why |
|---|---|---|
| recall | per-unit floor (first surviving record) | fair to the retriever: only score events whose trigger this rig actually saw |
| demand ("was it ever wanted?") | the log's global window | a fact about the user, not the retriever; the stricter floor **under-counts** it |

The recall bound raises the recall number. The demand bound raises demand too. If the decision rule ships when demand is zero, using the stricter bound for demand would push toward shipping on an artifact. **State each metric's bias direction out loud before choosing its bound.**

## The freeze protects the collector, not the scorer

"The rig is frozen" usually means *stop changing what gets recorded*. A scorer reads data that already exists. Correcting it re-reads the same records and cannot invalidate them.

Settle this with the fingerprint, not by argument. If your records carry a version hash, recompute it from its declared inputs and compare:

```python
h = sha256(collector_source + input_set_a + input_set_b + thresholds)
assert h.hexdigest()[:12] == recorded_rig     # scorer absent -> scorer is free
```

If the scorer is not one of the inputs, editing it changes no record and **does not restart the observation window**. If it *is* an input, treat it as part of the collector. Either way, print the pre-fix and post-fix readings side by side. That keeps the correction auditable, so a number never moves without a trace.

## Checklist

Before reporting a coverage or recall figure:

1. What is the first timestamp in the log file I am actually reading?
2. Were there earlier log files? Are the "missing" records in them?
3. Is my denominator filtered to `[window_start, window_end]`?
4. Does the apparent deficit correlate with the observed unit's age or duration? If it does, suspect censoring before you suspect the collector.
5. In any per-unit join, are both sides bounded by the same window?
6. Are the remaining misses real events, or harness artifacts? (For prompt collectors: `/compact`, `/clear`, command-name expansions and continuation summaries show up as `type:user` but never fire `UserPromptSubmit`.)

## Worked example (shape of the failure)

A hook-coverage report showed single-turn sessions at 100% and multi-turn sessions at about 50%. It was read as "the hook fires on a session's first prompt and unreliably after" and logged as a threat to validity. In fact, the log had been archived at a rig freeze, while the denominator counted every prompt in each session's transcript, including prompts from days before the archive. One long session contributed 19 prompts and 1 record; its other records were in the rotated files, and its first prompts came before the hook existed. Once the denominator was restricted to the log's own window with a per-prompt timestamp join, coverage was 100% for both groups. The few remaining misses were all one `/compact` operation (the command, its expansion and the continuation summary).

The same censoring was also pulling down a recall metric: half of its opportunities came from the one session split across archives, and those could never be won. The fix went into the scorer only. Both readings were printed, and recomputing the rig fingerprint showed that no record was invalidated and the window did not restart.

## Related failure modes

### Differencing a weighted aggregate whose weights are re-derived each period lets composition pass for real movement

A level and a change need different estimators. Some weighted aggregates recompute their weights every period: a volume-weighted average price, a traffic-weighted latency, a headcount-weighted score. You **cannot** difference these across periods to measure the thing they average. The difference includes the composition shift for free, and you can't tell it apart from real movement in the components.

Typical case: a market summary reports "average asking price per unit is up 1%". The average is weighted by each day's own listing counts across sub-markets. Over the window, the expensive sub-market added listings and the cheap one didn't. A fixed-weight calculation shows exactly 0% movement. The bias goes both ways: in other windows, the mix shift hides a real decline.

Cheap diagnostic: if every component held perfectly still and only the weights moved, would this number move? If yes, the number can't support any claim about the components.

How to fix it: use a fixed-weight (Laspeyres) index. Weight **both** endpoints by the same base-period weights, and only include components present in both periods, so only a component's own value can move the result. Keep the re-weighted aggregate for the **level**, where it is legitimate, and change only the **delta**. Two traps:

1. Renaming the statistic doesn't fix it. A true pooled median differenced across periods has the same flaw, because the pool's composition also shifts.
2. Decide which sibling statistics need fixing by **measuring** them, not by comparing the error's size to a threshold's size. A sharp cutoff on rounded integers means a 1-unit error is enough to cross a 5-unit threshold. A sibling metric judged "immaterial" this way turned out to flip the published advice on some real days.

Also: `Math.round()` on a small negative value returns `-0`, which fails `strictEqual` against `0`. Normalize before returning a rounded percentage.

### A scan's population list is unmaintained data, and nothing detects a unit silently dropping out of it

A "recent activity across all repos" digest is only as complete as the list it iterates. If that list is a hand-maintained inventory file rather than a live query of what it claims to cover (for example `ls` over the actual directory), every new repo is invisible to every scan built on it until someone adds it by hand. Nothing in the output shows the gap: a scan that skipped a repo looks the same as a scan that found no activity there. Such lists can drift dozens of entries behind reality, including actively developed projects. A stale config diff that is harmless and one that is a coverage bug show the same `git status` signature, so the drift is easy to file as "routine".

How to apply:

- For any pipeline whose population is a hand-maintained list (repos, services, accounts, feeds), regularly diff the list against the live source of truth: `ls`, an API's list-all endpoint, or a directory glob.
- Prefer deriving the list at run time with an explicit **exclude**-list over keeping an **include**-list. An include-list fails silently-closed: new things are invisible by default. An exclude-list fails silently-open: new things are included by default. Open is the safer direction for a coverage scan.
- If you inherit a hand-maintained list you can't convert yet, treat "does this list still match reality?" as its own periodic check, separate from "is this list well-formed?".

### A membership test, not just the membership list, can silently drop units

A correct list can still be filtered wrong. Scripts that gate on `[ -d "$repo_dir/.git" ]` treat every git worktree as nonexistent, because in a worktree `.git` is a **file** (a `gitdir:` pointer), not a directory. Repos that are correctly on the list can stay invisible to duplicate-work gates and activity digests for months. Fix: `-d` becomes `-e`, which is true for a directory or a gitdir file and still excludes non-repos.

In general, a filter predicate ("is a directory", "matches this regex") can encode an assumption about one subtype that a valid alternative subtype fails: a worktree, a symlink, a bare repo. Before you trust a scan's silence, check that each item is both **on** the list and **passes** its filter.

### A category-shaped grep counts a confirmation line as if it were the event it confirms

If you count an event by grepping a keyword that names the *topic* instead of the *specific line template*, you silently double-count whenever the same subsystem also logs a separate line acknowledging the event. Example: a restart count grepped broadly matched both `recreating container` (the event) and `post-restart auth=ok` (a confirmation logged just after it). The total was about 2x too high and still plausible enough to go unchallenged.

How to apply: before reporting a count from `grep -c` or similar over a log:

- Name the exact line template the pattern is meant to match.
- Check whether any other line logged near the same event would also match: an ack, a retry of the same attempt, a summary line restating counts.
- Match on a substring unique to the one line that fires exactly once per event.
- Sanity-check against an independent estimate, such as events divided by the log's day-span giving a plausible rate.

### A timeout that kills a scan mid-list yields partial data that reads as complete

`$(timeout N ./scan.sh || echo 'failed')` does **not** discard the killed process's output. Command substitution keeps whatever the process already wrote to stdout and then appends the fallback string. If the scan emits a list incrementally, the caller gets a well-formed list that stops wherever the clock ran out, with an error line underneath that is easy to read past.

That is worse than an empty result, because downstream logic treats absence from the list as a positive fact. A dedup gate fed a truncated "open branches" list under a "do NOT duplicate anything below" instruction will read "repo not listed" as "repo has no open branches" and assert a clean slate. Scans like this break as the input list grows past the timeout.

Fail closed instead:

1. Have the producer emit a completion sentinel as its final output, from exactly **one** place (`<!-- SCAN_COMPLETE ... -->`).
2. Have the consumer **require** the sentinel and discard partial output **whole**. Replace it with an explicit "no data, here is how to get it yourself" block. Never show partial results that read as authoritative.
3. Report unreachable items as NOT SCANNED instead of skipping them. A skipped item looks identical to a clean one. Doing this tends to surface items (for example repos with no remote) that were wrongly counted as clean for a long time.
4. Never compute a threshold decision (a cap, a quota, an alert) from an incomplete scan.
5. Make the scan faster (parallel fan-out) rather than raising the timeout. The input list will keep growing.

Detection: a failure line at the **bottom** of a long block is easy to miss. A per-run "Nth consecutive failure" tally can also badly undercount, because each run only sees its own truncated evidence.

### A per-call blind-map file clobbers the previous judge's mapping, silently inverting multi-judge results

Suppose a blind-evaluation script truncates and **reshuffles** a single `blind-map.tsv` on every call, while each judge's output goes to its own per-judge file. Then judging one run with two judges destroys the first judge's mapping and keeps only the last one. If the two calls drew opposite shuffles, reading the surviving map against the first judge's scores reports the exact opposite result: a 5-point win becomes a 5-point loss. Nothing errors, and the file exists and parses.

Rule: any blind or randomised label map must be keyed by the same identifier as the output it decodes (`blind-map-<judge>.tsv`). To recover from a clobbered map, match each verdict's distinguishing claims back to ground-truth features in the arm artifacts. Confirm each mapping with two independent features before trusting any score.

### Labeled time windows silently drift from the time they claim to cover

Two shapes, same root cause: a proxy for elapsed time that diverges from real elapsed time.

**Off-by-one at a section seam.** A "last 7 days" aggregate built with `for i in $(seq 2 7)` starts at two days ago on the theory that an adjacent "recent" block already covers yesterday. If that recent block shows a different data shape (raw lines instead of the aggregated rollup), the most recent full day is missing from every trend computed from it, on every run. The window is really 6 days. A range that looks deliberate is easy to read as correct by design rather than as an unchecked assumption.

**"N slots back" after a missed run.** Comparing today's snapshot to the row 7 slots back and calling it "the past week" is only true while the collector never misses a day. After a multi-week cron gap, that "week" covers far more time, streaks keep counting across the gap, and reported changes can even flip sign.

How to apply:

- Before trusting a labeled window ("last 7 days", "last 30 days"), count how many iterations the loop that builds it actually runs. Check whether the boundary day is really covered somewhere else or silently dropped.
- Choose windows by **calendar date**, not by index offset. Use the oldest snapshot within N days, or else the latest earlier one, and report the span actually covered.
- End streaks at a gap. Return null for day-over-day changes unless the prior row really is yesterday.
- Verify by replaying real history through the old and new code. Only the gap days should change.

### A file named `.jsonl` is not guaranteed to be line-delimited

`tail -50 file.jsonl | jq -r '...'` assumes one compact JSON object per line. If the writer pretty-prints (jq without `-c`, Python `json.dumps(indent=...)`), `tail` grabs fragments cut at line boundaries in the middle of objects. Those never parse, so the section renders "(parse error)" on every run.

Fix: `jq -s --arg cutoff ... '[.[] | select(.timestamp >= $cutoff)] | ...'`. Slurp mode parses the file as a stream of JSON values regardless of newlines, and filtering on the timestamp field makes a "last N days" label actually true. "Last 50 lines" is an untested proxy that would miscount even on a well-formed file, because record sizes vary.

How to apply: before using any line-count slice to sample the "last N" entries of a JSON log, confirm the file is really one compact object per line. Compare `wc -l` against a record count, or just look at the raw file. An **empty** result (looks like "no data") and a **parse error** (looks like "the tool is broken") are easy to confuse, and a `... || echo fallback` pattern can swallow either one.

### A per-call figure is not an optimization target until it is a share of total usage

A per-call number such as "45K tokens per call, mostly injected startup context" looks like a target on its own. First sum the job over a real window and divide by total usage. Small-model triage jobs with large per-call context can turn out to be under 1% of tokens and cost, while one large model's interactive sessions are about half. Dedupe transcript usage by `message.id`, weight by model price (cache read ~0.1x, cache write ~1.25x), and rank levers by each job's actual share, not by per-call size.

Corollary: replay real production traffic before routing a classifier to a smaller model. A small hand-picked golden set can show parity that a replay against real batches does not. A small eval set does not prove the real traffic mix behaves the same way.

### A primary/fallback host migration leaves the old host's local logs as a report's silent, stale source

Suppose a report builds its prompt or dashboard from local files on the host where the report job runs. If the workload it reports on moves to a new primary host (with the old one kept as fallback) and the report job stays put, every run on the new host becomes invisible to it, including runs that scored failures. The stale section renders as a normal thin result, not an error. Only diffing the new host's logs against the report shows the gap.

How to apply: when a scheduled job can fail over between hosts, every job that reports on its output must read from wherever it actually ran last, or from a centralized log, not from a fixed per-host path. A failover that keeps the workload running can make every host-local report about it silently wrong at the same moment.

### A failure logged with cost `0` can't be told apart from a legitimate zero-cost event once summed

If a service logs every job that died before producing a result (timeout, thrown error, credits exhausted) as `{costUsd: 0, ok: false}`, then a `0` from a genuinely free call and a `0` meaning "cost unknown" look the same once summed. The spend monitor leaves out each failed job's real, possibly nonzero cost while still counting it in `jobs`. Spend is undercounted and no error appears.

Fix: log `costUsd: null, costUnknown: true` on every failure path, and have the monitor count `unknownCostJobs` separately instead of turning `null` back into `0` before summing. A defensive read like `float(r.get("costUsd") or 0)` doesn't help if the writer never produces `null`.

In general: any ledger or metric that sums a numeric field (cost, duration, bytes) must separate "measured zero" from "never measured" **where the value is written**, not only where it is read.
