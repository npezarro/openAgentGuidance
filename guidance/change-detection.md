<!-- Load when: building or debugging anything that decides "did this change?": screen/file/page watchers, cache invalidation, sync, dedup, polling collectors -->
# Change Detection Must Sense the Dimension the Change Lives In

A change detector is a *measurement*, and like any measurement it can only see the
axis it samples. If you pick the wrong axis, it reports "unchanged" forever while real
work happens in front of it. This fails **silently and green**: the pipeline runs,
the logs are clean, the process count is right, and the record is empty.

## The rule

**Name the smallest change you need to catch, then confirm the signal moves for
it.** The question is not "does the detector work". The question is whether it moves for *that* change. Measure it once to find out.

Common mismatches:

| Detector | Blind to |
|---|---|
| perceptual/average image hash | text edits (a typed paragraph moves almost no cells at any grid size) |
| file mtime | content-identical rewrites; touch-only churn reports the opposite |
| file size | same-length edits (a one-character correction) |
| top-level object identity | deep mutation |
| ETag/Last-Modified | servers that do not set them honestly |
| line count | reordering, and edits within a line |

## Two rules that follow from it

- **Prefer the signal in the same medium as the content.** If the thing you care
  about is text, diff the text. Pixels are a poor proxy for text. Use them
  only as the fallback for content that genuinely has no text (video, images,
  canvases).
- **Strip volatile chrome before comparing.** Clocks, unread badges, progress
  percentages and scroll positions change on every sample. Leave them in and the
  detector reports "changed" every time. That is exactly as useless as never firing,
  and it fails in the direction that looks like it is working.

## Verify it the only way that counts

An untested detector's threshold is a guess. Make the smallest real change by hand
and assert the signal crossed the threshold. A detector you have never seen fire
is decoration, and one you have never seen *stay quiet* is noise.

## Worked lesson: a pixel hash cannot see a typed paragraph

Consider a screen-activity collector that gates frames on a small average hash of the full screen (for example 8x8, 64 bits) with a Hamming-distance threshold of a few bits. Typing a paragraph into a document flips almost none of those bits. The frame gets skipped, so progress *inside* a document is invisible by construction. Meanwhile the pipeline stays green: the daemon is alive, frames are flowing, and descriptions are being written.

The fix:

1. OCR each capture and treat text movement as the authoritative signal.
2. Keep the pixel hash only for text-free screens.
3. Strip volatile chrome (clocks, unread badges, percentages) from the extracted text before comparing, so the detector does not swing to reporting "changed" on every sample.

General rule: name the smallest change you must catch, then verify that the signal actually moves for it.
