#!/usr/bin/env bash
set -euo pipefail

# sync-jevdk-repo.sh — copy JevDK and jev-serve from this repo into a clone of
# ancientcomputing/jevdk, the standalone repo end users download them from.
#
#   scripts/sync-jevdk-repo.sh ../jevdk
#   SDK_VERSION=2.0.0 scripts/sync-jevdk-repo.sh ../jevdk    # also move the clone to another SDK
#
# One-way: this repo (examples/jevdk, examples/jev-serve) is the source of truth, and both folders
# are copied unchanged into <clone>/jevdk and <clone>/jev-serve, so they build there exactly as
# they do here (jev-serve takes the SDK binaries from ../jevdk). The clone's own files (README.md,
# NOTICE, SOURCE.md, scripts/) are left alone, except NOTICE, which is refreshed from this repo's.
# Then it builds both, runs jev-serve's tests, and shows what changed. It never commits or pushes.
#
# The SDK version is the one exception to "unchanged". examples/jevdk follows the SDK's releases
# closely; the jevdk repo stays on the main x.0.0 releases unless a newer one has something it
# needs. So the clone keeps its own `defaultSDKVersion` (jevdk/Package.swift), and only
# SDK_VERSION=<version> changes it. The release table (knownSDKReleases) is copied as is, so it
# must list that version.

cd "$(git rev-parse --show-toplevel)"
SRC="$PWD"
DEST="${1:-}"
[[ -n "$DEST" && -d "$DEST/.git" ]] || { echo "usage: scripts/sync-jevdk-repo.sh <path to a clone of ancientcomputing/jevdk>" >&2; exit 1; }
DEST="$(cd "$DEST" && pwd)"
git -C "$DEST" remote get-url origin | grep -q "ancientcomputing/jevdk" \
  || { echo "$DEST isn't a clone of ancientcomputing/jevdk" >&2; exit 1; }

echo "== Checking this repo for private references first"
./scripts/check-public-hygiene.sh

PKG=jevdk/Package.swift
VERSION_RE='^let defaultSDKVersion = "\([^"]*\)"'
KEEP="${SDK_VERSION:-$( [[ -f "$DEST/$PKG" ]] && sed -n "s/$VERSION_RE/\1/p" "$DEST/$PKG" )}"

EXCLUDES=(--exclude .build/ --exclude .swiftpm/ --exclude build/ --exclude dist/ --exclude Package.resolved
          --exclude xcuserdata/ --exclude .DS_Store --exclude jev-serve.json --exclude .env --exclude 'key.env')
for d in jevdk jev-serve; do
  echo "== Copying examples/$d → $DEST/$d"
  rsync -a --delete "${EXCLUDES[@]}" "$SRC/examples/$d/" "$DEST/$d/"
done
cp "$SRC/NOTICE" "$DEST/NOTICE"

if [[ -n "$KEEP" ]]; then
  grep -q "^    \"$KEEP\": SDKRelease(" "$DEST/$PKG" \
    || { echo "SDK $KEEP isn't in knownSDKReleases in examples/$PKG; add it there first" >&2; exit 1; }
  sed -i '' "s/$VERSION_RE/let defaultSDKVersion = \"$KEEP\"/" "$DEST/$PKG"
fi
echo "== SDK: the jevdk repo builds against $(sed -n "s/$VERSION_RE/\1/p" "$DEST/$PKG") (examples: $(sed -n "s/$VERSION_RE/\1/p" "$SRC/examples/$PKG"))"

echo "== Building"
( cd "$DEST/jevdk" && swift build -c release 2>&1 | tail -1 )
( cd "$DEST/jev-serve" && swift build -c release 2>&1 | tail -1 )
echo "== jev-serve tests"
( cd "$DEST/jev-serve" && swift test 2>&1 | grep -E "Test run with|✘|error:" | tail -3 )

echo "== Changes in $DEST (review, then commit and push yourself)"
git -C "$DEST" status --short
