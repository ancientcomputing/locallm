#!/usr/bin/env bash
# check-root-package.sh: the root Package.swift, Components/Package.swift and every example manifest must agree on the
# checksums of the release they build against. A re-published release changes its zips, and a manifest that was
# missed fails for users with "changed checksum".
#
#   scripts/check-root-package.sh            # compare the manifests with each other (offline)
#   scripts/check-root-package.sh --online   # also compare them with the .sha256 files on the GitHub release (needs gh)
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
python3 - "$@" <<'PY'
import re, sys, glob, subprocess
root = open("Package.swift").read()
release = re.search(r'let release = "([^"]+)"', root).group(1)
mods = re.findall(r'name: "(LocalLMLabSDK\w+)",\s*url:[^\n]*\n\s*checksum: "([0-9a-f]{64})"', root)
expected = dict(mods)
assert len(expected) == 4, f"expected 4 binary targets in Package.swift, found {len(expected)}"
known = set(expected.values())
bad = []
for f in ["Components/Package.swift"] + sorted(glob.glob("examples/*/Package.swift")):
    s = open(f).read()
    m = re.search(r'"%s":\s*SDKRelease\((.*?)\n    \)' % re.escape(release), s, re.S)
    if not m:
        continue
    for h in re.findall(r'"([0-9a-f]{64})"', m.group(1)):
        if h not in known:
            bad.append(f"{f}: {h[:12]}... is not one of the {release} checksums in Package.swift")
branch = subprocess.run(["git", "branch", "--show-current"], capture_output=True, text=True).stdout.strip()
if re.fullmatch(r"\d+\.\d+\.\d+-GA", branch) and branch != release:
    bad.append(f"Package.swift: release is {release} but this is the {branch} branch")
for f in ["docs/quickstart.md", "AGENTS.md"]:
    if f'branch: "{release}"' not in open(f).read() and f"**Branch** `{release}`" not in open(f).read():
        bad.append(f"{f}: does not tell people to add the package with the Branch rule {release}")
if "--online" in sys.argv:
    for mod, h in expected.items():
        url = f"https://github.com/ancientcomputing/locallm/releases/download/v{release}/{mod}-{release}.xcframework.zip.sha256"
        out = subprocess.run(["curl", "-sL", url], capture_output=True, text=True).stdout.split()
        if not out or out[0] != h:
            bad.append(f"Package.swift: {mod} is {h[:12]}... but the release says {(out[0][:12] + '...') if out else 'nothing'}")
if bad:
    print("FAIL:\n  " + "\n  ".join(bad)); sys.exit(1)
print(f"OK: Package.swift, Components and the examples agree on the {release} checksums" + (" and match the release" if "--online" in sys.argv else ""))
PY
