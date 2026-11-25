import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// The picture effects for inside the finger frame, built on Core Image.
///
/// Each effect gets the camera picture and the frame (Core Image coordinates, origin bottom-left)
/// and returns a picture that covers at least the frame.
struct Effects {
    typealias Apply = (_ image: CIImage, _ rect: CGRect, _ time: Double) -> CIImage

    let all: [(name: String, apply: Apply)]

    init(context: CIContext) {
        all = [
            ("pixelate", { image, rect, _ in
                let f = CIFilter.pixellate()
                f.inputImage = image.clampedToExtent()
                f.center = rect.origin
                f.scale = 12
                return f.outputImage!
            }),
            ("thermal", { image, _, _ in
                let f = CIFilter.thermal()
                f.inputImage = image
                return f.outputImage!
            }),
            ("edges", { image, _, _ in
                let f = CIFilter.edges()
                f.inputImage = image
                f.intensity = 8
                return f.outputImage!.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0])
            }),
            ("ascii", { image, rect, _ in ascii(image, rect, context: context) }),
            ("comic", { image, _, _ in
                let f = CIFilter.comicEffect()
                f.inputImage = image.clampedToExtent()
                return f.outputImage!
            }),
            ("invert", { image, _, _ in
                let f = CIFilter.colorInvert()
                f.inputImage = image
                return f.outputImage!
            }),
            ("rgb split", { image, _, _ in rgbSplit(image, shift: 12) }),
            ("blur", { image, _, _ in
                let f = CIFilter.gaussianBlur()
                f.inputImage = image.clampedToExtent()
                f.radius = 12
                return f.outputImage!
            }),
            ("night vision", { image, rect, _ in nightVision(image, rect) }),
            ("sepia", { image, _, _ in
                let f = CIFilter.sepiaTone()
                f.inputImage = image
                f.intensity = 1
                return f.outputImage!
            }),
            ("posterize", { image, _, _ in
                let f = CIFilter.colorPosterize()
                f.inputImage = image
                f.levels = 4
                return f.outputImage!
            }),
            ("kaleidoscope", { image, rect, time in
                // Three mirrors around a triangle from the frame's middle, slowly turning.
                let f = CIFilter.triangleKaleidoscope()
                f.inputImage = image.clampedToExtent()
                f.point = CGPoint(x: rect.midX, y: rect.midY)
                f.size = Float(min(rect.width, rect.height) / 3)
                f.rotation = Float(time * 0.03 * 2 * .pi)
                f.decay = 1  // 1: no fading away from the middle triangle
                return f.outputImage!
            }),
        ]
    }
}

/// Red moved right, blue moved left, green in place.
private func rgbSplit(_ image: CIImage, shift: CGFloat) -> CIImage {
    func channel(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, dx: CGFloat) -> CIImage {
        let f = CIFilter.colorMatrix()
        f.inputImage = image.clampedToExtent()
        f.rVector = CIVector(x: r, y: 0, z: 0, w: 0)
        f.gVector = CIVector(x: 0, y: g, z: 0, w: 0)
        f.bVector = CIVector(x: 0, y: 0, z: b, w: 0)
        return f.outputImage!.transformed(by: CGAffineTransform(translationX: dx, y: 0))
    }
    let red = channel(1, 0, 0, dx: shift), green = channel(0, 1, 0, dx: 0), blue = channel(0, 0, 1, dx: -shift)
    // Maximum, not addition: addition also adds the alphas, which darkens the result.
    return red.applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: green])
        .applyingFilter("CIMaximumCompositing", parameters: [kCIInputBackgroundImageKey: blue])
}

/// Grey, contrast up, grain, a green tint and dark scanlines every third row.
private func nightVision(_ image: CIImage, _ rect: CGRect) -> CIImage {
    let grey = image.applyingFilter("CIColorControls", parameters: [
        kCIInputSaturationKey: 0, kCIInputContrastKey: 1.6, kCIInputBrightnessKey: 0.05,
    ])
    let grain = CIFilter.randomGenerator().outputImage!
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.15, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0.15, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0.15, y: 0, z: 0, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
        ])
    let green = grain.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: grey])
        .applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.25, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0.25, w: 0),
        ])
    let stripes = CIFilter.stripesGenerator()
    stripes.center = rect.origin
    stripes.color0 = CIColor(red: 1, green: 1, blue: 1)
    stripes.color1 = CIColor(red: 0.5, green: 0.5, blue: 0.5)
    stripes.width = 1.5
    stripes.sharpness = 1
    let scanlines = stripes.outputImage!.transformed(by: CGAffineTransform(rotationAngle: .pi / 2))
    return green.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: scanlines])
}

/// Green characters on black, one per 8 px cell, darker cells get thinner characters.
private func ascii(_ image: CIImage, _ rect: CGRect, context: CIContext) -> CIImage {
    let cell: CGFloat = 8
    let chars = Array(" .:-=+*#%@")
    let cols = Int(rect.width / cell), rows = Int(rect.height / cell)
    guard cols > 0, rows > 0 else { return image }
    // One grey value per cell: shrink the frame so each cell becomes one pixel.
    let small = image.cropped(to: rect)
        .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
            .concatenating(CGAffineTransform(scaleX: 1 / cell, y: 1 / cell)))
    var grey = [UInt8](repeating: 0, count: cols * rows)
    context.render(small.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0]),
                   toBitmap: &grey, rowBytes: cols, bounds: CGRect(x: 0, y: 0, width: cols, height: rows),
                   format: .L8, colorSpace: nil)
    let w = Int(rect.width), h = Int(rect.height)
    let cg = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    cg.setFillColor(.black)
    cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedSystemFont(ofSize: 10, weight: .regular), .foregroundColor: NSColor.green,
    ]
    for row in 0..<rows {  // the bitmap's first row is the picture's top; Core Graphics counts from the bottom
        for col in 0..<cols {
            let index = Int(grey[row * cols + col]) * (chars.count - 1) / 255
            guard index > 0 else { continue }
            String(chars[index]).draw(at: CGPoint(x: CGFloat(col) * cell, y: CGFloat(rows - 1 - row) * cell - 2), withAttributes: attrs)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    return CIImage(cgImage: cg.makeImage()!).transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
}

/// The camera picture with `effect` inside `frame` (image pixels, origin top-left) and a white border.
func compose(_ image: CIImage, frame box: SIMD4<Float>?, effect: Effects.Apply, blackOutside: Bool, time: Double) -> CIImage {
    guard let box else { return image }
    let height = image.extent.height
    let rect = CGRect(x: CGFloat(box.x), y: height - CGFloat(box.w), width: CGFloat(box.z - box.x),
                      height: CGFloat(box.w - box.y)).integral.intersection(image.extent)
    guard !rect.isEmpty else { return image }
    let background = blackOutside ? CIImage(color: .black).cropped(to: image.extent) : image
    // A mask, not `cropped(to:)` plus `composited(over:)`: with some filters (thermal, edges) the
    // full-picture render then leaks the effect outside the frame, although single pixels read right.
    let mask = CIFilter.blendWithMask()
    mask.inputImage = effect(image.cropped(to: rect), rect, time)
    mask.backgroundImage = background
    mask.maskImage = CIImage(color: .white).cropped(to: rect)
    let inside = mask.outputImage!
    let border = [CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 2),
                  CGRect(x: rect.minX, y: rect.maxY - 2, width: rect.width, height: 2),
                  CGRect(x: rect.minX, y: rect.minY, width: 2, height: rect.height),
                  CGRect(x: rect.maxX - 2, y: rect.minY, width: 2, height: rect.height)]
        .reduce(CIImage.empty()) { CIImage(color: .white).cropped(to: $1).composited(over: $0) }
    return border.composited(over: inside).cropped(to: image.extent)
}
