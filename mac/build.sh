#!/usr/bin/env bash
# Builds "Decks Visuals.app" (Apple Silicon) into build/ and zips it. Runs on macOS (GitHub Actions or a Mac with Xcode tools).
set -euo pipefail
cd "$(dirname "$0")/.."
APP="build/Decks Visuals.app"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/site"
swiftc -O -swift-version 5 -target arm64-apple-macos13.0 mac/main.swift -o "$APP/Contents/MacOS/DecksVisuals"
cp mac/Info.plist "$APP/Contents/Info.plist"
cp index.html relay.html "$APP/Contents/Resources/site/"   # offline copy of the visuals
codesign --force --deep --sign - "$APP"                    # ad-hoc signature (required to run on Apple Silicon)
codesign --verify --verbose "$APP"
(cd build && ditto -c -k --keepParent "Decks Visuals.app" DecksVisuals-mac.zip)
ls -la build
