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

# Keep build products out of the repository: it may live in a synced folder
# (iCloud/Google Drive), which slows builds and can break code signing.
DERIVED="$HOME/Library/Developer/Xcode/DerivedData/iCam-install"
LOG="$DERIVED/install-mac.log"
mkdir -p "$DERIVED"

# The app gets a fresh build number on every install. The camera extension
# keeps its version until something it is built from changes: macOS replaces
# an active system extension whenever its version changes, and that is
# disruptive (apps using the camera keep the old copy, and the new camera may
# stay hidden until they quit).
extension_fingerprint() {
  {
    echo "$TEAM"
    find macOS/CameraExtension macOS/Shared Config iCam.xcodeproj/project.pbxproj \
      -type f ! -name '.*' -print0 | sort -z | xargs -0 shasum -a 256
  } | shasum -a 256 | cut -c1-16
}
APP_BUILD="$(date +%s)"
FINGERPRINT="$(extension_fingerprint)"
STATE="$DERIVED/extension-version"
EXT_BUILD=""
if [ -f "$STATE" ]; then
  read -r SAVED_FINGERPRINT SAVED_BUILD < "$STATE" || true
  if [ "${SAVED_FINGERPRINT:-}" = "$FINGERPRINT" ]; then
    EXT_BUILD="${SAVED_BUILD:-}"
  fi
fi
[ -n "$EXT_BUILD" ] || EXT_BUILD="$APP_BUILD"

EXTENSION_ID="$(sed -n 's/^[[:space:]]*BUNDLE_ID_PREFIX[[:space:]]*=[[:space:]]*\([^[:space:]]*\).*/\1/p' \
  Config/Signing.xcconfig | head -1).mac.CameraExtension"
ACTIVE_LINE="$(systemextensionsctl list 2>/dev/null | grep -F "$EXTENSION_ID" | grep -F "activated enabled" | head -1 || true)"
if [ -n "$ACTIVE_LINE" ] && ! printf '%s' "$ACTIVE_LINE" | grep -qF "/$EXT_BUILD)"; then
  echo "==> The camera extension changed and will be updated (extension build $EXT_BUILD)."
  VIDEO_APPS=""
  for app in OBS zoom.us FaceTime "Photo Booth" "QuickTime Player" MSTeams "Microsoft Teams" Webex \
             Discord Skype "Ecamm Live" Loom; do
    if pgrep -xq "$app"; then VIDEO_APPS="$VIDEO_APPS${VIDEO_APPS:+, }$app"; fi
  done
  if [ -n "$VIDEO_APPS" ]; then
    echo "    These apps may be using the camera: $VIDEO_APPS"
    echo "    Quit them first, otherwise macOS keeps the old camera running and the"
    echo "    new one may stay hidden until they quit (or until you restart the Mac)."
    if [ -t 0 ]; then
      read -r -p "    Press Enter once they are closed (or Ctrl-C to cancel)... " _
    fi
  fi
fi
echo "==> Building app build $APP_BUILD, extension build $EXT_BUILD (full log: $LOG)"
if ! xcodebuild \
  -project iCam.xcodeproj \
  -scheme "iCam (macOS)" \
  -configuration Release \
  -destination "generic/platform=macOS" \
  -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Automatic \
  CURRENT_PROJECT_VERSION="$APP_BUILD" \
  ICAM_EXTENSION_VERSION="$EXT_BUILD" \
  build >"$LOG" 2>&1; then
  echo "error: build failed. Errors:" >&2
  grep -E "error:|warning: .*(sign|provision)" "$LOG" | sort -u >&2 || tail -40 "$LOG" >&2
  exit 1
fi

APP="$DERIVED/Build/Products/Release/iCam.app"
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
echo "$FINGERPRINT $EXT_BUILD" > "$STATE"

if pgrep -xq iCam; then
  osascript -e 'quit app "iCam"' >/dev/null 2>&1 || true
  sleep 1
  pkill -x iCam 2>/dev/null || true
fi
rm -rf /Applications/iCam.app
cp -R "$APP" /Applications/
open /Applications/iCam.app
echo "==> Installed /Applications/iCam.app (build $APP_BUILD, camera extension build $EXT_BUILD)"
echo "    First run: approve the camera extension in System Settings when asked."
echo "    Video apps that were already open must be restarted to pick up a new extension."
sleep 5
EXT_LINES="$(systemextensionsctl list 2>/dev/null | grep -F "$EXTENSION_ID" || true)"
[ -n "$EXT_LINES" ] && echo "$EXT_LINES"
if printf '%s' "$EXT_LINES" | grep -q "terminated"; then
  echo "    An older copy of the camera extension is still loaded. Quit every app that"
  echo "    uses the camera (OBS, Zoom, FaceTime, browsers in a call...), then reopen iCam."
  echo "    If iCam still can't find its camera, restart the Mac."
fi
