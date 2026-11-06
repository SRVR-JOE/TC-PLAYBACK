#!/bin/bash
# Usage: scripts/build.sh [sim-iphone|sim-ipad|test]   — builds into ./build/DD (per worktree)
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate --quiet
DEST_IPHONE='platform=iOS Simulator,name=iPhone 17'
DEST_IPAD='platform=iOS Simulator,name=iPad Pro 13-inch (M5)'
MODE="${1:-sim-iphone}"
DEST="$DEST_IPHONE"; [ "$MODE" = sim-ipad ] && DEST="$DEST_IPAD"
ACTION=build; [ "$MODE" = test ] && ACTION=test
xcodebuild -project TCPlayback.xcodeproj -scheme TCPlayback -destination "$DEST" \
  -derivedDataPath build/DD $ACTION 2>&1 | grep -E "error:|warning: unre|\*\* (BUILD|TEST)|Test Case.*failed|Executed" | head -80
