#!/bin/bash
# S2/M3: build DeScratch from source on arm64 (not available prebuilt from
# Stefan-Olt/vs-plugin-build). Verified working 2026-07-17: DeScratch 4.0,
# meson 1.x + ninja from Homebrew, VS headers come from the repo's submodule.
set -euo pipefail

PLUGDIR="$HOME/Library/Application Support/FilmRestore/plugins"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$PLUGDIR"

cd "$WORK"
git clone --depth 1 --recurse-submodules --shallow-submodules \
  https://github.com/vapoursynth/descratch.git descratch
meson setup descratch/build descratch --buildtype=release
ninja -C descratch/build

lib="$(find descratch/build -name '*.dylib' -type f | head -1)"
cp "$lib" "$PLUGDIR/libdescratch.dylib"
install_name_tool -id "@loader_path/libdescratch.dylib" "$PLUGDIR/libdescratch.dylib" || true
codesign -s - -f "$PLUGDIR/libdescratch.dylib"
echo "installed: $PLUGDIR/libdescratch.dylib"
