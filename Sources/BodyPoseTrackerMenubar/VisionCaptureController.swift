import AppKit
import AVFoundation
import BodyPoseTrackerCore
import CoreGraphics
import CoreImage
import CoreMedia
import Foundation
import os
import Vision

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
        faceHoldSeconds: DetectionConfig.production.faceHoldSeconds,
        maxHandFaceRatio: DetectionConfig.production.maxHandFaceRatio,
        minHeadRadius: DetectionConfig.production.minHeadRadius
    )
    private var nextProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var nextFaceRunAt = Date.distantPast.timeIntervalSinceReferenceDate
    private var nextHandRunAt = Date.distantPast.timeIntervalSinceReferenceDate
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

    // Written on captureQueue, read from the main thread (menu state checks).
    private let runningState = OSAllocatedUnfairLock(initialState: false)

    var isRunning: Bool {
        runningState.withLock { $0 }
    }

    private func setRunning(_ running: Bool) {
        runningState.withLock { $0 = running }
    }

    init(log: FileLog, alertSoundURL: URL?, onStatus: @escaping (String, HairAlertState) -> Void) {
        self.log = log
        self.alertSoundURL = alertSoundURL
        self.onStatus = onStatus
        super.init()
        faceRequest.preferBackgroundProcessing = true
        handRequest.preferBackgroundProcessing = true
        configureAlertSound()
    }

    func start(config: DetectionConfig, completion: ((Bool) -> Void)? = nil) {
        captureQueue.async {
            self.config = config
            self.detector = HairPickingDetector(
                triggerSeconds: config.triggerSeconds,
                headScale: config.headScale,
                faceHoldSeconds: config.faceHoldSeconds,
                maxHandFaceRatio: config.maxHandFaceRatio,
                minHeadRadius: config.minHeadRadius
            )
            self.nextProcessAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.nextFaceRunAt = Date.distantPast.timeIntervalSinceReferenceDate
            self.nextHandRunAt = Date.distantPast.timeIntervalSinceReferenceDate
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
                self.setRunning(true)
                self.log.write(
                    "started config=\(config.name) preset=\(config.capturePreset.rawValue) faceFPS=\(config.faceFPS) idleHandFPS=\(config.idleHandFPS) " +
                        "activeHandFPS=\(config.activeHandFPS) cameraFPS=\(config.cameraFPS) maxHands=\(config.maxHands) " +
                        "triggerSeconds=\(config.triggerSeconds) maxHandFaceRatio=\(config.maxHandFaceRatio) " +
                        "minHeadRadius=\(config.minHeadRadius) handBoostHoldSeconds=\(config.handBoostHoldSeconds)"
                )
                self.publishStatus("Enabled", state: .empty, force: true)
                DispatchQueue.main.async {
                    completion?(true)
                }
            } catch {
                self.log.write("start failed: \(error.localizedDescription)")
                DispatchQueue.main.async {
                    self.onStatus("Start failed", .empty)
                    completion?(false)
                }
            }
        }
    }

    func stop(status: String = "Stopped", completion: (() -> Void)? = nil) {
        captureQueue.async {
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.setRunning(false)
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

    func setMaxHandFaceRatio(_ maxHandFaceRatio: Double) {
        captureQueue.async {
            let clampedLimit = max(0, maxHandFaceRatio)
            self.config = self.config.replacing(maxHandFaceRatio: clampedLimit)
            self.detector.setMaxHandFaceRatio(clampedLimit)
        }
    }

    private func configureSession() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
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
        guard isRunning else { return }
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
        guard isRunning else { return }

        let now = Date.timeIntervalSinceReferenceDate
        guard now >= nextProcessAt else { return }
        advanceSchedule(&nextProcessAt, interval: 1.0 / config.processingFPS, now: now)

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        logFrameSizeIfNeeded(width: width, height: height)

        let runFace = now >= nextFaceRunAt
        let handFPS = targetHandFPS(now: now)
        let runHands = recentFace(now: now) != nil && now >= nextHandRunAt
        guard runFace || runHands else { return }

        var requests: [VNRequest] = []
        if runFace {
            requests.append(faceRequest)
            advanceSchedule(&nextFaceRunAt, interval: 1.0 / config.faceFPS, now: now)
        }
        if runHands {
            requests.append(handRequest)
            advanceSchedule(&nextHandRunAt, interval: 1.0 / handFPS, now: now)
        }

        do {
            try sequenceHandler.perform(requests, on: sampleBuffer, orientation: .up)
            let detectedFace = runFace ? updateFaceState(width: width, height: height, now: now) : nil
            let face = detectedFace ?? recentFace(now: now)
            var handsForFrame = latestHands
            var stateForFrame = latestState

            if runHands {
                let hands = recognizedHands(width: width, height: height)
                let state = detector.update(
                    face: face,
                    faceObservedAt: lastFaceObservationAt,
                    hands: hands,
                    now: now
                )
                if hands.contains(where: { !$0.isEmpty }) {
                    lastHandObservationAt = now
                }
                latestHands = hands
                latestState = state
                handsForFrame = hands
                stateForFrame = state
                updateAlertSound(state: state, now: now)
                maybeLog(state: state, hands: hands, now: now)
                let label = state.active ? "Hand Near Head" : "Enabled"
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

    // Advancing along a fixed schedule (instead of snapping to the frame time) keeps
    // throttled rates at the configured FPS even though frames arrive on the camera's
    // coarser timing grid; snapping rounded every interval up to the next frame boundary.
    private func advanceSchedule(_ nextRunAt: inout TimeInterval, interval: TimeInterval, now: TimeInterval) {
        let scheduled = nextRunAt + interval
        nextRunAt = scheduled > now ? scheduled : now + interval
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
        let handFaceRatio = state.handFaceRatio.map { String(format: "%.2f", $0) } ?? "-"
        let handSizeStatus = state.handFaceRatio == nil ? "-" : (state.handSizeAccepted ? "ok" : "no")
        let handFPS = String(format: "%.0f", targetHandFPS(now: now))
        let usableHands = hands.filter { !$0.isEmpty }.count
        let pointCount = hands.reduce(0) { $0 + $1.count }
        log.write(
            "status config=\(config.name) face=\(state.faceSeen) hands=\(usableHands) rawHands=\(hands.count) points=\(pointCount) streak=\(state.streak) " +
                "handFPS=\(handFPS) active=\(state.active) score=\(score) handFace=\(handFaceRatio) handSize=\(handSizeStatus)"
        )
    }
}
