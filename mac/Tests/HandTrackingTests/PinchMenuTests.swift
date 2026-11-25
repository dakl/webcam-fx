import XCTest
@testable import HandTracking

final class PinchMenuTests: XCTestCase {
    func testQuickPinchMovesToNextItemOnRelease() {
        var menu = PinchMenu(count: 5)
        _ = menu.update(pinched: true, y: 0.5, now: 0)

        XCTAssertEqual(menu.update(pinched: false, y: 0.5, now: 0.2), .next)
        XCTAssertEqual(menu.selected, 1)
    }

    func testQuickPinchOnLastItemWrapsToFirst() {
        var menu = PinchMenu(count: 3, selected: 2)
        _ = menu.update(pinched: true, y: 0.5, now: 0)
        _ = menu.update(pinched: false, y: 0.5, now: 0.1)

        XCTAssertEqual(menu.selected, 0)
    }

    func testMovingHeldPinchDownTwoStepsSelectsTwoItemsLater() {
        var menu = PinchMenu(count: 5, selected: 1)
        _ = menu.update(pinched: true, y: 0.5, now: 0)
        _ = menu.update(pinched: true, y: 0.5, now: 0.5)
        _ = menu.update(pinched: true, y: 0.62, now: 0.6)

        XCTAssertTrue(menu.isOpen)
        XCTAssertEqual(menu.selected, 3)
    }

    func testMovingFarPastTheEndStopsAtLastItem() {
        var menu = PinchMenu(count: 5, selected: 1)
        _ = menu.update(pinched: true, y: 0.5, now: 0)
        _ = menu.update(pinched: true, y: 0.5, now: 0.5)
        _ = menu.update(pinched: true, y: 1.0, now: 0.6)

        XCTAssertEqual(menu.selected, 4)
    }

    func testReleasingOpenListKeepsSelectionAndReportsChosen() {
        var menu = PinchMenu(count: 5)
        _ = menu.update(pinched: true, y: 0.5, now: 0)
        _ = menu.update(pinched: true, y: 0.56, now: 0.5)

        XCTAssertEqual(menu.update(pinched: false, y: 0.56, now: 0.7), .chosen)
        XCTAssertEqual(menu.selected, 1)
        XCTAssertFalse(menu.isOpen)
    }
}

final class FingerFrameTests: XCTestCase {
    private func hand(tips: (SIMD2<Float>, SIMD2<Float>), gapCm: Float) -> Hand {
        var points = Array(repeating: SIMD3<Float>(0, 0, 0), count: 21)
        points[4] = [tips.0.x, tips.0.y, 0]
        points[8] = [tips.1.x, tips.1.y, 0]
        var world = Array(repeating: SIMD3<Float>(0, 0, 0), count: 21)
        world[4] = [gapCm / 100, 0, 0]
        return Hand(landmarks: points, world: world, presence: 1, rightScore: 0,
                    rect: RotatedRect(cx: 0, cy: 0, w: 1, h: 1, angle: 0))
    }

    func testTwoOpenHandsMakeTheBoxAroundTheirTips() {
        var frame = FingerFrame()
        let hands = [hand(tips: ([100, 300], [120, 100]), gapCm: 10), hand(tips: ([500, 320], [480, 90]), gapCm: 10)]

        XCTAssertEqual(frame.update(hands, now: 0), SIMD4(100, 90, 500, 320))
    }

    func testBoxHoldsStillWhileAHandCloses() {
        var frame = FingerFrame()
        _ = frame.update([hand(tips: ([100, 300], [120, 100]), gapCm: 10), hand(tips: ([500, 320], [480, 90]), gapCm: 10)], now: 0)
        let closing = [hand(tips: ([300, 200], [310, 190]), gapCm: 2), hand(tips: ([500, 320], [480, 90]), gapCm: 10)]

        XCTAssertEqual(frame.update(closing, now: 0.03), SIMD4(100, 90, 500, 320))
    }

    func testBoxDisappearsWhenAHandIsGoneLongerThanTheHoldTime() {
        var frame = FingerFrame()
        _ = frame.update([hand(tips: ([100, 300], [120, 100]), gapCm: 10), hand(tips: ([500, 320], [480, 90]), gapCm: 10)], now: 0)
        _ = frame.update([], now: 0.2)

        XCTAssertNil(frame.update([], now: 0.4))
    }
}
