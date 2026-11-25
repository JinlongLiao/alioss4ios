#!/bin/bash
set -euo pipefail

cd "$(dirname "$0")/.."
swift build -c release --arch arm64
bin_dir="$(swift build -c release --arch arm64 --show-bin-path)"
app="$PWD/dist/alioss4ios.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
install -m 755 "$bin_dir/alioss4ios" "$app/Contents/MacOS/alioss4ios"
install -m 644 scripts/Info.plist "$app/Contents/Info.plist"
for bundle in "$bin_dir"/*.bundle; do
    [[ -d "$bundle" ]] || continue
    ditto "$bundle" "$app/Contents/Resources/$(basename "$bundle")"
done
icon_source="Sources/alioss4ios/AppAssets.xcassets/AppIcon.appiconset/AppIcon.png"
icon_work="$(mktemp -d)"
trap 'rm -rf "$icon_work"' EXIT
iconset="$icon_work/AppIcon.iconset"
mkdir "$iconset"
for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$icon_source" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$icon_source" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
