#!/usr/bin/env bash
# Runs the Swift edge-DSP test suite.
#
# The repo lives inside iCloud Drive, which stamps extended attributes
# (com.apple.FinderInfo / file-provider metadata) onto synced files. codesign
# rejects bundles carrying those attributes ("resource fork, Finder information,
# or similar detritus not allowed"), so we build outside iCloud.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="${CADENCE_SWIFT_SCRATCH:-$HOME/Library/Caches/CadenceBuild/ios}"

cd "$ROOT_DIR/ios"
# Remove any in-iCloud build dir left over from a plain `swift test`.
rm -rf .build

swift test --scratch-path "$SCRATCH" "$@"
