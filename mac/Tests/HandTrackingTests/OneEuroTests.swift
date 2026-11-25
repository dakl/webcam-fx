import XCTest
@testable import HandTracking

final class OneEuroTests: XCTestCase {
    func testJitterAroundAStillValueIsDamped() {
        var filter = OneEuroFilter(minCutoff: 0.1, beta: 40)
        let jitter: [Float] = [0.04, 0.06, 0.04, 0.06, 0.04, 0.06, 0.04, 0.06, 0.04, 0.06]
        let out = jitter.enumerated().map { filter(SIMD3($1, 0, 0), at: Double($0) / 30).x }

        let settled = out.suffix(4)
        XCTAssertLessThan(settled.max()! - settled.min()!, 0.005)  // input swings 0.02
    }

    func testAStepIsFollowedWithinAFewFrames() {
        var filter = OneEuroFilter(minCutoff: 0.1, beta: 40)
        _ = filter(SIMD3(0.10, 0, 0), at: 0)
        let out = (1...10).map { filter(SIMD3(0.02, 0, 0), at: Double($0) / 30).x }

        XCTAssertLessThan(out.last!, 0.035)
    }
}
