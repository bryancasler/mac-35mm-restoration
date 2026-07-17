# FilmRestore (working title)

Single-purpose macOS app (Apple Silicon only) for restoring digitized film scans:
deflicker, vertical-scratch removal, dust/dirt removal, then a clean HEVC encode.
Native SwiftUI shelling out to Homebrew-installed ffmpeg and VapourSynth. All FOSS.

Fixed, validated processing order: **deflicker → scratch removal → dirt removal → encode**.

## Status

M1 (spike validation) complete — all five spikes pass; M2 (the app, ffmpeg-only) in
progress. See:

- [docs/ADR.md](docs/ADR.md) — architecture decision record (incl. VapourBox prior-art verdict)
- [docs/PLAN.md](docs/PLAN.md) — milestones M0–M5, spike list, verification criteria
- [spikes/RESULTS.md](spikes/RESULTS.md) — spike verdicts with numbers
- [FilmRestore/](FilmRestore/) — the app (SwiftPM package)

## Build & run

```
cd FilmRestore
swift build && .build/debug/FilmRestore          # GUI
.build/debug/FilmRestore --selftest <file.mkv>   # headless M2 verification
swift test                                        # unit tests
```

Requires `brew install ffmpeg` (VapourSynth stack comes in with M3/M4).

License: GPL-3.0 (DeScratch/RemoveDirt are GPL; see ADR-11).
