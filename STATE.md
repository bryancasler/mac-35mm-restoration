# STATE — read me first

<!-- Hard cap: 60 lines. Prune on every update: durable facts → ADR/RESULTS; stale notes → delete. -->

## Where we are
- **ALL MILESTONES M0–M5 COMPLETE** (2026-07-17), plus same-day additions:
  side-by-side comparison (custom + 6×10 s quick-sample reel), 2×/3× multi-pass
  (single-encode, no generational loss), job stats line. M4 `--selftest-vs`
  ALL PASS (7/7, audio Δ0.000 s). Unsigned DMG lives at release/FilmRestore.dmg
  and must be regenerated in any commit touching app sources (CLAUDE.md rule).
- 25 unit tests green. Headless verification flags on the binary:
  `--selftest <file>`, `--selftest-vs <file>`, `--selftest-sbs <file>`,
  `--doctor`, `--provision`.
- Last updated: 2026-07-17

## Next actions (in order)
1. **User:** GUI eyeball — open release/FilmRestore.dmg (or `swift build`), drag the
   scan in, test clip, A/B flip, mark-mode, quick-sample side-by-side reel.
2. **Open perf question** (parked, docs/perf-vs-fullrun.md): VS full-movie runs
   degrade progressively 80→39 fps; new prime suspect = deflicker.py per-frame
   std.Lut node accumulation (131k nodes; spikes only ran ≤7.2k frames). Fix sketch
   + isolation matrix in that file. Output correctness unaffected.
3. **User:** send prepared ffmpeg patch to ffmpeg-devel (one command + Gmail app
   password — steps in docs/upstream/ffmpeg-deflicker-median.md).
4. Someday: Developer ID signing + notarization (README has the commands).

## Blockers / open questions
- Only the parked perf question above. Nothing blocks use of the app.

## Environment facts (verified 2026-07-17)
- ffmpeg 8.1.2 (Homebrew; no drawtext filter), Xcode 26.6 (Swift 6.3.3),
  macOS 26.5.1, M4 Pro. VapourSynth R77 + bestsource (brew), meson+ninja (brew).
- Plugins in `~/Library/Application Support/FilmRestore/plugins/` (MVTools v24,
  RemoveDirt 1.1, TemporalMedian, zsmooth 0.19.0, DeScratch 4.0 self-built;
  sha256s in manifest.sha256; app can re-provision from zero via Setup/--provision).
- Real test asset: 35mm scan, 1440x1080, 23.98 fps (24000/1001), H.264 yuv420p MKV +
  pcm_s16be, 5491.5 s, 25.2 GB, 131,665 frames.
  Path: `/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv`
- App dirs: test clips → `~/Library/Application Support/FilmRestore/testclips/`,
  logs → `~/Library/Logs/FilmRestore/`. Side-by-side output lands next to source
  as `NAME.sidebyside.mp4`.
- A `NAME.restored.mkv` (~1.6 GB, q:v 60) may exist on the Desktop from selftests.

## Fresh findings not yet in ADR/RESULTS
- (empty — everything merged)
