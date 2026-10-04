#!/usr/bin/env bash
set -euo pipefail

# Builds a Developer ID–signed, notarized, stapled JevDK.app and a drag-to-Applications DMG.
#
#   VERSION=0.1.0 \
#   APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   KEYCHAIN_PROFILE=notary-profile \
#   scripts/release_macos.sh
#
#   VERSION           required, x.y.z — written to CFBundleShortVersionString / CFBundleVersion
#   APP_IDENTITY      required, a "Developer ID Application" identity (name or SHA-1 hash; use the
#                     hash when several identities share a name). SIGN_IDENTITY also accepted.
#   KEYCHAIN_PROFILE  notarytool profile (xcrun notarytool store-credentials <name>); required
#                     unless both NOTARIZE_* are 0. NOTARY_PROFILE also accepted.
#   TEAM_ID           optional, passed to notarytool
#   NOTARIZE_APP      1 (default) | 0
#   NOTARIZE_DMG      1 (default) | 0
#   DEVELOPER_DIR     Xcode 27 (default: xcode-select -p)
#
# Builds through JevDK.xcodeproj (project.yml) with signing off, then signs everything itself,
# inside-out, with the hardened runtime: the embedded SDK frameworks (Core, Remote, Inference)
# and their nested resource bundles, then the app. Not sandboxed, no entitlements — same as the
# `swift build` binary and the Xcode Run (JevDK uses the shared Hugging Face cache).
#
# Artifacts: dist/JevDK.app, dist/JevDK-<VERSION>-arm64.dmg (+ .sha256). Scratch in build/release.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="JevDK"
SCHEME="JevDK"
VERSION="${VERSION:-VERSION_NEEDED}"
APP_IDENTITY="${APP_IDENTITY:-${SIGN_IDENTITY:-}}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-${NOTARY_PROFILE:-}}"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
TEAM_ID="${TEAM_ID:-}"
NOTARIZE_APP="${NOTARIZE_APP:-1}"
NOTARIZE_DMG="${NOTARIZE_DMG:-1}"

DIST_DIR="$APP_ROOT/dist"
BUILD_DIR="$APP_ROOT/build/release"
ARCHIVE_PATH="$BUILD_DIR/${APP_NAME}.xcarchive"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
FRAMEWORKS_DIR="$CONTENTS_DIR/Frameworks"
DMG_STAGE_DIR="$BUILD_DIR/dmg-stage"
APP_ZIP="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
DMG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-arm64.dmg"

export DEVELOPER_DIR

require_env() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" ]]; then
    echo "$name is required" >&2
    exit 1
  fi
}

require_command() {
  local command_name="$1"
  if ! command -v "$command_name" >/dev/null 2>&1; then
    echo "$command_name is required" >&2
    exit 1
  fi
}

notarize_and_wait() {
  local artifact="$1"
  echo "Submitting for notarization: $artifact"
  if ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    echo "KEYCHAIN_PROFILE became unavailable before notarizing: $artifact" >&2
    echo "Try unlocking the login keychain or recreating the profile with xcrun notarytool store-credentials." >&2
    exit 1
  fi
  if [[ -n "$TEAM_ID" ]]; then
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$KEYCHAIN_PROFILE" \
      --team-id "$TEAM_ID" \
      --wait
  else
    xcrun notarytool submit "$artifact" \
      --keychain-profile "$KEYCHAIN_PROFILE" \
      --wait
  fi
}

sign() {
  codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$@"
}

require_env VERSION "$VERSION"
if [[ "$VERSION" == "VERSION_NEEDED" ]]; then
  echo "Set VERSION=x.y.z" >&2
  exit 1
fi
require_env APP_IDENTITY "$APP_IDENTITY"
if [[ "$NOTARIZE_APP" == "1" || "$NOTARIZE_DMG" == "1" ]]; then
  require_env KEYCHAIN_PROFILE "$KEYCHAIN_PROFILE"
fi

require_command xcodebuild
require_command xattr
require_command codesign
require_command ditto
require_command hdiutil
require_command shasum
require_command spctl
require_command xcrun

if ! security find-identity -v -p codesigning | grep -F "$APP_IDENTITY" >/dev/null 2>&1; then
  echo "APP_IDENTITY is not installed or is not valid for codesigning: $APP_IDENTITY" >&2
  security find-identity -v -p codesigning || true
  exit 1
fi
if [[ "$(security find-identity -v -p codesigning | grep -cF "$APP_IDENTITY")" -gt 1 ]]; then
  echo "APP_IDENTITY matches more than one identity; pass its SHA-1 hash instead: $APP_IDENTITY" >&2
  security find-identity -v -p codesigning | grep -F "$APP_IDENTITY" >&2 || true
  exit 1
fi

if [[ "$NOTARIZE_APP" == "1" || "$NOTARIZE_DMG" == "1" ]] && ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  echo "KEYCHAIN_PROFILE is not usable: $KEYCHAIN_PROFILE" >&2
  echo "Create it with: xcrun notarytool store-credentials $KEYCHAIN_PROFILE" >&2
  exit 1
fi

echo "Cleaning release artifacts..."
rm -rf "$BUILD_DIR" "$APP_DIR" "$DMG_PATH" "$DMG_PATH.sha256"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

# Release config, arm64 only, unsigned: the frameworks keep the SDK team's signature until we
# re-sign them below with APP_IDENTITY (required — the hardened runtime's library validation
# only loads frameworks signed by the app's own team).
echo "Archiving $SCHEME (Release, arm64)..."
xcodebuild archive \
  -project "$APP_ROOT/JevDK.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -archivePath "$ARCHIVE_PATH" \
  -derivedDataPath "$BUILD_DIR/DerivedData" \
  ARCHS=arm64 \
  ONLY_ACTIVE_ARCH=NO \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$VERSION" \
  CODE_SIGNING_ALLOWED=NO \
  CODE_SIGNING_REQUIRED=NO \
  CODE_SIGN_IDENTITY=""

ditto "$ARCHIVE_PATH/Products/Applications/${APP_NAME}.app" "$APP_DIR"

# project.yml's Info.plist carries fixed version strings; stamp the release version.
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS_DIR/Info.plist"

# Apache-2.0 §4(d): carry the SDK's NOTICE (it bundles the MLX stack) inside the app.
if [[ -f "$APP_ROOT/../../NOTICE" ]]; then
  mkdir -p "$CONTENTS_DIR/Resources"
  cp "$APP_ROOT/../../NOTICE" "$CONTENTS_DIR/Resources/NOTICE"
fi

# The published xcframework zips carry AppleDouble/xattr detritus that breaks signing.
find "$APP_DIR" -name '._*' -delete
xattr -cr "$APP_DIR"

echo "Verifying the app binary is arm64..."
file "$CONTENTS_DIR/MacOS/$APP_NAME"
shopt -s nullglob
FRAMEWORKS=("$FRAMEWORKS_DIR"/*.framework)
shopt -u nullglob
for fw in ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}; do
  file "$fw/$(basename "$fw" .framework)"
done

echo "Signing app bundle..."
# Inside-out: each framework's nested bundles, its binary, the framework; then the app last.
for fw in ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}; do  # (empty-array safe under set -u in bash 3.2)
  while IFS= read -r b; do sign "$b"; done < <(find "$fw" -depth -type d -name '*.bundle')
  sign "$fw/$(basename "$fw" .framework)"
  sign "$fw"
done
sign "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Creating app notarization zip..."
ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP"

if [[ "$NOTARIZE_APP" == "1" ]]; then
  notarize_and_wait "$APP_ZIP"

  echo "Stapling app..."
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl -a -vv --type execute "$APP_DIR"
else
  echo "Skipping app notarization because NOTARIZE_APP=$NOTARIZE_APP"
fi

echo "Creating drag-to-Applications DMG..."
rm -rf "$DMG_STAGE_DIR"
mkdir -p "$DMG_STAGE_DIR"
cp -R "$APP_DIR" "$DMG_STAGE_DIR/${APP_NAME}.app"
ln -s /Applications "$DMG_STAGE_DIR/Applications"

hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$DMG_STAGE_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH"

echo "Signing DMG..."
codesign --force --timestamp --sign "$APP_IDENTITY" "$DMG_PATH"
codesign --verify --verbose=2 "$DMG_PATH"

if [[ "$NOTARIZE_DMG" == "1" ]]; then
  notarize_and_wait "$DMG_PATH"

  echo "Stapling DMG..."
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"

  echo "Running Gatekeeper verification..."
  spctl --assess --type open --context context:primary-signature --verbose "$DMG_PATH"
else
  echo "Skipping DMG notarization because NOTARIZE_DMG=$NOTARIZE_DMG"
fi

# Write the checksum with a bare filename (not the absolute build path) so a
# consumer can `shasum -a 256 -c <file>.sha256` from the directory it's in.
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$DMG_PATH")" > "$(basename "$DMG_PATH").sha256" )

echo "Release artifacts:"
echo "$APP_DIR"
echo "$DMG_PATH"
echo "$DMG_PATH.sha256"
