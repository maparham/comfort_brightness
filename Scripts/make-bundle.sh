#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP="AutoBrightness.app"

swift build -c release --product AutoBrightnessApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AutoBrightnessApp "$APP/Contents/MacOS/AutoBrightness"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. macOS ties Screen Recording permission to the code signature,
# so a rebuild can re-trigger the permission prompt. If that becomes tiresome,
# sign with a free personal development certificate for a stable identity.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Install with: cp -R $APP /Applications/"
