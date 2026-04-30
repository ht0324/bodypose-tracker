#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "$SCRIPT_DIR/.."

ALERT_SOUND_SOURCE="Resources/iMovie-Alarm.mp3"
ALERT_SOUND_DEST="dist/BodyPoseTracker.app/Contents/Resources/iMovie-Alarm.mp3"
APP_ICON_SOURCE="Resources/AppIcon.icns"
APP_ICON_DEST="dist/BodyPoseTracker.app/Contents/Resources/AppIcon.icns"
INFO_PLIST_SOURCE="Packaging/BodyPoseTracker-Info.plist"
INFO_PLIST_DEST="dist/BodyPoseTracker.app/Contents/Info.plist"

if [[ ! -f "$ALERT_SOUND_SOURCE" ]]; then
  echo "Missing alert sound: $ALERT_SOUND_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$INFO_PLIST_SOURCE" ]]; then
  echo "Missing Info.plist template: $INFO_PLIST_SOURCE" >&2
  exit 1
fi

if [[ ! -f "$APP_ICON_SOURCE" ]]; then
  echo "Missing app icon: $APP_ICON_SOURCE" >&2
  exit 1
fi

swift build -c release --product BodyPoseTrackerMenubar
mkdir -p dist/BodyPoseTracker.app/Contents/MacOS dist/BodyPoseTracker.app/Contents/Resources
cp .build/release/BodyPoseTrackerMenubar dist/BodyPoseTracker.app/Contents/MacOS/BodyPoseTrackerMenubar
cp "$INFO_PLIST_SOURCE" "$INFO_PLIST_DEST"
cp "$ALERT_SOUND_SOURCE" "$ALERT_SOUND_DEST"
cp "$APP_ICON_SOURCE" "$APP_ICON_DEST"
rm -rf dist/BodyPoseTracker.app/Contents/_CodeSignature
xattr -cr dist/BodyPoseTracker.app
xattr -rd com.apple.FinderInfo dist/BodyPoseTracker.app 2>/dev/null || true
xattr -rd 'com.apple.fileprovider.fpfs#P' dist/BodyPoseTracker.app 2>/dev/null || true
codesign --force --deep --sign - dist/BodyPoseTracker.app
