# STATE — read me first

<!-- Hard cap: 60 lines. Prune on every update: durable facts → ADR/RESULTS; stale notes → delete. -->

## Where we are
- **Milestone: M3 done** (2026-07-17). M2 selftest ALL PASS on the real scan (full
  restore 250 fps / 10.4x, ETA monotonic, source untouched). M3 verified from-zero:
  detection → sha256-verified provisioning → DeScratch source build → doctor smoke
  PASS. Setup UI (checklist + approval sheet + doctor pane) behind toolbar button;
  headless flags: --selftest <file>, --doctor, --provision.
- Last updated: 2026-07-17

## Next actions (in order)
1. **User:** GUI eyeball — `cd FilmRestore && swift build && .build/debug/FilmRestore`,
   drag the scan in, render a test clip, check the A/B flip + frame-step; peek at the
   Setup sheet (stethoscope toolbar icon).
2. **User:** send prepared ffmpeg patch to ffmpeg-devel (one command + Gmail app
   password — steps in docs/upstream/ffmpeg-deflicker-median.md).
3. M4 — VS backend: .vpy templating (chain proven in spikes/s3_pipeline/chain60.vpy),
   deflicker.py + spotless.py as app resources, vspipe|ffmpeg backend, scratch/dirt
   controls, DeScratch mark-mode preview, engine pickers (RemoveDirt default, ADR-12).

## Blockers / open questions
- VS full-run ran at ~80 fps vs ~255 expected — likely Low Power Mode throttling;
  parked with check procedure + isolation matrix in docs/perf-vs-fullrun.md.
- Disk freed (23 GB at last check). LICENSE done (canonical GPL-3.0).

## Environment facts (verified 2026-07-17)
- ffmpeg 8.1.2 (Homebrew), Xcode 26.6 (Swift 6.3.3), macOS 26.5.1, M4 Pro.
  VapourSynth R77 + bestsource (brew), meson+ninja (brew).
- Plugins provisioned in `~/Library/Application Support/FilmRestore/plugins/`
  (MVTools v24, RemoveDirt 1.1, TemporalMedian, zsmooth 0.19.0, DeScratch 4.0
  self-built; sha256s in manifest.sha256 there).
- Real test asset: 35mm scan, 1440x1080, 23.98fps (24000/1001), H.264 yuv420p MKV +
  pcm_s16be, 5491.5 s, 25.2 GB, 131,665 frames.
  Path: `/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv`
- App dirs: test clips → `~/Library/Application Support/FilmRestore/testclips/`,
  logs → `~/Library/Logs/FilmRestore/`.
- Untracked test media (gitignored): spikes/s1_deflicker/clip60.mkv (950 MB FFV1),
  s3_pipeline/out60{.mkv,_preview.mp4}, s5_ab_player/source60_preview.mp4.

## Fresh findings not yet in ADR/RESULTS
- Selftest artifact intentionally deleted its output; a real user-run
  `.restored.mkv` was ~1.65 GB at q:v 60 (matches S3 estimate).
