# STATE — read me first

<!-- Hard cap: 60 lines. Prune on every update: durable facts → ADR/RESULTS; stale notes → delete. -->

## Where we are
- **Milestone:** M1 in progress. S2 PASS, S1 PASS (spikes/RESULTS.md — deflicker port
  bit-exact 1438/1440; full VS chain 280 fps). S3 next.
- Last updated: 2026-07-17

## Next actions (in order)
1. S3 — vspipe|ffmpeg single-encode end-to-end (reuse s1_deflicker/clip60.mkv; delete
   it once S3 concludes — disk is tight)
2. S4 progress parsing, S5 A/B player prototype (low risk, can parallelize via sub-agents)

## Blockers / open questions
- **Disk nearly full (~2.8 GB free after cleanup).** Lossless intermediates filled it
  once during S1. Full-movie outputs need tens of GB — user should free space before
  real runs; app's disk guard (ADR-10) is clearly justified.

## Environment facts (verified 2026-07-17)
- ffmpeg 8.1.2 (Homebrew), Xcode 26.6, macOS 26.5.1, M4 Pro. VapourSynth R77 + bestsource
  installed 2026-07-17 (brew).
- Real test asset: 35mm scan, 1440x1080, 23.98fps (24000/1001), H.264 yuv420p MKV +
  pcm_s16be audio, 5491.5 s (~91.5 min), 25.2 GB.
  Path: `/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv`

## Fresh findings not yet in ADR/RESULTS
- (empty)
