#!/usr/bin/env bash
#
# Notarize and staple build/Claude Switcher.app, then produce a distributable zip.
#
# Prerequisites:
#   1. The app is signed with a "Developer ID Application" identity AND the
#      hardened runtime. `make bundle` does this automatically when such an
#      identity is in your keychain. An ad-hoc signature CANNOT be notarized.
#   2. notarytool credentials. Either store a profile once:
#          xcrun notarytool store-credentials claude-switcher \
#              --apple-id you@example.com --team-id TEAMID \
#              --password <app-specific-password>
#      and run this with NOTARY_PROFILE=claude-switcher (the default), or pass
#      APPLE_ID / TEAM_ID / APP_PASSWORD in the environment.
#
# Why it matters: without notarization, macOS Gatekeeper blocks the app on every
# Mac except the one that built it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Switcher"
APP_DIR="$ROOT/build/$APP_NAME.app"
ZIP="$ROOT/build/$APP_NAME.zip"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-switcher}"

[[ -d "$APP_DIR" ]] || { echo "error: $APP_DIR not found - run 'make bundle' first" >&2; exit 1; }

# Refuse early rather than after a slow upload: Apple rejects ad-hoc signatures.
if codesign -dvv "$APP_DIR" 2>&1 | grep -q 'Signature=adhoc'; then
  cat >&2 <<'ERR'
error: this app is ad-hoc signed and cannot be notarized.

  Get a "Developer ID Application" certificate (Apple Developer Program), then:
      CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make bundle
      make notarize
ERR
  exit 1
fi

echo "==> Zipping for submission"
rm -f "$ZIP"
# ditto --keepParent preserves the .app structure the notary service expects.
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"

echo "==> Submitting to Apple (this can take a few minutes)"
if [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$ZIP" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" \
    --wait
else
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo "==> Stapling the ticket to the app"
xcrun stapler staple "$APP_DIR"
xcrun stapler validate "$APP_DIR"

echo "==> Re-zipping the stapled app for distribution"
rm -f "$ZIP"
/usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"

echo "==> Final Gatekeeper assessment"
spctl -a -t exec -vv "$APP_DIR" 2>&1 | sed 's/^/    /'

echo "==> Notarized and stapled: $ZIP"
