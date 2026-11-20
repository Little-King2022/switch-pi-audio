#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fixture="$scratch/LocalizationCheck.app"
mkdir -p "$fixture/Contents/MacOS" "$fixture/Contents/Resources"
cp Info.plist "$fixture/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleExecutable LocalizationCheck' "$fixture/Contents/Info.plist"
cp -R Resources/*.lproj "$fixture/Contents/Resources/"
xcrun swiftc -swift-version 5 -module-cache-path "$scratch/module-cache" Sources/Localization.swift CheckLocalization.swift \
  -o "$fixture/Contents/MacOS/LocalizationCheck"
"$fixture/Contents/MacOS/LocalizationCheck"
