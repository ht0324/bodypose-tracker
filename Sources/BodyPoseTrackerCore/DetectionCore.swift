import Foundation

public struct Landmark: Equatable {
    public let x: Double
    public let y: Double
    public let confidence: Double

    public init(x: Double, y: Double, confidence: Double = 1.0) {
        self.x = x
        self.y = y
        self.confidence = confidence
    }
}

public struct FaceBox: Equatable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let confidence: Double

    public init(x: Double, y: Double, width: Double, height: Double, confidence: Double = 1.0) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.confidence = confidence
    }
}

public struct HeadZone: Equatable {
    public let centerX: Double
    public let centerY: Double
    public let radiusX: Double
    public let radiusY: Double
    public let faceBox: FaceBox
    public let stale: Bool
}

public struct HairAlertState: Equatable {
    public let active: Bool
    public let streak: Int
    public let minDistance: Double?
    public let zoneScore: Double?
    public let headZone: HeadZone?
    public let faceSeen: Bool

    public static let empty = HairAlertState(
        active: false,
        streak: 0,
        minDistance: nil,
        zoneScore: nil,
        headZone: nil,
        faceSeen: false
    )
}

public final class HairPickingDetector {
    public let triggerSeconds: TimeInterval
    public let headScale: Double
    public let faceHoldSeconds: TimeInterval

    private(set) public var streak = 0
    private var closeStartedAt: TimeInterval?
    private var lastFace: FaceBox?
    private var lastFaceAt: TimeInterval = 0

    public init(
        triggerSeconds: TimeInterval = 0.3,
        headScale: Double,
        faceHoldSeconds: TimeInterval
    ) {
        self.triggerSeconds = max(0, triggerSeconds)
        self.headScale = headScale
        self.faceHoldSeconds = faceHoldSeconds
    }

    public func update(face: FaceBox?, hands: [[String: Landmark]], now: TimeInterval) -> HairAlertState {
        let faceSeen = face != nil
        let usableFace: FaceBox
        let stale: Bool

        if let face {
            lastFace = face
            lastFaceAt = now
            usableFace = face
            stale = false
        } else if let lastFace, now - lastFaceAt <= faceHoldSeconds {
            usableFace = lastFace
            stale = true
        } else {
            resetCloseTracking()
            return HairAlertState(
                active: false,
                streak: streak,
                minDistance: nil,
                zoneScore: nil,
                headZone: nil,
                faceSeen: false
            )
        }

        let zone = Self.estimateHeadZone(face: usableFace, headScale: headScale, stale: stale)
        let points = Self.alertPoints(from: hands)
        var minDistance: Double?
        var zoneScore: Double?

        if !points.isEmpty {
            let distances = points.map { hypot($0.x - zone.centerX, $0.y - zone.centerY) }
            minDistance = distances.min()

            let upperLimit = zone.faceBox.y + zone.faceBox.height * 1.10
            let scores = points
                .filter { $0.y <= upperLimit }
                .map { point in
                    hypot(
                        (point.x - zone.centerX) / zone.radiusX,
                        (point.y - zone.centerY) / zone.radiusY
                    )
                }
            zoneScore = scores.min()
        }

        let close = (zoneScore ?? .infinity) <= 1.0
        if close {
            if closeStartedAt == nil {
                closeStartedAt = now
            }
            streak += 1
        } else {
            resetCloseTracking()
        }

        return HairAlertState(
            active: closeStartedAt.map { now - $0 >= triggerSeconds - 1e-9 } ?? false,
            streak: streak,
            minDistance: minDistance,
            zoneScore: zoneScore,
            headZone: zone,
            faceSeen: faceSeen
        )
    }

    private func resetCloseTracking() {
        streak = 0
        closeStartedAt = nil
    }

    public static func estimateHeadZone(face: FaceBox, headScale: Double, stale: Bool = false) -> HeadZone {
        HeadZone(
            centerX: face.x + face.width * 0.5,
            centerY: face.y + face.height * 0.38,
            radiusX: max(48.0, face.width * 0.78 * headScale),
            radiusY: max(58.0, face.height * 0.82 * headScale),
            faceBox: face,
            stale: stale
        )
    }

    private static func alertPoints(from hands: [[String: Landmark]]) -> [Landmark] {
        let names = ["wrist", "thumb_tip", "index_tip", "middle_tip", "ring_tip", "little_tip"]
        return hands.flatMap { hand in
            names.compactMap { hand[$0] }
        }
    }
}
