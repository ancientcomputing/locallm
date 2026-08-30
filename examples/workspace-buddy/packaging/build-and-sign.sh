#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and (optionally) notarizes Workspace Buddy.app — same env-var names, same
# codesign/notarize sequence, same --entitlements-on-every-touching-sign discipline LocalLM Lab's
# own release tooling uses (see plate-today-tools' build-and-sign.sh, which this one is adapted
# from). Simpler than that script: no build-time opt-in flags — sandboxing here is unconditional
# (see WorkspaceBuddy.entitlements' comment for why), and there's no MCP/network connector to
# gate.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Workspace Buddy"
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
ENTITLEMENTS="$BUILD_DIR/WorkspaceBuddy.entitlements"

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
ICON_BUILD_DIR="$BUILD_DIR/icon"
mkdir -p "$ICON_BUILD_DIR"
echo "Compiling app icon asset catalog..."
xcrun actool --output-format human-readable-text --notices --warnings --errors \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
  --platform macosx --minimum-deployment-target 26.0 \
  --compile "$ICON_BUILD_DIR" \
  "$SCRIPT_DIR/Resources/Assets.xcassets"

echo "Building Workspace Buddy for arm64..."
swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift"

# Ask SwiftPM where it actually put the products rather than hardcoding a triple subdir. The
# classic build system uses `<build-path>/<triple>/release`; the Swift Build system (default in
# the Xcode 27 toolchain) uses `<build-path>/out/Products/Release`. --show-bin-path is correct
# for whichever ran, and doesn't rebuild.
BIN_DIR="$(swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift" --show-bin-path)"

BINARY="$BIN_DIR/WorkspaceBuddy"
# Core is built as a dynamic library product, so WorkspaceBuddy links against it via @rpath at
# runtime rather than statically — see plate-today-tools' build-and-sign.sh for the fuller
# writeup of why a packaged .app needs the Core artifact copied in explicitly and re-signed, and
# why the on-disk shape (flat dylib vs. framework bundle) differs between this private repo's
# path-dependency build and the public locallm copy's binaryTarget build.
CORE_DYLIB="$BIN_DIR/libLocalLMLabSDKCore.dylib"
CORE_FRAMEWORK="$BIN_DIR/LocalLMLabSDKCore.framework"
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

cp "$SCRIPT_DIR/WorkspaceBuddy.entitlements" "$ENTITLEMENTS"

cp "$ICON_BUILD_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ICON_BUILD_DIR/Assets.car" "$RESOURCES_DIR/Assets.car"
cp "$BINARY" "$MACOS_DIR/WorkspaceBuddy"
cp -R "$CORE_ARTIFACT_SRC" "$MACOS_DIR/$CORE_ARTIFACT_NAME"
# The published Core.xcframework zip currently carries AppleDouble (`._*`) sidecar files and
# stray xattrs; codesign --deep --strict rejects a bundle containing that "detritus". Strip it
# from the copy we're about to sign. (Root fix belongs in the SDK's xcframework zip step.)
find "$MACOS_DIR/$CORE_ARTIFACT_NAME" -name '._*' -delete
xattr -cr "$MACOS_DIR/$CORE_ARTIFACT_NAME"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/WorkspaceBuddy"

echo "Verifying binary is arm64..."
file "$MACOS_DIR/WorkspaceBuddy"

echo "Signing app bundle..."
codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$MACOS_DIR/$CORE_ARTIFACT_NAME"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$MACOS_DIR/WorkspaceBuddy"
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
