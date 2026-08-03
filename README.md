<p align="center">
  <img src="Resources/AppIcon.png" width="128" alt="BodyPoseTracker app icon">
</p>

# BodyPoseTracker

BodyPoseTracker is a small native macOS menu-bar app that watches for a hand
near your head and gives a short warning if it stays there. It is designed to
interrupt habits such as hair touching or hair picking while working at a desk.

The app uses Apple's Vision framework for face and hand-pose detection. All
processing happens on-device, and no camera frames or detection results are
uploaded.

## What it does

- Runs from a hand icon in the macOS menu bar.
- Detects a face and one nearby hand with Apple Vision.
- Waits through quick movements and warns only when the hand lingers near the
  head.
- Plays a bundled alarm sound and flashes a red menu-bar bubble during a
  warning.
- Pauses while Zoom or FaceTime is running. It also pauses when the Mac sleeps,
  the display sleeps, the screen locks, or the screen saver starts.
- Provides a 30-minute eating pause from the menu.
- Can launch at login and start detection when the Mac connects to external
  power or AirPods Pro become the active audio output.
- Includes a debug preview with the camera feed, face box, hand landmarks, and
  warning zone.

The menu also shows the current status, a daily streak counter, and a rotating
encouragement message.

## Build and run

Requirements:

- macOS 14 or newer
- Swift 5.9 and the Xcode command-line tools
- Camera permission

Build the packaged app and open it:

```bash
scripts/build-menubar-app.sh
open dist/BodyPoseTracker.app
```

The script creates `dist/BodyPoseTracker.app` and applies an ad hoc code
signature; it does not install the app. On first launch, open the hand menu,
choose `Enable`, and allow camera access when macOS asks.

## Using the menu

Use `Enable` or `Disable` to control detection manually. `I am eating!` pauses
capture for 30 minutes, then resumes it if detection was previously enabled.

`Auto Enable on External Power` starts detection when the Mac is plugged in.
`Auto Enable on AirPods Pro` starts it when AirPods Pro are selected as the
active audio output. These options start detection but do not turn it off when
the power or audio state changes.

If Zoom or FaceTime is running, the menu reports that capture is paused. You can
choose `Resume Anyway` to override that automatic pause.

## Debug preview

Choose `Show Debug Preview` to see what the detector sees. The preview draws a
green face box, a blue or red head zone, and cyan hand landmarks over the live
camera feed. A line at the bottom reports the frame rate, frame size, hand count,
streak, score, and activation delay.

The preview and the background menu-bar app use the same capture controller and
detection path.

## How detection works

AVFoundation supplies `320x240` camera frames at up to `10 FPS`. Face detection
runs at `2 FPS`. Hand detection runs at `4 FPS` while idle and increases to
`8 FPS` when a hand was recently visible or an alert may be starting.

The detector estimates a rounded triangular zone around the head, then checks
the wrist and five fingertips against that zone. With the current settings, a
point must remain inside for `0.2` seconds before the warning starts. A hand-size
check rejects observations that are implausibly large relative to the detected
face.

## Privacy and limitations

Camera processing stays on the Mac. The app does not send camera frames or
detection results to a server. macOS controls its own camera privacy indicator,
so that indicator may appear separately from the BodyPoseTracker menu-bar icon.

This is a personal assistive prototype, not a medical device. Detection quality
depends on camera angle, lighting, hand visibility, and the limits of Apple
Vision hand-pose tracking.

The daily streak shown in the menu is a simple day counter from a stored start
date. It is not calculated from detection events, and its default start date is
currently hard-coded.

## Development

Run the build and test suite:

```bash
swift build
swift test
```

For a short packaged-app smoke test:

```bash
open dist/BodyPoseTracker.app --args --duration 10
```

Runtime logs are written to `~/Library/Logs/BodyPoseTracker/BodyPoseTracker.log`.
Follow them with:

```bash
tail -f ~/Library/Logs/BodyPoseTracker/BodyPoseTracker.log
```

Logs include the delivered frame size, face and hand counts, adaptive hand FPS,
warning state, and detection score.

## Project layout

- `Sources/BodyPoseTrackerCore/DetectionCore.swift`: detection state, geometry,
  and public model types without camera or UI code.
- `Sources/BodyPoseTrackerMenubar/`: camera capture, Vision requests, menu-bar UI,
  alerts, automatic pause logic, and the debug preview.
- `Tests/BodyPoseTrackerCoreTests/`: deterministic detector tests.
- `Resources/`: the app icon and bundled alert sound.
- `Packaging/`: the app plist template.
- `scripts/build-menubar-app.sh`: builds `dist/BodyPoseTracker.app` and applies
  an ad hoc code signature.
