#!/usr/bin/env bash
set -euo pipefail

# Builds a Developer ID–signed, notarized jev-serve and zips it with the SDK frameworks it loads.
#
#   VERSION=0.2.0 \
#   APP_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
#   KEYCHAIN_PROFILE=notary-profile \
#   scripts/release_macos.sh
#
#   VERSION           required, x.y.z — printed by `jev-serve --version`
#   APP_IDENTITY      required, a "Developer ID Application" identity (name or SHA-1 hash; use the
#                     hash when several identities share a name). SIGN_IDENTITY also accepted.
#   KEYCHAIN_PROFILE  notarytool profile (xcrun notarytool store-credentials <name>); required
#                     unless NOTARIZE=0. NOTARY_PROFILE also accepted.
#   TEAM_ID           optional, passed to notarytool
#   NOTARIZE          1 (default) | 0
#
# The zip holds one folder: the jev-serve binary, the two frameworks next to it that it loads by
# @executable_path (LocalLMLabSDKCore, LocalLMLabSDKInference — MLX's compiled shaders are inside
# Inference), the SDK's NOTICE and a short README. Everything is signed inside-out with the
# hardened runtime. A zip can't be stapled: macOS checks the notarization online the first time
# the binary runs.
#
# Artifacts: dist/jev-serve-<VERSION>-arm64.zip (+ .sha256). Scratch in build/release.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

VERSION="${VERSION:-}"
APP_IDENTITY="${APP_IDENTITY:-${SIGN_IDENTITY:-}}"
KEYCHAIN_PROFILE="${KEYCHAIN_PROFILE:-${NOTARY_PROFILE:-}}"
TEAM_ID="${TEAM_ID:-}"
NOTARIZE="${NOTARIZE:-1}"

DIST_DIR="$APP_ROOT/dist"
BUILD_DIR="$APP_ROOT/build/release"
NAME="jev-serve-${VERSION}"
STAGE="$BUILD_DIR/$NAME"
ZIP_PATH="$DIST_DIR/${NAME}-arm64.zip"
VERSION_FILE="$APP_ROOT/Sources/JevServe/Version.swift"

die() { echo "$*" >&2; exit 1; }
sign() { codesign --force --options runtime --timestamp --sign "$APP_IDENTITY" "$@"; }

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]] || die "Set VERSION=x.y.z (got '${VERSION}')"
[[ -n "$APP_IDENTITY" ]] || die "APP_IDENTITY is required"
if [[ "$NOTARIZE" == "1" ]]; then [[ -n "$KEYCHAIN_PROFILE" ]] || die "KEYCHAIN_PROFILE is required (or NOTARIZE=0)"; fi
for c in swift codesign ditto shasum xcrun xattr; do command -v "$c" >/dev/null || die "$c is required"; done

security find-identity -v -p codesigning | grep -F "$APP_IDENTITY" >/dev/null \
  || die "APP_IDENTITY is not installed or not valid for codesigning: $APP_IDENTITY"
# Ambiguous only if the name matches different certificates (the same one is often listed several
# times, from the login, System and iCloud keychains, with the same SHA-1).
[[ "$(security find-identity -v -p codesigning | grep -F "$APP_IDENTITY" | awk '{print $2}' | sort -u | wc -l | tr -d ' ')" -le 1 ]] \
  || die "APP_IDENTITY matches more than one certificate; pass its SHA-1 hash instead"
if [[ "$NOTARIZE" == "1" ]]; then
  xcrun notarytool history --keychain-profile "$KEYCHAIN_PROFILE" >/dev/null 2>&1 \
    || die "KEYCHAIN_PROFILE is not usable: $KEYCHAIN_PROFILE (create it with: xcrun notarytool store-credentials $KEYCHAIN_PROFILE)"
fi

echo "Cleaning release artifacts..."
rm -rf "$BUILD_DIR" "$ZIP_PATH" "$ZIP_PATH.sha256"
mkdir -p "$STAGE" "$DIST_DIR"

# Stamp the version for this build only; put the source back however the script ends.
cp "$VERSION_FILE" "$BUILD_DIR/Version.swift.orig"
restore_version() { cp "$BUILD_DIR/Version.swift.orig" "$VERSION_FILE" 2>/dev/null || true; }
trap restore_version EXIT
sed -i '' "s/^let jevServeVersion = .*/let jevServeVersion = \"$VERSION\"/" "$VERSION_FILE"

echo "Building jev-serve (release, arm64)..."
( cd "$APP_ROOT" && swift build -c release --arch arm64 --product jev-serve )
BIN_DIR="$(cd "$APP_ROOT" && swift build -c release --arch arm64 --show-bin-path)"
restore_version

echo "Staging $NAME..."
cp "$BIN_DIR/jev-serve" "$STAGE/jev-serve"
for fw in LocalLMLabSDKCore LocalLMLabSDKInference; do
  [[ -d "$BIN_DIR/$fw.framework" ]] || die "missing $fw.framework next to the binary in $BIN_DIR. This script packages the published SDK binaries: run it from ancientcomputing/locallm or ancientcomputing/jevdk, not a source-built SDK."
  ditto "$BIN_DIR/$fw.framework" "$STAGE/$fw.framework"
done
# Apache-2.0 §4(d): the SDK's NOTICE (it bundles the MLX stack). At the repository root: one level
# up in ancientcomputing/jevdk, two in ancientcomputing/locallm.
for candidate in "$APP_ROOT/../NOTICE" "$APP_ROOT/../../NOTICE"; do
  if [[ -f "$candidate" ]]; then cp "$candidate" "$STAGE/NOTICE"; break; fi
done
[[ -f "$STAGE/NOTICE" ]] || echo "warning: no NOTICE found next to this repository; the zip ships without it" >&2
cat > "$STAGE/README.txt" <<TXT
jev-serve $VERSION — hosted Jev's HTTP API (OpenRouter /api/alpha/decisions, Featherless
/v1/classifier), answered by OpenJev on this Mac. Needs an Apple-silicon Mac with macOS 27.

Keep the two .framework folders next to jev-serve. Then:

  ./jev-serve --config jev-serve.json      # a config exported from JevDK (File → Export Server Config…)
  ./jev-serve --model mlx-community/Qwen3-4B-4bit   # quick try, no config
  ./jev-serve --help

Docs and source: https://github.com/ancientcomputing/jevdk
TXT

# The published xcframework zips carry AppleDouble / xattr detritus that breaks signing.
find "$STAGE" -name '._*' -delete
xattr -cr "$STAGE"

echo "Signing (inside-out, hardened runtime)..."
for fw in "$STAGE"/*.framework; do
  while IFS= read -r b; do sign "$b"; done < <(find "$fw" -depth -type d -name '*.bundle')
  sign "$fw/$(basename "$fw" .framework)"
  sign "$fw"
done
sign "$STAGE/jev-serve"
for item in "$STAGE"/*.framework "$STAGE/jev-serve"; do codesign --verify --strict --verbose=1 "$item"; done

echo "Smoke test: the signed binary loads its frameworks..."
"$STAGE/jev-serve" --version

echo "Zipping..."
# No AppleDouble (._*) entries: signatures are embedded, and a plain `unzip` stays clean.
( cd "$BUILD_DIR" && ditto -c -k --norsrc --noextattr --keepParent "$NAME" "$ZIP_PATH" )

if [[ "$NOTARIZE" == "1" ]]; then
  echo "Submitting for notarization..."
  args=(--keychain-profile "$KEYCHAIN_PROFILE" --wait --output-format json)
  [[ -n "$TEAM_ID" ]] && args+=(--team-id "$TEAM_ID")
  result="$(xcrun notarytool submit "$ZIP_PATH" "${args[@]}")"
  echo "$result"
  status="$(echo "$result" | /usr/bin/python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  [[ "$status" == "Accepted" ]] || die "Notarization status: $status (see: xcrun notarytool log <id> --keychain-profile $KEYCHAIN_PROFILE)"
else
  echo "Skipping notarization because NOTARIZE=$NOTARIZE"
fi

# Bare filename in the checksum, so `shasum -a 256 -c <file>.sha256` works where it's downloaded.
( cd "$DIST_DIR" && shasum -a 256 "$(basename "$ZIP_PATH")" > "$(basename "$ZIP_PATH").sha256" )

echo "Release artifacts:"
echo "$ZIP_PATH"
echo "$ZIP_PATH.sha256"
