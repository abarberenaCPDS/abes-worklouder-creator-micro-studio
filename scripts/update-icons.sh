#!/usr/bin/env bash
# Regenerate both app icon catalogs and website favicons from one drawing.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/.build/generated/AppIcon.iconset"

swift "$ROOT/scripts/genicon.swift" "$ICONSET"

for app in CreatorMicroStudio Inspector; do
  DEST="$ROOT/Apps/$app/Resources/Assets.xcassets/AppIcon.appiconset"
  cp "$ICONSET"/*.png "$DEST/"
done

# The splash screen loads this regular image-set asset so its mark stays in sync
# with the app icon rather than maintaining a separate keyboard illustration.
SPLASH_ICON="$ROOT/Apps/CreatorMicroStudio/Resources/Assets.xcassets/StudioAppIcon.imageset"
mkdir -p "$SPLASH_ICON"
cp "$ICONSET/icon_512x512.png" "$SPLASH_ICON/studio-app-icon.png"

cp "$ICONSET/icon_16x16.png" "$ROOT/docs/favicon-16.png"
cp "$ICONSET/icon_32x32.png" "$ROOT/docs/favicon-32.png"
sips -z 180 180 "$ICONSET/icon_256x256.png" --out "$ROOT/docs/apple-touch-icon.png" >/dev/null

echo "Updated app icons and website favicons."
