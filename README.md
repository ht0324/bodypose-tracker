# BodyPoseTracker

Native macOS menu-bar app for detecting hand movement near your head using
Apple Vision face rectangles and hand landmarks. It runs locally from
AVFoundation sample buffers and keeps one shared detection path for production
and debug preview.

## Build And Run

```bash
swift test
scripts/build-menubar-app.sh
open dist/BodyPoseTracker.app
```

The app appears as a hand icon in the menu bar. It starts production detection
automatically, and the menu can stop, restart, open the debug preview, or quit.
Use `Launch at Login` in the menu to register or unregister the app with
macOS login items. Use `Auto Enable on External Power` to let the app restart
production detection automatically when the Mac is plugged into power, even if
detection was previously disabled.

## Source Layout

The menu-bar target keeps the bootstrap in `main.swift`, app lifecycle in
`AppDelegate.swift`, camera and Vision work in `VisionCaptureController.swift`,
preview drawing in `DebugPreview.swift`, and small support types in
`DetectionConfig.swift`, `AppOptions.swift`, `FileLog.swift`, and
`ResourceLocations.swift`.

## Production Detection

Production requests a lower `320x240` camera capture preset, runs face detection
at `2 FPS`, idles hand detection at `4 FPS`, boosts hand detection to `8 FPS`
while a hand or near-warning is recent, tracks at most one hand, and requires
the hand to remain near the head for `0.2s` before the warning becomes active.
The app requests `10 FPS` at both the camera device and video connection layers;
macOS may still clamp the physical camera format to the nearest supported rate.

Production automatically pauses camera capture while Zoom (`us.zoom.xos`) or
FaceTime (`com.apple.FaceTime`) is running, then resumes after those apps quit.
This is event-driven through `NSWorkspace` app launch/termination notifications.
While paused, it also uses a low-frequency reconciliation check so short-lived
video-call app processes do not leave capture paused.

Production also pauses camera capture while the Mac sleeps, the display sleeps,
the session is locked/inactive, or the screen saver is running. If production
was enabled before the pause, it resumes after wake, unlock, or screen saver
exit.

Hand pose runs full-frame because Apple Vision hand pose is less stable when
cropped to a moving ROI. The detector only alerts when high-confidence hand
landmarks enter the blue/red head warning zone.

Warnings play the bundled `iMovie-Alarm.mp3` by default. You can override it
with `--alert-sound /path/to/sound.mp3`, or use `--no-alert-sound` to fall back
to the system beep. The bundled sound stops as soon as the warning clears. While
the warning is active, the menu-bar icon flashes red at the bundled alarm's
approximate beep cadence.

## Native Debug Preview

Choose `Show Debug Preview` from the menu bar app. The preview is an AppKit
window fed by the same `VisionCaptureController` used in production.

Visual legend:

- Green rectangle: detected face.
- Blue/red Reuleaux triangle: active head warning zone.
- Cyan points/lines: hand landmarks from Apple Vision.
- Bottom label: current detection config, measured processing FPS, camera/connection
  FPS, frame size, target face/hand FPS, hand counts, streak, score, and delay.

## Logs

```bash
tail -f ~/Library/Logs/BodyPoseTracker/BodyPoseTracker.log
```

Log lines include delivered frame size, face/hand counts, usable landmark count,
adaptive hand FPS, streak, active state, and score.

## Short Test Run

```bash
open dist/BodyPoseTracker.app --args --duration 10
```

Stop the app:

```bash
pkill -f BodyPoseTrackerMenubar
```

## Camera Permission

If macOS asks, allow `BodyPoseTracker.app` to access the camera. The app runs all
frame processing locally. The menu-bar camera privacy indicator is controlled by
macOS and cannot be hidden by the app.
