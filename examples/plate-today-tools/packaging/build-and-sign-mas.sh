#!/usr/bin/env bash
set -euo pipefail

# Builds, signs, and packages Plate Today (Tools).app for Mac App Store submission — a parallel path to
# build-and-sign.sh's Developer ID/notarized-.dmg flow, not a replacement for it. Real differences
# from that script, not just cosmetic:
#   - Signs with an "Apple Distribution" identity (APP_SIGN_IDENTITY), not Developer ID.
#   - Embeds a Mac App Store provisioning profile (Contents/embedded.provisionprofile) — nothing
#     in the Developer ID path needs this at all.
#   - App Sandbox is unconditional here, not opt-in — MAS requires it. No PLATETODAYTOOLS_APP_SANDBOX
#     flag; this script always builds sandboxed.
#   - Produces a signed .pkg via productbuild (needs a SEPARATE "Mac Installer Distribution"
#     identity, INSTALLER_SIGN_IDENTITY — signing the .app and signing the .pkg are genuinely
#     different certificate types, easy to conflate since both commonly get called "distribution"
#     casually), not a notarized .dmg. MAS packages aren't notarized/stapled the normal way — App
#     Review is the equivalent gate, not notarytool.
# See docs/sdk-guide.md section 10d for the one-time Apple Developer Portal setup
# (certificate, App ID, provisioning profile) this script assumes is already done.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

APP_NAME="Plate Today (Tools)"
BUNDLE_ID="lab.locallm.sdk.reference.platetodaytools"
VERSION="${VERSION:-0.1.0}"
APP_SIGN_IDENTITY="${APP_SIGN_IDENTITY:-}"
INSTALLER_SIGN_IDENTITY="${INSTALLER_SIGN_IDENTITY:-}"
# Explicit path takes priority; otherwise auto-discovered below by matching this app's bundle ID
# against every profile's own application-identifier, since Xcode's storage location/filename
# (UUID-named, no bundle ID in the path) gives no other way to find "the right one" for this app.
PROVISIONING_PROFILE="${PROVISIONING_PROFILE:-}"
DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER="${PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER:-0}"
PLATETODAYTOOLS_INCLUDE_TODOIST="${PLATETODAYTOOLS_INCLUDE_TODOIST:-1}"
PLATETODAYTOOLS_INCLUDE_CONTACTS="${PLATETODAYTOOLS_INCLUDE_CONTACTS:-0}"

DIST_DIR="$APP_ROOT/dist"
BUILD_DIR="$APP_ROOT/build/release-mas"
APP_DIR="$DIST_DIR/${APP_NAME}.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
ENTITLEMENTS="$BUILD_DIR/PlateTodayTools-MAS.entitlements"
PKG_PATH="$DIST_DIR/${APP_NAME}-${VERSION}-mas.pkg"
# Modern Xcode's actual storage location — NOT ~/Library/MobileDevice/Provisioning Profiles/,
# which is what most online docs/scripts still reference and where nothing shows up if you only
# check there. See docs/sdk-guide.md section 10d.
PROFILES_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

export DEVELOPER_DIR

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "$1 is required" >&2
    exit 1
  fi
}

require_command swift
require_command codesign
require_command productbuild
require_command python3
require_command security

if [[ -z "$APP_SIGN_IDENTITY" ]]; then
  APP_SIGN_IDENTITY="$(security find-identity -v -p codesigning | grep -oE '"Apple Distribution:[^"]+"' | head -1 | tr -d '"')"
fi
if [[ -z "$APP_SIGN_IDENTITY" ]]; then
  echo "No APP_SIGN_IDENTITY set and no 'Apple Distribution' identity found automatically." >&2
  echo "See docs/sdk-guide.md section 10d to create one." >&2
  security find-identity -v -p codesigning || true
  exit 1
fi
if ! security find-identity -v -p codesigning | grep -F "$APP_SIGN_IDENTITY" >/dev/null 2>&1; then
  echo "APP_SIGN_IDENTITY is not installed or is not valid for codesigning: $APP_SIGN_IDENTITY" >&2
  security find-identity -v -p codesigning || true
  exit 1
fi

if [[ -z "$INSTALLER_SIGN_IDENTITY" ]]; then
  INSTALLER_SIGN_IDENTITY="$(security find-identity -v | grep -oE '"(Mac Installer Distribution|3rd Party Mac Developer Installer):[^"]+"' | head -1 | tr -d '"')"
fi
if [[ -z "$INSTALLER_SIGN_IDENTITY" ]]; then
  echo "No INSTALLER_SIGN_IDENTITY set and no installer-signing identity found automatically." >&2
  echo "This is a DIFFERENT certificate from Apple Distribution — create one via Xcode ->" >&2
  echo "Settings -> Accounts -> your team -> Manage Certificates -> + -> Mac Installer Distribution." >&2
  security find-identity -v || true
  exit 1
fi

if [[ -z "$PROVISIONING_PROFILE" ]]; then
  echo "Searching $PROFILES_DIR for a profile matching $BUNDLE_ID..."
  if [[ -d "$PROFILES_DIR" ]]; then
    for candidate in "$PROFILES_DIR"/*.provisionprofile; do
      [[ -f "$candidate" ]] || continue
      # Entitlements.com.apple.application-identifier — the dots inside the key itself need
      # escaping (plutil -extract otherwise treats them as key-path separators and reports "no
      # value at that key path" even though the key is right there under Entitlements).
      app_id="$(security cms -D -i "$candidate" 2>/dev/null | plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - - 2>/dev/null || true)"
      if [[ "$app_id" == *".$BUNDLE_ID" ]]; then
        PROVISIONING_PROFILE="$candidate"
        break
      fi
    done
  fi
fi
if [[ -z "$PROVISIONING_PROFILE" || ! -f "$PROVISIONING_PROFILE" ]]; then
  echo "Could not find a provisioning profile for $BUNDLE_ID automatically." >&2
  echo "Set PROVISIONING_PROFILE explicitly, or check $PROFILES_DIR for the right one -" >&2
  echo "see docs/sdk-guide.md section 10d for how it's verified." >&2
  exit 1
fi
echo "Using provisioning profile: $PROVISIONING_PROFILE"

# The provisioning profile embeds an application-identifier (TEAMID.bundleID) that must ALSO be
# signed into the bundle's own entitlements — Xcode's automatic signing does this invisibly, but a
# manual codesign --entitlements call only embeds exactly what's in that plist. Without it, App
# Store Connect rejects the upload for TestFlight with "the signature ... is missing an
# application identifier but has an application identifier in the provisioning profile" (confirmed
# live via a real Transporter upload, 2026-08-14). Same plutil-escaping caveat as the profile
# lookup above.
APP_IDENTIFIER="$(security cms -D -i "$PROVISIONING_PROFILE" 2>/dev/null | plutil -extract 'Entitlements.com\.apple\.application-identifier' raw -o - - 2>/dev/null || true)"
if [[ -z "$APP_IDENTIFIER" ]]; then
  echo "Could not extract com.apple.application-identifier from $PROVISIONING_PROFILE" >&2
  exit 1
fi
echo "Using application identifier: $APP_IDENTIFIER"

echo "Cleaning release artifacts..."
rm -rf "$BUILD_DIR" "$APP_DIR" "$PKG_PATH"
mkdir -p "$BUILD_DIR" "$DIST_DIR"

echo "Generating app icon..."
python3 "$SCRIPT_DIR/generate_app_icon.py"
ICON_BUILD_DIR="$BUILD_DIR/icon"
mkdir -p "$ICON_BUILD_DIR"
# CFBundleIconName (already set in Info.plist) requires an actual asset catalog to resolve
# against — a bare .icns via CFBundleIconFile alone isn't sufficient for App Store Connect's
# asset-catalog validation ("Missing asset catalog", confirmed live via a real Transporter upload,
# 2026-08-14) or for System Settings' Privacy & Security pane. actool derives both Assets.car and
# an AppIcon.icns from the same appiconset in one pass.
echo "Compiling app icon asset catalog..."
xcrun actool --output-format human-readable-text --notices --warnings --errors \
  --app-icon AppIcon \
  --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist" \
  --platform macosx --minimum-deployment-target 26.0 \
  --compile "$ICON_BUILD_DIR" \
  "$SCRIPT_DIR/Resources/Assets.xcassets"

echo "Building Plate Today (Tools) for arm64 (App Sandbox: on, always, for MAS; Location/Weather: $([ "$PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER" == "1" ] && echo included || echo excluded); Todoist: $([ "$PLATETODAYTOOLS_INCLUDE_TODOIST" == "1" ] && echo included || echo excluded); Contacts: $([ "$PLATETODAYTOOLS_INCLUDE_CONTACTS" == "1" ] && echo included || echo excluded))..."
PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER="$PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER" \
PLATETODAYTOOLS_INCLUDE_TODOIST="$PLATETODAYTOOLS_INCLUDE_TODOIST" \
PLATETODAYTOOLS_INCLUDE_CONTACTS="$PLATETODAYTOOLS_INCLUDE_CONTACTS" \
  swift build --package-path "$APP_ROOT" -c release --arch arm64 --build-path "$BUILD_DIR/swift"

BINARY="$BUILD_DIR/swift/arm64-apple-macosx/release/PlateTodayTools"
# Same @rpath dynamic-library situation as build-and-sign.sh — see that script's comment for the
# full "Library not loaded" failure-mode writeup this works around, including why the on-disk
# shape (flat dylib vs. LocalLMLabSDKCore.framework) depends on whether Core comes from source
# (this private repo) or a binaryTarget (the public locallm copy).
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

cp "$SCRIPT_DIR/PlateTodayTools.entitlements" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.app-sandbox bool true" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.security.network.client bool true" "$ENTITLEMENTS"
/usr/libexec/PlistBuddy -c "Add :com.apple.application-identifier string $APP_IDENTIFIER" "$ENTITLEMENTS"
if [[ "$PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER" == "1" ]]; then
  echo "Adding Location usage-description key and entitlement (PLATETODAYTOOLS_INCLUDE_LOCATION_WEATHER=1)..."
  /usr/libexec/PlistBuddy -c "Add :NSLocationUsageDescription string 'Plate Today (Tools) looks up your current location, once, to include today'\\''s local weather in your summary.'" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.personal-information.location bool true" "$ENTITLEMENTS"
fi
if [[ "$PLATETODAYTOOLS_INCLUDE_CONTACTS" == "1" ]]; then
  echo "Adding Contacts usage-description key and entitlement (PLATETODAYTOOLS_INCLUDE_CONTACTS=1)..."
  /usr/libexec/PlistBuddy -c "Add :NSContactsUsageDescription string 'Plate Today (Tools) searches your Contacts, on request, to enrich a calendar event or reminder that names a specific person.'" "$CONTENTS_DIR/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :com.apple.security.personal-information.addressbook bool true" "$ENTITLEMENTS"
fi

cp "$ICON_BUILD_DIR/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$ICON_BUILD_DIR/Assets.car" "$RESOURCES_DIR/Assets.car"
cp "$BINARY" "$MACOS_DIR/PlateTodayTools"
cp -R "$CORE_ARTIFACT_SRC" "$MACOS_DIR/$CORE_ARTIFACT_NAME"

if [[ "$CORE_ARTIFACT_NAME" == *.framework ]]; then
  # SwiftPM's .framework build output (and the public locallm copy's binaryTarget slice) is a
  # flat, unversioned bundle — no Versions/ directory at all. That's fine for dyld to load, but
  # App Store Connect's real validation rejects it: "must contain a symbolic link 'X' ->
  # 'Versions/Current/X'" for the binary, Headers, and Resources, plus a Versions/Current symlink
  # resolving to a real version directory (confirmed live via a real Transporter upload,
  # 2026-08-14 — see "Anatomy of Framework Bundles"). Restructure into the classic umbrella-
  # framework layout before signing.
  echo "Restructuring $CORE_ARTIFACT_NAME into a versioned framework bundle (required for MAS/TestFlight validation)..."
  FW_DIR="$MACOS_DIR/$CORE_ARTIFACT_NAME"
  FW_BINARY_NAME="${CORE_ARTIFACT_NAME%.framework}"
  FW_VERSION_DIR="$FW_DIR/Versions/A"
  mkdir -p "$FW_VERSION_DIR"
  for item in "$FW_DIR"/*; do
    [[ "$(basename "$item")" == "Versions" ]] && continue
    mv "$item" "$FW_VERSION_DIR/"
  done
  # Info.plist belongs inside Versions/A/Resources in the versioned layout, not at the top level.
  mkdir -p "$FW_VERSION_DIR/Resources"
  if [[ -f "$FW_VERSION_DIR/Info.plist" ]]; then
    mv "$FW_VERSION_DIR/Info.plist" "$FW_VERSION_DIR/Resources/Info.plist"
  fi
  ln -s A "$FW_DIR/Versions/Current"
  ln -s "Versions/Current/$FW_BINARY_NAME" "$FW_DIR/$FW_BINARY_NAME"
  ln -s Versions/Current/Resources "$FW_DIR/Resources"
  [[ -d "$FW_VERSION_DIR/Headers" ]] && ln -s Versions/Current/Headers "$FW_DIR/Headers"
  [[ -d "$FW_VERSION_DIR/Modules" ]] && ln -s Versions/Current/Modules "$FW_DIR/Modules"
fi

cp "$PROVISIONING_PROFILE" "$CONTENTS_DIR/embedded.provisionprofile"
printf 'APPL????' > "$CONTENTS_DIR/PkgInfo"
chmod +x "$MACOS_DIR/PlateTodayTools"

echo "Verifying binary is arm64..."
file "$MACOS_DIR/PlateTodayTools"

echo "Signing app bundle..."
# Same discipline as build-and-sign.sh: sign the binary first, then the whole bundle WITH
# --entitlements again, since the bundle-level sign re-signs the main executable regardless and
# silently drops entitlements applied a moment earlier if --entitlements isn't repeated.
codesign --force --options runtime --timestamp --sign "$APP_SIGN_IDENTITY" "$MACOS_DIR/$CORE_ARTIFACT_NAME"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_SIGN_IDENTITY" "$MACOS_DIR/PlateTodayTools"
codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$APP_SIGN_IDENTITY" "$APP_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_DIR"

echo "Verifying provisioning profile matches this signature..."
security cms -D -i "$APP_DIR/Contents/embedded.provisionprofile" | plutil -p - | grep -E "Name|application-identifier"

echo "Building signed .pkg via productbuild..."
productbuild --component "$APP_DIR" /Applications --sign "$INSTALLER_SIGN_IDENTITY" "$PKG_PATH"

echo "Verifying .pkg signature..."
pkgutil --check-signature "$PKG_PATH"

echo "Release artifacts:"
echo "$APP_DIR"
echo "$PKG_PATH"
echo
echo "Not done here: uploading to App Store Connect (Transporter.app, or"
echo "xcrun altool --upload-package / the App Store Connect API) - this script produces a"
echo "correctly signed .pkg, not a submission."
