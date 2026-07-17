# Spike Results

Verdicts land here as each spike completes (M1). Pass/fail criteria are defined in
[docs/PLAN.md](../docs/PLAN.md#riskiest-assumptions--spikes-ordered-by-remaining-risk).

| Spike | Question | Verdict | Numbers |
|---|---|---|---|
| S1 | deflicker.py port matches ffmpeg vf_deflicker? | **PASS** (2026-07-17) | pm/am: 1438/1440 frames bit-identical, rest ≥69 dB; 298 fps; full chain 280 fps |
| S2 | arm64 plugin stack provisions + benchmarks | **PASS** (2026-07-17) | bs 573 / +DeScratch 356 / +RemoveDirt 346 / +SpotLess 75 / full chain 302 fps |
| S3 | vspipe→hevc_videotoolbox single-encode correct + fast | **PASS** (2026-07-17) | 212 fps (60 s), 255 fps sustained (5 min); all correctness checks clean |
| S4 | progress parsing → reliable ETA both modes | **PASS** (2026-07-17) | ETA monotonic both modes, 0 jitter violations; 6 parsing gotchas documented |
| S5 | toggle A/B player glitch-free | **PASS*** (2026-07-17) | 164-line prototype compiles + runs; *perceptual check awaits user eyeball |

## S2 — arm64 plugin stack (2026-07-17): PASS

Machine: M4 Pro, macOS 26.5.1, VapourSynth R77 (Homebrew), test asset = real 35mm scan
(1440x1080 yuv420p, 23.976 fps). Benchmarks: 1440-frame (60 s) window via
`vspipe -p --arg stage=<x> s2_plugins/bench.vpy .`, plugins loaded from
`~/Library/Application Support/FilmRestore/plugins` via `VAPOURSYNTH_EXTRA_PLUGIN_PATH`.

| Stage | fps | × realtime |
|---|---|---|
| bestsource decode only | 573 | 23.9x |
| + DeScratch (mindif=5, maxwidth=3, minlen=100) | 356 | 14.8x |
| + RemoveDirt (classic composition, zsmooth Clense/Repair) | 346 | 14.4x |
| + SpotLess (radT=1, blksize=8, pel=2, thsad=10000) | 75 | 3.1x |
| DeScratch → RemoveDirt full chain | 302 | 12.6x |

Findings:
- **Provisioning works end-to-end.** Prebuilts (sha256s in plugins/manifest.sha256):
  MVTools v24, RemoveDirt v1.1, TemporalMedian v1 from Stefan-Olt/vs-plugin-build
  darwin-aarch64 releases; zsmooth 0.19.0 official aarch64-macos. All load via
  `VAPOURSYNTH_EXTRA_PLUGIN_PATH`; Homebrew tree untouched.
- **DeScratch is NOT prebuilt anywhere** (confirms ADR-6). Built from source:
  `github.com/vapoursynth/descratch` (DeScratch 4.0), meson+ninja, VS headers via its
  own submodule, arm64 clean build, 2 min. Script: `s2_plugins/build-descratch.sh`.
  Gotcha: `maxwidth` must be odd (1–15) — a UI constraint for M4.
- **ADR-12 verdict: RemoveDirt default HOLDS.** Plain-C RemoveDirt runs 346 fps — nowhere
  near "unusably slow". SpotLess (75 fps, ~3x realtime) stays the advanced option;
  zsmooth's TemporalMedian used (NEON), dubhater's tmedian also provisioned as spare.
- zsmooth provides Clense/ForwardClense/BackwardClense/Repair, so the classic RemoveDirt
  composition needs **no RGVS plugin**.
- bestsource one-time index of the 25 GB / 91.5-min file: **~3.7 min** (cached
  thereafter; decode then 573 fps). M2/M3 UX must show an indexing progress state on
  first open of a large file.
- No MVTools freeze observed (v24 pinned). Sustained multi-minute runs come in S3.

## S1 — deflicker.py fidelity (2026-07-17): PASS

Port: `s1_deflicker/deflicker.py` — faithful reimplementation of
`libavfilter/vf_deflicker.c` (release/8.1): forward-looking window of `size` luma means
(EOF pads by repeating the last mean, matching ffmpeg's flush), gain applied to luma only
with C truncation semantics (per-frame `std.Lut`), chroma untouched. All 7 modes.

Validation on the 1440-frame FFV1 test clip (frames 14000–15439 of the real scan),
per-frame framemd5 ffmpeg-vs-vspipe (decode alignment first verified bit-identical):

| Mode | Bit-identical frames | Residual |
|---|---|---|
| pm (default, size=10) | 1438/1440 | 2 frames at 71.2/69.3 dB PSNR-Y, chroma inf — ±1 LSB float32-vs-double noise |
| am | 1438/1440 | same character |
| median | n/a | **ffmpeg's median mode is broken upstream** (see below) |

Findings:
- **PASS at the "visually identical" bar and effectively at bit-exactness.** ADR-3
  primary topology confirmed; double-pipe and FFV1-intermediate fallbacks not needed.
- **ffmpeg bug found:** vf_deflicker's median comparator does `round(aa - bb)` on the
  *pointers* (both release/8.1 and master) — the window is never actually sorted, so
  ffmpeg's "median" returns garbage. Our port implements a true median (correct by
  construction); ffmpeg-match validation is meaningless for this mode. Flagged for
  upstream report.
  *2026-07-17 update:* root-caused and fixed — the broken comparator makes AV_QSORT
  apply a fixed value-independent permutation (size=5: elements 2↔3 swapped), so
  "median" returns an arbitrary window slot; the ~25% match rate was coincidence.
  One-line patch (`FFDIFFSIGN(*aa, *bb)`) validated against a patched master build;
  repro + ready-to-send patch in docs/upstream/ffmpeg-deflicker-median.md.
- Gotcha for anyone comparing outputs: ffmpeg's `psnr` filter syncs by PTS — mkv-vs-y4m
  timestamp rounding misaligns frames and reports a bogus ~41 dB. Use `-f framemd5`
  (sequential) or fifos into one psnr process.
- Throughput: deflicker.py alone 298 fps; **full restoration chain
  (deflicker → DeScratch → RemoveDirt) 280 fps = 11.7x realtime** — VS filtering will
  not be the pipeline bottleneck (VideoToolbox encode runs ~12x).
- Watch: per-frame `std.Lut` node creation is the cost driver; fine at 1440x1080.

## S3 — single-encode chain (2026-07-17): PASS

Topology: `vspipe -c y4m chain.vpy - | ffmpeg -f yuv4mpegpipe -i - -ss <t> -t <d> -i SRC
-map 0:v:0 -map 1:a:0 -c:v hevc_videotoolbox -q:v 60 -tag:v hvc1 -colorspace bt709
-color_range tv -c:a flac -shortest OUT.mkv` — full restoration chain
(deflicker pm/10 → DeScratch → RemoveDirt) live in the .vpy.

| Check | Result |
|---|---|
| End-to-end throughput (60 s clip) | 212 fps = 8.9x realtime (6.8 s wall) |
| Sustained (5 min / 7200 frames) | 255 fps = 10.6x realtime, no MVTools stall |
| Full-movie extrapolation (91.5 min) | ~9 min wall |
| Frame count / fps preserved | 1440 frames, 24000/1001 ✓ |
| Colorimetry restated | bt709 + tv range present in output ✓ (source has no primaries/trc tags — only restate what exists) |
| A/V duration + start times | both 60.06 s, both start 0.000 ✓ |
| Decode clean | software ✓, VideoToolbox hw (QuickTime proxy) ✓ |
| Output size (q:v 60) | 18.9 MB / 60 s ≈ 2.5 Mbps → full movie ≈ 1.7 GB |

Findings:
- **AVPlayer/QuickTime can't open MKV** → test clips for the M2 A/B player must be
  rendered as video-only MP4 (hvc1); full-run output stays MKV. ADR-8 amended.
  Verified: `-c copy -tag:v hvc1` remux into MP4 carries the tag, hw-decodes cleanly.
- `-tag:v hvc1` is a no-op in MKV (Matroska CodecID, not FourCC) — harmless to keep.
- Audio: `-ss`/`-t` on the source input + `-map 1:a:0 -c:a flac` gives sample-accurate
  sync by construction (PCM in, both streams PTS 0).
- Disk guard justified again: q:v 60 output is small (~1.7 GB/movie), but lossless
  intermediates are ~1 GB/min — the app must never write those uninstructed.

## S4 — progress parsing → ETA (2026-07-17): PASS

Script: `s4_progress/progress_spike.py` (+ `run.log`). Both modes emit `-progress pipe:1`
blocks, `progress=end` seen, exits 0, ETA monotonic after warmup with zero jitter
violations (>2 s upward).

Phase 1 (ffmpeg deflicker → VT, total=1440 via ffprobe): 0.5 s→inf(warmup) · 1.5 s/f313→5.4 s
· 3.0 s/f688→3.3 s · 4.1 s/f936→2.2 s · 5.1 s/f1187→1.1 s · 6.3 s/f1440→0.
Phase 2 (vspipe|ffmpeg, app-supplied total): 0.9 s→inf · 1.9 s/f346→4.8 s · 3.5 s/f742→2.8 s
· 4.5 s/f997→1.8 s · 5.5 s/f1244→0.8 s · 6.2 s/f1440→0. vspipe stderr `Frame: N/M`
secondary signal parsed (12 lines).

Gotchas (all handled; bake into M2 ProgressParser):
1. **ffprobe on MKV:** stream-level `nb_frames` and `duration` are both N/A — total frames
   must come from *format* duration × `avg_frame_rate`. Probe needs this fallback chain.
2. `-progress` emits every **0.5 s** by default (`-stats_period`), first block has
   `fps=0.0` → skip ETA until fps>0.
3. `-progress pipe:1` works identically on piped y4m stdin (re-confirms ADR-9); final
   `progress=end` block reliably carries `frame=total`.
4. vspipe stderr mixes CR-delimited `Frame:` lines with LF-delimited status lines — split
   on whichever of \r/\n comes first (naive CR-first splitting glues lines).
5. vspipe's last `Frame:` update may be < total (rate-limited; saw 1342/1440) — treat
   process exit as completion, never wait for `Frame: N/N`.
6. vspipe's counter leads the encoder's (pipe buffering) — encoder `frame=` drives ETA;
   vspipe signal is secondary (useful pre-encode, e.g. during bestsource indexing).

## S5 — toggle A/B player prototype (2026-07-17): PASS (build+run; eyeball pending)

`s5_ab_player/ABPlayer.swift` — 164 lines, AppKit+AVFoundation, per ADR-8: two muted
AVPlayers / stacked AVPlayerLayers, KVO-gated `preroll(atRate:)`, single
`setRate(1, time:, atHostTime:)` anchor shared by both, SPACE flips layer opacity only,
LEFT/RIGHT zero-tolerance frame-step (1001/24000), P pause/resume with re-anchor.
Compiles clean (`swiftc … -framework AVFoundation -framework AppKit`, exit 0); launched,
window up, alive at 6 s, clean kill. **Glitch-free flip judgment = user eyeball**:
`cd` repo root, run `spikes/s5_ab_player/abplayer` (build first per its README).
A clip: `s5_ab_player/source60_preview.mp4`; B clip: `s3_pipeline/out60_preview.mp4`.

AVFoundation gotchas (bake into M2 player):
1. `preroll(atRate:)` silently fails unless item is `.readyToPlay` and rate 0 — gate
   behind item-status KVO.
2. Anchor host time must be ~100 ms in the future; anchoring at "now" drops first frames.
3. Wrap opacity/layer changes in `CATransaction.setDisableActions(true)` or CA's implicit
   0.25 s cross-fade reads as a glitch.
4. After pause, snap both players to the nearest 1001/24000 boundary before stepping or
   A/B can rest on different frames.
