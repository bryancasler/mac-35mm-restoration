# STATE — read me first

<!-- Hard cap: 60 lines. Prune on every update: durable facts → ADR/RESULTS; stale notes → delete. -->

## Where we are
- **Milestone:** M0 complete (planning docs + process system committed). M1 (spikes) is next.
- Last updated: 2026-07-17

## Next actions (in order)
1. S2 — install VS stack (`brew install vapoursynth vapoursynth-bestsource`), provision
   plugins from vs-plugin-build prebuilts, confirm DeScratch availability, benchmark
   filters on the real scan (spike defs: docs/PLAN.md → Riskiest assumptions)
2. S1 — port vf_deflicker to VS Python, validate vs ffmpeg output (top risk)
3. S3 — vspipe|ffmpeg single-encode end-to-end
4. S4 progress parsing, S5 A/B player prototype (low risk, can parallelize via sub-agents)

## Blockers / open questions
- None. User decisions on record: prebuilt plugin provisioning; VS-Python deflicker
  port preferred (fallbacks: double-pipe, then FFV1 intermediate) — see ADR-3, ADR-6.

## Environment facts (verified 2026-07-17)
- ffmpeg 8.1.2 (Homebrew), Xcode 26.6, macOS 26.5.1, M4 Pro. VapourSynth NOT installed yet.
- Real test asset: 35mm scan, 1440x1080, 23.98fps, H.264 MKV + PCM audio.
  Path: (fill in when first used by a spike)

## Fresh findings not yet in ADR/RESULTS
- (empty)
