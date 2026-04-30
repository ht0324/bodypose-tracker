import AppKit
import AVFoundation
import BodyPoseTrackerCore
import CoreImage
import CoreMedia
import Foundation
import Vision

private let bundledAlertSoundName = "iMovie-Alarm"
private let bundledAlertSoundExtension = "mp3"

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

struct DetectionConfig {
    let name: String
    let capturePreset: AVCaptureSession.Preset
    let cameraFPS: Double
    let faceFPS: Double
    let idleHandFPS: Double
    let activeHandFPS: Double
    let handBoostHoldSeconds: TimeInterval
    let maxHands: Int
    let triggerSeconds: TimeInterval
    let headScale: Double
    let faceHoldSeconds: TimeInterval

    var processingFPS: Double {
        max(faceFPS, activeHandFPS)
    }

    static let production = DetectionConfig(
        name: "Production",
        capturePreset: .qvga320x240,
        cameraFPS: 10,
        faceFPS: 2,
        idleHandFPS: 4,
        activeHandFPS: 8,
        handBoostHoldSeconds: 1.5,
        maxHands: 1,
        triggerSeconds: 0.3,
        headScale: 1.4,
        faceHoldSeconds: 1.0
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
    let autostart: Bool
    let alertSoundURL: URL?

    static func parse(arguments: [String]) -> AppOptions {
        var duration: TimeInterval?
        var autostart = true
        var alertSoundURL = defaultAlertSoundURL()
        var index = 1

        while index < arguments.count {
            switch arguments[index] {
            case "--duration" where index + 1 < arguments.count:
                duration = TimeInterval(arguments[index + 1])
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
    let config: DetectionConfig
    let appliedCameraFPS: Double?
    let appliedConnectionFPS: Double?
    let targetHandFPS: Double
    let observedProcessingFPS: Double
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
        let cameraFPS = frameData.appliedCameraFPS.map { String(format: "%.0f", $0) } ?? "-"
        let connectionFPS = frameData.appliedConnectionFPS.map { String(format: "%.0f", $0) } ?? "-"
        let usableHands = frameData.hands.filter { !$0.isEmpty }.count
        let pointCount = frameData.hands.reduce(0) { $0 + $1.count }
        let line1 = String(
            format: "%@ | fps %.1f | cam %@/%@ | face %.0f | hand %.0f/%.0f | delay %.1fs",
            frameData.config.name,
            frameData.observedProcessingFPS,
            cameraFPS,
            connectionFPS,
            frameData.config.faceFPS,
            frameData.targetHandFPS,
            frameData.config.activeHandFPS,
            frameData.config.triggerSeconds
        )
        let line2 = String(
            format: "size %.0fx%.0f | face %@ | hands %d/%d pts %d | streak %d | score %@",
            frameData.imageSize.width,
            frameData.imageSize.height,
            frameData.face == nil ? "no" : "yes",
            usableHands,
            frameData.hands.count,
            pointCount,
            frameData.state.streak,
            score
        )
        let text = "\(line1)\n\(line2)"

        let barHeight: CGFloat = 48
        let barRect = CGRect(x: imageRect.minX, y: imageRect.minY, width: imageRect.width, height: barHeight)
        NSColor.black.withAlphaComponent(0.78).setFill()
        barRect.fill()

        let attributes: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.white.withAlphaComponent(0.92),
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .medium)
        ]
        NSAttributedString(string: text, attributes: attributes).draw(
            in: barRect.insetBy(dx: 10, dy: 6)
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
    private let captureQueue = DispatchQueue(label: "BodyPoseTracker.capture", qos: .utility)
    private let sequenceHandler = VNSequenceRequestHandler()
    private lazy var ciContext = CIContext()
    private let faceRequest = VNDetectFaceRectanglesRequest()
    private let handRequest = VNDetectHumanHandPoseRequest()
    private let log: FileLog
    private let onStatus: (String, HairAlertState) -> Void
    private let alertSoundURL: URL?
    private var debugFrameHandler: ((DebugFrame) -> Void)?

    private var config = DetectionConfig.production
    private var detector = HairPickingDetector(
        triggerSeconds: DetectionConfig.production.triggerSeconds,
        headScale: DetectionConfig.production.headScale,
        faceHoldSeconds: DetectionConfig.production.faceHoldSeconds
    )
    private var lastProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastFaceProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastHandProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastFaceObservationAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastHandObservationAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastFrameWidth = 0
    private var lastFrameHeight = 0
    private var latestFace: FaceBox?
    private var lastLogAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastBeepAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var lastPublishedStatus: String?
    private var lastPublishedActive: Bool?
    private var debugFrameTimes: [TimeInterval] = []
    private var appliedCameraFPS: Double?
    private var appliedConnectionFPS: Double?
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
        faceRequest.preferBackgroundProcessing = true
        handRequest.preferBackgroundProcessing = true
        configureAlertSound()
    }

    func start(config: DetectionConfig) {
        captureQueue.async {
            self.config = config
            self.detector = HairPickingDetector(
                triggerSeconds: config.triggerSeconds,
                headScale: config.headScale,
                faceHoldSeconds: config.faceHoldSeconds
            )
            self.lastProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastFaceProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastHandProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastFaceObservationAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastHandObservationAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastFrameWidth = 0
            self.lastFrameHeight = 0
            self.latestFace = nil
            self.lastBeepAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.lastPublishedStatus = nil
            self.lastPublishedActive = nil
            self.debugFrameTimes = []
            self.latestHands = []
            self.latestState = .empty
            self.alertWasActive = false
            self.handRequest.maximumHandCount = config.maxHands

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
                    "started config=\(config.name) preset=\(config.capturePreset.rawValue) faceFPS=\(config.faceFPS) idleHandFPS=\(config.idleHandFPS) " +
                        "activeHandFPS=\(config.activeHandFPS) cameraFPS=\(config.cameraFPS) maxHands=\(config.maxHands) " +
                        "triggerSeconds=\(config.triggerSeconds) handBoostHoldSeconds=\(config.handBoostHoldSeconds)"
                )
                self.publishStatus("Running \(config.name)", state: .empty, force: true)
            } catch {
                self.log.write("start failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onStatus("Start failed", .empty)
                }
            }
        }
    }

    func stop(status: String = "Stopped", completion: (() -> Void)? = nil) {
        captureQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.isRunning = false
            self.alertWasActive = false
            self.lastPublishedStatus = nil
            self.lastPublishedActive = nil
            self.latestHands = []
            self.latestState = .empty
            self.stopAlertSound()
            self.log.write("stopped status=\(status)")
            DispatchQueue.main.async {
                self.onStatus(status, .empty)
                completion?()
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
        configureSessionPreset()

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw NSError(domain: "BodyPoseTracker", code: 1, userInfo: [NSLocalizedDescriptionKey: "No video camera found"])
        }
        configureCameraFrameRate(device)

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
        configureConnectionFrameRate(output)

        session.commitConfiguration()
    }

    private func configureSessionPreset() {
        if session.canSetSessionPreset(config.capturePreset) {
            session.sessionPreset = config.capturePreset
            log.write("session preset requested=\(config.capturePreset.rawValue) applied=\(session.sessionPreset.rawValue)")
            return
        }

        if session.canSetSessionPreset(.vga640x480) {
            session.sessionPreset = .vga640x480
            log.write("session preset requested=\(config.capturePreset.rawValue) unsupported; applied=\(session.sessionPreset.rawValue)")
        } else {
            log.write("session preset requested=\(config.capturePreset.rawValue) unsupported; using default=\(session.sessionPreset.rawValue)")
        }
    }

    private func configureCameraFrameRate(_ device: AVCaptureDevice) {
        guard config.cameraFPS > 0 else { return }

        let ranges = device.activeFormat.videoSupportedFrameRateRanges
        guard !ranges.isEmpty else {
            log.write("camera frame duration unavailable: no frame-rate ranges")
            return
        }

        let targetFPS = config.cameraFPS
        let compatibleRange = ranges.first { range in
            range.minFrameRate <= targetFPS && targetFPS <= range.maxFrameRate
        } ?? ranges.min { lhs, rhs in
            abs(lhs.maxFrameRate - targetFPS) < abs(rhs.maxFrameRate - targetFPS)
        }
        guard let compatibleRange else { return }

        let appliedFPS = min(max(targetFPS, compatibleRange.minFrameRate), compatibleRange.maxFrameRate)
        let roundedFPS = max(1, Int32(appliedFPS.rounded()))
        let frameDuration = CMTime(value: 1, timescale: roundedFPS)

        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            device.activeVideoMinFrameDuration = frameDuration
            device.activeVideoMaxFrameDuration = frameDuration
            appliedCameraFPS = Double(roundedFPS)
            log.write(
                String(
                    format: "camera frame duration targetFPS=%.1f appliedFPS=%d",
                    targetFPS,
                    roundedFPS
                )
            )
        } catch {
            appliedCameraFPS = nil
            log.write("camera frame duration failed: \(error.localizedDescription)")
        }
    }

    private func configureConnectionFrameRate(_ output: AVCaptureVideoDataOutput) {
        guard config.cameraFPS > 0 else { return }
        guard let connection = output.connection(with: .video) else {
            log.write("connection frame duration unavailable: no video connection")
            return
        }

        let roundedFPS = max(1, Int32(config.cameraFPS.rounded()))
        let frameDuration = CMTime(value: 1, timescale: roundedFPS)
        var applied = false

        if connection.isVideoMinFrameDurationSupported {
            connection.videoMinFrameDuration = frameDuration
            applied = true
        }
        if connection.isVideoMaxFrameDurationSupported {
            connection.videoMaxFrameDuration = frameDuration
            applied = true
        }

        if applied {
            appliedConnectionFPS = Double(roundedFPS)
            log.write(
                String(
                    format: "connection frame duration targetFPS=%.1f appliedFPS=%d",
                    config.cameraFPS,
                    roundedFPS
                )
            )
        } else {
            appliedConnectionFPS = nil
            log.write("connection frame duration unsupported")
        }
    }

    private func publishStatus(_ status: String, state: HairAlertState, force: Bool = false) {
        guard force || lastPublishedStatus != status || lastPublishedActive != state.active else {
            return
        }
        lastPublishedStatus = status
        lastPublishedActive = state.active
        DispatchQueue.main.async {
            self.onStatus(status, state)
        }
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastProcessAt < 1.0 / config.processingFPS {
            return
        }
        lastProcessAt = now

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        logFrameSizeIfNeeded(width: width, height: height)

        let runFace = now - lastFaceProcessAt >= 1.0 / config.faceFPS
        let handFPS = targetHandFPS(now: now)
        let runHands = recentFace(now: now) != nil && now - lastHandProcessAt >= 1.0 / handFPS
        guard runFace || runHands else { return }

        var requests: [VNRequest] = []
        if runFace {
            requests.append(faceRequest)
            lastFaceProcessAt = now
        }
        if runHands {
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
                let hands = recognizedHands(width: width, height: height)
                let state = detector.update(face: face, hands: hands, now: now)
                if hands.contains(where: { !$0.isEmpty }) {
                    lastHandObservationAt = now
                }
                latestHands = hands
                latestState = state
                handsForFrame = hands
                stateForFrame = state
                updateAlertSound(state: state, now: now)
                maybeLog(state: state, hands: hands, now: now)
                let label = state.active ? "Hand Near Head" : "Running \(config.name)"
                publishStatus(label, state: state)
            } else if face == nil {
                let state = detector.update(face: nil, hands: [], now: now)
                lastHandObservationAt = Date.distantPast.timeIntervalSinceReferenceDate
                latestHands = []
                latestState = state
                handsForFrame = []
                stateForFrame = state
                updateAlertSound(state: state, now: now)
                maybeLog(state: state, hands: [], now: now)
            }

            emitDebugFrame(
                pixelBuffer: pixelBuffer,
                width: width,
                height: height,
                face: face,
                hands: handsForFrame,
                state: stateForFrame,
                targetHandFPS: targetHandFPS(now: now),
                now: now
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
        targetHandFPS: Double,
        now: TimeInterval
    ) {
        guard let debugFrameHandler else { return }
        let observedFPS = updateObservedDebugFPS(now: now)
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
                config: config,
                appliedCameraFPS: appliedCameraFPS,
                appliedConnectionFPS: appliedConnectionFPS,
                targetHandFPS: targetHandFPS,
                observedProcessingFPS: observedFPS
            )
        )
    }

    private func targetHandFPS(now: TimeInterval) -> Double {
        let recentlySawHand = now - lastHandObservationAt <= config.handBoostHoldSeconds
        let shouldBoost = recentlySawHand || latestState.active || latestState.streak > 0
        return shouldBoost ? config.activeHandFPS : config.idleHandFPS
    }

    private func logFrameSizeIfNeeded(width: Int, height: Int) {
        guard width != lastFrameWidth || height != lastFrameHeight else { return }
        lastFrameWidth = width
        lastFrameHeight = height
        log.write("video frame size width=\(width) height=\(height)")
    }

    private func updateObservedDebugFPS(now: TimeInterval) -> Double {
        debugFrameTimes.append(now)
        debugFrameTimes.removeAll { now - $0 > 2.0 }
        guard let first = debugFrameTimes.first, let last = debugFrameTimes.last, last > first else {
            return Double(debugFrameTimes.count)
        }
        return Double(debugFrameTimes.count - 1) / (last - first)
    }

    private func updateFaceState(width: Int, height: Int, now: TimeInterval) -> FaceBox? {
        guard let face = bestFace(width: width, height: height) else { return nil }
        latestFace = face
        lastFaceObservationAt = now
        return face
    }

    private func bestFace(width: Int, height: Int) -> FaceBox? {
        let observations = faceRequest.results ?? []
        return observations
            .map { observation -> FaceBox in
                let box = observation.boundingBox
                return FaceBox(
                    x: Double(box.origin.x) * Double(width),
                    y: (1.0 - Double(box.origin.y) - Double(box.height)) * Double(height),
                    width: Double(box.width) * Double(width),
                    height: Double(box.height) * Double(height),
                    confidence: Double(observation.confidence)
                )
            }
            .max { lhs, rhs in
                lhs.width * lhs.height * max(lhs.confidence, 0.01) <
                    rhs.width * rhs.height * max(rhs.confidence, 0.01)
            }
    }

    private func recognizedHands(width: Int, height: Int) -> [[String: Landmark]] {
        let observations = handRequest.results ?? []
        return observations.map { observation in
            let points = (try? observation.recognizedPoints(.all)) ?? [:]
            var hand: [String: Landmark] = [:]
            for (joint, point) in points {
                guard point.confidence >= 0.28, let label = handLabel(joint) else { continue }
                let imagePoint = Self.imagePoint(from: point, width: width, height: height)
                hand[label] = Landmark(
                    x: Double(imagePoint.x),
                    y: Double(imagePoint.y),
                    confidence: Double(point.confidence)
                )
            }
            return hand
        }
    }

    private func recentFace(now: TimeInterval) -> FaceBox? {
        guard let latestFace, now - lastFaceObservationAt <= config.faceHoldSeconds else {
            return nil
        }
        return latestFace
    }

    private static func imagePoint(
        from point: VNRecognizedPoint,
        width: Int,
        height: Int
    ) -> CGPoint {
        let normalizedPoint = CGPoint(x: CGFloat(point.x), y: CGFloat(point.y))
        let imagePoint = VNImagePointForNormalizedPoint(normalizedPoint, width, height)
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
        let handFPS = String(format: "%.0f", targetHandFPS(now: now))
        let usableHands = hands.filter { !$0.isEmpty }.count
        let pointCount = hands.reduce(0) { $0 + $1.count }
        log.write(
            "status config=\(config.name) face=\(state.faceSeen) hands=\(usableHands) rawHands=\(hands.count) points=\(pointCount) streak=\(state.streak) " +
                "handFPS=\(handFPS) active=\(state.active) score=\(score)"
        )
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let pauseApps: [(bundleID: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.apple.FaceTime", "FaceTime")
    ]
    private let options = AppOptions.parse(arguments: CommandLine.arguments)
    private lazy var log = FileLog(url: defaultLogURL())
    private var statusItem: NSStatusItem?
    private var statusMenuItem = NSMenuItem(title: "Starting...", action: nil, keyEquivalent: "")
    private var productionToggleMenuItem = NSMenuItem(title: "Start Production", action: nil, keyEquivalent: "")
    private var debugPreviewMenuItem = NSMenuItem(title: "Show Debug Preview", action: nil, keyEquivalent: "")
    private var controller: VisionCaptureController?
    private var debugPreviewWindow: DebugPreviewWindowController?
    private var productionWanted = false
    private var runningPauseAppBundleIDs = Set<String>()
    private var workspaceObservers: [NSObjectProtocol] = []
    private var pauseReconcileTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        setupStatusItem()
        log.write("menubar app launched config=\(DetectionConfig.production.name)")

        controller = VisionCaptureController(log: log, alertSoundURL: options.alertSoundURL) { [weak self] status, state in
            self?.updateStatus(status, state: state)
        }
        setupPauseAppMonitoring()

        if options.autostart {
            start(.production)
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
        for observer in workspaceObservers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        workspaceObservers = []
        stopPauseReconcileTimer()
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
        productionToggleMenuItem.action = #selector(toggleProduction)
        menu.addItem(productionToggleMenuItem)
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

    private func setupPauseAppMonitoring() {
        refreshRunningPauseApps()
        let notificationCenter = NSWorkspace.shared.notificationCenter
        workspaceObservers = [
            notificationCenter.addObserver(
                forName: NSWorkspace.didLaunchApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleWorkspaceAppChange(notification, launched: true)
            },
            notificationCenter.addObserver(
                forName: NSWorkspace.didTerminateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                self?.handleWorkspaceAppChange(notification, launched: false)
            }
        ]

        if let reason = pauseReason {
            log.write("pause apps already running reason=\(reason)")
        }
    }

    private func refreshRunningPauseApps() {
        let pauseBundleIDs = Set(pauseApps.map(\.bundleID))
        runningPauseAppBundleIDs = Set(
            NSWorkspace.shared.runningApplications
                .compactMap(\.bundleIdentifier)
                .filter { pauseBundleIDs.contains($0) }
        )
    }

    private func handleWorkspaceAppChange(_ notification: Notification, launched: Bool) {
        let previousBundleIDs = runningPauseAppBundleIDs
        let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        refreshRunningPauseApps()

        let launchedBundleIDs = runningPauseAppBundleIDs.subtracting(previousBundleIDs)
        let terminatedBundleIDs = previousBundleIDs.subtracting(runningPauseAppBundleIDs)
        let notifiedPauseBundleID = app?.bundleIdentifier.flatMap { pauseAppName(for: $0) == nil ? nil : $0 }
        logPauseAppChanges(launchedBundleIDs: launchedBundleIDs, terminatedBundleIDs: terminatedBundleIDs)

        if launchedBundleIDs.isEmpty,
           terminatedBundleIDs.isEmpty,
           let bundleID = notifiedPauseBundleID,
           let appName = pauseAppName(for: bundleID) {
            let eventName = launched ? "launch" : "terminate"
            log.write("pause app \(eventName) event name=\(appName) bundleID=\(bundleID) stateUnchanged")
        }

        if !launchedBundleIDs.isEmpty || !terminatedBundleIDs.isEmpty || notifiedPauseBundleID != nil {
            reconcileProductionPause()
        }
    }

    private var pauseReason: String? {
        let names = pauseApps.compactMap { app in
            runningPauseAppBundleIDs.contains(app.bundleID) ? app.name : nil
        }
        return names.isEmpty ? nil : names.joined(separator: ", ")
    }

    private func pauseAppName(for bundleID: String) -> String? {
        pauseApps.first { $0.bundleID == bundleID }?.name
    }

    private func reconcileProductionPause() {
        guard productionWanted else { return }

        if let reason = pauseReason {
            pauseProduction(reason: reason)
            startPauseReconcileTimerIfNeeded()
        } else if controller?.isRunning != true {
            stopPauseReconcileTimer()
            log.write("pause apps cleared; resuming production")
            start(.production)
        } else {
            stopPauseReconcileTimer()
        }
    }

    private func pauseProduction(reason: String) {
        startPauseReconcileTimerIfNeeded()
        let status = "Paused: \(reason)"
        if controller?.isRunning == true {
            log.write("pausing production reason=\(reason)")
            controller?.stop(status: status) { [weak self] in
                guard let self, self.productionWanted, self.pauseReason == nil else { return }
                self.log.write("pause apps cleared during stop; resuming production")
                self.start(.production)
            }
        } else {
            updateStatus(status, state: .empty)
        }
    }

    private func startPauseReconcileTimerIfNeeded() {
        guard pauseReconcileTimer == nil else { return }

        pauseReconcileTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            guard self.productionWanted else {
                self.stopPauseReconcileTimer()
                return
            }

            let previousBundleIDs = self.runningPauseAppBundleIDs
            self.refreshRunningPauseApps()
            let launchedBundleIDs = self.runningPauseAppBundleIDs.subtracting(previousBundleIDs)
            let terminatedBundleIDs = previousBundleIDs.subtracting(self.runningPauseAppBundleIDs)
            self.logPauseAppChanges(launchedBundleIDs: launchedBundleIDs, terminatedBundleIDs: terminatedBundleIDs)

            if !launchedBundleIDs.isEmpty || !terminatedBundleIDs.isEmpty || self.pauseReason == nil {
                self.reconcileProductionPause()
            }
        }
        pauseReconcileTimer?.tolerance = 0.5
    }

    private func stopPauseReconcileTimer() {
        pauseReconcileTimer?.invalidate()
        pauseReconcileTimer = nil
    }

    private func logPauseAppChanges(launchedBundleIDs: Set<String>, terminatedBundleIDs: Set<String>) {
        for bundleID in launchedBundleIDs.sorted() {
            if let appName = pauseAppName(for: bundleID) {
                log.write("pause app launched name=\(appName) bundleID=\(bundleID)")
            }
        }
        for bundleID in terminatedBundleIDs.sorted() {
            if let appName = pauseAppName(for: bundleID) {
                log.write("pause app terminated name=\(appName) bundleID=\(bundleID)")
            }
        }
    }

    private func start(_ config: DetectionConfig) {
        productionWanted = true
        if let reason = pauseReason {
            log.write("production start deferred reason=\(reason)")
            pauseProduction(reason: reason)
            return
        }

        updateStatus("Checking Camera", state: .empty)
        requestCameraAccess { [weak self] granted in
            guard let self else { return }
            guard self.productionWanted else {
                self.log.write("production start canceled before camera startup")
                self.updateStatus("Stopped", state: .empty)
                return
            }
            if let reason = self.pauseReason {
                self.log.write("production start deferred after camera check reason=\(reason)")
                self.pauseProduction(reason: reason)
                return
            }
            guard granted else {
                self.productionWanted = false
                self.log.write("camera permission denied")
                self.updateStatus("Camera Permission Denied", state: .empty)
                return
            }
            self.log.write("camera permission granted; starting capture config=\(config.name)")
            self.controller?.start(config: config)
        }
    }

    private func updateStatus(_ status: String, state: HairAlertState) {
        statusMenuItem.title = "Status: \(status)"
        updateProductionToggleTitle(status: status)
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

    private func updateProductionToggleTitle(status: String) {
        switch status {
        case "Stopped", "Camera Permission Denied", "Start failed":
            productionWanted = false
            productionToggleMenuItem.title = "Start Production"
        default:
            productionToggleMenuItem.title = "Stop Production"
        }
    }

    @objc private func toggleProduction() {
        if productionWanted || controller?.isRunning == true {
            stopProduction()
        } else {
            start(.production)
        }
    }

    private func stopProduction() {
        productionWanted = false
        stopPauseReconcileTimer()
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

        if !productionWanted && controller?.isRunning != true {
            start(.production)
        }
    }

    @objc private func quit() {
        controller?.setDebugFrameHandler(nil)
        debugPreviewWindow?.close()
        stopProduction()
        NSApp.terminate(nil)
    }
}

let delegate = AppDelegate()
NSApplication.shared.delegate = delegate
NSApplication.shared.run()
