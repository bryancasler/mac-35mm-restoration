# STATE — read me first

<!-- Hard cap: 60 lines. Prune on every update: durable facts → ADR/RESULTS; stale notes → delete. -->

## Where we are
- **Milestone:** M1 in progress. S2 PASS (see spikes/RESULTS.md — full chain 302 fps,
  RemoveDirt default holds). S1 is next.
- Last updated: 2026-07-17

## Next actions (in order)
1. S1 — port vf_deflicker to VS Python, validate vs ffmpeg output (top risk)
2. S3 — vspipe|ffmpeg single-encode end-to-end
3. S4 progress parsing, S5 A/B player prototype (low risk, can parallelize via sub-agents)

## Blockers / open questions
- None. User decisions on record: prebuilt plugin provisioning; VS-Python deflicker
  port preferred (fallbacks: double-pipe, then FFV1 intermediate) — see ADR-3, ADR-6.

## Environment facts (verified 2026-07-17)
- ffmpeg 8.1.2 (Homebrew), Xcode 26.6, macOS 26.5.1, M4 Pro. VapourSynth R77 + bestsource
  installed 2026-07-17 (brew).
- Real test asset: 35mm scan, 1440x1080, 23.98fps (24000/1001), H.264 yuv420p MKV +
  pcm_s16be audio, 5491.5 s (~91.5 min), 25.2 GB.
  Path: `/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv`

## Fresh findings not yet in ADR/RESULTS
- (empty)
