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

## Production Detection

Production requests a lower camera capture cadence, runs face detection at
`2 FPS`, runs hand detection at `8 FPS`, tracks at most one hand, and requires
the hand to remain near the head for `0.3s` before the warning becomes active.
The camera may clamp the requested `10 FPS` capture cadence to the nearest
supported format.

Hand pose runs full-frame because Apple Vision hand pose is less stable when
cropped to a moving ROI. The detector only alerts when high-confidence hand
landmarks enter the blue/red head warning zone.

Warnings play the bundled `iMovie-Alarm.mp3` by default. You can override it
with `--alert-sound /path/to/sound.mp3`, or use `--no-alert-sound` to fall back
to the system beep. The bundled sound stops as soon as the warning clears.

## Native Debug Preview

Choose `Show Debug Preview` from the menu bar app. The preview is an AppKit
window fed by the same `VisionCaptureController` used in production.

Visual legend:

- Green rectangle: detected face.
- Blue/red ellipse: active head warning zone.
- Cyan points/lines: hand landmarks from Apple Vision.
- Bottom label: current profile, measured processing FPS, camera FPS, target
  face/hand FPS, hand counts, streak, score, and delay.

## Logs

```bash
tail -f ~/Library/Logs/BodyPoseTracker/BodyPoseTracker.log
```

Log lines include face/hand counts, usable landmark count, streak, active
state, and score.

## Short Test Run

```bash
open dist/BodyPoseTracker.app --args --duration 10 --profile production
```

Stop the app:

```bash
pkill -f BodyPoseTrackerMenubar
```

## Camera Permission

If macOS asks, allow `BodyPoseTracker.app` to access the camera. The app runs all
frame processing locally. The menu-bar camera privacy indicator is controlled by
macOS and cannot be hidden by the app.
