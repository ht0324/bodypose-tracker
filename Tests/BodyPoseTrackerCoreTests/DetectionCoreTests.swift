import XCTest
@testable import BodyPoseTrackerCore

final class DetectionCoreTests: XCTestCase {
    func testHandNearHeadActivatesAfterContinuousDelay() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        let hands = [["index_tip": Landmark(x: 170, y: 80)]]

        XCTAssertFalse(detector.update(face: face, hands: hands, now: 0).active)
        XCTAssertFalse(detector.update(face: face, hands: hands, now: 0.29).active)
        let third = detector.update(face: face, hands: hands, now: 0.3)

        XCTAssertTrue(third.active)
        XCTAssertEqual(third.streak, 3)
        XCTAssertLessThan(third.zoneScore ?? 999, 1.0)
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

    func testFaceHoldCoversBriefOcclusion() {
        let detector = HairPickingDetector(triggerSeconds: 0.3, headScale: 1.4, faceHoldSeconds: 1.0)
        let face = FaceBox(x: 100, y: 100, width: 100, height: 100)
        _ = detector.update(face: face, hands: [], now: 0)

        XCTAssertFalse(detector.update(face: nil, hands: [["index_tip": Landmark(x: 170, y: 80)]], now: 0.5).active)
        let state = detector.update(face: nil, hands: [["index_tip": Landmark(x: 170, y: 80)]], now: 0.8)

        XCTAssertTrue(state.active)
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
