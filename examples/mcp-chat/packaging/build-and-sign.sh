#!/usr/bin/env bash
set -euo pipefail

# Builds and signs "MCP Chat.app" (unnotarized, local use). Works with either way of getting the SDK:
#   - binary (the published SDK release): Core and Inference are .frameworks next to the binary,
#     each carrying its own resource bundles (the MLX Metal shaders);
#   - source (path dependencies): Core and Inference are dynamic libraries next to the binary, and
#     the MLX runtime's resource bundles go in Contents/Resources, where SwiftPM's lookup finds them
#     (building the SDK from source needs the Metal Toolchain).
# Needs Xcode 27 (Swift 6.4).
#
#   APP_IDENTITY  codesigning identity (default: the first "Apple Development" identity; "-" = ad hoc)
#   CONFIG        debug | release (default: release)
#   SANDBOX       1 (default) | 0 — 0 signs without App Sandbox, for development only: the app can
#                 then use an existing model cache (MCPCHAT_MODEL_CACHE) instead of downloading

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_NAME="MCP Chat"
BIN_NAME="MCPChat"
CONFIG="${CONFIG:-release}"
DEVELOPER_DIR="${DEVELOPER_DIR:-$(xcode-select -p)}"
export DEVELOPER_DIR
APP_IDENTITY="${APP_IDENTITY:-$(security find-identity -v -p codesigning | grep 'Apple Development' | head -1 | sed -E 's/.*"(.*)".*/\1/' || true)}"
APP_IDENTITY="${APP_IDENTITY:--}"

BUILD_DIR="$APP_ROOT/build"
APP_DIR="$APP_ROOT/dist/${APP_NAME}.app"
rm -rf "$APP_DIR"
mkdir -p "$BUILD_DIR" "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"

swift build --package-path "$APP_ROOT" -c "$CONFIG" --arch arm64 --build-path "$BUILD_DIR/swift"
BIN_DIR="$(swift build --package-path "$APP_ROOT" -c "$CONFIG" --arch arm64 --build-path "$BUILD_DIR/swift" --show-bin-path)"

cp "$SCRIPT_DIR/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$BIN_DIR/$BIN_NAME" "$APP_DIR/Contents/MacOS/$BIN_NAME"
shopt -s nullglob
for lib in "$BIN_DIR"/*.dylib; do cp "$lib" "$APP_DIR/Contents/MacOS/"; done
for bundle in "$BIN_DIR"/*.bundle; do cp -R "$bundle" "$APP_DIR/Contents/Resources/"; done
FRAMEWORKS=()
for fw in "$BIN_DIR"/LocalLMLabSDK*.framework; do
  name="$(basename "$fw")"
  cp -R "$fw" "$APP_DIR/Contents/MacOS/$name"
  # The published xcframework zips carry AppleDouble/xattr detritus that breaks signing.
  find "$APP_DIR/Contents/MacOS/$name" -name '._*' -delete
  xattr -cr "$APP_DIR/Contents/MacOS/$name"
  FRAMEWORKS+=("$APP_DIR/Contents/MacOS/$name")
done
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"

echo "Signing as: $APP_IDENTITY"
ENT="$SCRIPT_DIR/MCPChat.entitlements"
if [[ "${SANDBOX:-1}" == "0" ]]; then
  ENT="$BUILD_DIR/MCPChat-dev.entitlements"
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict/></plist>\n' > "$ENT"
  echo "Development build: App Sandbox OFF"
fi
for lib in "$APP_DIR"/Contents/MacOS/*.dylib; do codesign --force --sign "$APP_IDENTITY" "$lib"; done
# Frameworks inside-out: nested bundles, the framework binary, then the framework.
for fw in ${FRAMEWORKS[@]+"${FRAMEWORKS[@]}"}; do  # (empty-array safe under set -u in bash 3.2)
  while IFS= read -r b; do codesign --force --sign "$APP_IDENTITY" "$b"; done < <(find "$fw" -type d -name '*.bundle')
  codesign --force --sign "$APP_IDENTITY" "$fw/$(basename "$fw" .framework)"
  codesign --force --sign "$APP_IDENTITY" "$fw"
done
codesign --force --entitlements "$ENT" --sign "$APP_IDENTITY" "$APP_DIR/Contents/MacOS/$BIN_NAME"
codesign --force --entitlements "$ENT" --sign "$APP_IDENTITY" "$APP_DIR"
codesign --verify --deep --strict --verbose=2 "$APP_DIR"
echo "$APP_DIR"
