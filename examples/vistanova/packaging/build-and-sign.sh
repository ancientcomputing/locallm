#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, notarizes, and packages VistaNova.app + VistaNova-<version>.dmg for direct
# (non-App-Store) distribution — the artifact you'd attach to a GitHub Release.
#
# Unlike the SDK examples' own packaging/build-and-sign.sh scripts (which `swift build` the
# executable by hand and manually copy/sign each xcframework into the bundle), this one builds
# through the real Xcode project this repo already generates via `xcodegen` — `xcodebuild
# archive` + `-exportArchive` handles embedding and signing LocalLMLabSDKCore.framework /
# LocalLMLabSDKInference.framework itself, so there's no manual framework-copying step here.
#
# Requires: xcodegen, Xcode (xcodebuild), a Developer ID Application certificate in your keychain,
# and notarytool credentials stored under a keychain profile (one-time setup):
#
#   xcrun notarytool store-credentials <profile-name> \
#     --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#
# Usage:
#   APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   TEAM_ID=TEAMID \
#   KEYCHAIN_PROFILE=<profile-name> \
#     packaging/build-and-sign.sh
#
# Env vars:
#   APP_IDENTITY     Codesigning identity. Default "-" (ad hoc): builds and packages for a quick
#                     local smoke test, but skips notarization (Gatekeeper rejects an ad-hoc app
#                     on any other Mac) — set this for a real release.
#   TEAM_ID          Your Apple Developer Team ID. Required unless APP_IDENTITY is ad hoc.
#   KEYCHAIN_PROFILE notarytool keychain profile name. Required unless NOTARIZE=0.
#   VERSION          Marketing version for the .app/.dmg filenames. Default: project.yml's
#                     MARKETING_VERSION.
#   NOTARIZE         1 (default, unless APP_IDENTITY is ad hoc) or 0 to skip notarization.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="VistaNova"
SCHEME="VistaNova"
PROJECT="$REPO_ROOT/VistaNova.xcodeproj"
VERSION="${VERSION:-$(sed -n 's/.*MARKETING_VERSION: "\(.*\)"/\1/p' "$REPO_ROOT/project.yml" | head -1)}"
APP_IDENTITY="${APP_IDENTITY:--}"
TEAM_ID="${TEAM_ID:-}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-}"

BUILD_DIR="$REPO_ROOT/build/release"
DIST_DIR="$REPO_ROOT/dist"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
EXPORT_OPTIONS="$BUILD_DIR/ExportOptions.plist"
APP_PATH="$EXPORT_DIR/${APP_NAME}.app"
APP_ZIP="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
DMG_STAGING="$BUILD_DIR/dmg-staging"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}.dmg"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

require_env() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "$name is required (see this script's header comment for setup)" >&2
    exit 1
  fi
}

notarize_and_wait() {
  local artifact="$1"
  echo "Submitting for notarization: $artifact"
  if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "KEYCHAIN_PROFILE is not usable: $KEYCHAIN_PROFILE" >&2
    echo "Create it with: xcrun notarytool store-credentials $KEYCHAIN_PROFILE --apple-id you@example.com --team-id $TEAM_ID --password <app-specific-password>" >&2
    exit 1
  fi
  xcrun notarytool submit "$artifact" --keychain-profile "$KEYCHAIN_PROFILE" --team-id "$TEAM_ID" --wait
}

if [[ "$APP_IDENTITY" == "-" ]]; then
  ADHOC=1
  NOTARIZE="${NOTARIZE:-0}"
  echo "APP_IDENTITY not set — signing ad hoc. The .app/.dmg will only run on THIS Mac (Gatekeeper"
  echo "rejects an ad-hoc app anywhere else) and won't be notarized. Set APP_IDENTITY, TEAM_ID, and"
  echo "KEYCHAIN_PROFILE for a real release build."
else
  ADHOC=0
  NOTARIZE="${NOTARIZE:-1}"
  require_env TEAM_ID "$TEAM_ID"
fi
if [[ "$NOTARIZE" == "1" ]]; then
  require_env KEYCHAIN_PROFILE "$KEYCHAIN_PROFILE"
fi
require_env VERSION "$VERSION"

require_command xcodegen
require_command xcodebuild
require_command codesign
require_command ditto
require_command spctl
require_command xcrun
require_command hdiutil

if [[ "$ADHOC" == "0" ]] && ! security find-identity -v -p codesigning | grep -F "$APP_IDENTITY" >/dev/null 2>&1; then
  echo "APP_IDENTITY is not a valid codesigning identity in your keychain: $APP_IDENTITY" >&2
  security find-identity -v -p codesigning || true
  exit 1
fi
if [[ "$NOTARIZE" == "1" ]] && ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  echo "KEYCHAIN_PROFILE is not usable: $KEYCHAIN_PROFILE" >&2
  echo "Create it with: xcrun notarytool store-credentials $KEYCHAIN_PROFILE --apple-id you@example.com --team-id $TEAM_ID --password <app-specific-password>" >&2
  exit 1
fi

echo "Cleaning previous release artifacts..."
rm -rf "$BUILD_DIR" "$DIST_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "Regenerating Xcode project from project.yml..."
(cd "$REPO_ROOT" && xcodegen generate)

echo "Archiving $SCHEME (Release)..."
xcodebuild archive \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE_PATH" \
  -destination 'generic/platform=macOS' \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$APP_IDENTITY" \
  ${TEAM_ID:+DEVELOPMENT_TEAM="$TEAM_ID"} \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  ENABLE_HARDENED_RUNTIME=YES \
  MARKETING_VERSION="$VERSION"

cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>method</key>
    <string>developer-id</string>
    <key>signingStyle</key>
    <string>manual</string>
    <key>signingCertificate</key>
    <string>$APP_IDENTITY</string>
    $( [[ -n "$TEAM_ID" ]] && echo "<key>teamID</key><string>$TEAM_ID</string>" )
</dict>
</plist>
PLIST

if [[ "$ADHOC" == "1" ]]; then
  # -exportArchive's developer-id method requires a team, which an ad-hoc archive doesn't have —
  # pull the .app straight out of the archive instead. Fine for a local smoke test; a real
  # release build (APP_IDENTITY/TEAM_ID set) always goes through the real export below.
  echo "Ad hoc: using the archived .app directly (no -exportArchive, no team to export with)..."
  mkdir -p "$EXPORT_DIR"
  ditto "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$APP_PATH"
else
  echo "Exporting .app..."
  xcodebuild -exportArchive \
    -archivePath "$ARCHIVE_PATH" \
    -exportPath "$EXPORT_DIR" \
    -exportOptionsPlist "$EXPORT_OPTIONS"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "Expected app not found: $APP_PATH" >&2
  exit 1
fi

echo "Verifying signature..."
codesign --verify --deep --strict --verbose=2 "$APP_PATH"

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Creating notarization zip..."
  ditto -c -k --keepParent "$APP_PATH" "$APP_ZIP"
  notarize_and_wait "$APP_ZIP"
  echo "Stapling app..."
  xcrun stapler staple "$APP_PATH"
  xcrun stapler validate "$APP_PATH"
  spctl -a -vv --type execute "$APP_PATH"
else
  echo "Skipping app notarization (NOTARIZE=$NOTARIZE)."
fi

echo "Building DMG..."
rm -rf "$DMG_STAGING"
mkdir -p "$DMG_STAGING"
ditto "$APP_PATH" "$DMG_STAGING/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGING/Applications"
rm -f "$DMG_PATH"
hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGING" -ov -format UDZO "$DMG_PATH"

if [[ "$ADHOC" == "0" ]]; then
  echo "Signing DMG..."
  codesign --force --sign "$APP_IDENTITY" --timestamp "$DMG_PATH"
fi

if [[ "$NOTARIZE" == "1" ]]; then
  notarize_and_wait "$DMG_PATH"
  echo "Stapling DMG..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
else
  echo "Skipping DMG notarization (NOTARIZE=$NOTARIZE)."
fi

echo
echo "Done."
echo "App: $APP_PATH"
echo "DMG: $DMG_PATH"
[[ "$NOTARIZE" == "1" ]] || echo "(not notarized — set APP_IDENTITY/TEAM_ID/KEYCHAIN_PROFILE and re-run for a distributable build)"
