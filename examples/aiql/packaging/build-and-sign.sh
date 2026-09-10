#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and (optionally) notarizes AIQL.app — adapted from
# workspace-buddy-local's build-and-sign.sh. The one real difference: this app links TWO SDK binaries
# (LocalLMLabSDKCore.framework AND LocalLMLabSDKInference.framework — the MLX runtime, which
# carries its own Metal shaders + resource bundles), so both get copied in and signed.
#
# Env: APP_IDENTITY (Developer ID Application), KEYCHAIN_PROFILE (notarytool profile, only if
# NOTARIZE_APP=1), DEVELOPER_DIR (Xcode 27 — defaults to `xcode-select -p`), LOCALLM_SDK_VERSION, VERSION, TEAM_ID.
#
# The sandbox + MLX path is verified end to end (download, on-disk cache, Metal shader load all
# work under App Sandbox). The model download needs `com.apple.security.network.client` (in
# AIQL.entitlements) and lands in the app's container at
# ~/Library/Containers/<bundle-id>/Data/Library/Caches/huggingface/hub/ — see the README.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="AIQL"
BIN_NAME="AIQL"
VERSION="${VERSION:-0.1.0}"
APP_IDENTITY="${APP_IDENTITY:-${SIGN_IDENTITY:--}}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-${NOTARY_PROFILE:-}}"
# This example's Package.swift is swift-tools-version 6.4 (macOS 27 + the two-binary SDK), so it
# needs Xcode 27 (Swift 6.4+). Default to the active toolchain; override with DEVELOPER_DIR.
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
TEAM_ID="${TEAM_ID:-}"
NOTARIZE_APP="${NOTARIZE_APP:-1}"

DIST_DIR="$APP_ROOT/dist"
BUILD_DIR="$APP_ROOT/build/release"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_ZIP="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
ENTITLEMENTS="$BUILD_DIR/${BIN_NAME}.entitlements"

export DEVELOPER_DIR

# Fail early with an actionable message rather than SwiftPM's cryptic
# "using Swift tools version 6.4.0 but the installed version is 6.3.3".
_swift_ver="$(swift --version 2>/dev/null | grep -oE 'Swift version [0-9]+\.[0-9]+' | awk '{print $3}')"
_major="${_swift_ver%%.*}"; _minor="${_swift_ver##*.}"
if [[ -z "$_swift_ver" ]] || (( _major < 6 || (_major == 6 && _minor < 4) )); then
  echo "error: needs Swift 6.4+ (Xcode 27). DEVELOPER_DIR=$DEVELOPER_DIR -> Swift ${_swift_ver:-unknown}." >&2
  echo "       select Xcode 27: sudo xcode-select -s /Applications/Xcode.app  (or set DEVELOPER_DIR), then re-run $0" >&2
  exit 1
fi

require_env()     { [[ -n "$2" ]] || { echo "$1 is required" >&2; exit 1; }; }
require_command() { command -v "$1" >/dev/null 2>&1 || { echo "$1 is required" >&2; exit 1; }; }

notarize_and_wait() {
  local artifact="$1"
  echo "Submitting for notarization: $artifact"
  if [[ -n "$TEAM_ID" ]]; then
    xcrun notarytool submit "$artifact" --keychain-profile "$KEYCHAIN_PROFILE" --team-id "$TEAM_ID" --wait
  else
    xcrun notarytool submit "$artifact" --keychain-profile "$KEYCHAIN_PROFILE" --wait
  fi
}

if [[ "$APP_IDENTITY" == "-" ]]; then
  ADHOC=1
  SIGN_FLAGS=""            # ad-hoc: no hardened runtime (it rejects the Team-signed SDK frameworks
  NOTARIZE_APP=0           # under an ad-hoc outer signature) and no secure timestamp
  echo "APP_IDENTITY not set - signing ad-hoc. The .app runs on THIS Mac only: Gatekeeper rejects"
  echo "an ad-hoc app anywhere else, and TCC / App Sandbox grants are unreliable. Set APP_IDENTITY"
  echo "to any codesigning identity (a free 'Apple Development' cert from Xcode > Settings >"
  echo "Accounts works) to fix that; a Developer ID + NOTARIZE_APP=1 to distribute."
else
  ADHOC=0
  SIGN_FLAGS="--options runtime --timestamp"
fi
[[ "$NOTARIZE_APP" == "1" ]] && require_env KEYCHAIN_PROFILE "$KEYCHAIN_PROFILE"

require_command swift
require_command codesign
require_command ditto
require_command xcrun
require_command python3

if [[ "$ADHOC" == "0" ]] && ! security find-identity -v -p codesigning | grep -F "$APP_IDENTITY" >/dev/null 2>&1; then
  echo "APP_IDENTITY is not a valid codesigning identity: $APP_IDENTITY" >&2
  security find-identity -v -p codesigning || true
  exit 1
fi

echo "Cleaning release artifacts..."
rm -rf "$BUILD_DIR" "$APP_DIR"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "Generating app icon..."
python3 "$SCRIPT_DIR/generate_app_icon.py"
ICON_BUILD_DIR="$BUILD_DIR/icon"
mkdir -p "$ICON_BUILD_DIR"
xcrun actool --output-format human-readable-text --notices --warnings --errors \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
  --platform macosx --minimum-deployment-target 27.0 \
  --compile "$ICON_BUILD_DIR" \
  "$SCRIPT_DIR/Resources/Assets.xcassets"

echo "Building $APP_NAME for arm64 (needs the Metal Toolchain)..."
swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift"
BIN_DIR="$(swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift" --show-bin-path)"
BINARY="$BIN_DIR/$BIN_NAME"

echo "Creating app bundle..."
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
cp "$SCRIPT_DIR/Info.plist" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$CONTENTS_DIR/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $VERSION" "$CONTENTS_DIR/Info.plist"
cp "$SCRIPT_DIR/${BIN_NAME}.entitlements" "$ENTITLEMENTS"
cp "$ICON_BUILD_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ICON_BUILD_DIR/Assets.car" "$RESOURCES_DIR/Assets.car"
cp "$BINARY" "$MACOS_DIR/$BIN_NAME"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/$BIN_NAME"

# Both SDK frameworks sit next to the binary. Strip the AppleDouble/xattr detritus the published
# xcframework zips carry, then sign inside-out (nested .bundles first, then the framework binary,
# then the framework), before the app binary and the app.
FRAMEWORKS=(LocalLMLabSDKCore.framework LocalLMLabSDKInference.framework)
for fw in "${FRAMEWORKS[@]}"; do
  src="$BIN_DIR/$fw"
  [[ -d "$src" ]] || { echo "missing $src — did 'swift build' produce the binaryTarget frameworks?" >&2; exit 1; }
  cp -R "$src" "$MACOS_DIR/$fw"
  find "$MACOS_DIR/$fw" -name '._*' -delete
  xattr -cr "$MACOS_DIR/$fw"
  while IFS= read -r b; do
    codesign --force $SIGN_FLAGS --sign "$APP_IDENTITY" "$b"
  done < <(find "$MACOS_DIR/$fw" -type d -name '*.bundle')
  codesign --force $SIGN_FLAGS --sign "$APP_IDENTITY" "$MACOS_DIR/$fw/$(basename "$fw" .framework)"
  codesign --force $SIGN_FLAGS --sign "$APP_IDENTITY" "$MACOS_DIR/$fw"
done

echo "Signing app..."
codesign --force $SIGN_FLAGS --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$MACOS_DIR/$BIN_NAME"
codesign --force $SIGN_FLAGS --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Creating notarization zip..."
ditto -c -k --keepParent "$APP_DIR" "$APP_ZIP"

if [[ "$NOTARIZE_APP" == "1" ]]; then
  notarize_and_wait "$APP_ZIP"
  xcrun stapler staple "$APP_DIR"
  xcrun stapler validate "$APP_DIR"
  spctl -a -vv --type execute "$APP_DIR" || true
else
  echo "Skipping notarization (NOTARIZE_APP=$NOTARIZE_APP)."
fi

echo
echo "Release artifact: $APP_DIR"
