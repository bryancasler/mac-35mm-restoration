#!/bin/bash
# Package FilmRestore.app into an unsigned (ad-hoc) .dmg at release/FilmRestore.dmg.
# Re-run after any app change — CLAUDE.md requires the refreshed dmg to ride in the
# same commit as source changes under FilmRestore/.
# First launch on another Mac: right-click → Open (unsigned = Gatekeeper prompt).
set -euo pipefail

cd "$(dirname "$0")/.."
./scripts/make-app.sh "${1:--}"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R dist/FilmRestore.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p ../release
rm -f ../release/FilmRestore.dmg
hdiutil create -volname FilmRestore -srcfolder "$STAGE" -ov -format UDZO \
  ../release/FilmRestore.dmg -quiet
echo "built release/FilmRestore.dmg ($(du -h ../release/FilmRestore.dmg | cut -f1 | tr -d ' '))"
