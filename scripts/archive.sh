#!/usr/bin/env bash
# Create a signed Xcode archive of Creator Micro Studio and its Inspector helper.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ARCHIVE_PATH="${1:-$ROOT/.build/archives/AbesWorkLouderCreatorMicroStudio.xcarchive}"
mkdir -p "$(dirname "$ARCHIVE_PATH")"

xcodebuild -quiet \
  -project "$ROOT/AbesWorkLouderCreatorMicroStudio.xcodeproj" \
  -scheme CreatorMicroStudio \
  -configuration Release \
  -destination 'generic/platform=macOS' \
  -derivedDataPath "$ROOT/.build/DerivedData" \
  -archivePath "$ARCHIVE_PATH" \
  archive

echo "Archive created at: $ARCHIVE_PATH"
