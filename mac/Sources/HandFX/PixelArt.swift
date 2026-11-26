import CoreImage
import CoreImage.CIFilterBuiltins
import PixelGrid
import Vision

/// You as an 8-bit character. The frame is averaged into a grid of blocks, each block takes a
/// palette colour (kept steady between frames, lone blocks cleaned up), Vision's person mask gives
/// you a one-block black outline, and the background gets darker blocks.
///
/// Used only on the camera queue; `palette` and `blocksAcross` are set there too.
final class PixelArt {
    static let blockChoices = [32, 48, 64, 96, 128]

    var palette = Palette.all[0]
    var blocksAcross = 64

    private let context: CIContext
    private var grid = PixelGrid()
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()

    init(context: CIContext) {
        self.context = context
    }

    func callAsFunction(_ image: CIImage, _ rect: CGRect) -> CIImage {
        let block = max(rect.width / CGFloat(blocksAcross), 4)
        let cols = Int((rect.width / block).rounded(.up))
        let rows = Int((rect.height / block).rounded(.up))
        guard cols > 0, rows > 0 else { return image }

        let boosted = image.applyingFilter(
            "CIColorControls",
            parameters: [
                kCIInputSaturationKey: 1.15, kCIInputContrastKey: 1.05,
            ])
        let pixels = shrink(boosted, rect, block, cols, rows, format: .RGBA8, bytesPerPixel: 4)
        let colours = stride(from: 0, to: pixels.count, by: 4).map {
            SIMD3(Float(pixels[$0]), Float(pixels[$0 + 1]), Float(pixels[$0 + 2]))
        }
        let indexes = grid.quantize(colours, cols: cols, rows: rows, palette: palette)
        let body = personMask(image, rect).map { mask in
            shrink(mask, rect, block, cols, rows, format: .L8, bytesPerPixel: 1).map { $0 >= 128 }
        }

        var out = [UInt8](repeating: 255, count: cols * rows * 4)
        for r in 0..<rows {
            for c in 0..<cols {
                let i = r * cols + c
                var colour = palette.colours[indexes[i]]
                if let body, !body[i] {
                    let nearBody = (-1...1).contains { dr in
                        (-1...1).contains { dc in
                            let (nr, nc) = (r + dr, c + dc)
                            return nr >= 0 && nr < rows && nc >= 0 && nc < cols && body[nr * cols + nc]
                        }
                    }
                    colour = nearBody ? .zero : colour * 0.35  // outline, or darker background
                }
                (out[i * 4], out[i * 4 + 1], out[i * 4 + 2]) = (UInt8(colour.x), UInt8(colour.y), UInt8(colour.z))
            }
        }
        let small = CIImage(
            bitmapData: Data(out), bytesPerRow: cols * 4, size: CGSize(width: cols, height: rows),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        // Blow each pixel up to one sharp block; the bitmap's first row (the top) stays on top.
        return small.samplingNearest()
            .transformed(
                by: CGAffineTransform(scaleX: block, y: block)
                    .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    /// The frame averaged down to `cols` x `rows` pixels (Lanczos, so each block is a true average),
    /// read out top row first.
    private func shrink(
        _ image: CIImage, _ rect: CGRect, _ block: CGFloat, _ cols: Int, _ rows: Int,
        format: CIFormat, bytesPerPixel: Int
    ) -> [UInt8] {
        let scaled = image.clampedToExtent().cropped(to: rect)
            .transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
            .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1 / block, kCIInputAspectRatioKey: 1])
        var bytes = [UInt8](repeating: 0, count: cols * rows * bytesPerPixel)
        context.render(
            scaled, toBitmap: &bytes, rowBytes: cols * bytesPerPixel,
            bounds: CGRect(x: 0, y: 0, width: cols, height: rows), format: format,
            colorSpace: format == .L8 ? nil : CGColorSpace(name: CGColorSpace.sRGB))
        return bytes
    }

    /// 1 where Vision sees a person, 0 elsewhere, covering `rect`.
    private func personMask(_ image: CIImage, _ rect: CGRect) -> CIImage? {
        let crop = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        try? VNImageRequestHandler(ciImage: crop).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        return mask.transformed(
            by: CGAffineTransform(scaleX: rect.width / mask.extent.width, y: rect.height / mask.extent.height)
                .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }
}
