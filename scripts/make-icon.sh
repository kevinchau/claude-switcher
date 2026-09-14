#!/usr/bin/env bash
#
# Build assets/AppIcon.icns from assets/AppIcon.png (1024x1024).
# Regenerate only when the artwork changes; the .icns is committed so a plain
# `make bundle` needs no image tooling.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT/assets/AppIcon.png"
OUT="$ROOT/assets/AppIcon.icns"
SET="$(mktemp -d)/AppIcon.iconset"

[[ -f "$SRC" ]] || { echo "error: missing $SRC" >&2; exit 1; }

mkdir -p "$SET"
# The sizes `iconutil` expects; anything missing makes it refuse the set.
for spec in "16 16x16" "32 16x16@2x" "32 32x32" "64 32x32@2x" \
            "128 128x128" "256 128x128@2x" "256 256x256" "512 256x256@2x" \
            "512 512x512" "1024 512x512@2x"; do
  set -- $spec
  sips -z "$1" "$1" "$SRC" --out "$SET/icon_$2.png" >/dev/null
done

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"
echo "==> Wrote $OUT ($(du -h "$OUT" | cut -f1))"
