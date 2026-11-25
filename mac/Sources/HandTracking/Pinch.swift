import Foundation

public enum Pinch {
    public static let onCm: Float = 3.5  // thumb and index tips closer than this start a pinch
    public static let offCm: Float = 5.5  // they must open wider than this before the next pinch counts
    public static let gaugeStartCm: Float = 10  // the on-screen gauge starts filling here
    public static let frames = 2  // frames in a row under onCm, so one noisy frame does not trigger

    /// Distance between the thumb and index tips across the picture, in centimetres.
    ///
    /// Depth (z) is left out: the model guesses it poorly, and on a closed pinch seen from the
    /// front it can put the tips 3–6 cm apart in z.
    public static func gapCm(_ hand: Hand) -> Float {
        let d = SIMD2(hand.world[4].x - hand.world[8].x, hand.world[4].y - hand.world[8].y)
        return (d * d).sum().squareRoot() * 100
    }

    /// 0 when the fingers are far apart, 1 when they are close enough to pinch.
    public static func progress(_ gapCm: Float) -> Float {
        min(max((gaugeStartCm - gapCm) / (gaugeStartCm - onCm), 0), 1)
    }
}

/// One hand's pinch: closed while pinched, so holding a pinch triggers once.
public struct PinchState {
    public private(set) var closed = false
    private var framesUnder = 0

    public init() {}

    /// Feed one frame's finger gap; return true on the frame a new pinch starts.
    public mutating func update(_ gapCm: Float) -> Bool {
        if closed {
            if gapCm > Pinch.offCm { closed = false }
            return false
        }
        framesUnder = gapCm < Pinch.onCm ? framesUnder + 1 : 0
        guard framesUnder >= Pinch.frames else { return false }
        closed = true
        framesUnder = 0
        return true
    }

    /// Forget a pinch in progress; a pinch held while out of view stays closed.
    public mutating func handLost() { framesUnder = 0 }
}
