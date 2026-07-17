# FilmRestore — Milestone Plan & Spike List

Status: accepted 2026-07-17. Architecture decisions live in [ADR.md](ADR.md).

Local state verified at planning time: Homebrew 6.0.11, ffmpeg 8.1.2 installed;
VapourSynth **not** installed (good — spikes exercise the real setup path); Xcode 26.6,
macOS 26.5, M4 Pro.

Validated phase-1 command (tested against a real 35mm scan, 1440x1080 23.98fps H.264 MKV
with PCM audio, ~12x realtime on the media engine):

```
ffmpeg -i INPUT.mkv -map 0 -vf "deflicker=mode=pm:size=10" \
  -c:v hevc_videotoolbox -q:v 60 -tag:v hvc1 -c:a flac OUTPUT.mkv
```

---

## Milestones

**M0 — Planning docs + process system into repo (0.5 day). ✅ done 2026-07-17**
Commit `docs/ADR.md` + `docs/PLAN.md`, `spikes/` skeleton, and the **repo-based
process-management system**: `CLAUDE.md` (session protocol, file roles, sub-agent
briefing template) + `STATE.md` (living state, 60-line cap). Rationale: conversation
context compacts and sessions end; the .md files are the durable source of truth, and
sub-agents get briefed by file pointer instead of pasted context. Protocol details
live in [CLAUDE.md](../CLAUDE.md).

**M1 — Spike scripts (no UI).** Prove/decide the risky bits with throwaway bash/python in
`spikes/` (details below). Exit criteria: S1–S3 have written verdicts (numbers + chosen
topology) committed as `spikes/RESULTS.md`. *The highest-risk item is the deflicker port
(S1), not vspipe piping — desk research largely de-risked the latter.*

**M2 — SwiftUI app, ffmpeg-only (the useful shipped tool). ✅ built 2026-07-17;
headless selftest ALL PASS on the real scan (10/10 criteria); GUI eyeball pending user.**
Drag-drop + Open dialog → ffprobe JSON probe card (resolution, duration, codec, audio
tracks, est. size/runtime) → deflicker controls (size 2–129 def 10, mode pm/am/median) →
encode settings (VT quality slider def 60; audio copy/FLAC; advanced: x265 CRF, FFV1) →
**test-clip render** (60 s from user timestamp, default 10:00, `-ss` before `-i` for fast
seek) → **toggle A/B player** → full run with progress/ETA/sleep-prevention, disk-space
guard, per-job log. Internals: `JobPlan` + `ProcessRunner` (async stderr/`-progress`
parsing) + `FFmpegBackend`.

**M3 — Dependency detection + guided setup. ✅ done 2026-07-17** — verified from-zero:
plugins dir wiped → detection reports missing → app's provisioner re-downloads
(sha256-verified) + rebuilds DeScratch → doctor 10-frame smoke PASS. (brew-side
detection verified by state inspection; a literal `brew uninstall vapoursynth` walk
was skipped — detection covers it and the reinstall cost buys nothing.)
Detect: `/opt/homebrew/bin/{ffmpeg,vspipe}` + versions; `vapoursynth-bestsource` present;
plugin dir state. Setup screen: copy-paste brew commands with live re-check; then the
**plugin provisioning step** (user-approved, sha256-pinned downloads from
vs-plugin-build/zsmooth into Application Support; DeScratch source-build script if needed).
A "doctor" pane runs a 10-frame smoke .vpy through vspipe to prove the stack end-to-end.
*Provisioning is bigger than "show brew commands" because the restoration plugins aren't in
Homebrew — this is the meat of M3.*

**M4 — Restoration filters + single-encode pipeline.**
`.vpy` template engine (bestsource → deflicker.py → DeScratch → RemoveDirt/SpotLess, each
behind its toggle); vspipe|ffmpeg backend with colorimetry restatement; DeScratch **mark
mode** preview (its native `mark=True` debug highlight) as a test-clip variant; scratch
controls (mindif, minlen, maxangle), dirt engine + strength mapping (RemoveDirt:
gmthreshold/mthreshold; SpotLess: thsad/radT). Test-clip A/B now compares any two
setting-variants, not just source-vs-output.

**M5 — Polish.**
Presets ("35mm scan", "8mm home movie", "VHS capture"), job queue, app icon, notarized
release build (Developer ID + notarytool; straightforward since nothing is bundled), README
with setup walkthrough.

---

## Riskiest assumptions → spikes (ordered by remaining risk)

Desk research already answered the original four risky assumptions:
(1) vspipe→VideoToolbox piping **yes** (with the colorimetry gotcha, ADR-4);
(2) arm64 plugin builds **yes** (VapourBox CI + vs-plugin-build prove it; recipe extracted);
(3) progress parsing **yes** (`-progress` works on pipes; app supplies totals);
(4) AVKit **sufficient** (toggle pattern, ADR-8). What remains is empirical:

**S1 — deflicker.py fidelity (top risk).** Port `vf_deflicker` (pm/am/median) to a VS
script. Validate: run ffmpeg-deflicker and VS-deflicker on the same 60 s of the real scan,
compare per-frame luma means + PSNR between outputs; pass = visually identical and
mean-luma curves overlap. Fail → fall back to double-pipe (S1b: prove ffmpeg rawvideo →
custom .vpy pipe-source → ffmpeg encode on 60 s).

**S2 — the full arm64 stack, end-to-end + benchmark.**
`brew install vapoursynth vapoursynth-bestsource`; provision MVTools (pin version — v29
current, freeze history on macOS), zsmooth, TemporalMedian, RemoveDirt from vs-plugin-build
prebuilts into an EXTRA_PLUGIN_PATH dir; confirm whether DeScratch is available prebuilt,
else meson-build it (VapourBox recipe). Run each filter on the real scan via vspipe null
output (`vspipe -p job.vpy .`) and record fps: bestsource alone, +DeScratch, +RemoveDirt,
+SpotLess. Verdict includes RemoveDirt-vs-SpotLess speed/quality and whether the ADR-12
default flips. No published M-series MVTools benchmarks exist — this number decides UX
expectations (test-clip render time).

**S3 — single-encode throughput + correctness.** Full chain
`vspipe | ffmpeg -c:v hevc_videotoolbox` with audio mux from source, colorimetry restated:
confirm output plays correctly (QuickTime + mpv), audio sync, hvc1 tag, and measure
end-to-end fps on 60 s.

**S4 — progress parsing.** Tiny script driving both phase-1 and phase-2 commands, parsing
`-progress pipe:1` + vspipe stderr, printing ETA; pass = monotonic sane ETA both modes.

**S5 — toggle A/B prototype.** ~100-line Swift playground/app: two pre-rolled muted
AVPlayers, host-time anchor, opacity flip, zero-tolerance frame-step. Pass = no visible
glitch on flip, frame-accurate stepping.

Spikes are throwaway: bash + .vpy + minimal Swift, committed under `spikes/` with a
RESULTS.md verdict each.

---

## Repo layout

```
mac-35mm-restoration/
├── docs/ADR.md, PLAN.md          # M0: planning docs
├── spikes/                        # M1: s1_deflicker/ s2_plugins/ s3_pipeline/ s4_progress/ s5_ab_player/ RESULTS.md
├── FilmRestore/                   # M2+: Xcode project
│   ├── App/ (SwiftUI views)
│   ├── Core/ (JobPlan, ProcessRunner, Probe, DiskGuard, ProgressParser)
│   ├── Backends/ (FFmpegBackend, VapourSynthBackend, VpyTemplate)
│   ├── Setup/ (DependencyDetector, PluginProvisioner, manifest.json)
│   └── Resources/scripts/ (deflicker.py, spotless.py)
└── LICENSE (GPL-3.0)
```

## Verification

- **M0/M1:** each spike has an executable pass/fail criterion above; RESULTS.md records
  numbers (fps, PSNR) against the real 1440x1080 scan.
- **M2:** end-to-end: drag the real MKV in → probe card correct vs ffprobe manual run →
  60 s test clip renders and A/B toggles glitch-free → full run output matches the
  validated CLI command's output (same ffmpeg args ⇒ bit-similar), ETA within ~15% after
  30 s, source untouched (checksum), log written.
- **M3:** wipe VapourSynth (`brew uninstall`), walk the guided setup from zero on this
  machine; doctor smoke-test passes.
- **M4:** A/B of deflicker-only vs deflicker+DeScratch+dirt on the scan's known-damaged
  sections; mark-mode highlights real scratches; single-encode output audio-synced and
  correctly tagged.
