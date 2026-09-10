<!-- Load when: auditing a logger/collector's coverage, or a metric whose denominator comes from a different source than its numerator -->
# Measurement Windows and Censored Denominators

A collector's coverage is `records / opportunities`. The numerator comes from the
log. The denominator usually comes from somewhere else (a transcript, a database,
the thing being observed). Those two sources almost never share a start time, and
when they don't, the ratio is wrong in a way that looks like a behavioural finding.

## The rule

**Align the denominator to the collector's own observation window before computing
coverage.** The window starts at the first record in *the log you are reading*, not
at the moment the collector was installed, and not at the beginning of the observed
unit's life.

```
window_start = min(ts) over the CURRENT log file
denominator  = opportunities where window_start <= ts <= window_end
```

Compute coverage both ways. If the uncorrected and corrected numbers differ, the
gap is measurement, not behaviour, and you must explain it before theorising about
the collector.

## Why the artifact is convincing

The bias is not random. It scales with how long the observed unit has been alive:
a unit that predates the window contributes its whole pre-window history to the
denominator and nothing to the numerator. So the deficit concentrates in
long-lived units.

If your segmentation variable correlates with age, and "multi-turn vs
single-turn", "active vs idle", "power user vs new user", "long-running job vs
one-shot" all do, the artifact arrives pre-packaged as a plausible mechanism:

> "It fires reliably on the first event and unreliably after."

That sentence is what a censored denominator sounds like. Short units are
entirely inside the window and read 100%; long units straddle it and read ~50%.
No such mechanism exists.

## A rotation you performed yourself is still censoring

The trap that makes this hard to catch: you can *know* about the rotation and
still get it wrong, because knowing it answers a different question.

- "Did the rotation lose data?" No, it was archived deliberately.
- "Does the denominator start where the current log starts?" Nobody asked.

Ruling out "log resets" as a cause of *missing writes* does not rule it out as a
cause of a *mis-specified denominator*. They are separate failures with the same
name. Check the archives explicitly: if the "missing" records are sitting in
`*.v1.jsonl` / `*.archive` / the rotated file, the collector never failed.

```bash
# The decisive check, and it is cheap. Do it FIRST.
for f in <log> <archives>; do
  echo "$f: $(grep -c "$UNIT_ID" "$f") records"
done
```

## The same censoring propagates into any per-unit join

A metric that joins a full-lifetime event set against a window-truncated record
set inherits the bug and hides it better:

```python
opened[sid]  # scanned from the WHOLE transcript, all of the unit's life
would[sid]   # built only from records in the CURRENT log
recall = len(opened & would) / len(opened)      # structurally unwinnable misses
```

Every event that happened before the log's window is a guaranteed miss, because
the record that would have matched it is in the archive. Time-bound **both** sides
of a per-unit join, or drop units whose record set is known to be truncated.

This matters most when a metric has a "if the number is low, abandon the plan"
branch: censoring only ever pushes the number down, so it manufactures false
negatives, never false positives.

## Fix every direction, not just the flattering one

When you correct a censored join, check each metric separately for **which way
its bias points**. They will not agree, and applying one bound everywhere is how
a rig quietly gets tuned toward the answer you want.

A worked case: two metrics reading the same event set.

| metric | correct bound | why |
|---|---|---|
| recall | per-unit floor (first surviving record) | fair to the retriever: only score events whose trigger this rig actually saw |
| demand ("was it ever wanted?") | the log's global window | a fact about the user, not the retriever; the stricter floor **under-counts** it |

The recall bound raises the number. The demand bound raises it too, and the
decision rule ships when demand is zero, so tightening demand would have pushed
toward shipping on an artifact. **State each metric's bias direction out loud
before choosing its bound.**

## The freeze protects the collector, not the scorer

"The rig is frozen" usually means *stop changing what gets recorded*. A scorer
reads data that already exists; correcting it re-reads the same records and
cannot invalidate them.

Settle this with the fingerprint rather than by argument. If your records carry a
version hash, recompute it from its declared inputs and compare:

```python
h = sha256(collector_source + input_set_a + input_set_b + thresholds)
assert h.hexdigest()[:12] == recorded_rig     # scorer absent -> scorer is free
```

If the scorer is not an input, editing it changes no record and **does not
restart the observation window**. If it *is* an input, treat it as the collector.
Print the pre-fix and post-fix readings side by side either way, so the
correction is auditable instead of a number that silently moved.

## Checklist

Before reporting a coverage or recall figure:

1. What is the first timestamp in the log file I am actually reading?
2. Were there earlier log files? Do the "missing" records live in them?
3. Is my denominator filtered to `[window_start, window_end]`?
4. Does the apparent deficit correlate with the observed unit's age or duration?
   If yes, suspect censoring before suspecting the collector.
5. In any per-unit join, are both sides bounded by the same window?
6. Are the residual misses real events, or harness artifacts? (For prompt
   collectors: `/compact`, `/clear`, command-name expansions, and continuation
   summaries appear as `type:user` but never fire `UserPromptSubmit`.)

## Worked example

Reported hook coverage was single-turn 102/102 = 100%, multi-turn 40/77 = 52%,
read as "the hook fires on a session's first prompt and unreliably after" and
logged as a validity threat.

The log had been archived at a rig freeze partway through the measured period;
the denominator counted every prompt in each session's transcript, including
prompts from days before that. One session contributed 19 prompts and 1 record.
Its other 6 records were in the rotated log files, and its first 2 prompts
predated the hook's existence entirely.

Corrected to the log's own window, per-prompt timestamp join across all
transcripts: **153/153 = 100%**, single- and multi-turn alike. The 3 apparent
residuals were one `/compact` operation (the command, its expansion, and the
continuation summary). No first-prompt bias exists.

The same censoring was independently depressing the recall metric: 4 of its 8
opportunities came from the one archive-split session, and were unwinnable by
construction. Fixed in the scorer (reading moved 12% -> 25%, both printed); the
collector was not touched, and recomputing the rig fingerprint from its declared
inputs proved no record was invalidated and the window did not restart.

Related discipline: diagnose before retrying, and confirm every new assertion
fails against the pre-fix code.

### Differencing a weighted aggregate whose weights are re-derived each period lets composition masquerade as the measurement

A level and a change need different estimators. Any weighted aggregate whose
weights are recomputed each period (a volume-weighted average price, a
traffic-weighted latency, a headcount-weighted score) CANNOT be differenced
across periods to measure the thing it averages: you get the composition shift
for free, and it is indistinguishable from real movement in the underlying
components.

A worked case: a daily market narrative claimed "asking $/sqft is up 1%, sellers
still hold pricing power". The number differenced an active-weighted mean of four
sub-market medians, weighted by each day's own listing counts. Over the measured
week the expensive sub-market (~$810/sqft) added 21 listings while the cheap one
(~$665) did not. Measured against 29 real daily snapshots: the fixed-weight move
was EXACTLY 0.00% while the shipped number said +1%. Across 22 windows the value
was wrong on 5, and the qualitative claim fired or vanished on 3. The bias is not
one-directional: on two other windows the mix shift MASKED a genuine ~0.4%
decline.

Diagnostic question, cheap to ask: what happens to this number if every component
holds perfectly still and only the weights move? If the answer is "it moves", the
number cannot support a claim about the components.

Fix shape: a fixed-weight (Laspeyres) index. Weight BOTH endpoints by the same
base-period weights and restrict to components present in both periods, so only a
component's own value can move the result. Keep the re-weighted aggregate for the
LEVEL (that is a legitimate use) and change only the DELTA. Two traps worth
noting: (1) renaming the statistic does not fix it, a true pooled median
differenced across periods has the identical flaw, because the pool composition
also shifts; (2) scope the fix by MEASURING sibling statistics rather than fixing
them on principle, since one sibling metric here had the same shape but its worst
pure-mix swing was 1 unit against a 5-unit reporting threshold, so it was
correctly left alone with the reasoning recorded.

Also: `Math.round()` on a small negative value returns `-0`, which fails
`strictEqual` against `0`. Normalize before returning a rounded percentage.

### A scan's population list is itself unmaintained data, and nothing detects an item silently falling out of it

A "recent activity across all repos" digest is only as complete as the list of
repos it iterates. When that list is a separately-maintained inventory file
rather than a live query of the thing it claims to cover (e.g. `ls` over the
actual directory), a newly-created repo is invisible to every scan built on it
until someone remembers to add it by hand, and nothing about the output signals
the gap, because a scan that's missing a repo looks identical to a scan that
correctly found no activity in it.

A worked case: a config file's `repos` array fed an activity digest, a dedup
gate, and report scripts. It had drifted 34 repos behind the actual repo
directory for at least 6 days, several of them live and under active
development. Every digest generated in that window silently omitted them: not
filtered out, never queried at all. The gap stayed hidden because it surfaced as
an ordinary-looking `git status` diff on a config file inside an already-known,
already-deprioritized hazard, so two prior sessions saw the diff and correctly
filed it as "routine drift" without checking whether the *content* of that drift
was a coverage bug. A stale-but-harmless config diff and a stale-and-broken one
produce the identical `git status` signature.

How to apply: for any pipeline whose population is a hand-maintained list (repos,
services, accounts, feeds) rather than a live enumeration, periodically diff the
list against the live source of truth (`ls`, an API's list-all endpoint, a
directory glob) rather than trusting that additions get remembered. Prefer
deriving the list at run time (with an explicit exclude-list for what to skip)
over hand-maintaining an include-list, since an include-list fails
silently-closed (new things are invisible by default) while an exclude-list fails
silently-open (new things are included by default, which is the safer direction
for a coverage scan). When you inherit a hand-maintained list you can't
immediately convert, treat "does this list still match reality" as its own
periodic check, separate from "is the data in this list correctly formatted".

### A category-shaped grep counts a confirmation line as if it were the event it confirms

Counting occurrences of an event in a log by grepping a keyword that names the
*topic* rather than the *specific line template* silently double-counts whenever
the same subsystem also logs a distinct line acknowledging that event.

A worked case: a restart count was produced by grepping a service log for
restart-related lines, and came back 549. The real number, counting only the
container-recreation line itself, is 248. The broader grep matched both
`recreating container` (the event) and `post-restart auth=ok` (a *different* line
logged right after, confirming the restart that already got counted). Every
recreation was therefore counted twice under a keyword broad enough to catch its
own echo, and the inflated number was plausible enough (still supporting
"restarts happen often") that it went uncorrected until someone re-derived it
from the one unique line template.

This is the same shape as a censored-denominator bug (the count looks like a fact
about the system, not an artifact of the query) but the mechanism is different:
here the log has more than one line PER event, and the grep pattern doesn't
distinguish which one it's matching.

How to apply: before reporting a count derived from `grep -c` (or equivalent)
over a log, name the exact line template the pattern is meant to match, and check
whether any OTHER line in the same file logged near the same event would also
match it (an ack, a retry-of-the-same-attempt, a summary line that restates
counts already logged individually). Prefer matching on a substring unique to the
one line that fires exactly once per event, and sanity-check the result against
an independent estimate (here, "recreations" divided by the log's day-span gave
"about one every seven hours", which is a plausible rate and would have caught
549 as roughly 2x too high before it shipped).

### A timeout that kills a scan mid-list yields partial data that reads as complete data

`$(timeout N ./scan.sh || echo 'failed')` does NOT discard the killed process's
output. Command substitution keeps whatever the process already wrote to stdout,
then appends the fallback string. If the scan emits a list incrementally, the
caller receives a well-formed list that simply stops wherever the clock ran out,
with an error line underneath it that is easy to read past.

This is worse than an empty result, because downstream logic treats
absence-from-the-list as a positive fact. In a worked case, a truncated
open-branch list was injected under 'DO NOT create PRs for any work listed below,
creating a duplicate is a critical failure', so 'repo not in the list' silently
meant 'repo has no open branches'. The scan had grown to ~87s against a 60s
timeout; ALL 22 retained briefings were affected and 7 of them showed zero open
branches, asserting a clean slate.

Fail closed instead:

1. Have the producer emit a completion sentinel from exactly ONE place, as its
   final output (`<!-- SCAN_COMPLETE ... -->`).
2. Have the consumer REQUIRE that sentinel and discard partial output WHOLE,
   substituting an explicit 'no data, here is how to get it yourself' block.
   Never show partial results that read as authoritative.
3. Report unreachable items as NOT SCANNED rather than skipping them. A skipped
   item is indistinguishable from a clean one. Doing this surfaced two repos with
   no git remote at all that had been counted as clean for months.
4. Never compute a threshold decision (a cap, a quota, an alert) from an
   incomplete scan.
5. Prefer making the scan faster (parallel fan-out: 87s to 7.7s) over raising the
   timeout. Growth in the input list is what breaks these, and it will grow
   again.

Detection: a runner whose failure line appears at the BOTTOM of a long block is
structurally easy to miss. Also note that a per-run 'Nth consecutive failure'
tally can badly undercount, because each run only sees its own truncated
evidence.
