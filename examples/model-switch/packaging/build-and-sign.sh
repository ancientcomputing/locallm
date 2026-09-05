#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and (optionally) notarizes Model Switch.app — same structure as components-demo's
# and plate-today's packaging/build-and-sign.sh (same env-var names, same codesign/notarize
# sequence). Like components-demo, this app has no TCC-gated connectors and no build-time feature
# flags. Unlike either, it links TWO SDK binaries — LocalLMLabSDKCore AND LocalLMLabSDKRemote
# (the online-providers layer) — both consumed as xcframeworks, so both are copied into the
# bundle and signed. LocalLMLabSDKComponents is a source dependency and compiles into the
# executable. See plate-today's script for the full failure-mode writeups this mirrors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Model Switch"
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
ENTITLEMENTS="$BUILD_DIR/ModelSwitch.entitlements"

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

if [[ -z "${LOCALLM_SDK_VERSION:-}" ]]; then
  echo "LOCALLM_SDK_VERSION is required (Package.swift resolves the SDK binaries from it)." >&2
  echo "e.g. LOCALLM_SDK_VERSION=1.0.0-beta.3 $0" >&2
  exit 1
fi

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
ICON_BUILD_DIR="$BUILD_DIR/icon"
mkdir -p "$ICON_BUILD_DIR"
echo "Compiling app icon asset catalog..."
xcrun actool --output-format human-readable-text --notices --warnings --errors \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
  --platform macosx --minimum-deployment-target 27.0 \
  --compile "$ICON_BUILD_DIR" \
  "$SCRIPT_DIR/Resources/Assets.xcassets"

echo "Building Model Switch for arm64..."
swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift"
BIN_DIR="$(swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift" --show-bin-path)"

BINARY="$BIN_DIR/ModelSwitch"

echo "Creating app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS_DIR/Info.plist"

# No entitlements needed (no sandbox, no TCC-gated API) — outbound HTTPS from a non-sandboxed
# Developer ID build needs none. Still copied and signed via --entitlements on every codesign
# call, same as the other packaging scripts: that flag must be present on every call touching a
# binary or a later re-sign silently drops it. Keep entitlements-file comments plain ASCII if any
# are ever added — AMFIUnserializeXML rejects an em-dash in an XML comment with an opaque error.
cp "$SCRIPT_DIR/ModelSwitch.entitlements" "$ENTITLEMENTS"

cp "$ICON_BUILD_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ICON_BUILD_DIR/Assets.car" "$RESOURCES_DIR/Assets.car"
cp "$BINARY" "$MACOS_DIR/ModelSwitch"

# Core + Remote both ship as xcframeworks (Components is a source dep, compiled in). SwiftPM
# extracts each as <Name>.framework next to the product; both link via @rpath and both must sit
# in Contents/MacOS next to the executable — same "Library not loaded: @rpath/..." failure mode
# as plate-today's Core copy, one per binary here.
SDK_FRAMEWORKS=(LocalLMLabSDKCore.framework LocalLMLabSDKRemote.framework)
for fw in "${SDK_FRAMEWORKS[@]}"; do
  if [[ ! -d "$BIN_DIR/$fw" ]]; then
    echo "Expected SDK framework not found: $BIN_DIR/$fw" >&2
    exit 1
  fi
  cp -R "$BIN_DIR/$fw" "$MACOS_DIR/$fw"
  # The published xcframework zips carry AppleDouble (`._*`) sidecars / stray xattrs; codesign
  # --deep --strict rejects a bundle containing that. Strip it from the copy we sign.
  find "$MACOS_DIR/$fw" -name '._*' -delete
  xattr -cr "$MACOS_DIR/$fw"
done

printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/ModelSwitch"

echo "Verifying binary is arm64..."
file "$MACOS_DIR/ModelSwitch"

echo "Signing app bundle..."
for fw in "${SDK_FRAMEWORKS[@]}"; do
  codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$MACOS_DIR/$fw"
done
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$MACOS_DIR/ModelSwitch"
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
