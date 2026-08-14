#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and (optionally) notarizes Components Demo.app — same structure as plate-today's
# packaging/build-and-sign.sh (same env-var names, same codesign/notarize sequence), simplified
# since this app has no TCC-gated connectors (Calendar/Reminders/Location) and no build-time
# feature flags. See that script's comments for the full failure-mode writeups this mirrors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Components Demo"
VERSION="${VERSION:-0.1.0}"
APP_IDENTITY="${APP_IDENTITY:-${SIGN_IDENTITY:-}}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-${NOTARY_PROFILE:-}}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEAM_ID="${TEAM_ID:-}"
NOTARIZE_APP="${NOTARIZE_APP:-1}"

DIST_DIR="$APP_ROOT/dist"
BUILD_DIR="$APP_ROOT/build/release"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_ZIP="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
ENTITLEMENTS="$BUILD_DIR/ComponentsDemo.entitlements"

export DEVELOPER_DIR

require_env() {
  local name="$1" value="$2"
  if [[ -z "$value" ]]; then
    echo "$name is required" >&2
    exit 1
  fi
}

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
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
    xcrun notarytool submit "$artifact" --keychain-profile "$KEYCHAIN_PROFILE" --team-id "$TEAM_ID" --wait
  else
    xcrun notarytool submit "$artifact" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  fi
}

require_env APP_IDENTITY "$APP_IDENTITY"
if [[ "$NOTARIZE_APP" == "1" ]]; then
  require_env KEYCHAIN_PROFILE "$KEYCHAIN_PROFILE"
fi

require_command swift
require_command codesign
require_command ditto
require_command spctl
require_command xcrun
require_command python3

if ! security find-identity -v -p codesigning | grep -F "$APP_IDENTITY" >/dev/null 2>&1; then
  echo "APP_IDENTITY is not installed or is not valid for codesigning: $APP_IDENTITY" >&2
  security find-identity -v -p codesigning || true
  exit 1
fi

if [[ "$NOTARIZE_APP" == "1" ]] && ! xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1; then
  echo "KEYCHAIN_PROFILE is not usable: $KEYCHAIN_PROFILE" >&2
  echo "Create it with: xcrun notarytool store-credentials $KEYCHAIN_PROFILE" >&2
  exit 1
fi

echo "Cleaning release artifacts..."
rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "Generating app icon..."
python3 "$SCRIPT_DIR/generate_app_icon.py"

echo "Building Components Demo for arm64..."
swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift"

BINARY="$BUILD_DIR/swift/arm64-apple-macosx/release/ComponentsDemo"
# Components links against Core (a binaryTarget in Components' own Package.swift) via @rpath, same
# as plate-today's binaryTarget path — see that script's comment for the full "Library not loaded"
# failure-mode writeup. Unlike plate-today, THIS app only ever depends on Core through Components'
# binary boundary (never as source), so it only ever produces the framework shape below, never the
# flat-dylib shape — still detecting both for consistency with the other packaging script, and in
# case that ever changes.
CORE_DYLIB="$BUILD_DIR/swift/arm64-apple-macosx/release/libLocalLMLabSDKCore.dylib"
CORE_FRAMEWORK="$BUILD_DIR/swift/arm64-apple-macosx/release/LocalLMLabSDKCore.framework"
if [[ -f "$CORE_DYLIB" ]]; then
  CORE_ARTIFACT_NAME="libLocalLMLabSDKCore.dylib"
  CORE_ARTIFACT_SRC="$CORE_DYLIB"
elif [[ -d "$CORE_FRAMEWORK" ]]; then
  CORE_ARTIFACT_NAME="LocalLMLabSDKCore.framework"
  CORE_ARTIFACT_SRC="$CORE_FRAMEWORK"
else
  echo "Core build output not found as either a dylib or a framework:" >&2
  echo "  $CORE_DYLIB" >&2
  echo "  $CORE_FRAMEWORK" >&2
  exit 1
fi

echo "Creating app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS_DIR/Info.plist"

# No TCC entitlements needed here (unlike plate-today) -- this app only demonstrates the MCP
# server picker/OAuth flow (outbound HTTPS + Keychain), neither of which needs an entitlement for
# a non-sandboxed Developer ID build. Still copied and signed via --entitlements like plate-today's
# script, for the same reason: that flag must be present on every codesign call touching this
# binary or a later re-sign silently drops it. (Found the hard way: AMFIUnserializeXML, unlike
# plutil, rejects an em-dash inside an XML comment in the entitlements file with an opaque "syntax
# error" -- keep entitlements-file comments plain ASCII if any are ever added here.)
cp "$SCRIPT_DIR/ComponentsDemo.entitlements" "$ENTITLEMENTS"

cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$BINARY" "$MACOS_DIR/ComponentsDemo"
cp -R "$CORE_ARTIFACT_SRC" "$MACOS_DIR/$CORE_ARTIFACT_NAME"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/ComponentsDemo"

echo "Verifying binary is arm64..."
file "$MACOS_DIR/ComponentsDemo"

echo "Signing app bundle..."
codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$MACOS_DIR/$CORE_ARTIFACT_NAME"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$MACOS_DIR/ComponentsDemo"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP_DIR"

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
  echo "Skipping notarization because NOTARIZE_APP=$NOTARIZE_APP"
fi

echo "Release artifact:"
echo "$APP_DIR"
