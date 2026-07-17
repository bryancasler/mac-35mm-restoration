#!/bin/bash
# M5: assemble FilmRestore.app from the SwiftPM release build.
# Ad-hoc signed by default; pass a "Developer ID Application: …" identity as $1
# to sign for distribution (then notarize with scripts in README).
set -euo pipefail

cd "$(dirname "$0")/.."
IDENTITY="${1:--}"
APP="dist/FilmRestore.app"

swift build -c release

rm -rf dist && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp .build/release/FilmRestore "$APP/Contents/MacOS/FilmRestore"
# bundled python scripts — Bundle.module searches Contents/Resources in an .app
if [ -d .build/release/FilmRestore_FilmRestore.bundle ]; then
  cp -R .build/release/FilmRestore_FilmRestore.bundle "$APP/Contents/Resources/"
fi

# icon
swift scripts/make-icon.swift dist/icon_1024.png
ICONSET=dist/FilmRestore.iconset
mkdir -p "$ICONSET"
for s in 16 32 128 256 512; do
  sips -z $s $s dist/icon_1024.png --out "$ICONSET/icon_${s}x${s}.png" >/dev/null
  d=$((s * 2))
  sips -z $d $d dist/icon_1024.png --out "$ICONSET/icon_${s}x${s}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/FilmRestore.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>FilmRestore</string>
    <key>CFBundleDisplayName</key><string>FilmRestore</string>
    <key>CFBundleIdentifier</key><string>com.bryancasler.filmrestore</string>
    <key>CFBundleVersion</key><string>1.0</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>FilmRestore</string>
    <key>CFBundleIconFile</key><string>FilmRestore</string>
    <key>LSMinimumSystemVersion</key><string>15.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.video</string>
</dict>
</plist>
PLIST

codesign --force --deep --sign "$IDENTITY" "$APP"
echo "built $APP (signed: $IDENTITY)"
