#!/usr/bin/env bash
#
# Assemble build/Claude Switcher.app from the release binary and sign it.
#
# Usage:   scripts/bundle.sh
#          VERSION=0.2.0 scripts/bundle.sh
#          CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" scripts/bundle.sh
#
# Signing identity resolution, in order:
#   1. $CODESIGN_IDENTITY, if set.
#   2. The first "Developer ID Application" identity in the keychain.
#   3. Ad-hoc ("-").
#
# Only 1 and 2 produce something other machines can run without Gatekeeper
# blocking it, and only those can then be notarized (see scripts/notarize.sh).
# An ad-hoc build is fine on the machine that built it and nowhere else.
#
# Expects `swift build -c release` to have already run (the Makefile's `bundle`
# target depends on `build`).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

VERSION="${VERSION:-0.2.0}"
APP_NAME="Claude Switcher"
EXEC_NAME="claude-switcher"
BUNDLE_ID="tech.local.claude-switcher"
BUILD_DIR="$ROOT/build"
APP_DIR="$BUILD_DIR/$APP_NAME.app"
CONTENTS="$APP_DIR/Contents"

# Ask SwiftPM where the release products actually live; fall back to the
# conventional path if the query fails (e.g. no toolchain on PATH).
BIN_DIR="$(swift build -c release --show-bin-path 2>/dev/null | tail -n 1 || true)"
if [[ -z "${BIN_DIR:-}" || ! -d "$BIN_DIR" ]]; then
  BIN_DIR="$ROOT/.build/release"
fi
BIN_SRC="$BIN_DIR/$EXEC_NAME"

if [[ ! -x "$BIN_SRC" ]]; then
  echo "error: release binary not found at: $BIN_SRC" >&2
  echo "       run 'make build' (or 'swift build -c release') first." >&2
  exit 1
fi

echo "==> Assembling $APP_NAME.app"
rm -rf "$APP_DIR"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

cp "$BIN_SRC" "$CONTENTS/MacOS/$EXEC_NAME"
chmod +x "$CONTENTS/MacOS/$EXEC_NAME"

ICNS="$ROOT/assets/AppIcon.icns"
if [[ -f "$ICNS" ]]; then
  cp "$ICNS" "$CONTENTS/Resources/AppIcon.icns"
else
  echo "warning: $ICNS missing - building without an icon (run scripts/make-icon.sh)" >&2
fi

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>en</string>
	<key>CFBundleExecutable</key>
	<string>$EXEC_NAME</string>
	<key>CFBundleIdentifier</key>
	<string>$BUNDLE_ID</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundleIconName</key>
	<string>AppIcon</string>
	<key>CFBundleName</key>
	<string>$APP_NAME</string>
	<key>CFBundleDisplayName</key>
	<string>$APP_NAME</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>$VERSION</string>
	<key>CFBundleVersion</key>
	<string>$VERSION</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>LSUIElement</key>
	<true/>
	<key>NSHighResolutionCapable</key>
	<true/>
	<key>NSSupportsAutomaticTermination</key>
	<false/>
	<key>NSSupportsSuddenTermination</key>
	<false/>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.developer-tools</string>
	<key>NSHumanReadableCopyright</key>
	<string>MIT licensed. Not affiliated with or endorsed by Anthropic.</string>
</dict>
</plist>
PLIST

# Sanity-check the plist we just generated before handing it to codesign.
/usr/bin/plutil -lint "$CONTENTS/Info.plist" >/dev/null

# Quarantine / resource-fork xattrs make codesign fail; strip them first.
/usr/bin/xattr -cr "$APP_DIR" 2>/dev/null || true

# Resolve a signing identity. `security find-identity` prints lines like:
#   1) ABC123... "Developer ID Application: Jane Doe (TEAM123)"
if [[ -z "${CODESIGN_IDENTITY:-}" ]]; then
  CODESIGN_IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
    | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -n 1)"
fi

if [[ -n "${CODESIGN_IDENTITY:-}" ]]; then
  echo "==> Signing with: $CODESIGN_IDENTITY"
  # --options runtime (hardened runtime) and a secure timestamp are both
  # prerequisites for notarization; neither is possible with an ad-hoc signature.
  codesign --force --sign "$CODESIGN_IDENTITY" \
           --options runtime --timestamp \
           "$APP_DIR"
  SIGNED_PROPERLY=1
else
  echo "==> No Developer ID Application identity found - signing ad-hoc"
  codesign --force --sign - "$APP_DIR"
  SIGNED_PROPERLY=0
fi

echo "==> Verifying signature"
codesign --verify --strict --verbose=2 "$APP_DIR"

echo "==> Gatekeeper assessment"
if spctl -a -t exec -vv "$APP_DIR" 2>&1 | sed 's/^/    /'; then
  :
else
  echo "    (rejected - expected until the app is Developer ID signed AND notarized)"
fi

echo "==> Built: $APP_DIR (version $VERSION)"

if [[ "$SIGNED_PROPERLY" -eq 0 ]]; then
  cat >&2 <<'WARN'

NOTE: this is an AD-HOC signed build.
  It runs on this Mac, but on any other Mac Gatekeeper will refuse to open it
  ("unidentified developer" / "damaged"). To produce a build you can hand to
  someone else you need a "Developer ID Application" certificate from an Apple
  Developer Program membership, then:

      CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make bundle
      make notarize

WARN
fi
