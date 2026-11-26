import CoreImage
import CoreImage.CIFilterBuiltins
import Vision

/// You as an 8-bit character. Vision cuts the person out of the frame; the person gets big
/// pixels in the 32-colour ENDESGA 32 palette and a dark one-pixel outline, the background the
/// same pixels darker.
final class PixelArt {
    static let blocksAcross: CGFloat = 64

    private let palette = PixelArt.paletteImage()

    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    func callAsFunction(_ image: CIImage, _ rect: CGRect) -> CIImage {
        let block = max((rect.width / Self.blocksAcross).rounded(), 6)
        let blocks = pixellate(image.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 1.15, kCIInputContrastKey: 1.05,
        ]), block, rect)
        let art = palettize(blocks)
        let background = art.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.5])
        guard let person = personMask(image, rect) else { return art }

        // The mask in whole blocks, and one block wider for the outline.
        let body = threshold(pixellate(person, block, rect))
        let grown = threshold(pixellate(body.applyingFilter("CIMorphologyMaximum", parameters: [kCIInputRadiusKey: block]),
                                        block, rect))
        let outlined = blend(CIImage(color: .black), over: background, mask: grown)
        return blend(art, over: outlined, mask: body)
    }

    /// 1 where Vision sees a person, 0 elsewhere, covering `rect`.
    private func personMask(_ image: CIImage, _ rect: CGRect) -> CIImage? {
        let crop = image.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY))
        try? VNImageRequestHandler(ciImage: crop).perform([request])
        guard let buffer = request.results?.first?.pixelBuffer else { return nil }
        let mask = CIImage(cvPixelBuffer: buffer)
        return mask.transformed(by: CGAffineTransform(scaleX: rect.width / mask.extent.width, y: rect.height / mask.extent.height)
            .concatenating(CGAffineTransform(translationX: rect.minX, y: rect.minY)))
    }

    private func pixellate(_ image: CIImage, _ block: CGFloat, _ rect: CGRect) -> CIImage {
        let f = CIFilter.pixellate()
        f.inputImage = image.clampedToExtent()
        f.center = rect.origin  // blocks line up with the frame, the same for picture and mask
        f.scale = Float(block)
        return f.outputImage!
    }

    private func palettize(_ image: CIImage) -> CIImage {
        let f = CIFilter.palettize()
        f.inputImage = image
        f.paletteImage = palette
        f.perceptual = true
        return f.outputImage!
    }

    private func threshold(_ image: CIImage) -> CIImage {
        let f = CIFilter.colorThreshold()
        f.inputImage = image
        f.threshold = 0.5
        return f.outputImage!
    }

    private func blend(_ top: CIImage, over bottom: CIImage, mask: CIImage) -> CIImage {
        let f = CIFilter.blendWithMask()
        f.inputImage = top
        f.backgroundImage = bottom
        f.maskImage = mask
        return f.outputImage!
    }

    /// The ENDESGA 32 palette (by Endesga), as a 32 x 1 picture.
    private static func paletteImage() -> CIImage {
        let hex: [UInt32] = [
            0xBE4A2F, 0xD77643, 0xEAD4AA, 0xE4A672, 0xB86F50, 0x733E39, 0x3E2731, 0xA22633,
            0xE43B44, 0xF77622, 0xFEAE34, 0xFEE761, 0x63C74D, 0x3E8948, 0x265C42, 0x193C3E,
            0x124E89, 0x0099DB, 0x2CE8F5, 0xFFFFFF, 0xC0CBDC, 0x8B9BB4, 0x5A6988, 0x3A4466,
            0x262B44, 0x181425, 0xFF0044, 0x68386C, 0xB55088, 0xF6757A, 0xE8B796, 0xC28569,
        ]
        let bytes = hex.flatMap { c -> [UInt8] in [UInt8(c >> 16 & 0xFF), UInt8(c >> 8 & 0xFF), UInt8(c & 0xFF), 255] }
        return CIImage(bitmapData: Data(bytes), bytesPerRow: hex.count * 4,
                       size: CGSize(width: hex.count, height: 1), format: .RGBA8,
                       colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }
}
