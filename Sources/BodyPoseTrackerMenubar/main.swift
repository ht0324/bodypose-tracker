import AppKit
import AVFoundation
import BodyPoseTrackerCore
import CoreMedia
import Foundation
import Vision

private let bundledAlertSoundName = "iMovie-Alarm"
private let bundledAlertSoundExtension = "mp3"

private func projectRootURL() -> URL? {
    let currentDirectory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let homeProject = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Documents")
        .appendingPathComponent("Projects")
        .appendingPathComponent("bodypose-tracker")

    return [currentDirectory, homeProject].first { candidate in
        FileManager.default.fileExists(atPath: candidate.appendingPathComponent("track_pose.py").path)
    }
}

private var projectAlertSoundURL: URL {
    (projectRootURL() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
        .appendingPathComponent("Resources")
        .appendingPathComponent("\(bundledAlertSoundName).\(bundledAlertSoundExtension)")
}

private func defaultLogURL() -> URL {
    FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library")
        .appendingPathComponent("Logs")
        .appendingPathComponent("BodyPoseTracker")
        .appendingPathComponent("BodyPoseTracker.log")
}

private func defaultAlertSoundURL() -> URL? {
    if let bundledURL = Bundle.main.url(forResource: bundledAlertSoundName, withExtension: bundledAlertSoundExtension) {
        return bundledURL
    }

    let projectURL = projectAlertSoundURL
    if FileManager.default.fileExists(atPath: projectURL.path) {
        return projectURL
    }

    return nil
}

struct NativeProfile {
    let name: String
    let cameraWidth: Int
    let cameraHeight: Int
    let faceFPS: Double
    let handFPS: Double
    let maxDimension: Int
    let maxHands: Int
    let triggerFrames: Int
    let triggerSeconds: TimeInterval
    let headScale: Double
    let faceHoldSeconds: TimeInterval
    let presenceGate: Bool

    var processingFPS: Double {
        max(faceFPS, handFPS)
    }

    static let production = NativeProfile(
        name: "Production",
        cameraWidth: 640,
        cameraHeight: 360,
        faceFPS: 4,
        handFPS: 8,
        maxDimension: 480,
        maxHands: 1,
        triggerFrames: 5,
        triggerSeconds: 0.3,
        headScale: 1.4,
        faceHoldSeconds: 1.0,
        presenceGate: true
    )

    static let background = NativeProfile(
        name: "Background",
        cameraWidth: 640,
        cameraHeight: 360,
        faceFPS: 3,
        handFPS: 6,
        maxDimension: 384,
        maxHands: 1,
        triggerFrames: 4,
        triggerSeconds: 0.3,
        headScale: 1.4,
        faceHoldSeconds: 1.0,
        presenceGate: true
    )

    static let eco = NativeProfile(
        name: "Eco",
        cameraWidth: 480,
        cameraHeight: 270,
        faceFPS: 2,
        handFPS: 3,
        maxDimension: 320,
        maxHands: 1,
        triggerFrames: 3,
        triggerSeconds: 0.3,
        headScale: 1.4,
        faceHoldSeconds: 1.0,
        presenceGate: true
    )

    static let all = [production, background, eco]
}

final class FileLog {
    private let queue = DispatchQueue(label: "BodyPoseTracker.log")
    private let url: URL

    init(url: URL) {
        self.url = url
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    func write(_ message: String) {
        let line = "\(Date()) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: self.url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        }
        print(message)
    }
}

struct AppOptions {
    let duration: TimeInterval?
    let profile: NativeProfile
    let autostart: Bool
    let alertSoundURL: URL?

    static func parse(arguments: [String]) -> AppOptions {
        var duration: TimeInterval?
        var profile = NativeProfile.production
        var autostart = true
        var alertSoundURL = defaultAlertSoundURL()
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration" where index + 1 < arguments.count:
                duration = TimeInterval(arguments[index + 1])
                index += 2
            case "--profile" where index + 1 < arguments.count:
                let raw = arguments[index + 1].lowercased()
                profile = NativeProfile.all.first { $0.name.lowercased() == raw } ?? profile
                index += 2
            case "--no-autostart":
                autostart = false
                index += 1
            case "--alert-sound" where index + 1 < arguments.count:
                alertSoundURL = URL(fileURLWithPath: (arguments[index + 1] as NSString).expandingTildeInPath)
                index += 2
            case "--no-alert-sound":
                alertSoundURL = nil
                index += 1
            default:
                index += 1
            }
        }

        return AppOptions(
            duration: duration,
            profile: profile,
            autostart: autostart,
            alertSoundURL: alertSoundURL
        )
    }
}

final class VisionCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "BodyPoseTracker.capture", qos: .userInitiated)
    private let sequenceHandler = VNSequenceRequestHandler()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let log: FileLog
    private let onStatus: (String, HairAlertState) -> Void
    private let alertSoundURL: URL?

    private var profile = NativeProfile.production
    private var detector = HairPickingDetector(
        triggerFrames: NativeProfile.production.triggerFrames,
        triggerSeconds: NativeProfile.production.triggerSeconds,
        headScale: NativeProfile.production.headScale,
        faceHoldSeconds: NativeProfile.production.faceHoldSeconds
    )
    private var lastProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastFaceProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastHandProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastFaceObservationAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastLogAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastBeepAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var handRegionOfInterest = VNNormalizedIdentityRect
    private var alertWasActive = false
    private var configured = false
    private var alertPlayer: AVAudioPlayer?

    private(set) var isRunning = false

    init(log: FileLog, alertSoundURL: URL?, onStatus: @escaping (String, HairAlertState) -> Void) {
        self.log = log
        self.alertSoundURL = alertSoundURL
        self.onStatus = onStatus
        super.init()
        configureAlertSound()
    }

    func start(profile: NativeProfile) {
        captureQueue.async {
            self.profile = profile
            self.detector = HairPickingDetector(
                triggerFrames: profile.triggerFrames,
                triggerSeconds: profile.triggerSeconds,
                headScale: profile.headScale,
                faceHoldSeconds: profile.faceHoldSeconds
            )
            self.lastProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastFaceProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastHandProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastFaceObservationAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastBeepAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.handRegionOfInterest = VNNormalizedIdentityRect
            self.alertWasActive = false
            self.handRequest.maximumHandCount = profile.maxHands

            do {
                if !self.configured {
                    try self.configureSession()
                    self.configured = true
                }
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                self.isRunning = true
                self.log.write(
                    "started profile=\(profile.name) faceFPS=\(profile.faceFPS) handFPS=\(profile.handFPS) " +
                        "maxHands=\(profile.maxHands) triggerSeconds=\(profile.triggerSeconds)"
                )
                DispatchQueue.main.async {
                    self.onStatus("Running \(profile.name)", .empty)
                }
            } catch {
                self.log.write("start failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onStatus("Start failed", .empty)
                }
            }
        }
    }

    func stop() {
        captureQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.isRunning = false
            self.alertWasActive = false
            self.stopAlertSound()
            self.log.write("stopped")
            DispatchQueue.main.async {
                self.onStatus("Stopped", .empty)
            }
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        session.sessionPreset = .vga640x480

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "BodyPoseTracker", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video camera found"])
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw NSError(domain: "BodyPoseTracker", code: 2, userInfo: [NSLocalizedDescriptionKey: "Cannot add camera input"])
        }
        session.addInput(input)

        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: captureQueue)
        guard session.canAddOutput(output) else {
            throw NSError(domain: "BodyPoseTracker", code: 3, userInfo: [NSLocalizedDescriptionKey: "Cannot add video output"])
        }
        session.addOutput(output)

        session.commitConfiguration()
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastProcessAt < 1.0 / profile.processingFPS {
            return
        }
        lastProcessAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let runFace = now - lastFaceProcessAt >= 1.0 / profile.faceFPS
        let runHands = (!profile.presenceGate || detector.hasRecentFace(now: now)) &&
            now - lastHandProcessAt >= 1.0 / profile.handFPS
        guard runFace || runHands else { return }

        var requests: [VNRequest] = []
        if runFace {
            requests.append(faceRequest)
            lastFaceProcessAt = now
        }
        if runHands {
            handRequest.regionOfInterest = recentHandRegionOfInterest(now: now)
            requests.append(handRequest)
            lastHandProcessAt = now
        }

        do {
            try sequenceHandler.perform(requests, on: sampleBuffer, orientation: .up)
            let face = runFace ? updateFaceState(width: width, height: height, now: now) : nil
            let hands = runHands ? recognizedHands(width: width, height: height, regionOfInterest: handRequest.regionOfInterest) : []
            let state = detector.update(face: face, hands: hands, now: now)
            updateAlertSound(state: state, now: now)
            maybeLog(state: state, hands: hands, now: now)
            DispatchQueue.main.async {
                let label = state.active ? "Hand Near Head" : "Running \(self.profile.name)"
                self.onStatus(label, state)
            }
        } catch {
            if now - lastLogAt > 2.0 {
                lastLogAt = now
                log.write("vision error: \(error.localizedDescription)")
            }
        }
    }

    private func updateFaceState(width: Int, height: Int, now: TimeInterval) -> FaceBox? {
        guard let best = bestFace(width: width, height: height) else { return nil }
        handRegionOfInterest = Self.handSearchRegion(around: best.normalizedBox)
        lastFaceObservationAt = now
        return best.face
    }

    private func bestFace(width: Int, height: Int) -> (face: FaceBox, normalizedBox: CGRect)? {
        let observations = faceRequest.results ?? []
        return observations
            .map { observation -> (face: FaceBox, normalizedBox: CGRect) in
                let box = observation.boundingBox
                return (
                    FaceBox(
                        x: Double(box.origin.x) * Double(width),
                        y: (1.0 - Double(box.origin.y) - Double(box.height)) * Double(height),
                        width: Double(box.width) * Double(width),
                        height: Double(box.height) * Double(height),
                        confidence: Double(observation.confidence)
                    ),
                    box
                )
            }
            .max { lhs, rhs in
                lhs.face.width * lhs.face.height * max(lhs.face.confidence, 0.01) <
                    rhs.face.width * rhs.face.height * max(rhs.face.confidence, 0.01)
            }
    }

    private func recognizedHands(width: Int, height: Int, regionOfInterest: CGRect) -> [[String: Landmark]] {
        let observations = handRequest.results ?? []
        return observations.map { observation in
            let points = (try? observation.recognizedPoints(.all)) ?? [:]
            var hand: [String: Landmark] = [:]
            for (joint, point) in points {
                guard point.confidence >= 0.28, let label = handLabel(joint) else { continue }
                let imagePoint = Self.imagePoint(
                    from: point,
                    width: width,
                    height: height,
                    regionOfInterest: regionOfInterest
                )
                hand[label] = Landmark(
                    x: Double(imagePoint.x),
                    y: Double(imagePoint.y),
                    confidence: Double(point.confidence)
                )
            }
            return hand
        }
    }

    private func recentHandRegionOfInterest(now: TimeInterval) -> CGRect {
        guard now - lastFaceObservationAt <= profile.faceHoldSeconds else {
            return VNNormalizedIdentityRect
        }
        return handRegionOfInterest
    }

    private static func handSearchRegion(around faceBox: CGRect) -> CGRect {
        let side = min(1.0, max(faceBox.width, faceBox.height) * 3.0)
        let centerX = faceBox.midX
        let centerY = faceBox.midY
        return clampedNormalizedRect(
            CGRect(
                x: centerX - side * 0.5,
                y: centerY - side * 0.5,
                width: side,
                height: side
            )
        )
    }

    private static func clampedNormalizedRect(_ rect: CGRect) -> CGRect {
        let width = min(max(rect.width, 0.05), 1.0)
        let height = min(max(rect.height, 0.05), 1.0)
        let x = min(max(rect.origin.x, 0), 1.0 - width)
        let y = min(max(rect.origin.y, 0), 1.0 - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func imagePoint(
        from point: VNRecognizedPoint,
        width: Int,
        height: Int,
        regionOfInterest: CGRect
    ) -> CGPoint {
        let normalizedPoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        let imagePoint: CGPoint
        if VNNormalizedRectIsIdentityRect(regionOfInterest) {
            imagePoint = VNImagePointForNormalizedPoint(normalizedPoint, width, height)
        } else {
            imagePoint = VNImagePointForNormalizedPointUsingRegionOfInterest(
                normalizedPoint,
                width,
                height,
                regionOfInterest
            )
        }
        return CGPoint(x: imagePoint.x, y: CGFloat(height) - imagePoint.y)
    }

    private func handLabel(_ joint: VNHumanHandPoseObservation.JointName) -> String? {
        switch joint {
        case .wrist: return "wrist"
        case .thumbTip: return "thumb_tip"
        case .indexTip: return "index_tip"
        case .middleTip: return "middle_tip"
        case .ringTip: return "ring_tip"
        case .littleTip: return "little_tip"
        default: return nil
        }
    }

    private func updateAlertSound(state: HairAlertState, now: TimeInterval) {
        guard state.active else {
            guard alertWasActive else { return }
            alertWasActive = false
            stopAlertSound()
            return
        }

        alertWasActive = true
        guard now - lastBeepAt >= 2.0 else { return }
        lastBeepAt = now
        DispatchQueue.main.async {
            if let alertPlayer = self.alertPlayer {
                alertPlayer.stop()
                alertPlayer.currentTime = 0
                if alertPlayer.play() {
                    return
                }
            }
            NSSound.beep()
        }
    }

    private func stopAlertSound() {
        DispatchQueue.main.async {
            self.alertPlayer?.stop()
            self.alertPlayer?.currentTime = 0
        }
    }

    private func configureAlertSound() {
        guard let alertSoundURL else {
            log.write("alert sound disabled; using system beep")
            return
        }

        guard FileManager.default.fileExists(atPath: alertSoundURL.path) else {
            log.write("alert sound missing path=\(alertSoundURL.path); using system beep")
            return
        }

        do {
            let player = try AVAudioPlayer(contentsOf: alertSoundURL)
            player.prepareToPlay()
            alertPlayer = player
            log.write("alert sound loaded path=\(alertSoundURL.path)")
        } catch {
            log.write("alert sound failed path=\(alertSoundURL.path) error=\(error.localizedDescription); using system beep")
        }
    }

    private func maybeLog(state: HairAlertState, hands: [[String: Landmark]], now: TimeInterval) {
        guard now - lastLogAt >= 2.0 else { return }
        lastLogAt = now
        let score = state.zoneScore.map { String(format: "%.2f", $0) } ?? "-"
        let roi = recentHandRegionOfInterest(now: now)
        log.write(
            "status profile=\(profile.name) face=\(state.faceSeen) hands=\(hands.count) streak=\(state.streak) " +
                "active=\(state.active) score=\(score) roi=\(String(format: "%.2f,%.2f,%.2f,%.2f", roi.origin.x, roi.origin.y, roi.width, roi.height))"
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = AppOptions.parse(arguments: CommandLine.arguments)
    private lazy var log = FileLog(url: defaultLogURL())
    private var statusItem: NSStatusItem?
    private var statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private var controller: VisionCaptureController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        log.write("menubar app launched profile=\(options.profile.name)")

        controller = VisionCaptureController(log: log, alertSoundURL: options.alertSoundURL) { [weak self] status, state in
            self?.updateStatus(status, state: state)
        }

        if options.autostart {
            start(options.profile)
        } else {
            updateStatus("Stopped", state: .empty)
        }

        if let duration = options.duration {
            DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
                self.controller?.stop()
                NSApp.terminate(nil)
            }
        }
        log.write("applicationDidFinishLaunching complete")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationWillTerminate(_ notification: Notification) {
        log.write("applicationWillTerminate")
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        configureStatusButton(
            item.button,
            symbolName: "hand.raised",
            accessibilityDescription: "BodyPoseTracker",
            tint: nil
        )
        let menu = NSMenu()
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Start Production", action: #selector(startProduction), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Start Background", action: #selector(startBackground), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Start Eco", action: #selector(startEco), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stop), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Open Debug Preview", action: #selector(openDebugPreview), keyEquivalent: ""))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(quit), keyEquivalent: "q"))
        item.menu = menu
        statusItem = item
    }

    private func configureStatusButton(
        _ button: NSStatusBarButton?,
        symbolName: String,
        accessibilityDescription: String,
        tint: NSColor?
    ) {
        guard let button else { return }

        let image = makeStatusImage(
            symbolName: symbolName,
            accessibilityDescription: accessibilityDescription,
            tint: tint
        )
        button.image = image
        button.contentTintColor = nil
        button.title = ""
        button.imagePosition = .imageOnly
        button.toolTip = accessibilityDescription
    }

    private func makeStatusImage(
        symbolName: String,
        accessibilityDescription: String,
        tint: NSColor?
    ) -> NSImage? {
        guard let baseImage = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription) else {
            return nil
        }

        let configuredImage: NSImage
        if let tint,
           let tintedImage = baseImage.withSymbolConfiguration(.init(paletteColors: [tint])) {
            configuredImage = tintedImage
            configuredImage.isTemplate = false
        } else {
            configuredImage = baseImage
            configuredImage.isTemplate = true
        }
        configuredImage.size = NSSize(width: 18, height: 18)
        return configuredImage
    }

    private func requestCameraAccess(_ completion: @escaping (Bool) -> Void) {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        log.write("camera authorization status before request=\(status.rawValue)")
        switch status {
        case .authorized:
            completion(true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.log.write("camera authorization request completed granted=\(granted)")
                    completion(granted)
                }
            }
        default:
            log.write("camera authorization unavailable status=\(status.rawValue)")
            completion(false)
        }
    }

    private func start(_ profile: NativeProfile) {
        updateStatus("Checking Camera", state: .empty)
        requestCameraAccess { [weak self] granted in
            guard let self else { return }
            guard granted else {
                self.log.write("camera permission denied")
                self.updateStatus("Camera Permission Denied", state: .empty)
                return
            }
            self.log.write("camera permission granted; starting capture profile=\(profile.name)")
            self.controller?.start(profile: profile)
        }
    }

    private func updateStatus(_ status: String, state: HairAlertState) {
        statusMenuItem.title = "Status: \(status)"
        if state.active {
            configureStatusButton(
                statusItem?.button,
                symbolName: "hand.raised.fill",
                accessibilityDescription: "Hand Near Head",
                tint: .systemRed
            )
        } else if status == "Stopped" {
            configureStatusButton(
                statusItem?.button,
                symbolName: "hand.raised.slash",
                accessibilityDescription: "BodyPoseTracker Stopped",
                tint: nil
            )
        } else {
            configureStatusButton(
                statusItem?.button,
                symbolName: "hand.raised",
                accessibilityDescription: "BodyPoseTracker",
                tint: nil
            )
        }
    }

    @objc private func startProduction() {
        start(.production)
    }

    @objc private func startBackground() {
        start(.background)
    }

    @objc private func startEco() {
        start(.eco)
    }

    @objc private func stop() {
        controller?.stop()
    }

    @objc private func openDebugPreview() {
        controller?.stop()
        guard let rootURL = projectRootURL() else {
            log.write("debug preview unavailable: project root not found")
            return
        }

        let pythonURL = rootURL
            .appendingPathComponent(".venv")
            .appendingPathComponent("bin")
            .appendingPathComponent("python")
        guard FileManager.default.fileExists(atPath: pythonURL.path) else {
            log.write("debug preview unavailable: missing \(pythonURL.path)")
            return
        }

        let task = Process()
        task.currentDirectoryURL = rootURL
        task.executableURL = pythonURL
        task.environment = ProcessInfo.processInfo.environment.merging(
            ["BODYPOSE_SKIP_PERMISSION": "1"],
            uniquingKeysWith: { _, new in new }
        )
        task.arguments = [
            rootURL.appendingPathComponent("track_pose.py").path,
            "--profile",
            "debug",
            "--beep",
            "--alert-sound",
            projectAlertSoundURL.path
        ]
        try? task.run()
    }

    @objc private func quit() {
        controller?.stop()
        NSApp.terminate(nil)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
