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
    public let radius: Double
    public let faceBox: FaceBox
    public let stale: Bool
}

public struct HairAlertState: Equatable {
    public let active: Bool
    public let streak: Int
    public let zoneScore: Double?
    public let headZone: HeadZone?
    public let faceSeen: Bool

    public static let empty = HairAlertState(
        active: false,
        streak: 0,
        zoneScore: nil,
        headZone: nil,
        faceSeen: false
    )
}

public final class HairPickingDetector {
    private static let reuleauxVertexY = 1.0 - sqrt(3.0)
    private static let reuleauxRadius = 2.0

    public let triggerSeconds: TimeInterval
    public let headScale: Double
    public let faceHoldSeconds: TimeInterval

    private(set) public var streak = 0
    private var closeStartedAt: TimeInterval?
    private var lastFace: FaceBox?
    private var lastFaceAt: TimeInterval = 0

    public init(
        triggerSeconds: TimeInterval = 0.2,
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
                zoneScore: nil,
                headZone: nil,
                faceSeen: false
            )
        }

        let zone = Self.estimateHeadZone(face: usableFace, headScale: headScale, stale: stale)
        let points = Self.alertPoints(from: hands)
        var zoneScore: Double?

        if !points.isEmpty {
            let upperLimit = zone.faceBox.y + zone.faceBox.height * 1.10
            let scores = points
                .filter { $0.y <= upperLimit }
                .map { Self.headZoneScore(point: $0, in: zone) }
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
        let baseRadiusX = max(48.0, face.width * 0.78 * headScale)
        let baseRadiusY = max(58.0, face.height * 0.82 * headScale)
        let radius = max(baseRadiusX, baseRadiusY) * 1.10

        return HeadZone(
            centerX: face.x + face.width * 0.5,
            centerY: face.y + face.height * 0.38,
            radius: radius,
            faceBox: face,
            stale: stale
        )
    }

    public static func headZoneScore(point: Landmark, in zone: HeadZone) -> Double {
        guard zone.radius > 0 else { return .infinity }

        let normalizedX = (point.x - zone.centerX) / zone.radius
        let normalizedY = (point.y - zone.centerY) / zone.radius
        let vertices = normalizedReuleauxVertices()
        let maxDistance = vertices
            .map { hypot(normalizedX - $0.x, normalizedY - $0.y) }
            .max() ?? .infinity
        return maxDistance / reuleauxRadius
    }

    public static func headZoneBoundaryPoints(for zone: HeadZone, samplesPerArc: Int = 24) -> [Landmark] {
        let samples = max(2, samplesPerArc)
        let vertices = normalizedReuleauxVertices()
        var points: [(x: Double, y: Double)] = []

        appendArc(
            center: vertices[2],
            startAngle: -2.0 * .pi / 3.0,
            endAngle: -.pi / 3.0,
            samples: samples,
            into: &points
        )
        appendArc(
            center: vertices[0],
            startAngle: 0,
            endAngle: .pi / 3.0,
            samples: samples,
            into: &points
        )
        appendArc(
            center: vertices[1],
            startAngle: 2.0 * .pi / 3.0,
            endAngle: .pi,
            samples: samples,
            into: &points
        )

        return points.map { point in
            Landmark(
                x: zone.centerX + point.x * zone.radius,
                y: zone.centerY + point.y * zone.radius
            )
        }
    }

    private static func normalizedReuleauxVertices() -> [(x: Double, y: Double)] {
        [
            (x: -1.0, y: reuleauxVertexY),
            (x: 1.0, y: reuleauxVertexY),
            (x: 0.0, y: 1.0)
        ]
    }

    private static func appendArc(
        center: (x: Double, y: Double),
        startAngle: Double,
        endAngle: Double,
        samples: Int,
        into points: inout [(x: Double, y: Double)]
    ) {
        for index in 0...samples {
            if !points.isEmpty, index == 0 { continue }
            let t = Double(index) / Double(samples)
            let angle = startAngle + (endAngle - startAngle) * t
            points.append(
                (
                    x: center.x + reuleauxRadius * cos(angle),
                    y: center.y + reuleauxRadius * sin(angle)
                )
            )
        }
    }

    private static func alertPoints(from hands: [[String: Landmark]]) -> [Landmark] {
        let names = ["wrist", "thumb_tip", "index_tip", "middle_tip", "ring_tip", "little_tip"]
        return hands.flatMap { hand in
            names.compactMap { hand[$0] }
        }
    }
}
