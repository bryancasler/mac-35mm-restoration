# Spike Results

Verdicts land here as each spike completes (M1). Pass/fail criteria are defined in
[docs/PLAN.md](../docs/PLAN.md#riskiest-assumptions--spikes-ordered-by-remaining-risk).

| Spike | Question | Verdict | Numbers |
|---|---|---|---|
| S1 | deflicker.py port matches ffmpeg vf_deflicker? | **PASS** (2026-07-17) | pm/am: 1438/1440 frames bit-identical, rest ≥69 dB; 298 fps; full chain 280 fps |
| S2 | arm64 plugin stack provisions + benchmarks | **PASS** (2026-07-17) | bs 573 / +DeScratch 356 / +RemoveDirt 346 / +SpotLess 75 / full chain 302 fps |
| S3 | vspipe→hevc_videotoolbox single-encode correct + fast | pending | — |
| S4 | progress parsing → reliable ETA both modes | pending | — |
| S5 | toggle A/B player glitch-free | pending | — |

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
- Gotcha for anyone comparing outputs: ffmpeg's `psnr` filter syncs by PTS — mkv-vs-y4m
  timestamp rounding misaligns frames and reports a bogus ~41 dB. Use `-f framemd5`
  (sequential) or fifos into one psnr process.
- Throughput: deflicker.py alone 298 fps; **full restoration chain
  (deflicker → DeScratch → RemoveDirt) 280 fps = 11.7x realtime** — VS filtering will
  not be the pipeline bottleneck (VideoToolbox encode runs ~12x).
- Watch: per-frame `std.Lut` node creation is the cost driver; fine at 1440x1080.
