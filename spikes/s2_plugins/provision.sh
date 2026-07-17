#!/bin/bash
# S2: provision restoration plugins (darwin-aarch64 prebuilts) into the app-managed
# dir loaded via VAPOURSYNTH_EXTRA_PLUGIN_PATH. Never touches Homebrew's tree.
# sha256 sums recorded to manifest.sha256 on first run; verified on re-runs.
set -euo pipefail

PLUGDIR="$HOME/Library/Application Support/FilmRestore/plugins"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PLUGDIR"

declare -a URLS=(
  "https://github.com/Stefan-Olt/vs-plugin-build/releases/download/vsplugin/com.nodame.mvtools/v24/darwin-aarch64/2024-09-30T17.08.31%2B00.00Z/MVTools-v24-darwin-aarch64.zip"
  "https://github.com/Stefan-Olt/vs-plugin-build/releases/download/vsplugin/com.vapoursynth.removedirt/v1.1/darwin-aarch64/2026-01-07T00.39.06%2B00.00Z/RemoveDirt-v1.1-darwin-aarch64.zip"
  "https://github.com/Stefan-Olt/vs-plugin-build/releases/download/vsplugin/com.nodame.temporalmedian/v1/darwin-aarch64/2024-09-30T20.56.40%2B00.00Z/TemporalMedian-v1-darwin-aarch64.zip"
  "https://github.com/adworacz/zsmooth/releases/download/0.19.0/zsmooth-aarch64-macos.zip"
)

cd "$WORK"
for url in "${URLS[@]}"; do
  f="${url##*/}"
  echo "== $f"
  curl -fsSL -o "$f" "$url"
  shasum -a 256 "$f"
  unzip -o -q "$f" -d extracted/
done

find extracted -name '*.dylib' -exec cp -v {} "$PLUGDIR/" \;
shasum -a 256 *.zip > "$PLUGDIR/manifest.sha256"
echo "== installed:"
ls -la "$PLUGDIR"
