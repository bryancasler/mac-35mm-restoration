# FilmRestore (working title)

Single-purpose macOS app (Apple Silicon only) for restoring digitized film scans:
deflicker, vertical-scratch removal, dust/dirt removal, then a clean HEVC encode.
Native SwiftUI shelling out to Homebrew-installed ffmpeg and VapourSynth. All FOSS.

Fixed, validated processing order: **deflicker → scratch removal → dirt removal → encode**.

## Setup walkthrough

1. **Homebrew tools** (the app's Setup screen shows these too, with live re-check):
   ```
   brew install ffmpeg                       # required — phase-1 features
   brew install vapoursynth vapoursynth-bestsource meson ninja   # for scratch/dirt removal
   ```
2. **Get the app** — either grab the prebuilt unsigned image committed at
   [release/FilmRestore.dmg](release/FilmRestore.dmg) (right-click → Open on first
   launch to pass Gatekeeper; regenerated on every app change), or build it yourself:
   ```
   cd FilmRestore
   ./scripts/make-dmg.sh        # → release/FilmRestore.dmg (via dist/FilmRestore.app)
   open dist/FilmRestore.app
   ```
   (Development: `swift build && .build/debug/FilmRestore`.)
3. **Restoration plugins:** open Setup (stethoscope icon) → *Download plugins…* —
   the app fetches four sha256-pinned prebuilt plugins (MVTools, RemoveDirt,
   TemporalMedian, zsmooth) into `~/Library/Application Support/FilmRestore/plugins`
   after you approve the exact URLs, and builds DeScratch from source (~2 min).
   Homebrew's tree is never touched. Then *Run smoke test* — it renders 10 frames
   through every plugin to prove the stack.

## Using it

1. Drag a scan in (MKV/MP4/MOV). The probe card shows resolution, duration, codec,
   audio, and estimated output size + runtime.
2. Pick a preset (35mm scan / 8mm home movie / VHS capture) or set the three filter
   groups by hand. "Mark detected scratches" renders a preview with scratches
   highlighted instead of fixed — good for tuning `mindif`/`minlen`.
3. **Render a test clip** (60 s, default from 10:00) → the A/B player opens:
   SPACE flips source↔filtered instantly, P pauses, arrow keys frame-step.
   *Pin B as A* keeps the current render so you can compare two settings variants.
4. **Restore full video** — output lands next to the source as `NAME.restored.mkv`
   (never overwrites; the source is opened read-only). Progress shows fps + ETA;
   sleep is prevented; every job writes a log to `~/Library/Logs/FilmRestore/`.
5. **Side-by-side comparison** — renders source (left) and restored (right) into one
   video next to the source (`NAME.sidebyside.mp4`): either a chosen start + length,
   or *Quick sample*, which picks six random 10-second segments spread across the
   film and stitches them into a one-minute comparison reel.
6. **Double/triple processing** — the 1×/2×/3× selector runs the whole restoration
   chain that many times *inside a single encode* (no generational loss, no
   intermediate files). Applies to full runs, test clips, side-by-side, and the queue.
7. Batch: add files to the Queue and run them all with the current settings.
   Live stats (frames/fps/speed/ETA) show during every job; a summary line
   (frames · wall time · fps · realtime × · output size) appears when it finishes.

Measured on an M4 Pro against a real 1440x1080 35mm scan: the full restoration
chain runs ~250 fps (≈10x realtime) — a 90-minute film in ~9 minutes.

## Distribution builds (optional)

`./scripts/make-app.sh "Developer ID Application: Your Name (TEAMID)"` signs with
your identity; then notarize:
```
ditto -c -k --keepParent dist/FilmRestore.app dist/FilmRestore.zip
xcrun notarytool submit dist/FilmRestore.zip --keychain-profile <profile> --wait
xcrun stapler staple dist/FilmRestore.app
```
Nothing is bundled (ADR-7), so notarization has no embedded-dylib complications.

## Project docs

- [docs/ADR.md](docs/ADR.md) — architecture decisions (incl. VapourBox prior-art verdict)
- [docs/PLAN.md](docs/PLAN.md) — milestones M0–M5 + verification criteria
- [spikes/RESULTS.md](spikes/RESULTS.md) — validation spike verdicts with numbers
- [CLAUDE.md](CLAUDE.md) / [STATE.md](STATE.md) — repo-based process management

License: GPL-3.0 (DeScratch/RemoveDirt are GPL; see ADR-11).
