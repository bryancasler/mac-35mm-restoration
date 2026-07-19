#!/bin/bash
# S7 visual-iteration harness: renders before|after composites for a fixed
# sample set through the current restoration chain (Animated-preset settings
# by default; override the chain by editing chain() in iter_chain.py).
# Usage: ./render_iter.sh <iter_label>
set -euo pipefail
ITER="${1:?iter label}"
PLUG="$HOME/Library/Application Support/FilmRestore/plugins"
PYSITE="$HOME/Library/Application Support/FilmRestore/pysite"
SCRIPTS="$(cd ../../FilmRestore/Sources/FilmRestore/Resources/scripts && pwd)"
SRC="/Users/4Site/Desktop/The Brave Little Toaster Raw 35mm Scan [Encode].mkv"
OUT="iters/$ITER"
mkdir -p "$OUT"

# fixed sample set: name:start_frame (36-frame windows, mid-frame captured)
SAMPLES="tenA:14386 tenB:14746 tenC:15106 tenD:15466 static:50000 motion:70000"

for s in $SAMPLES; do
  name="${s%%:*}"; start="${s#*:}"
  cat > "$OUT/${name}.vpy" <<VPY
import sys
sys.path.insert(0, r"$SCRIPTS")
sys.path.insert(0, r"$PYSITE")
import vapoursynth as vs
core = vs.core
from iter_chain import chain
clip = core.bs.VideoSource(r"$SRC")
before = clip[$start:$start+36]
after = chain(before, ml_path=r"$PWD/mlmasks/${name}.mkv")
pair = core.std.StackHorizontal([before, after])
pair = pair[18]  # mid frame only
pair.set_output()
VPY
  VAPOURSYNTH_EXTRA_PLUGIN_PATH="$PLUG" PYTHONPATH="$PYSITE:." /opt/homebrew/bin/vspipe -c y4m "$OUT/${name}.vpy" - 2>/dev/null \
    | ffmpeg -y -hide_banner -loglevel error -f yuv4mpegpipe -i - -frames:v 1 "$OUT/${name}.png"
done
echo "iteration $ITER rendered: $OUT"
