#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and (optionally) notarizes Plate Today.app — same env-var names, same
# codesign/notarize sequence, same --entitlements-on-every-touching-sign discipline LocalLM Lab's
# own release tooling uses, since that already worked out the real TCC/codesign failure modes the
# hard way (see packaging/PlateToday.entitlements' comment). This app is simpler (single binary,
# no nested chooser bundle), so the script is shorter, but the sequence that matters — sign
# binary, sign bundle WITH --entitlements again, verify, notarize, staple — is unchanged.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Plate Today"
VERSION="${VERSION:-0.1.0}"
APP_IDENTITY="${APP_IDENTITY:-${SIGN_IDENTITY:-}}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-${NOTARY_PROFILE:-}}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
TEAM_ID="${TEAM_ID:-}"
NOTARIZE_APP="${NOTARIZE_APP:-1}"
# Build-time opt-in, default OFF — see Package.swift's comment for why (Location Services
# flakiness + tccutil's Location reset limitation). Read here too, not just by `swift build`
# itself, because packaging also needs to know whether to declare the Location entitlement/
# usage-description key at all.
PLATETODAY_INCLUDE_LOCATION_WEATHER="${PLATETODAY_INCLUDE_LOCATION_WEATHER:-0}"
# Build-time opt-in, default OFF — see Package.swift's comment for why (not part of the daily-
# summary narrative, on-demand enrichment only; avoids an extra TCC prompt by default). Read here
# too, same reason as Location above — packaging needs to know whether to declare the Contacts
# entitlement/usage-description key at all.
PLATETODAY_INCLUDE_CONTACTS="${PLATETODAY_INCLUDE_CONTACTS:-0}"
# Build-time opt-in, default OFF.
# Plate Today is the SDK's proving ground for App Sandbox compatibility: a single-process SwiftUI
# app with no subprocess spawning, unlike LocalLM Lab's Go<->Swift architecture, so it can validate
# Core under sandbox without also needing LocalLM Lab's XPC rearchitecture solved first. Default
# build stays unsandboxed/Developer-ID-shaped (tier (2) in that roadmap, already working); this
# flag produces the sandboxed variant (tier (1) proof-of-concept) without disturbing the default.
PLATETODAY_APP_SANDBOX="${PLATETODAY_APP_SANDBOX:-0}"

DIST_DIR="$APP_ROOT/dist"
BUILD_DIR="$APP_ROOT/build/release"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
APP_ZIP="$BUILD_DIR/${APP_NAME}-${VERSION}.zip"
ENTITLEMENTS="$BUILD_DIR/PlateToday.entitlements"

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
# CFBundleIconName (already set in Info.plist) requires an actual asset catalog to resolve
# against — a bare .icns via CFBundleIconFile alone isn't sufficient for every consumer (System
# Settings' Privacy & Security pane, and App Store Connect's asset-catalog validation for the MAS
# build). actool derives both Assets.car and an AppIcon.icns from the same appiconset in one pass.
echo "Compiling app icon asset catalog..."
xcrun actool --output-format human-readable-text --notices --warnings --errors \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
  --platform macosx --minimum-deployment-target 26.0 \
  --compile "$ICON_BUILD_DIR" \
  "$SCRIPT_DIR/Resources/Assets.xcassets"

echo "Building Plate Today for arm64 (Location/Weather: $([ "$PLATETODAY_INCLUDE_LOCATION_WEATHER" == "1" ] && echo included || echo excluded), Contacts: $([ "$PLATETODAY_INCLUDE_CONTACTS" == "1" ] && echo included || echo excluded), App Sandbox: $([ "$PLATETODAY_APP_SANDBOX" == "1" ] && echo on || echo off))..."
PLATETODAY_INCLUDE_LOCATION_WEATHER="$PLATETODAY_INCLUDE_LOCATION_WEATHER" \
PLATETODAY_INCLUDE_CONTACTS="$PLATETODAY_INCLUDE_CONTACTS" \
  swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift"

BINARY="$BUILD_DIR/swift/arm64-apple-macosx/release/PlateToday"
# Core is built as a dynamic library product (see ../../../Core/Package.swift's `type: .dynamic`
# — required for the Components/xcframework binary boundary elsewhere in this repo), so
# PlateToday links against it via @rpath at runtime rather than statically. A bare `swift build`
# output directory has both files side by side and works; a packaged .app does not unless the
# Core artifact is copied in explicitly and re-signed — confirmed the hard way via a dyld "Library
# not loaded" failure on first real launch of the packaged bundle.
#
# The on-disk shape differs depending on how this package.swift depends on Core, and both are real:
# this private repo's `.package(path: "../../Core")` produces a flat `libLocalLMLabSDKCore.dylib`
# next to the binary, but the public `locallm` copy's `.binaryTarget` (a prebuilt
# Core.xcframework) produces a `LocalLMLabSDKCore.framework` bundle instead — PlateToday's own
# @rpath entry (`@rpath/LocalLMLabSDKCore.framework/LocalLMLabSDKCore` in that case) expects the
# whole framework directory, not a renamed flat file. Confirmed the hard way running this same
# script against the public copy's binaryTarget build, which produces the framework shape and
# failed to find a nonexistent flat dylib. Detect whichever shape this build actually produced.
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

cp "$SCRIPT_DIR/PlateToday.entitlements" "$ENTITLEMENTS"
if [[ "$PLATETODAY_INCLUDE_LOCATION_WEATHER" == "1" ]]; then
  echo "Adding Location usage-description key and entitlement (PLATETODAY_INCLUDE_LOCATION_WEATHER=1)..."
  /usr/libexec/PlistBuddy -c "Add :NSLocationUsageDescription string 'Plate Today looks up your current location, once, to include today'\\''s local weather in your summary.'" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.personal-information.location bool true" "$ENTITLEMENTS"
fi
if [[ "$PLATETODAY_INCLUDE_CONTACTS" == "1" ]]; then
  echo "Adding Contacts usage-description key and entitlement (PLATETODAY_INCLUDE_CONTACTS=1)..."
  /usr/libexec/PlistBuddy -c "Add :NSContactsUsageDescription string 'Plate Today searches your Contacts, on request, to enrich a calendar event or reminder that names a specific person.'" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.personal-information.addressbook bool true" "$ENTITLEMENTS"
fi
if [[ "$PLATETODAY_APP_SANDBOX" == "1" ]]; then
  echo "Adding App Sandbox entitlement (PLATETODAY_APP_SANDBOX=1)..."
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "$ENTITLEMENTS"
  # Unconditional (not gated behind PLATETODAY_INCLUDE_LOCATION_WEATHER), since Weather and the
  # MCP client's HTTPS calls (Todoist et al) both need outbound network access unconditionally
  # under sandbox — without this, any outbound connection is silently blocked, which surfaced
  # live as "connectivity issues" fetching weather and the Todoist MCP server never connecting at
  # all, confirmed via a real sandboxed build with no network entitlement present.
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.network.client bool true" "$ENTITLEMENTS"
fi

cp "$ICON_BUILD_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ICON_BUILD_DIR/Assets.car" "$RESOURCES_DIR/Assets.car"
cp "$BINARY" "$MACOS_DIR/PlateToday"
cp -R "$CORE_ARTIFACT_SRC" "$MACOS_DIR/$CORE_ARTIFACT_NAME"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/PlateToday"

echo "Verifying binary is arm64..."
file "$MACOS_DIR/PlateToday"

echo "Signing app bundle..."
# Sign the binary directly first (cheap early sanity check), then the whole bundle WITH
# --entitlements again — the bundle-level sign re-signs the main executable regardless, silently
# dropping entitlements applied a moment earlier if --entitlements isn't repeated here. Confirmed
# the hard way.
# failure-mode writeup.
codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$MACOS_DIR/$CORE_ARTIFACT_NAME"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_IDENTITY" "$MACOS_DIR/PlateToday"
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
