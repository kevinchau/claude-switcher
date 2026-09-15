#!/usr/bin/env bash
#
# Build build/Claude Switcher.dmg — a drag-to-Applications disk image containing
# the app, signed with the same Developer ID identity as the app itself.
#
# Notarization is separate: run `make notarize-dmg` after this (the disk image is
# a distinct artifact from the app and needs its own ticket, so that a download
# of the .dmg opens without a Gatekeeper prompt).
#
# Usage:  scripts/dmg.sh
#         CODESIGN_IDENTITY="Developer ID Application: …" scripts/dmg.sh

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

APP_NAME="Claude Switcher"
APP_DIR="$ROOT/build/$APP_NAME.app"
DMG="$ROOT/build/$APP_NAME.dmg"
VOLNAME="$APP_NAME"

[[ -d "$APP_DIR" ]] || { echo "error: $APP_DIR not found — run 'make bundle' first" >&2; exit 1; }

STAGE="$(mktemp -d)/dmg"
mkdir -p "$STAGE"
cp -R "$APP_DIR" "$STAGE/"
# The /Applications alias is what makes the window a drag-to-install target.
ln -s /Applications "$STAGE/Applications"

echo "==> Creating disk image"
rm -f "$DMG"
hdiutil create \
  -volname "$VOLNAME" \
  -srcfolder "$STAGE" \
  -fs HFS+ \
  -format UDZO \
  -ov \
  "$DMG" >/dev/null
rm -rf "$(dirname "$STAGE")"

# Sign the image itself. Without this the .dmg is unsigned even though the app
# inside it is fine, and Gatekeeper judges the thing the user actually downloaded.
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> Signing the disk image with: $CODESIGN_IDENTITY"
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
  codesign --verify --strict --verbose=2 "$DMG"
else
  echo "==> No Developer ID identity — the disk image is left unsigned" >&2
fi

echo "==> Built: $DMG ($(du -h "$DMG" | cut -f1))"
