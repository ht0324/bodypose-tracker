import XCTest
import BodyPoseTrackerCore

final class DetectionCoreTests: XCTestCase {
    private let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
    private let closeHand = [["index_tip": Landmark(x: 170, y: 80)]]

    func testLeavingZoneResetsContinuousDelay() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let farHand = [["index_tip": Landmark(x: 400, y: 80)]]

        XCTAssertFalse(detector.update(face: face, hands: closeHand, now: 0).active)
        XCTAssertFalse(detector.update(face: face, hands: closeHand, now: 0.2).active)

        let reset = detector.update(face: face, hands: farHand, now: 0.25)
        XCTAssertFalse(reset.active)
        XCTAssertEqual(reset.streak, 0)
        XCTAssertGreaterThan(reset.zoneScore ?? 0, 1.0)

        XCTAssertFalse(detector.update(face: face, hands: closeHand, now: 0.4).active)
        XCTAssertFalse(detector.update(face: face, hands: closeHand, now: 0.69).active)
        XCTAssertTrue(detector.update(face: face, hands: closeHand, now: 0.7).active)
    }

    func testLargeNearCameraHandDoesNotActivate() {
        let detector = HairPickingDetector(triggerSeconds: 0, headScale: 1.4, faceHoldSeconds: 1.0)
        let largeHand = [[
            "wrist": Landmark(x: 90, y: 120),
            "thumb_tip": Landmark(x: 230, y: 100),
            "index_tip": Landmark(x: 170, y: 80),
            "middle_tip": Landmark(x: 180, y: 20),
            "ring_tip": Landmark(x: 210, y: 50),
            "little_tip": Landmark(x: 225, y: 85)
        ]]

        let state = detector.update(face: face, hands: largeHand, now: 0)

        XCTAssertFalse(state.active)
        XCTAssertEqual(state.streak, 0)
        XCTAssertGreaterThan(state.handFaceRatio ?? 0, 1.3)
        XCTAssertFalse(state.handSizeAccepted)
        XCTAssertNil(state.zoneScore)
    }

    func testDefaultAlertTimingAndLiveHandSizeLimit() {
        let detector = HairPickingDetector(headScale: 1.4, faceHoldSeconds: 1.0)
        let sameSizeHand = [[
            "wrist": Landmark(x: 95, y: 110),
            "thumb_tip": Landmark(x: 160, y: 100),
            "index_tip": Landmark(x: 170, y: 80),
            "middle_tip": Landmark(x: 180, y: 30),
            "ring_tip": Landmark(x: 190, y: 65),
            "little_tip": Landmark(x: 195, y: 90)
        ]]

        XCTAssertFalse(detector.update(face: face, hands: sameSizeHand, now: 0).active)
        XCTAssertFalse(detector.update(face: face, hands: sameSizeHand, now: 0.19).active)
        let state = detector.update(face: face, hands: sameSizeHand, now: 0.2)

        XCTAssertTrue(state.active)
        XCTAssertEqual(state.handFaceRatio ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertTrue(state.handSizeAccepted)
        XCTAssertLessThan(state.zoneScore ?? 999, 1.0)

        let strictDetector = HairPickingDetector(
            triggerSeconds: 0,
            headScale: 1.4,
            faceHoldSeconds: 1.0,
            maxHandFaceRatio: 0.95
        )
        let rejected = strictDetector.update(face: face, hands: sameSizeHand, now: 0)
        XCTAssertFalse(rejected.active)
        XCTAssertFalse(rejected.handSizeAccepted)

        strictDetector.setMaxHandFaceRatio(1.3)
        XCTAssertTrue(strictDetector.update(face: face, hands: sameSizeHand, now: 0.1).active)
    }

    func testHeadZoneCanShrinkToConfigurableMinimumRadius() {
        let face = FaceBox(x: 100, y: 100, width: 20, height: 20)
        let zone = HairPickingDetector.estimateHeadZone(face: face, headScale: 1.4, minRadius: 40)

        XCTAssertEqual(zone.radius, 40, accuracy: 0.0001)
    }

    func testReuleauxZoneCatchesUpperHairAreaAndTapersLowerSide() {
        let detector = HairPickingDetector(triggerSeconds: 0, headScale: 1.4, faceHoldSeconds: 1.0)
        let upperSide = [["index_tip": Landmark(x: 43, y: 50)]]
        // Both points pass the separate vertical cutoff at y = 210.
        let lowerSide = [["index_tip": Landmark(x: 43, y: 207)]]

        XCTAssertTrue(detector.update(face: face, hands: upperSide, now: 0).active)
        let outside = detector.update(face: face, hands: lowerSide, now: 0.1)
        XCTAssertFalse(outside.active)
        XCTAssertGreaterThan(outside.zoneScore ?? 0, 1.0)
    }

    func testFaceHoldCoversOcclusionAndExpiresFromObservationTime() {
        let observations: [(observedAt: Double?, suppliedAt: Double)] = [(nil, 10), (10, 10.6)]
        for observation in observations {
            let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
            // Start with either a fresh face or a cached face from the capture controller.
            _ = detector.update(face: face, faceObservedAt: observation.observedAt, hands: [], now: observation.suppliedAt)
            XCTAssertFalse(detector.update(face: nil, hands: closeHand, now: 10.7).active)
            let held = detector.update(face: nil, hands: closeHand, now: 11)
            XCTAssertTrue(held.active)
            XCTAssertEqual(held.headZone?.stale, true)

            let expired = detector.update(face: nil, hands: closeHand, now: 11.1)
            XCTAssertFalse(expired.active)
            XCTAssertNil(expired.headZone)
            XCTAssertEqual(expired.streak, 0)
        }
    }
}
