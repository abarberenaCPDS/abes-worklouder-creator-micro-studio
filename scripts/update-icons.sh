#!/usr/bin/env bash
# Regenerate both app icon catalogs and website favicons from one drawing.
# Stable (Release) builds use AppIcon; Dev (Debug) builds use AppIconDev, the
# same artwork with a DEV badge, so the two installs are easy to tell apart.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ICONSET="$ROOT/.build/generated/AppIcon.iconset"
DEV_ICONSET="$ROOT/.build/generated/AppIconDev.iconset"

swift "$ROOT/scripts/genicon.swift" "$ICONSET"
swift "$ROOT/scripts/genicon.swift" "$DEV_ICONSET" --dev

for app in CreatorMicroStudio Inspector; do
  CATALOG="$ROOT/Apps/$app/Resources/Assets.xcassets"
  cp "$ICONSET"/*.png "$CATALOG/AppIcon.appiconset/"
  mkdir -p "$CATALOG/AppIconDev.appiconset"
  cp "$CATALOG/AppIcon.appiconset/Contents.json" "$CATALOG/AppIconDev.appiconset/Contents.json"
  cp "$DEV_ICONSET"/*.png "$CATALOG/AppIconDev.appiconset/"
done

# The splash screen loads these regular image-set assets so its mark stays in
# sync with the app icon rather than maintaining a separate keyboard illustration.
for variant in "StudioAppIcon:$ICONSET" "StudioAppIconDev:$DEV_ICONSET"; do
  name="${variant%%:*}"
  source="${variant#*:}"
  SPLASH_ICON="$ROOT/Apps/CreatorMicroStudio/Resources/Assets.xcassets/$name.imageset"
  mkdir -p "$SPLASH_ICON"
  if [[ ! -f "$SPLASH_ICON/Contents.json" ]]; then
    sed "s/studio-app-icon.png/studio-app-icon-dev.png/" \
      "$ROOT/Apps/CreatorMicroStudio/Resources/Assets.xcassets/StudioAppIcon.imageset/Contents.json" \
      > "$SPLASH_ICON/Contents.json"
  fi
  if [[ "$name" == StudioAppIcon ]]; then
    cp "$source/icon_512x512.png" "$SPLASH_ICON/studio-app-icon.png"
  else
    cp "$source/icon_512x512.png" "$SPLASH_ICON/studio-app-icon-dev.png"
  fi
done

# Favicons always show the stable artwork.
cp "$ICONSET/icon_16x16.png" "$ROOT/docs/favicon-16.png"
cp "$ICONSET/icon_32x32.png" "$ROOT/docs/favicon-32.png"
sips -z 180 180 "$ICONSET/icon_256x256.png" --out "$ROOT/docs/apple-touch-icon.png" >/dev/null

echo "Updated stable and dev app icons and website favicons."
