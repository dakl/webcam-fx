import Foundation

/// Choose from `count` items with one hand.
///
/// A quick pinch moves to the next item. A pinch held for `holdSeconds` opens a list: moving the
/// pinched hand down or up moves the selection, and opening the fingers keeps it.
public struct PinchMenu {
    public static let holdSeconds = 0.4
    /// Moving the pinch this fraction of the picture height moves one item.
    public static let step: Float = 0.06

    public enum Event { case next, chosen }

    public let count: Int
    public var selected: Int
    public private(set) var isOpen = false
    public private(set) var startY: Float = 0
    public private(set) var startIndex = 0
    private var startedAt: Double?

    public init(count: Int, selected: Int = 0) {
        self.count = count
        self.selected = selected
    }

    /// Feed one frame: is the hand pinched, the pinch's height (0 top, 1 bottom), the time in seconds.
    public mutating func update(pinched: Bool, y: Float, now: Double) -> Event? {
        if pinched {
            if startedAt == nil {
                (startedAt, startY, startIndex) = (now, y, selected)
            }
            if !isOpen, let start = startedAt, now - start >= Self.holdSeconds {
                isOpen = true
            }
            if isOpen {
                let steps = Int(((y - startY) / Self.step).rounded())
                selected = min(max(startIndex + steps, 0), count - 1)
            }
            return nil
        }
        guard startedAt != nil else { return nil }
        let event: Event = isOpen ? .chosen : .next
        if event == .next { selected = (selected + 1) % count }
        isOpen = false
        startedAt = nil
        return event
    }
}

/// The rectangle made by the thumb and index tips of two hands, held still while a hand pinches.
public struct FingerFrame {
    public static let smoothing: Float = 0.7
    public static let freezeBelowCm: Float = 7  // hold the frame still while a hand's tips are this close
    public static let holdSeconds = 0.3  // keep the frame this long when tracking drops a hand
    public static let minSide: Float = 40  // px

    /// xmin, ymin, xmax, ymax in image pixels.
    public private(set) var box: SIMD4<Float>?
    private var seenAt = -Double.infinity

    public init() {}

    /// Feed one frame's hands; returns the frame if it is big enough to use.
    public mutating func update(_ hands: [Hand], now: Double) -> SIMD4<Float>? {
        if hands.count == 2 {
            seenAt = now
            let closing = hands.contains { Pinch.gapCm($0) < Self.freezeBelowCm }
            if !(closing && box != nil) {
                let tips = hands.flatMap { [$0.landmarks[4], $0.landmarks[8]] }
                let xs = tips.map(\.x)
                let ys = tips.map(\.y)
                let new = SIMD4(xs.min()!, ys.min()!, xs.max()!, ys.max()!)
                box = box.map { Self.smoothing * $0 + (1 - Self.smoothing) * new } ?? new
            }
        } else if now - seenAt > Self.holdSeconds {
            box = nil
        }
        guard let b = box, b.z - b.x > Self.minSide, b.w - b.y > Self.minSide else { return nil }
        return b
    }
}
