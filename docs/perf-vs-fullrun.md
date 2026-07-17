# Open question: VS full-run throughput (parked 2026-07-17)

During the M4 `--selftest-vs` full-movie run, throughput sat at ~80 fps (3.3×
realtime) versus 250–280 fps (≈10×) in spikes S1–S3, with vspipe at ~1.3 cores
(spikes: ~6.7) and ffmpeg nearly idle. Output correct, only slow. Parked for later
revisiting — not a blocker (3.3× realtime is usable).

## Hypothesis 0 (likely, check first): Low Power Mode

The machine may have been in battery-saver / Low Power Mode during the run — that
alone throttles P-cores and would explain both the low core utilization and the
steady-but-slow rate. The fast spike numbers were measured earlier in the day.

**Check next session:** `pmset -g | grep -i lowpower` (and whether on AC), then simply
re-run a 5-min window benchmark on AC power with Low Power Mode off:

```
cd spikes/s3_pipeline
VAPOURSYNTH_EXTRA_PLUGIN_PATH="$HOME/Library/Application Support/FilmRestore/plugins" \
  /opt/homebrew/bin/vspipe -p chain5min.vpy .
```

≈255 fps → hypothesis confirmed, close this file with a dated note (and consider
having the app warn when Low Power Mode is active before a full run —
`ProcessInfo.processInfo.isLowPowerModeEnabled`).

## If it reproduces at full power: isolation matrix

Structural differences between fast spike runs and the slow app full run:
1. spikes trimmed the clip in-script before filtering; the app's full run runs
   deflicker's 10 shifted-PlaneStats prop_src clips over all 131,665 frames;
2. the app's full-run ffmpeg demuxes the 25 GB source as a second input for audio.

~2,000-frame benchmarks (vspipe `-s/-e` bounds a run without editing the .vpy):

| # | Setup | Isolates |
|---|---|---|
| A | untrimmed full chain, `vspipe -p -s 14000 -e 15999 … .` | full-length graph, no encode/audio |
| B | trimmed-in-script chain (spike baseline) | expect ~280 fps |
| C | untrimmed, deflicker OFF | deflicker's shifted-stats graph as culprit |
| D | untrimmed chain \| ffmpeg with vs without the audio input | audio-demux throttling |

Decision: A slow + B fast + C fast → deflicker graph scaling; fix by replacing the 10
spliced stats clips with one stats prop_src + lazily-cached means (then re-validate
bit-exactness with the S1 framemd5 procedure). A fast + D-with-audio slow → add
`-thread_queue_size 4096` to the audio input or pre-demux audio to FLAC and mux that.
A slow + C slow → VS cache/threading; set explicit `core.num_threads`/cache in the
generated .vpy.

Target when revisited: ≥200 fps sustained on the 5-min window, `--selftest-vs`
re-run ALL PASS.
