#!/usr/bin/env bash
set -euo pipefail

# check-public-hygiene.sh — guard against private-repo references leaking into the public
# `ancientcomputing/locallm` tree.
#
# The SDK's reference examples and Components are authored in the PRIVATE `locallmlab-sdk` repo
# and copied here by hand (see locallmlab-sdk/docs/04-open-source-sync.md). That copy step is
# where private-isms slip through: sibling `.package(path: "../../Core")` deps, links to the
# private repo's numbered design docs, "this private repo" asides, stale Xcode-beta paths.
#
# Run from the repo root (or anywhere inside it). Exits non-zero and prints every offending
# line if anything is found. Wire it into CI and into the sync doc's "After copying" checklist.
#
#   ./scripts/check-public-hygiene.sh

cd "$(git rev-parse --show-toplevel)"

fail=0
report() {  # <label> <ripgrep-or-grep-args...>
  local label="$1"; shift
  local hits
  # -I skip binary, -n line numbers; the pattern set is passed by the caller
  if hits="$(git grep -nIE "$@" -- \
      ':!scripts/check-public-hygiene.sh' \
      ':!LICENSE' ':!NOTICE' 2>/dev/null)"; then
    echo "✗ $label"
    echo "$hits" | sed 's/^/    /'
    echo
    fail=1
  fi
}

# 1. Names of the private repos. The public repo is "ancientcomputing/locallm" and the
#    testing repo "ancientcomputing/locallm-staging" — both fine; anything else is a leak.
report "private repo name (locallmlab-sdk / locallmlab-main / ancientcomputing/locallmlab)" \
  -e 'locallmlab-sdk' -e 'locallmlab-main' -e 'ancientcomputing/locallmlab'

# 2. "this private repo" / "the private repo" asides — meaningless (wrong, even) once public.
report '"private repo" aside' -e 'private repo'

# 3. Stale Xcode beta paths — Xcode 27 shipped; everything is /Applications/Xcode.app now.
report 'Xcode-beta reference' -e 'Xcode-beta'

# 4. Links to the private repo's numbered design docs (docs/NN-name.md). The public repo's
#    docs/ are all named, never numbered — any docs/NN- reference is dangling.
report 'reference to a numbered (private) design doc' -e 'docs/[0-9][0-9]-[a-z]'

# 5. Sibling path-deps on closed packages. Components is public (path-dep OK); Core, Inference
#    and Remote are not — a public example must reach them via .binaryTarget(url:checksum:).
report 'path-dependency on a closed package (Core/Inference/Remote)' \
  -e '\.package\(path: *"\.\./\.\./(Core|Inference|Remote)"' \
  -e 'package\(path: *"\.\./\.\./\.\./(Core|Inference|Remote)'

if [ "$fail" -ne 0 ]; then
  echo "FAIL: private-repo references found in the public tree (see above)."
  echo "Fix them in locallmlab-sdk first, then re-copy — do not patch only the public side."
  exit 1
fi
echo "OK: no private-repo references found."
