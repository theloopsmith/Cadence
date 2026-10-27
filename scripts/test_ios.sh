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

# XCTest ships with Xcode, not with the Command Line Tools. If xcode-select
# points at CommandLineTools, `swift test` fails with "no such module 'XCTest'",
# so point this one invocation at a full Xcode without needing sudo.
if [ -z "${DEVELOPER_DIR:-}" ] && ! xcrun --find xctest >/dev/null 2>&1; then
  for candidate in /Applications/Xcode.app /Applications/Xcode-beta.app; do
    if [ -d "$candidate/Contents/Developer" ]; then
      export DEVELOPER_DIR="$candidate/Contents/Developer"
      echo "Using Xcode toolchain at $DEVELOPER_DIR (XCTest is not in the Command Line Tools)."
      break
    fi
  done
fi

swift test --scratch-path "$SCRATCH" "$@"
