# STATE — read me first

<!-- Hard cap: 60 lines. Prune on every update: durable facts → ADR/RESULTS; stale notes → delete. -->

## Where we are
- **Milestone: M1 COMPLETE** (2026-07-17). All five spikes PASS — see spikes/RESULTS.md
  for numbers. Exit criteria exceeded (S1–S5 done, not just S1–S3). M2 (SwiftUI app,
  ffmpeg-only) is next.
- Last updated: 2026-07-17

## Next actions (in order)
1. **User:** eyeball the S5 A/B prototype (build/run per spikes/s5_ab_player/README.md)
   — the one perceptual check no script can do (flip glitch, frame-step alignment).
2. **User:** free disk space (~2 GB left) before real restoration runs.
3. M2 — Xcode project skeleton per docs/PLAN.md (JobPlan, ProcessRunner, FFmpegBackend,
   probe card, test-clip render, A/B player, full run). Carry in: RESULTS.md gotcha
   lists from S3 (MP4-not-MKV test clips), S4 (ProgressParser rules, ffprobe fallback
   chain), S5 (AVFoundation anchor/preroll/CATransaction rules).
4. LICENSE: fetch canonical GPL-3.0 text (deferred from M0).

## Blockers / open questions
- Disk nearly full (~2 GB free) — S1 lossless intermediates filled it once; full-movie
  outputs ≈1.7 GB at q:v 60. User to clear space.
- S5 perceptual pass pending user (all automated checks green).

## Environment facts (verified 2026-07-17)
- ffmpeg 8.1.2 (Homebrew), Xcode 26.6, macOS 26.5.1, M4 Pro. VapourSynth R77 +
  bestsource installed (brew). meson+ninja installed (brew).
- Plugins provisioned in `~/Library/Application Support/FilmRestore/plugins/`
  (MVTools v24, RemoveDirt 1.1, TemporalMedian, zsmooth 0.19.0, DeScratch 4.0 self-built;
  sha256s in manifest.sha256 there).
- Real test asset: 35mm scan, 1440x1080, 23.98fps (24000/1001), H.264 yuv420p MKV +
  pcm_s16be, 5491.5 s, 25.2 GB.
  Path: `/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv`
- Untracked-but-kept test media (gitignored): spikes/s1_deflicker/clip60.mkv (950 MB
  FFV1, frames 14000–15439 — delete if disk pressure), s3_pipeline/out60{.mkv,_preview.mp4},
  s5_ab_player/source60_preview.mp4 + `abplayer` binary.

## Fresh findings not yet in ADR/RESULTS
- (empty — everything merged)
