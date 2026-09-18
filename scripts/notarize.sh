#!/usr/bin/env bash
#
# Notarize and staple build/Claude Switcher.app, then produce a distributable zip.
#
# Prerequisites:
#   1. The app is signed with a "Developer ID Application" identity AND the
#      hardened runtime. `make bundle` does this automatically when such an
#      identity is in your keychain. An ad-hoc signature CANNOT be notarized.
#   2. notarytool credentials, in any one of three forms:
#      a. An App Store Connect API key (preferred - no password changes hands):
#             ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 \
#             ASC_KEY_ID=XXXX ASC_ISSUER_ID=<uuid> scripts/notarize.sh
#      b. A stored keychain profile:
#             xcrun notarytool store-credentials claude-switcher \
#                 --apple-id you@example.com --team-id TEAMID
#         then run with NOTARY_PROFILE=claude-switcher (the default).
#      c. APPLE_ID / TEAM_ID / APP_PASSWORD in the environment.
#
# Why it matters: without notarization, macOS Gatekeeper blocks the app on every
# Mac except the one that built it.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="Claude Switcher"
APP_DIR="$ROOT/build/$APP_NAME.app"
ZIP="$ROOT/build/$APP_NAME.zip"
DMG="$ROOT/build/$APP_NAME.dmg"
NOTARY_PROFILE="${NOTARY_PROFILE:-claude-switcher}"

# Optional local credentials: a gitignored .notary.env at the repo root setting the ASC_*
# (or APPLE_ID / TEAM_ID / APP_PASSWORD) variables described above. The environment wins.
if [[ -f "$ROOT/.notary.env" ]]; then
  # shellcheck disable=SC1091
  source "$ROOT/.notary.env"
fi

# TARGET=app (default) notarizes the .app, submitted as a zip because the notary
# service takes archives, not bundles. TARGET=dmg notarizes the disk image, which
# is submitted directly. A .dmg needs its OWN ticket: Gatekeeper judges the file
# the user actually downloaded, so stapling only the app inside is not enough.
TARGET="${TARGET:-app}"

case "$TARGET" in
  app)
    [[ -d "$APP_DIR" ]] || { echo "error: $APP_DIR not found - run 'make bundle' first" >&2; exit 1; }
    SUBJECT="$APP_DIR"; UPLOAD="$ZIP" ;;
  dmg)
    [[ -f "$DMG" ]] || { echo "error: $DMG not found - run 'make dmg' first" >&2; exit 1; }
    SUBJECT="$DMG"; UPLOAD="$DMG" ;;
  *)
    echo "error: TARGET must be 'app' or 'dmg' (got '$TARGET')" >&2; exit 1 ;;
esac

# Refuse early rather than after a slow upload: Apple rejects ad-hoc signatures.
if codesign -dvv "$SUBJECT" 2>&1 | grep -q 'Signature=adhoc'; then
  cat >&2 <<'ERR'
error: this app is ad-hoc signed and cannot be notarized.

  Get a "Developer ID Application" certificate (Apple Developer Program), then:
      CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make bundle
      make notarize
ERR
  exit 1
fi

if [[ "$TARGET" == "app" ]]; then
  echo "==> Zipping for submission"
  rm -f "$ZIP"
  # ditto --keepParent preserves the .app structure the notary service expects.
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"
fi

echo "==> Submitting to Apple (this can take a few minutes)"
# Prefer an API key: it needs no app-specific password, so no secret has to be
# typed, pasted or stored in the clear.
if [[ -n "${ASC_KEY_PATH:-}" && -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  xcrun notarytool submit "$UPLOAD" \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
    --wait
elif [[ -n "${APPLE_ID:-}" && -n "${TEAM_ID:-}" && -n "${APP_PASSWORD:-}" ]]; then
  xcrun notarytool submit "$UPLOAD" \
    --apple-id "$APPLE_ID" --team-id "$TEAM_ID" --password "$APP_PASSWORD" \
    --wait
else
  xcrun notarytool submit "$UPLOAD" --keychain-profile "$NOTARY_PROFILE" --wait
fi

echo "==> Stapling the ticket"
xcrun stapler staple "$SUBJECT"
xcrun stapler validate "$SUBJECT"

if [[ "$TARGET" == "app" ]]; then
  echo "==> Re-zipping the stapled app"
  rm -f "$ZIP"
  /usr/bin/ditto -c -k --keepParent "$APP_DIR" "$ZIP"
  echo "==> Final Gatekeeper assessment"
  spctl -a -t exec -vv "$APP_DIR" 2>&1 | sed 's/^/    /'
  echo "==> Notarized and stapled: $ZIP"
else
  echo "==> Final Gatekeeper assessment"
  # A disk image is assessed as 'open', not 'exec' - that is the operation a
  # user performs on it.
  spctl -a -t open --context context:primary-signature -vv "$DMG" 2>&1 | sed 's/^/    /'
  echo "==> Notarized and stapled: $DMG"
fi
