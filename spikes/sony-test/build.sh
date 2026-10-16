#!/usr/bin/env bash
# Builds the throwaway Sony test app with the Command Line Tools (no Xcode needed).
set -euo pipefail
cd "$(dirname "$0")"
APP=build/SonyTest.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp Info.plist "$APP/Contents/Info.plist"
swiftc -swift-version 5 -O -target arm64-apple-macos14.0 main.swift -o "$APP/Contents/MacOS/SonyTest"
codesign --force --sign - "$APP"
echo "Built $APP"
