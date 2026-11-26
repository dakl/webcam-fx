import XCTest

@testable import HandTracking

final class GeometryTests: XCTestCase {
    func testAnchorsMatchTheDetectorOutputCount() {
        XCTAssertEqual(PalmDecoder.anchors.count, 2016)
    }

    func testOverlappingPalmsMergeIntoTheirScoreWeightedAverage() {
        let kp = Array(repeating: SIMD2<Float>(0, 0), count: 7)
        let a = Palm(box: [0, 0, 10, 10], keypoints: kp, score: 0.9)
        let b = Palm(box: [1, 0, 11, 10], keypoints: kp, score: 0.3)
        let far = Palm(box: [50, 50, 60, 60], keypoints: kp, score: 0.6)

        let merged = PalmDecoder.weightedNMS([b, far, a])

        XCTAssertEqual(merged.map(\.score), [0.9, 0.6])
        XCTAssertEqual(merged[0].box.x, 0.25, accuracy: 1e-5)
    }

    func testCropForAnUprightPalmIsUnturnedEnlargedAndShiftedTowardTheFingers() {
        var kp = Array(repeating: SIMD2<Float>(0, 0), count: 7)
        kp[0] = [100, 140]  // wrist
        kp[2] = [100, 60]  // middle finger base, straight above

        let r = rect(for: Palm(box: [60, 60, 140, 140], keypoints: kp, score: 1))

        XCTAssertEqual(r.angle, 0, accuracy: 1e-5)
        XCTAssertEqual(r.w, 208, accuracy: 1e-3)
        XCTAssertEqual(r.cx, 100, accuracy: 1e-3)
        XCTAssertEqual(r.cy, 60, accuracy: 1e-3)
    }

    func testCropTopPointsFromWristTowardFingers() {
        var kp = Array(repeating: SIMD2<Float>(0, 0), count: 7)
        kp[0] = [60, 100]  // wrist on the left
        kp[2] = [140, 100]  // fingers to the right

        let r = rect(for: Palm(box: [60, 60, 140, 140], keypoints: kp, score: 1))
        let top = r.point(u: 0, v: -0.5) - SIMD2(r.cx, r.cy)

        XCTAssertGreaterThan(top.x, 0)
        XCTAssertEqual(top.y, 0, accuracy: 1e-3)
    }
}

final class PinchStateTests: XCTestCase {
    func testGapUnderThresholdForTwoFramesTriggersOnce() {
        var state = PinchState()

        XCTAssertEqual([state.update(2), state.update(2), state.update(2)], [false, true, false])
    }

    func testHoveringBetweenOnAndOffAfterPinchDoesNotRetrigger() {
        var state = PinchState()
        _ = state.update(2)
        _ = state.update(2)

        XCTAssertEqual([state.update(4.5), state.update(3), state.update(3)], [false, false, false])
    }
}

final class PinchGapTests: XCTestCase {
    func testGapLeavesOutDepth() {
        var world = Array(repeating: SIMD3<Float>(0, 0, 0), count: 21)
        world[4] = [0.005, 0, 0.03]  // thumb tip: 0.5 cm across, 3 cm nearer the camera
        world[8] = [0, 0, -0.02]  // index tip
        let hand = Hand(
            landmarks: world, world: world, presence: 1, rightScore: 0,
            rect: RotatedRect(cx: 0, cy: 0, w: 1, h: 1, angle: 0))

        XCTAssertEqual(Pinch.gapCm(hand), 0.5, accuracy: 1e-4)
    }
}
