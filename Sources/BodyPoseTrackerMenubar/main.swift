import AppKit
import AVFoundation
import BodyPoseTrackerCore
import CoreImage
import CoreMedia
import Foundation
import Vision

private let bundledAlertSoundName = "iMovie-Alarm"
private let bundledAlertSoundExtension = "mp3"
private let useVisionHandRegionOfInterest = false
private let plannedHandROIScale: CGFloat = 4.0

private var projectAlertSoundURL: URL {
    URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
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
        faceFPS: 2,
        handFPS: 8,
        maxDimension: 480,
        maxHands: 1,
        triggerFrames: 5,
        triggerSeconds: 0.3,
        headScale: 1.4,
        faceHoldSeconds: 1.0,
        presenceGate: true
    )
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
        let profile = NativeProfile.production
        var autostart = true
        var alertSoundURL = defaultAlertSoundURL()
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration" where index + 1 < arguments.count:
                duration = TimeInterval(arguments[index + 1])
                index += 2
            case "--profile" where index + 1 < arguments.count:
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

struct DebugFrame {
    let image: CGImage
    let imageSize: CGSize
    let face: FaceBox?
    let hands: [[String: Landmark]]
    let state: HairAlertState
    let plannedHandROI: CGRect?
    let visionHandROI: CGRect
    let visionROIEnabled: Bool
    let profile: NativeProfile
}

final class DebugPreviewView: NSView {
    private static let handEdges: [(String, String)] = [
        ("wrist", "thumb_cmc"),
        ("thumb_cmc", "thumb_mp"),
        ("thumb_mp", "thumb_ip"),
        ("thumb_ip", "thumb_tip"),
        ("wrist", "index_mcp"),
        ("index_mcp", "index_pip"),
        ("index_pip", "index_dip"),
        ("index_dip", "index_tip"),
        ("wrist", "middle_mcp"),
        ("middle_mcp", "middle_pip"),
        ("middle_pip", "middle_dip"),
        ("middle_dip", "middle_tip"),
        ("wrist", "ring_mcp"),
        ("ring_mcp", "ring_pip"),
        ("ring_pip", "ring_dip"),
        ("ring_dip", "ring_tip"),
        ("wrist", "little_mcp"),
        ("little_mcp", "little_pip"),
        ("little_pip", "little_dip"),
        ("little_dip", "little_tip")
    ]

    var frameData: DebugFrame? {
        didSet {
            needsDisplay = true
        }
    }

    override var wantsUpdateLayer: Bool {
        false
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.black.setFill()
        bounds.fill()

        guard let frameData else {
            drawCenteredMessage("Waiting for camera frames...")
            return
        }

        let imageRect = fittedImageRect(imageSize: frameData.imageSize)
        NSImage(cgImage: frameData.image, size: frameData.imageSize).draw(in: imageRect)

        drawPlannedROI(frameData.plannedHandROI, imageSize: frameData.imageSize, imageRect: imageRect)
        drawFace(frameData.face, imageRect: imageRect)
        drawHeadZone(frameData.state.headZone, active: frameData.state.active, imageRect: imageRect)
        drawHands(frameData.hands, imageRect: imageRect)
        drawStatus(frameData, imageRect: imageRect)
    }

    private func drawCenteredMessage(_ message: String) {
        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.72),
            .font: NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)
        ]
        let attributed = NSAttributedString(string: message, attributes: attributes)
        let size = attributed.size()
        attributed.draw(
            at: CGPoint(
                x: bounds.midX - size.width * 0.5,
                y: bounds.midY - size.height * 0.5
            )
        )
    }

    private func fittedImageRect(imageSize: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return bounds }
        let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
        let width = imageSize.width * scale
        let height = imageSize.height * scale
        return CGRect(
            x: bounds.midX - width * 0.5,
            y: bounds.midY - height * 0.5,
            width: width,
            height: height
        )
    }

    private func projectTopLeftRect(_ rect: CGRect, into imageRect: CGRect) -> CGRect {
        let scale = imageRect.width / max(1, frameData?.imageSize.width ?? 1)
        return CGRect(
            x: imageRect.minX + rect.origin.x * scale,
            y: imageRect.maxY - (rect.origin.y + rect.height) * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
    }

    private func point(fromTopLeftImagePoint point: Landmark, imageRect: CGRect) -> CGPoint {
        let scale = imageRect.width / max(1, frameData?.imageSize.width ?? 1)
        return CGPoint(
            x: imageRect.minX + point.x * scale,
            y: imageRect.maxY - point.y * scale
        )
    }

    private func normalizedVisionRect(_ rect: CGRect, imageSize: CGSize, imageRect: CGRect) -> CGRect {
        let topLeftRect = CGRect(
            x: rect.origin.x * imageSize.width,
            y: (1.0 - rect.origin.y - rect.height) * imageSize.height,
            width: rect.width * imageSize.width,
            height: rect.height * imageSize.height
        )
        return projectTopLeftRect(topLeftRect, into: imageRect)
    }

    private func drawPlannedROI(_ roi: CGRect?, imageSize: CGSize, imageRect: CGRect) {
        guard let roi else { return }
        let rect = normalizedVisionRect(roi, imageSize: imageSize, imageRect: imageRect)
        NSColor.systemOrange.withAlphaComponent(0.9).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawFace(_ face: FaceBox?, imageRect: CGRect) {
        guard let face else { return }
        let rect = projectTopLeftRect(
            CGRect(x: face.x, y: face.y, width: face.width, height: face.height),
            into: imageRect
        )
        NSColor.systemGreen.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(rect: rect)
        path.lineWidth = 2
        path.stroke()
    }

    private func drawHeadZone(_ zone: HeadZone?, active: Bool, imageRect: CGRect) {
        guard let zone else { return }
        let rect = projectTopLeftRect(
            CGRect(
                x: zone.centerX - zone.radiusX,
                y: zone.centerY - zone.radiusY,
                width: zone.radiusX * 2,
                height: zone.radiusY * 2
            ),
            into: imageRect
        )
        let color: NSColor = active ? .systemRed : (zone.stale ? .systemGray : .systemBlue)
        color.withAlphaComponent(0.95).setStroke()
        let path = NSBezierPath(ovalIn: rect)
        path.lineWidth = active ? 4 : 3
        path.stroke()
    }

    private func drawHands(_ hands: [[String: Landmark]], imageRect: CGRect) {
        for hand in hands {
            NSColor.systemCyan.withAlphaComponent(0.92).setStroke()
            for (start, end) in Self.handEdges {
                guard let a = hand[start], let b = hand[end] else { continue }
                let path = NSBezierPath()
                path.move(to: point(fromTopLeftImagePoint: a, imageRect: imageRect))
                path.line(to: point(fromTopLeftImagePoint: b, imageRect: imageRect))
                path.lineWidth = 2
                path.stroke()
            }

            NSColor.systemCyan.setFill()
            for landmark in hand.values {
                let center = point(fromTopLeftImagePoint: landmark, imageRect: imageRect)
                NSBezierPath(
                    ovalIn: CGRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)
                ).fill()
            }
        }
    }

    private func drawStatus(_ frameData: DebugFrame, imageRect: CGRect) {
        let score = frameData.state.zoneScore.map { String(format: "%.2f", $0) } ?? "-"
        let roiLabel: String
        if frameData.visionROIEnabled {
            roiLabel = String(
                format: "Vision ROI %.2f,%.2f %.2fx%.2f",
                frameData.visionHandROI.origin.x,
                frameData.visionHandROI.origin.y,
                frameData.visionHandROI.width,
                frameData.visionHandROI.height
            )
        } else {
            roiLabel = "Vision ROI full frame"
        }
        let planned = frameData.plannedHandROI == nil ? "planned 4x unavailable" : "orange planned 4x head square"
        let text = String(
            format: "Profile %@ | face %@ | hands %d | streak %d | score %@ | %@ | %@ | delay %.1fs",
            frameData.profile.name,
            frameData.face == nil ? "no" : "yes",
            frameData.hands.count,
            frameData.state.streak,
            score,
            roiLabel,
            planned,
            frameData.profile.triggerSeconds
        )

        let barHeight: CGFloat = 30
        let barRect = CGRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: barHeight)
        NSColor.black.withAlphaComponent(0.78).setFill()
        barRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        ]
        NSAttributedString(string: text, attributes: attributes).draw(
            in: barRect.insetBy(dx: 10, dy: 7)
        )
    }
}

final class DebugPreviewWindowController: NSWindowController, NSWindowDelegate {
    private let previewView = DebugPreviewView(frame: CGRect(x: 0, y: 0, width: 960, height: 620))
    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 960, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "BodyPoseTracker Debug Preview"
        window.minSize = NSSize(width: 640, height: 420)
        window.contentView = previewView
        super.init(window: window)
        window.delegate = self
        window.center()
    }

    required init?(coder: NSCoder) {
        return nil
    }

    func update(frame: DebugFrame) {
        previewView.frameData = frame
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
        onClose = nil
    }
}

final class VisionCaptureController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    private let session = AVCaptureSession()
    private let captureQueue = DispatchQueue(label: "BodyPoseTracker.capture", qos: .userInitiated)
    private let sequenceHandler = VNSequenceRequestHandler()
    private let ciContext = CIContext()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let log: FileLog
    private let onStatus: (String, HairAlertState) -> Void
    private let alertSoundURL: URL?
    private var debugFrameHandler: ((DebugFrame) -> Void)?

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
    private var latestFace: FaceBox?
    private var lastLogAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastBeepAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var handRegionOfInterest = VNNormalizedIdentityRect
    private var latestHands: [[String: Landmark]] = []
    private var latestState = HairAlertState.empty
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
            self.latestFace = nil
            self.lastBeepAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.handRegionOfInterest = VNNormalizedIdentityRect
            self.latestHands = []
            self.latestState = .empty
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
            self.latestHands = []
            self.latestState = .empty
            self.stopAlertSound()
            self.log.write("stopped")
            DispatchQueue.main.async {
                self.onStatus("Stopped", .empty)
            }
        }
    }

    func setDebugFrameHandler(_ handler: ((DebugFrame) -> Void)?) {
        captureQueue.async {
            self.debugFrameHandler = handler
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
        let runHands = (!profile.presenceGate || recentFace(now: now) != nil) &&
            now - lastHandProcessAt >= 1.0 / profile.handFPS
        guard runFace || runHands else { return }

        var requests: [VNRequest] = []
        if runFace {
            requests.append(faceRequest)
            lastFaceProcessAt = now
        }
        if runHands {
            handRequest.regionOfInterest = useVisionHandRegionOfInterest ? recentHandRegionOfInterest(now: now) : VNNormalizedIdentityRect
            requests.append(handRequest)
            lastHandProcessAt = now
        }

        do {
            try sequenceHandler.perform(requests, on: sampleBuffer, orientation: .up)
            let detectedFace = runFace ? updateFaceState(width: width, height: height, now: now) : nil
            let face = detectedFace ?? recentFace(now: now)
            var handsForFrame = latestHands
            var stateForFrame = latestState

            if runHands {
                let hands = recognizedHands(width: width, height: height, regionOfInterest: handRequest.regionOfInterest)
                let state = detector.update(face: face, hands: hands, now: now)
                latestHands = hands
                latestState = state
                handsForFrame = hands
                stateForFrame = state
                updateAlertSound(state: state, now: now)
                maybeLog(state: state, hands: hands, now: now)
                DispatchQueue.main.async {
                    let label = state.active ? "Hand Near Head" : "Running \(self.profile.name)"
                    self.onStatus(label, state)
                }
            } else if face == nil {
                let state = detector.update(face: nil, hands: [], now: now)
                latestHands = []
                latestState = state
                handsForFrame = []
                stateForFrame = state
                updateAlertSound(state: state, now: now)
                maybeLog(state: state, hands: [], now: now)
            }

            let plannedROI = face == nil ? nil : recentHandRegionOfInterest(now: now)
            let visionROI = useVisionHandRegionOfInterest ? (plannedROI ?? VNNormalizedIdentityRect) : VNNormalizedIdentityRect
            emitDebugFrame(
                pixelBuffer: pixelBuffer,
                width: width,
                height: height,
                face: face,
                hands: handsForFrame,
                state: stateForFrame,
                plannedROI: plannedROI,
                visionROI: visionROI
            )
        } catch {
            if now - lastLogAt > 2.0 {
                lastLogAt = now
                log.write("vision error: \(error.localizedDescription)")
            }
        }
    }

    private func emitDebugFrame(
        pixelBuffer: CVPixelBuffer,
        width: Int,
        height: Int,
        face: FaceBox?,
        hands: [[String: Landmark]],
        state: HairAlertState,
        plannedROI: CGRect?,
        visionROI: CGRect
    ) {
        guard let debugFrameHandler else { return }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let imageRect = CGRect(x: 0, y: 0, width: width, height: height)
        guard let cgImage = ciContext.createCGImage(image, from: imageRect) else { return }
        debugFrameHandler(
            DebugFrame(
                image: cgImage,
                imageSize: CGSize(width: width, height: height),
                face: face,
                hands: hands,
                state: state,
                plannedHandROI: plannedROI,
                visionHandROI: visionROI,
                visionROIEnabled: useVisionHandRegionOfInterest,
                profile: profile
            )
        )
    }

    private func updateFaceState(width: Int, height: Int, now: TimeInterval) -> FaceBox? {
        guard let best = bestFace(width: width, height: height) else { return nil }
        latestFace = best.face
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

    private func recentFace(now: TimeInterval) -> FaceBox? {
        guard let latestFace, now - lastFaceObservationAt <= profile.faceHoldSeconds else {
            return nil
        }
        return latestFace
    }

    private static func handSearchRegion(around faceBox: CGRect) -> CGRect {
        let side = min(1.0, max(faceBox.width, faceBox.height) * plannedHandROIScale)
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
        case .thumbCMC: return "thumb_cmc"
        case .thumbMP: return "thumb_mp"
        case .thumbIP: return "thumb_ip"
        case .thumbTip: return "thumb_tip"
        case .indexMCP: return "index_mcp"
        case .indexPIP: return "index_pip"
        case .indexDIP: return "index_dip"
        case .indexTip: return "index_tip"
        case .middleMCP: return "middle_mcp"
        case .middlePIP: return "middle_pip"
        case .middleDIP: return "middle_dip"
        case .middleTip: return "middle_tip"
        case .ringMCP: return "ring_mcp"
        case .ringPIP: return "ring_pip"
        case .ringDIP: return "ring_dip"
        case .ringTip: return "ring_tip"
        case .littleMCP: return "little_mcp"
        case .littlePIP: return "little_pip"
        case .littleDIP: return "little_dip"
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
        let visionROI = useVisionHandRegionOfInterest ? String(format: "%.2f,%.2f,%.2f,%.2f", roi.origin.x, roi.origin.y, roi.width, roi.height) : "full"
        log.write(
            "status profile=\(profile.name) face=\(state.faceSeen) hands=\(hands.count) streak=\(state.streak) " +
                "active=\(state.active) score=\(score) visionROI=\(visionROI) plannedROI=\(String(format: "%.2f,%.2f,%.2f,%.2f", roi.origin.x, roi.origin.y, roi.width, roi.height))"
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let options = AppOptions.parse(arguments: CommandLine.arguments)
    private lazy var log = FileLog(url: defaultLogURL())
    private var statusItem: NSStatusItem?
    private var statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private var debugPreviewMenuItem = NSMenuItem(title: "Show Debug Preview", action: nil, keyEquivalent: "")
    private var controller: VisionCaptureController?
    private var debugPreviewWindow: DebugPreviewWindowController?

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
        menu.addItem(NSMenuItem(title: "Stop", action: #selector(stop), keyEquivalent: ""))
        menu.addItem(.separator())
        debugPreviewMenuItem.action = #selector(toggleDebugPreview)
        menu.addItem(debugPreviewMenuItem)
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

    @objc private func stop() {
        controller?.stop()
    }

    @objc private func toggleDebugPreview() {
        if let debugPreviewWindow {
            controller?.setDebugFrameHandler(nil)
            debugPreviewWindow.close()
            self.debugPreviewWindow = nil
            debugPreviewMenuItem.title = "Show Debug Preview"
            return
        }

        let preview = DebugPreviewWindowController()
        debugPreviewWindow = preview
        debugPreviewMenuItem.title = "Hide Debug Preview"
        preview.onClose = { [weak self, weak preview] in
            guard let self else { return }
            if self.debugPreviewWindow === preview {
                self.controller?.setDebugFrameHandler(nil)
                self.debugPreviewWindow = nil
                self.debugPreviewMenuItem.title = "Show Debug Preview"
            }
        }
        controller?.setDebugFrameHandler { [weak preview] frame in
            DispatchQueue.main.async {
                preview?.update(frame: frame)
            }
        }
        preview.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)

        if controller?.isRunning != true {
            start(.production)
        }
    }

    @objc private func quit() {
        controller?.setDebugFrameHandler(nil)
        debugPreviewWindow?.close()
        controller?.stop()
        NSApp.terminate(nil)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
