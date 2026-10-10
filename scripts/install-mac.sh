#!/bin/bash
# Builds the Mac app (Release, signed with your team from Config/Signing.xcconfig),
# installs it into /Applications and launches it. Camera extensions can only be
# activated from apps inside /Applications.
set -euo pipefail
cd "$(dirname "$0")/.."

xcodebuild \
  -project iCam.xcodeproj \
  -scheme "iCam (macOS)" \
  -configuration Release \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  build

APP="build/Build/Products/Release/iCam.app"
if pgrep -xq iCam; then
  osascript -e 'quit app "iCam"' || true
  sleep 1
fi
rm -rf /Applications/iCam.app
cp -R "$APP" /Applications/
open /Applications/iCam.app
echo "Installed /Applications/iCam.app"
