# FilmRestore — Architecture Decision Record

Status: accepted 2026-07-17. Scope: macOS (Apple Silicon only) app that restores digitized
film scans with a fixed, validated pipeline: **deflicker → scratch removal → dirt removal →
encode**. Deflicker runs first because brightness fluctuation confuses the motion estimation
the dirt filters depend on; scratch removal precedes dirt removal so temporal filters don't
chew scratch edges. This ordering is tested and not up for re-derivation.

Companion doc: [PLAN.md](PLAN.md) (milestones, spikes, verification).

---

## Prior-art verdict: VapourBox — study it, don't fork it

Research (repo cloned and read, 2026-07-17): [VapourBox](https://github.com/StuartCameronCode/VapourBox)
is a **Flutter (Dart) GUI + Rust CLI worker**, not native — it actually *started* as a SwiftUI
app (`legacy/iDeinterlace/`) and was ported away from what we want. GPL-3.0, single
maintainer, 34 stars, very active but bus-factor 1 with self-admitted flaky macOS deps CI.

**Why building fresh wins:**
- Its preview is **single-frame** before/after (worker `--preview --frame N` → PNG). Our core
  UX — 60-second test clips with A/B playback — doesn't exist there and doesn't fall out of
  its architecture.
- Contributing a SwiftUI front end to a Flutter app is a rewrite, not a contribution.
- Adding a filter touches ~20 places across Dart/Rust/JSON/vpy templates (its own docs warn
  of silent failures).

**What we take from it (GPL-3.0, compatible with our license):**
- `Scripts/download-deps-macos.sh` (1718 lines) — the proven arm64 recipe: DeScratch and
  MVTools **build cleanly from source with meson on arm64**; `install_name_tool`
  @loader_path relocation + ad-hoc codesign ordering; the vspipe env-wrapper trick
  (`VAPOURSYNTH_CONF_PATH` with `AutoloadSystemPluginDir=false`).
- `worker/templates/spotless.py` — SpotLess is **not a compiled plugin**, it's ~150 lines of
  Python (Didée's algorithm via `mv.Super/Analyse/Compensate` + TemporalMedian). We ship our
  own copy; only binary deps are MVTools + a temporal-median provider.
- The `.vpy` templating approach and frame-map design.
- Its deps model (runtime-downloaded, sha256-verified zip) is the blueprint **if** phase-3
  bundling ever happens.

---

## ADR-1: Build fresh; native SwiftUI app + thin process orchestration

SwiftUI (macOS 15+ target), `Foundation.Process` for ffmpeg/ffprobe/vspipe. No Electron, no
embedded libffmpeg/libvapoursynth — shell-out only, which also keeps the GPL boundary clean
and sidesteps signing issues for phases 1–2.

## ADR-2: Two pipeline backends behind one `JobPlan` abstraction

- **Phase 1 (ffmpeg-only):** exactly the validated command —
  `ffmpeg -i IN -map 0 -vf "deflicker=mode=pm:size=N" -c:v hevc_videotoolbox -q:v Q -tag:v hvc1 -c:a flac|copy OUT.mkv`.
- **Phase 2 (VS active):** single-encode chain: generate `.vpy` from a Swift template →
  `vspipe -c y4m job.vpy - | ffmpeg -f yuv4mpegpipe -i - -i SOURCE -map 0:v:0 -map 1:a -c:v hevc_videotoolbox … -c:a flac|copy -shortest OUT.mkv`.
- The UI never knows which backend runs; it sees a `JobPlan` (stages, arg arrays, expected
  frame total, output path).

## ADR-3: Deflicker inside VapourSynth via a Python port of ffmpeg's `vf_deflicker`

Research finding: no VS-native deflicker equivalent exists, and Homebrew ffmpeg is **not**
built with `--enable-vapoursynth`, so ffmpeg can't read .vpy scripts. But `vf_deflicker.c` is
small and simple: per-frame luma mean normalized against a windowed mean
(am/gm/hm/qm/cm/pm/median modes). Port it as `deflicker.py` (PlaneStats + `frame_eval` +
`std.Expr`/`std.Levels` gain) shipped with the app. **Spike S1 gates this**: output must
match ffmpeg's deflicker within tolerance on the real scan. Fallbacks, in order:
(a) double pipe `ffmpeg -vf deflicker [rawvideo] | vspipe [custom pipe-source .vpy] | ffmpeg encode`
(VapourBox's proven pattern, no intermediate file); (b) FFV1 intermediate file (always
works; two passes + temp disk).

## ADR-4: y4m colorimetry must be restated at encode

Verified: vspipe's y4m carries geometry/fps/bit depth (10-bit survives as `C420p10`) but
**no color matrix/primaries/transfer tags**. The encode ffmpeg always gets explicit
`-colorspace/-color_primaries/-color_trc/-color_range` copied from the probe of the source.
10-bit: be explicit with `-pix_fmt p010le -profile:v main10` (hevc_videotoolbox accepts
nv12/yuv420p/p010le; verified locally on ffmpeg 8.1.2).

## ADR-5: Source loader = bestsource

`brew install vapoursynth-bestsource` — arm64 bottle in homebrew-core, MIT, maintained by
Mellbin, "always frame accurate" indexing. ffms2 is the fallback; L-SMASH adds nothing here.

## ADR-6: Dependency strategy — Homebrew core + app-managed prebuilt plugins

- Homebrew (guided setup screen shows commands, app verifies versions):
  `brew install ffmpeg vapoursynth vapoursynth-bestsource`. VapourSynth is R77 in
  homebrew-core with arm64 bottles.
- **Restoration plugins are in no Homebrew repo.** The app provisions them itself: downloads
  sha256-pinned darwin-aarch64 dylibs from
  [Stefan-Olt/vs-plugin-build](https://github.com/Stefan-Olt/vs-plugin-build) releases
  (CI-builds 76+ plugins for macOS 11+, including MVTools, RemoveDirt, TemporalMedian) and
  [zsmooth](https://github.com/adworacz/zsmooth)'s official arm64 releases into
  `~/Library/Application Support/FilmRestore/plugins/`, loaded via
  **`VAPOURSYNTH_EXTRA_PLUGIN_PATH`** — never touching Homebrew's tree (whose site-packages
  path changes on Python bumps).
- Pin a version manifest (URL + sha256 per plugin) in the app; each download is listed and
  user-approved on the setup screen.
- DeScratch is likely absent from vs-plugin-build (spike confirms): fallback is the repo's
  `build-descratch.sh` (meson build, VapourBox-proven on arm64) as a guided step for this
  one plugin.
- Python-side scripts (`spotless.py`, `deflicker.py`) ship inside the app bundle and are
  injected via `sys.path` in the generated .vpy — scripts have no compile/notarize problem.
- MVTools: v24+ has official arm64/NEON support (sse2neon + aarch64 asm); **pin a known-good
  version** — Hybrid downgraded v23→v20 over macOS freezes; current is v29.

## ADR-7: No bundling of the VS stack in the .app (phases 1–2); phase-3 assessment: skip it

VapourBox proves bundling is possible (embedded python-build-standalone + VS R73 from source
+ full dylib relocation + separate deps download) and also proves its cost: 1700 lines of
build script, flaky CI, macOS-15+ floor, constant ABI chasing. For a single-user personal
tool with Homebrew already required, bundling buys nothing. If the app is ever distributed
broadly, adopt VapourBox's downloaded-deps model wholesale rather than in-app bundling.

## ADR-8: A/B preview = toggle-first, AVKit only (no custom compositor)

Two pre-rolled **muted** AVPlayers (source clip + rendered clip), anchored once via
`setRate(_:time:atHostTime:)` with `automaticallyWaitsToMinimizeStalling = false`, and the
A/B switch toggles **view opacity** — instant flip, no re-seek; ms-level drift is invisible
because only one is shown, and an instant flip is perceptually better for spotting
differences than side-by-side. Frame-step/seek uses zero-tolerance `seek(to:)`. Side-by-side
(if wanted later) = single AVPlayer + AVMutableComposition with two tracks and transforms —
sync perfect by construction; do NOT use free-running dual players for side-by-side.
Verified sufficient for local files; documented AVPlayer sync problems are HLS-specific.

## ADR-9: Progress/ETA = parse ffmpeg `-progress pipe:1` + app-supplied frame total

Verified: `-progress` emits machine-readable `frame=/fps=/speed=/out_time_us=` blocks ~1/s
identically for piped stdin input; what's missing on a pipe is only the *total*, which the
app knows from ffprobe (phase 1) or the VS script's frame count (phase 2). vspipe's stderr
`Frame: N/M` is the secondary signal (CR-delimited parsing). Per-job log file captures full
stderr of every process.

## ADR-10: Job safety

Estimated output size from quality-slider→bitrate heuristic (calibrated by test clips:
actual test-clip output size × duration ratio is the best estimator — a nice side-benefit of
test-clip-first UX); refuse start if > free space (`volumeAvailableCapacityForImportantUsage`).
Sleep prevention via `ProcessInfo.beginActivity(.idleSystemSleepDisabled)` (native, no child
process — equivalent to caffeinate; trivial to swap if you prefer the CLI). Source opened
read-only; output auto-suffixed `NAME.restored.mkv` with collision counter; never overwrite
without prompt.

## ADR-11: License GPL-3.0

DeScratch and RemoveDirt are GPL-2.0, spotless.py (if adapted from VapourBox) is GPL-3.0; we
only shell out to the binaries, but adapting any VapourBox code makes the repo GPL-3.0
anyway. GPL-3.0 satisfies "GPL-compatible" and is the least-friction choice.

## ADR-12: Dirt engine default stays RemoveDirt, with a benchmark-triggered escape hatch

arm64 caveat found in research: RemoveDirt's arm64 build is the plain-C path (its SIMD is
x86-only), while SpotLess rides NEON-optimized MVTools + zsmooth. If spike S2 shows
RemoveDirt unusably slow or clearly worse, flip the default to SpotLess and note why.
SpotLess's preferred temporal-median provider is **zsmooth** (MIT, official arm64 binaries) —
provision it instead of/alongside dubhater's TemporalMedian.
