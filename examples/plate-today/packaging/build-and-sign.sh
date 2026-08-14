#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and (optionally) notarizes Plate Today.app — mirrors locallmlab-main's
# scripts/release-macos.sh structure (same env-var names, same codesign/notarize sequence, same
# --entitlements-on-every-touching-sign discipline) since that script already worked out the real
# TCC/codesign failure modes the hard way (see packaging/PlateToday.entitlements' comment). This
# app is simpler (single binary, no nested chooser bundle), so the script is shorter, but the
# sequence that matters — sign binary, sign bundle WITH --entitlements again, verify, notarize,
# staple — is unchanged.

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
# Build-time opt-in, default OFF — see docs/07-release-roadmap.md (locallmlab-sdk) phase 1.
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

echo "Building Plate Today for arm64 (Location/Weather: $([ "$PLATETODAY_INCLUDE_LOCATION_WEATHER" == "1" ] && echo included || echo excluded), App Sandbox: $([ "$PLATETODAY_APP_SANDBOX" == "1" ] && echo on || echo off))..."
PLATETODAY_INCLUDE_LOCATION_WEATHER="$PLATETODAY_INCLUDE_LOCATION_WEATHER" \
  swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift"

BINARY="$BUILD_DIR/swift/arm64-apple-macosx/release/PlateToday"
# Core is built as a dynamic library product (see ../../../Core/Package.swift's `type: .dynamic`
# — required for the Components/xcframework binary boundary elsewhere in this repo), so
# PlateToday links against it via @rpath at runtime rather than statically. A bare `swift build`
# output directory has both files side by side and works; a packaged .app does not unless the
# dylib is copied in explicitly and re-signed — confirmed the hard way via a dyld "Library not
# loaded" failure on first real launch of the packaged bundle.
CORE_DYLIB="$BUILD_DIR/swift/arm64-apple-macosx/release/libLocalLMLabSDKCore.dylib"

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

cp "$SCRIPT_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$BINARY" "$MACOS_DIR/PlateToday"
cp "$CORE_DYLIB" "$MACOS_DIR/libLocalLMLabSDKCore.dylib"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/PlateToday"

echo "Verifying binary is arm64..."
file "$MACOS_DIR/PlateToday"

echo "Signing app bundle..."
# Sign the binary directly first (cheap early sanity check), then the whole bundle WITH
# --entitlements again — the bundle-level sign re-signs the main executable regardless, silently
# dropping entitlements applied a moment earlier if --entitlements isn't repeated here. Confirmed
# the hard way in locallmlab-main's release-macos.sh; see that script's comments for the full
# failure-mode writeup.
codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$MACOS_DIR/libLocalLMLabSDKCore.dylib"
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
