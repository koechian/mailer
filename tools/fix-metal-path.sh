#!/bin/bash
# Xcode's Metal compiler lives in a disk image macOS mounts under a random
# folder name (…/MetalToolchain-v27.2.47.0.iLY049) that changes after a
# restart, but SwiftPM keeps the old folder in its cached build plans and
# then fails with "unable to spawn process … metal". Point the cached plans
# at today's folder (the fix Cued's build.sh uses, 2026-10-29).
set -euo pipefail
cd "$(dirname "$0")/.."
MOUNT="$(ls -d /var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-* 2>/dev/null | head -1 || true)"
PLANS=".build/out/Intermediates.noindex/XCBuildData"
[ -n "$MOUNT" ] && [ -d "$PLANS" ] || exit 0
{ grep -rl "com.apple.MobileAsset.MetalToolchain-" "$PLANS" 2>/dev/null || true; } | while read -r plan; do
    sed -i '' -E "s#/var/run/com\.apple\.security\.cryptexd/mnt/com\.apple\.MobileAsset\.MetalToolchain-[^/\"]+#$MOUNT#g" "$plan"
done
