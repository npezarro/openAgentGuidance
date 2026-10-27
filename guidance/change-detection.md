<!-- Load when: building or debugging anything that decides "did this change?": screen/file/page watchers, cache invalidation, sync, dedup, polling collectors -->
# Change Detection Must Sense the Dimension the Change Lives In

A change detector is a *measurement*. Like any measurement, it only sees the axis it samples. If you pick the wrong axis, it reports "unchanged" forever while real work happens in front of it. This fails **silently and green**: the pipeline runs, the logs are clean, the process count is right, and the record is empty.

## The rule

**Name the smallest change you need to catch, then confirm the signal moves for it.** The question is not "does the detector work". The question is whether it moves for *that* change, measured at least once.

Common mismatches:

| Detector | Blind to |
|---|---|
| perceptual/average image hash | text edits (a typed paragraph moves almost no cells at any grid size) |
| file mtime | content-identical rewrites, and touch-only churn reports the opposite |
| file size | same-length edits (a one-character correction) |
| top-level object identity | deep mutation |
| ETag/Last-Modified | servers that do not set them honestly |
| line count | reordering, and edits within a line |
| whole-second timestamp cursor | rows written in the same second as the cursor |

## Two rules that follow from it

- **Prefer the signal in the same medium as the content.** If the thing you care about is text, diff the text. Pixels are a poor proxy for text. Use them only as the fallback for content that has no text at all (video, images, canvases).
- **Strip volatile chrome before comparing.** Clocks, unread badges, progress percentages and scroll positions change on every sample. Leave them in and the detector reports "changed" every time. That is as useless as never firing, and it fails in the direction that looks like it is working.

## Worked failure modes

### A pixel hash cannot see a typed paragraph

Say a screen-activity recorder gates frames on a small average hash of the full screen (for example 8x8, 64 bits) with a low Hamming threshold. Typing a paragraph into a document flips almost none of those bits. The frame gets skipped, so progress *inside* a document is invisible by construction, while every health check stays green.

Fix:
- Extract the text (OCR, accessibility tree, or DOM) from each capture and treat text movement as the authoritative signal.
- Keep the pixel hash only for screens with no text.
- Strip volatile chrome before the text comparison.

### A "what's new since last run" cursor on whole-second timestamps with strict `>` drops rows for good

A query like `timestamp > lastRun` breaks when both the stored cursor and new rows are stamped to the second (for example SQLite `datetime('now')`). A row written in the same wall-clock second as the cursor update is excluded from that run and from every later one, because `>` never becomes true for it. This is a permanent loss, not a missed cycle. Switching to `>=` is not the fix either, because then the boundary row gets re-read forever. Second-granularity time cannot tell "already read" apart from "written a moment later".

Fix:
- Use a monotonic cursor that is never reused, such as an AUTOINCREMENT id.
- Advance the cursor to the last row you actually **read**. Do not advance it to `MAX(id)` or to "now" after the run. That way a row inserted between the query and the cursor update gets picked up on the next pass instead of being skipped.
- Test against a real database with a row stamped in the same second as the run. A mocked clock cannot reproduce a same-instant tie.

## Verify it the only way that counts

Until you test a detector, its threshold is a guess. Make the smallest real change by hand and assert that the signal crossed the threshold. Then make a no-op change, or none at all, and assert that it stayed quiet. If you have never seen a detector fire, it is decoration. If you have never seen it *stay quiet*, it is noise.
