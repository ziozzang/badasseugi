#!/bin/zsh
# Builds build/Badasseugi.app with plain swiftc (no Xcode project needed). macOS 26+, Apple Silicon.
#   ./build.sh [release|debug]
set -euo pipefail
cd "$(dirname "$0")"
APP="build/Badasseugi.app"
OPT=(-O); [[ "${1:-release}" == "debug" ]] && OPT=(-Onone -g)
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc "${OPT[@]}" -swift-version 5 -target arm64-apple-macosx26.0 -parse-as-library \
  -o "$APP/Contents/MacOS/Badasseugi" Sources/App/*.swift Sources/Shared/*.swift
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp -R Models/silero-vad-unified-256ms-v6.2.1.mlmodelc "$APP/Contents/Resources/"
codesign --force --sign -  "$APP"
echo "Built $APP (v$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist))"
