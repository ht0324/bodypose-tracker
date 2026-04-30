# BodyPoseTracker

Native macOS menu-bar app for detecting hand movement near your head using
Apple Vision face rectangles and hand landmarks. The production app uses
AVFoundation sample buffers directly; the Python/OpenCV script remains as a
visual debug prototype.

## Swift Menubar App

```bash
scripts/build-menubar-app.sh
open dist/BodyPoseTracker.app
```

The app appears as a `Pose` item in the menu bar. It starts production detection
automatically, and can stop, open the debug preview, or quit from the menu.

Production mode runs face detection at `4 FPS`, hand detection at `8 FPS`,
tracks at most one hand, and restricts hand pose to a square region centered on
the detected head. The square side is `5x` the detected head size, so the search
area is about `25x` the head area before it is clamped to the camera frame.

Warnings play the bundled `iMovie-Alarm.mp3` by default. You can override it
with `--alert-sound /path/to/sound.mp3`, or use `--no-alert-sound` to fall back
to the system beep. The bundled sound stops as soon as the warning clears.

Short test run:

```bash
open dist/BodyPoseTracker.app --args --duration 10 --profile production
```

Logs:

```bash
tail -f ~/Library/Logs/BodyPoseTracker/BodyPoseTracker.log
```

Stop the native menubar app:

```bash
pkill -f BodyPoseTrackerMenubar
```

## Python Debug Preview

The Python script is still useful for visual diagnosis because it draws the
face/head zone and hand landmarks.

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements.txt
.venv/bin/python track_pose.py --profile debug --beep
```

Other Python profiles:

```bash
.venv/bin/python track_pose.py --profile production --beep
```

Stop the Python tracker:

```bash
pkill -f 'bodypose-tracker/[t]rack_pose.py'
```

## Camera Permission

If macOS asks, allow `BodyPoseTracker.app` to access the camera. The app runs all
frame processing locally.

## Build And Test

```bash
swift test
scripts/build-menubar-app.sh
```

## Python Tuning

- `--head-scale 1.15` makes the warning zone smaller.
- `--head-scale 1.6` makes it more sensitive.
- `--trigger-seconds 0.3` requires the hand to stay close for 0.3 seconds
  before warning, and resets immediately when the hand leaves.
- `--trigger-frames 8` is kept for debug streak display compatibility.
- `--process-every 2` improves speed by running Vision every other frame.
- `--face-hold-seconds 1.5` keeps using the last face box longer when a hand
  briefly covers your face.
- `--target-fps 6` caps the processing loop for background use.
- `--camera-fps 6` asks the camera backend for a lower capture rate.
- `--presence-gate` skips hand-pose inference until a recent face exists.
- `--no-preview` keeps detection/beeps running without drawing a camera window.
- `--alert-sound /path/to/sound.mp3` plays a custom warning sound.
- `--profile debug` uses the visual preview plus body-pose overlay for
  diagnosis. The green box is the face rectangle, the blue ellipse is the
  warning zone, and the orange square is the production hand-search ROI.
- `--profile production` is the recommended always-on mode: no preview,
  one-hand detection, `0.3s` trigger, and presence-gated hand inference.
- `--debug-body` also runs/draws body pose landmarks for diagnosis.

## Modes Summary

| Profile | Purpose | Preview | Body Pose | Face / Hand FPS |
| --- | --- | --- | --- | --- |
| Swift Production | menu-bar always-on mode | no | no | 4 / 8 |
| Python Debug | visual diagnosis | yes | optional | configurable |
