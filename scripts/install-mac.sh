#!/bin/bash
# Builds the Mac app + camera extension (Release), installs it into
# /Applications and launches it. Camera extensions can only be activated from
# apps inside /Applications.
#
# The app and its camera extension MUST be signed by the same team. The team
# is taken from, in order:
#   1. the DEVELOPMENT_TEAM environment variable
#      (DEVELOPMENT_TEAM=ABCDE12345 ./scripts/install-mac.sh)
#   2. DEVELOPMENT_TEAM in Config/Signing.xcconfig
#   3. the first "Apple Development" certificate in your keychain
# and passed to xcodebuild for *all* targets, so a team picked in Xcode for
# only one target can't cause a signing mismatch.
set -euo pipefail
cd "$(dirname "$0")/.."

team_from_xcconfig() {
  sed -n 's/^[[:space:]]*DEVELOPMENT_TEAM[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*/\1/p' \
    Config/Signing.xcconfig | head -1
}

team_from_keychain() {
  security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | openssl x509 -noout -subject 2>/dev/null \
    | sed -n 's/.*OU[[:space:]]*=[[:space:]]*\([A-Z0-9]\{10\}\).*/\1/p' \
    | head -1
}

TEAM="${DEVELOPMENT_TEAM:-}"
[ -n "$TEAM" ] || TEAM="$(team_from_xcconfig)"
[ -n "$TEAM" ] || TEAM="$(team_from_keychain)"

if [ -z "$TEAM" ]; then
  echo "error: No Apple Developer team found." >&2
  echo "Set DEVELOPMENT_TEAM in Config/Signing.xcconfig (Xcode › Settings › Accounts shows your Team ID)," >&2
  echo "or run: DEVELOPMENT_TEAM=ABCDE12345 $0" >&2
  exit 1
fi
echo "==> Signing with team $TEAM"

LOG="build/install-mac.log"
mkdir -p build
echo "==> Building (full log: $LOG)"
if ! xcodebuild \
  -project iCam.xcodeproj \
  -scheme "iCam (macOS)" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath build \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  build >"$LOG" 2>&1; then
  echo "error: build failed. Errors:" >&2
  grep -E "error:|warning: .*(sign|provision)" "$LOG" | sort -u >&2 || tail -40 "$LOG" >&2
  exit 1
fi

APP="build/Build/Products/Release/iCam.app"
EXT="$APP/Contents/Library/SystemExtensions"

# Sanity check: both bundles must carry the same team identifier.
APP_TEAM="$(codesign -dv "$APP" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
for ext in "$EXT"/*.systemextension; do
  EXT_TEAM="$(codesign -dv "$ext" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [ "$APP_TEAM" != "$EXT_TEAM" ] || [ "$APP_TEAM" = "not set" ]; then
    echo "error: signing mismatch (app: $APP_TEAM, extension: $EXT_TEAM)" >&2
    exit 1
  fi
done
echo "==> Signed: app and camera extension both use team $APP_TEAM"

if pgrep -xq iCam; then
  osascript -e 'quit app "iCam"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x iCam 2>/dev/null || true
fi
rm -rf /Applications/iCam.app
cp -R "$APP" /Applications/
open /Applications/iCam.app
echo "==> Installed /Applications/iCam.app"
echo "    First run: approve the camera extension in System Settings when asked."
