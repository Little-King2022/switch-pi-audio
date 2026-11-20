#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
app="${1:-$PWD/build/Switch 音频.app}"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp Info.plist "$app/Contents/Info.plist"
icon_temp=$(mktemp -d)
trap 'rm -r "$icon_temp"' EXIT
objects=()
for source in Decoder/SBCDecoder.c Decoder/upstream/srce/*.c; do
  object="$icon_temp/$(basename "$source" .c).o"
  xcrun clang -O2 -target arm64-apple-macosx14.0 -I Decoder/upstream/include -c "$source" -o "$object"
  objects+=("$object")
done
xcrun swiftc -O -swift-version 5 -target arm64-apple-macosx14.0 \
  -import-objc-header Decoder/SBCDecoder.h Sources/*.swift "${objects[@]}" -o "$app/Contents/MacOS/SwitchPiAudio"
cp Decoder/NOTICE "$app/Contents/Resources/SBC-LICENSE.txt"
printf '\nSBC decoder copyright Open Interface North America, Broadcom and Android contributors.\n' >> "$app/Contents/Resources/SBC-LICENSE.txt"
mkdir "$icon_temp/AppIcon.iconset"
xcrun swift MakeIcon.swift "$icon_temp/full.png"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$icon_temp/full.png" --out "$icon_temp/AppIcon.iconset/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$icon_temp/full.png" --out "$icon_temp/AppIcon.iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$icon_temp/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
printf '%s\n' "$app"
