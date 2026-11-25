import Foundation

/// One tracked hand.
public struct Hand {
    /// 21 points in image pixels; z is depth relative to the wrist, in the same scale.
    public var landmarks: [SIMD3<Float>]
    /// 21 points in metres, centred on the hand.
    public var world: [SIMD3<Float>]
    public var presence: Float
    /// The model's score for a right hand, as MediaPipe reports it (it assumes a mirrored picture).
    public var rightScore: Float
    public var rect: RotatedRect

    public var isRight: Bool { rightScore > 0.5 }
}

/// MediaPipe's hand landmarker on the two ONNX models: palm detection, then per-hand landmarks,
/// and the landmarks give the next frame's crop, so the detector runs only while a hand is missing.
public final class HandTracker {
    public static let landmarkSize = 224
    public var maxHands = 2
    public var minPresence: Float = 0.5

    private let detector: OrtModel
    private let landmarker: OrtModel
    private var tracked: [RotatedRect] = []
    private var detInput = [Float](repeating: 0, count: PalmDecoder.inputSize * PalmDecoder.inputSize * 3)
    private var lmInput = [Float](repeating: 0, count: landmarkSize * landmarkSize * 3)

    public init(models: URL? = nil, coreML: Bool = true) throws {
        let folder = models ?? Bundle.module.url(forResource: "Models", withExtension: nil)!
        // The detector stays on the CPU: Core ML's MLProgram format cannot read one of its
        // convolutions, and the older format is slower than the CPU for this model.
        detector = try OrtModel(url: folder.appendingPathComponent("hand_detector.onnx"), input: "input_1",
                                outputs: ["Identity", "Identity_1"], coreML: false)
        landmarker = try OrtModel(url: folder.appendingPathComponent("hand_landmarks_detector.onnx"), input: "input_1",
                                  outputs: ["Identity", "Identity_1", "Identity_2", "Identity_3"], coreML: coreML)
    }

    /// Track hands in one video frame.
    public func process(_ image: PixelImage) throws -> [Hand] {
        var hands: [Hand] = []
        for r in tracked {
            let hand = try landmarks(image, in: r)
            if hand.presence >= minPresence { hands.append(hand) }
        }
        hands = dropDuplicates(hands)
        if hands.count < maxHands {
            for palm in try detect(image) where hands.count < maxHands {
                let r = rect(for: palm)
                if hands.contains(where: { iou($0.rect.bounds, r.bounds) > 0.5 }) { continue }
                let hand = try landmarks(image, in: r)
                if hand.presence >= minPresence { hands.append(hand) }
            }
        }
        tracked = hands.map { rect(forLandmarks: $0.landmarks) }
        return hands
    }

    /// Hands found by the detector alone, with no tracking. For tests and comparisons.
    public func detectOnly(_ image: PixelImage) throws -> [Hand] {
        try detect(image).prefix(maxHands).map { try landmarks(image, in: rect(for: $0)) }.filter { $0.presence >= minPresence }
    }

    /// Palms in image pixels, best first.
    public func detect(_ image: PixelImage) throws -> [Palm] {
        let side = Float(max(image.width, image.height))
        let padX = (side - Float(image.width)) / 2, padY = (side - Float(image.height)) / 2
        let k = side / Float(PalmDecoder.inputSize)
        image.sample(into: &detInput, size: PalmDecoder.inputSize, map: (k, 0, -padX, 0, k, -padY))
        let s = Int64(PalmDecoder.inputSize)
        let out = try detector.run(&detInput, shape: [1, s, s, 3])
        return PalmDecoder.decode(boxes: out[0], logits: out[1]).map { p in
            var p = p
            p.box = p.box * side - SIMD4(padX, padY, padX, padY)
            p.keypoints = p.keypoints.map { $0 * side - SIMD2(padX, padY) }
            return p
        }
    }

    /// Run the landmark model on the crop `r`.
    public func landmarks(_ image: PixelImage, in r: RotatedRect) throws -> Hand {
        let n = Float(Self.landmarkSize)
        let (c, s) = (cos(r.angle), sin(r.angle))
        // output pixel (u, v) -> rect units (u/n - 0.5, v/n - 0.5) -> image
        let map = (a: c * r.w / n, b: -s * r.h / n, c: r.cx - (c * r.w - s * r.h) / 2,
                   d: s * r.w / n, e: c * r.h / n, f: r.cy - (s * r.w + c * r.h) / 2)
        image.sample(into: &lmInput, size: Self.landmarkSize, map: map)
        let s64 = Int64(Self.landmarkSize)
        let out = try landmarker.run(&lmInput, shape: [1, s64, s64, 3])
        let landmarks = (0..<21).map { i -> SIMD3<Float> in
            let p = r.point(u: out[0][3 * i] / n - 0.5, v: out[0][3 * i + 1] / n - 0.5)
            return [p.x, p.y, out[0][3 * i + 2] / n * r.w]
        }
        let world = (0..<21).map { i -> SIMD3<Float> in
            let (x, y) = (out[3][3 * i], out[3][3 * i + 1])
            return [c * x - s * y, s * x + c * y, out[3][3 * i + 2]]
        }
        return Hand(landmarks: landmarks, world: world, presence: out[1][0], rightScore: out[2][0], rect: r)
    }

    /// Two crops can end up on the same hand; keep the one the model is surer of.
    private func dropDuplicates(_ hands: [Hand]) -> [Hand] {
        var kept: [Hand] = []
        for hand in hands.sorted(by: { $0.presence > $1.presence })
        where !kept.contains(where: { iou($0.rect.bounds, hand.rect.bounds) > 0.5 }) {
            kept.append(hand)
        }
        return kept
    }
}
