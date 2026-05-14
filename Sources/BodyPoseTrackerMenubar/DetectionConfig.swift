import AVFoundation
import Foundation

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
    let maxHandFaceRatio: Double
    let minHeadRadius: Double

    var processingFPS: Double {
        max(faceFPS, activeHandFPS)
    }

    func replacing(maxHandFaceRatio: Double) -> DetectionConfig {
        DetectionConfig(
            name: name,
            capturePreset: capturePreset,
            cameraFPS: cameraFPS,
            faceFPS: faceFPS,
            idleHandFPS: idleHandFPS,
            activeHandFPS: activeHandFPS,
            handBoostHoldSeconds: handBoostHoldSeconds,
            maxHands: maxHands,
            triggerSeconds: triggerSeconds,
            headScale: headScale,
            faceHoldSeconds: faceHoldSeconds,
            maxHandFaceRatio: max(0, maxHandFaceRatio),
            minHeadRadius: minHeadRadius
        )
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
        triggerSeconds: 0.2,
        headScale: 1.4,
        faceHoldSeconds: 1.0,
        maxHandFaceRatio: 1.3,
        minHeadRadius: 40
    )
}
