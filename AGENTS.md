# Repository Guidelines

## Project Structure & Module Organization
BodyPoseTracker is a SwiftPM macOS 14 menu-bar app. `Package.swift` defines the `BodyPoseTrackerCore` library target and the `BodyPoseTrackerMenubar` executable target. Core detector state, geometry, and public model types live in `Sources/BodyPoseTrackerCore/DetectionCore.swift`. AppKit, AVFoundation, menu-bar, logging, launch-at-login, and debug preview code live in `Sources/BodyPoseTrackerMenubar/`. XCTest coverage is under `Tests/BodyPoseTrackerCoreTests/`. Bundle inputs are kept in `Resources/`, the app plist template is in `Packaging/`, and `scripts/build-menubar-app.sh` assembles `dist/BodyPoseTracker.app`.

## Build, Test, and Development Commands
- `swift test`: runs the XCTest suite for the core detector.
- `swift build`: compiles all SwiftPM targets for a quick sanity check.
- `swift run BodyPoseTrackerMenubar --duration 10`: runs the menu-bar executable briefly from the repo checkout.
- `scripts/build-menubar-app.sh`: creates and ad-hoc signs `dist/BodyPoseTracker.app`, copying the plist, icon, and alert sound.
- `open dist/BodyPoseTracker.app --args --duration 10`: smoke-tests the packaged app.
- `tail -f ~/Library/Logs/BodyPoseTracker/BodyPoseTracker.log`: follows runtime detector logs.

## Coding Style & Naming Conventions
Use Swift 5.9 conventions with four-space indentation and no tabs. Prefer `UpperCamelCase` for types, `lowerCamelCase` for methods and properties, and focused `private` helpers near the code that uses them. Keep pure detection behavior in `BodyPoseTrackerCore`; keep camera, Vision, AppKit, and filesystem side effects in `BodyPoseTrackerMenubar`. No formatter is configured, so match the surrounding Swift style before introducing new patterns.

## Testing Guidelines
Tests use XCTest and should be named `test...` with behavior-focused descriptions, as in `testFaceHoldExpires`. Favor deterministic detector tests with explicit timestamps, face boxes, and landmarks. Add or update core tests for any change to zone scoring, activation delay, face-hold behavior, or alert state. Run `swift test` before opening a PR; for camera, menu-bar, preview, or packaging changes, also run the packaged app briefly and inspect the log.

## Commit & Pull Request Guidelines
Recent commits use short imperative subjects such as `Pause capture during video calls` and `Refactor menubar app structure`. Keep commits focused and describe the user-visible behavior or internal boundary changed. PRs should include a concise summary, verification commands run, relevant log notes, linked issues if any, and screenshots or screen recordings for debug preview or menu UI changes.

## Runtime & Generated Files
Do not commit `.build/`, `.swiftpm/`, `dist/`, logs, `.DS_Store`, or Python cache files. Keep new bundled assets in `Resources/` and update `scripts/build-menubar-app.sh` when the final `.app` needs to copy them.
