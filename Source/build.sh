#!/bin/bash
# Compila OkiPaste como binario universal (Intel + Apple Silicon), firma la app y la reinicia.
set -e
cd "$(dirname "$0")"
APP=~/OkiPaste/OkiPaste.app
MIN_OS=12.0

swiftc -O -target x86_64-apple-macosx$MIN_OS main.swift -o /tmp/okipaste_x86_64
swiftc -O -target arm64-apple-macosx$MIN_OS main.swift -o /tmp/okipaste_arm64
lipo -create /tmp/okipaste_x86_64 /tmp/okipaste_arm64 -output "$APP/Contents/MacOS/OkiPaste"
rm -f /tmp/okipaste_x86_64 /tmp/okipaste_arm64

codesign --force --deep -s - --identifier com.alejandro.okipaste "$APP"
launchctl kickstart -k gui/$(id -u)/com.alejandro.okipaste 2>/dev/null \
  || launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.alejandro.okipaste.plist
echo "Compilado (universal) y reiniciado"
