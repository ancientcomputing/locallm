#!/usr/bin/env bash
set -euo pipefail

# flush-sdk-cache.sh — force every example's next Xcode build to re-download the SDK
# xcframeworks from GitHub instead of reusing a locally cached copy.
#
# Each example's Package.swift resolves LocalLMLabSDK{Core,Inference,Remote,Claude} as a
# binaryTarget pinned by URL + checksum (see examples/*/Package.swift, Components/Package.swift).
# Xcode/SwiftPM only re-verifies that pin the first time it downloads an artifact — once it's
# sitting in DerivedData or the global SwiftPM artifact cache, a rebuild reuses it even after a
# new SDK release lands, because the cache key is the URL, not "did GitHub's content change".
# Bumping defaultSDKVersion (and its checksum) is what makes a real version change visible; this
# script is for the "I'm not sure what's stale locally, just make everything re-fetch" case —
# after a beta bump, before filing an SDK bug, or when an example behaves like it's running old
# SDK code despite the manifest looking right.
#
# Run from anywhere inside the repo:
#   ./scripts/flush-sdk-cache.sh

cd "$(git rev-parse --show-toplevel)"

echo "== DerivedData for this repo's example projects =="
derived_data="$HOME/Library/Developer/Xcode/DerivedData"
if [ -d "$derived_data" ]; then
  # Match DerivedData's "<ProjectName>-<hash>" naming against every *.xcodeproj under examples/.
  proj_names="$(find examples -maxdepth 2 -iname '*.xcodeproj' -exec basename {} .xcodeproj \; | sort -u)"
  while IFS= read -r name; do
    [ -z "$name" ] && continue
    for dir in "$derived_data/$name"-*; do
      [ -d "$dir" ] || continue
      echo "  removing $(basename "$dir")"
      rm -rf "$dir"
    done
  done <<< "$proj_names"
else
  echo "  (no DerivedData directory found)"
fi

echo "== SwiftPM global artifact cache (ancientcomputing/locallm entries) =="
swiftpm_cache="$HOME/Library/Caches/org.swift.swiftpm/artifacts"
if [ -d "$swiftpm_cache" ]; then
  found=0
  for dir in "$swiftpm_cache"/https___github_com_ancientcomputing_locallm_*; do
    [ -d "$dir" ] || continue
    found=1
    echo "  removing $(basename "$dir")"
    rm -rf "$dir"
  done
  [ "$found" -eq 0 ] && echo "  (nothing cached)"
else
  echo "  (no SwiftPM artifact cache found)"
fi

echo "== Local .build directories under examples/ =="
found=0
while IFS= read -r dir; do
  found=1
  echo "  removing $dir"
  rm -rf "$dir"
done < <(find examples Components -maxdepth 2 -type d -name .build 2>/dev/null)
[ "$found" -eq 0 ] && echo "  (none)"

echo
echo "Done. Next Xcode build (or 'swift build') re-resolves and re-downloads from GitHub."
