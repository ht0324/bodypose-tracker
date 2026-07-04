import XCTest
@testable import BodyPoseTrackerCore

final class DetectionCoreTests: XCTestCase {
    func testDefaultDelayActivatesAfterTwoTenthsSecond() {
        let detector = HairPickingDetector(headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        let hands = [["index_tip": Landmark(x: 170, y: 80)]]

        XCTAssertFalse(detector.update(face: face, hands: hands, now: 0).active)
        XCTAssertFalse(detector.update(face: face, hands: hands, now: 0.19).active)
        XCTAssertTrue(detector.update(face: face, hands: hands, now: 0.2).active)
    }

    func testLeavingZoneResetsContinuousDelay() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        let closeHand = [["index_tip": Landmark(x: 170, y: 80)]]
        let farHand = [["index_tip": Landmark(x: 400, y: 80)]]

        XCTAssertFalse(detector.update(face: face, hands: closeHand, now: 0).active)
        XCTAssertFalse(detector.update(face: face, hands: closeHand, now: 0.2).active)

        let reset = detector.update(face: face, hands: farHand, now: 0.25)
        XCTAssertFalse(reset.active)
        XCTAssertEqual(reset.streak, 0)

        XCTAssertFalse(detector.update(face: face, hands: closeHand, now: 0.4).active)
        XCTAssertFalse(detector.update(face: face, hands: closeHand, now: 0.69).active)
        XCTAssertTrue(detector.update(face: face, hands: closeHand, now: 0.7).active)
    }

    func testFarHandDoesNotActivate() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        let hands = [["index_tip": Landmark(x: 400, y: 80)]]

        let state = detector.update(face: face, hands: hands, now: 0)

        XCTAssertFalse(state.active)
        XCTAssertGreaterThan(state.zoneScore ?? 0, 1.0)
    }

    func testLargeNearCameraHandDoesNotActivate() {
        let detector = HairPickingDetector(triggerSeconds: 0.2, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        let largeHand = [[
            "wrist": Landmark(x: 90, y: 120),
            "thumb_tip": Landmark(x: 230, y: 100),
            "index_tip": Landmark(x: 170, y: 80),
            "middle_tip": Landmark(x: 180, y: 20),
            "ring_tip": Landmark(x: 210, y: 50),
            "little_tip": Landmark(x: 225, y: 85)
        ]]

        XCTAssertFalse(detector.update(face: face, hands: largeHand, now: 0).active)
        XCTAssertFalse(detector.update(face: face, hands: largeHand, now: 0.2).active)
        let state = detector.update(face: face, hands: largeHand, now: 0.4)

        XCTAssertFalse(state.active)
        XCTAssertEqual(state.streak, 0)
        XCTAssertGreaterThan(state.handFaceRatio ?? 0, 1.3)
        XCTAssertFalse(state.handSizeAccepted)
        XCTAssertNil(state.zoneScore)
    }

    func testSameSizeHandCanActivateAtDefaultRatio() {
        let detector = HairPickingDetector(triggerSeconds: 0.2, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        let sameSizeHand = [[
            "wrist": Landmark(x: 95, y: 110),
            "thumb_tip": Landmark(x: 160, y: 100),
            "index_tip": Landmark(x: 170, y: 80),
            "middle_tip": Landmark(x: 180, y: 30),
            "ring_tip": Landmark(x: 190, y: 65),
            "little_tip": Landmark(x: 195, y: 90)
        ]]

        XCTAssertFalse(detector.update(face: face, hands: sameSizeHand, now: 0).active)
        let state = detector.update(face: face, hands: sameSizeHand, now: 0.2)

        XCTAssertTrue(state.active)
        XCTAssertEqual(state.handFaceRatio ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertTrue(state.handSizeAccepted)
        XCTAssertLessThan(state.zoneScore ?? 999, 1.0)
    }

    func testUpdatingHandFaceRatioChangesAcceptance() {
        let detector = HairPickingDetector(
            triggerSeconds: 0,
            headScale: 1.4,
            faceHoldSeconds: 1.0,
            maxHandFaceRatio: 0.95
        )
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        let sameSizeHand = [[
            "wrist": Landmark(x: 95, y: 110),
            "thumb_tip": Landmark(x: 160, y: 100),
            "index_tip": Landmark(x: 170, y: 80),
            "middle_tip": Landmark(x: 180, y: 30),
            "ring_tip": Landmark(x: 190, y: 65),
            "little_tip": Landmark(x: 195, y: 90)
        ]]

        XCTAssertFalse(detector.update(face: face, hands: sameSizeHand, now: 0).handSizeAccepted)

        detector.setMaxHandFaceRatio(1.3)
        let state = detector.update(face: face, hands: sameSizeHand, now: 0.1)

        XCTAssertTrue(state.handSizeAccepted)
        XCTAssertEqual(detector.maxHandFaceRatio, 1.3, accuracy: 0.0001)
        XCTAssertEqual(state.handFaceRatio ?? -1, 1.0, accuracy: 0.0001)
        XCTAssertLessThan(state.zoneScore ?? 999, 1.0)
    }

    func testHeadZoneCanShrinkToConfigurableMinimumRadius() {
        let face = FaceBox(x: 100, y: 100, width: 20, height: 20)
        let zone = HairPickingDetector.estimateHeadZone(face: face, headScale: 1.4, minRadius: 40)

        XCTAssertEqual(zone.radius, 40, accuracy: 0.0001)
    }

    func testReuleauxZoneCatchesUpperHairAreaAndTapersLowerSide() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        let zone = HairPickingDetector.estimateHeadZone(face: face, headScale: 1.4)
        let upperSidePoint = Landmark(
            x: zone.centerX - zone.radius * 0.85,
            y: zone.centerY - zone.radius * 0.70
        )
        let lowerSidePoint = Landmark(
            x: zone.centerX - zone.radius * 0.85,
            y: zone.centerY + zone.radius * 0.70
        )

        let oldCircleScore = hypot(
            (upperSidePoint.x - zone.centerX) / zone.radius,
            (upperSidePoint.y - zone.centerY) / zone.radius
        )
        let state = detector.update(face: face, hands: [["index_tip": upperSidePoint]], now: 0)

        XCTAssertGreaterThan(oldCircleScore, 1.0)
        XCTAssertLessThan(state.zoneScore ?? 999, 1.0)
        XCTAssertGreaterThan(HairPickingDetector.headZoneScore(point: lowerSidePoint, in: zone), 1.0)
    }

    func testFaceHoldCoversBriefOcclusion() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        _ = detector.update(face: face, hands: [], now: 0)

        XCTAssertFalse(detector.update(face: nil, hands: [["index_tip": Landmark(x: 170, y: 80)]], now: 0.5).active)
        let state = detector.update(face: nil, hands: [["index_tip": Landmark(x: 170, y: 80)]], now: 0.8)

        XCTAssertTrue(state.active)
        XCTAssertTrue(state.headZone?.stale ?? false)
    }

    func testFaceHoldExpiresRelativeToObservationTime() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        _ = detector.update(face: face, faceObservedAt: 0, hands: [], now: 0.9)

        let state = detector.update(face: nil, hands: [["index_tip": Landmark(x: 170, y: 80)]], now: 1.2)

        XCTAssertFalse(state.active)
        XCTAssertNil(state.headZone)
    }

    func testReSuppliedHeldFaceStillCoversHoldWindow() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        _ = detector.update(face: face, faceObservedAt: 0, hands: [], now: 0.5)

        let state = detector.update(face: nil, hands: [["index_tip": Landmark(x: 170, y: 80)]], now: 0.9)

        XCTAssertNotNil(state.headZone)
        XCTAssertTrue(state.headZone?.stale ?? false)
    }

    func testFaceHoldExpires() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        _ = detector.update(face: face, hands: [], now: 0)

        let state = detector.update(face: nil, hands: [["index_tip": Landmark(x: 170, y: 80)]], now: 1.5)

        XCTAssertFalse(state.active)
        XCTAssertNil(state.headZone)
    }
}
