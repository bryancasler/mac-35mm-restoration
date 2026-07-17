# FilmRestore (working title)

Single-purpose macOS app (Apple Silicon only) for restoring digitized film scans:
deflicker, vertical-scratch removal, dust/dirt removal, then a clean HEVC encode.
Native SwiftUI shelling out to Homebrew-installed ffmpeg and VapourSynth. All FOSS.

Fixed, validated processing order: **deflicker → scratch removal → dirt removal → encode**.

## Status

Planning complete; spikes (M1) next. See:

- [docs/ADR.md](docs/ADR.md) — architecture decision record (incl. VapourBox prior-art verdict)
- [docs/PLAN.md](docs/PLAN.md) — milestones M0–M5, spike list, verification criteria
- [spikes/](spikes/) — throwaway validation scripts and RESULTS.md

License: GPL-3.0 (DeScratch/RemoveDirt are GPL; see ADR-11).
