import Foundation

/// One Euro filter (Casiez et al. 2012): strong smoothing while a value is still, little while it moves fast.
///
/// `minCutoff` (Hz) sets the smoothing at rest; `beta` sets how fast the cutoff rises with speed.
/// Values and speeds are in the units you feed; scale them so `beta` means the same at every distance.
public struct OneEuroFilter {
    public var minCutoff: Float
    public var beta: Float
    public var derivativeCutoff: Float
    private var last: (time: Double, value: SIMD3<Float>, speed: SIMD3<Float>)?

    public init(minCutoff: Float, beta: Float, derivativeCutoff: Float = 1) {
        (self.minCutoff, self.beta, self.derivativeCutoff) = (minCutoff, beta, derivativeCutoff)
    }

    private static func alpha(_ cutoff: Float, _ dt: Float) -> Float {
        let tau = 1 / (2 * .pi * cutoff)
        return 1 / (1 + tau / dt)
    }

    public mutating func callAsFunction(_ value: SIMD3<Float>, at time: Double) -> SIMD3<Float> {
        guard let previous = last, time > previous.time else {
            last = (time, value, .zero)
            return value
        }
        let dt = Float(time - previous.time)
        let speed = previous.speed + Self.alpha(derivativeCutoff, dt) * ((value - previous.value) / dt - previous.speed)
        let magnitude = (speed * speed).sum().squareRoot()
        let a = Self.alpha(minCutoff + beta * magnitude, dt)
        let smoothed = previous.value + a * (value - previous.value)
        last = (time, smoothed, speed)
        return smoothed
    }
}

/// Smooths the 21 image and world points of one hand over time.
public struct HandSmoother {
    private var image = Array(repeating: OneEuroFilter(minCutoff: 0.05, beta: 80), count: 21)
    private var world = Array(repeating: OneEuroFilter(minCutoff: 0.1, beta: 40), count: 21)

    public init() {}

    /// Image points are filtered in units of the hand crop's size, so the result does not depend
    /// on how near the hand is to the camera.
    public mutating func callAsFunction(_ hand: Hand, at time: Double) -> Hand {
        var out = hand
        let size = max(hand.rect.w, 1)
        for i in 0..<21 {
            out.landmarks[i] = image[i](hand.landmarks[i] / size, at: time) * size
            out.world[i] = world[i](hand.world[i], at: time)
        }
        return out
    }
}
