import AppKit
import CoreImage

/// The frame as text: one character per cell on black, brighter cells get denser characters.
///
/// Used only on the camera queue; `characters`, `colour` and `columns` are set there too.
final class AsciiArt {
    struct Characters: Equatable {
        let name: String
        let ramp: [Character]  // darkest first
    }

    enum Colour: String, CaseIterable {
        case green, amber, white
        case picture = "picture colours"

        var ns: NSColor? {
            switch self {
            case .green: .green
            case .amber: NSColor(red: 1, green: 0.69, blue: 0, alpha: 1)
            case .white: .white
            case .picture: nil
            }
        }
    }

    static let characterSets = [
        Characters(name: "classic", ramp: Array(" .:-=+*#%@")),
        Characters(name: "detailed", ramp: Array(" .'`^\",:;Il!i><~+_-?][}{1)(|/tfjrxnuvczXYUJCLQ0OZmwqpdbkhao*#MW&8%B@$")),
        Characters(name: "blocks", ramp: Array(" ░▒▓█")),
        Characters(name: "dots", ramp: Array(" ·•●")),
    ]
    static let columnChoices = [40, 60, 80, 120, 160]

    var characters = characterSets[0]
    var colour = Colour.green
    var columns = 80

    private let context: CIContext

    init(context: CIContext) {
        self.context = context
    }

    func callAsFunction(_ image: CIImage, _ rect: CGRect) -> CIImage {
        // The string drawing makes autoreleased objects; the camera queue does not free them per frame.
        autoreleasepool { render(image, rect) }
    }

    /// White characters drawn once per row, then tinted with one multiply: a colour per character
    /// in the text takes seconds per frame.
    private func render(_ image: CIImage, _ rect: CGRect) -> CIImage {
        let cell = max(rect.width / CGFloat(columns), 4)
        let cols = Int(rect.width / cell)
        let rows = Int(rect.height / cell)
        guard cols > 0, rows > 0 else { return image }
        // One colour per cell: shrink the frame so each cell becomes one pixel. Row 0 is the top.
        let small = image.cropped(to: rect)
            .transformed(
                by: CGAffineTransform(translationX: -rect.minX, y: -rect.minY)
                    .concatenating(CGAffineTransform(scaleX: 1 / cell, y: 1 / cell)))
        let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
        var rgba = [UInt8](repeating: 0, count: cols * rows * 4)
        context.render(
            small, toBitmap: &rgba, rowBytes: cols * 4, bounds: CGRect(x: 0, y: 0, width: cols, height: rows),
            format: .RGBA8, colorSpace: sRGB)

        let w = Int(rect.width)
        let h = Int(rect.height)
        let cg = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: sRGB,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        cg.setFillColor(.black)
        cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: false)
        // One string per row, spaced so each character takes exactly one cell: a draw per character
        // is tens of thousands of draws per frame on a large frame. Menlo has the block and dot
        // characters, so no fallback font changes the spacing.
        let size = cell * 1.25
        let font = NSFont(name: "Menlo", size: size) ?? .monospacedSystemFont(ofSize: size, weight: .regular)
        let advance = ("M" as NSString).size(withAttributes: [.font: font]).width
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white, .kern: cell - advance]
        let ramp = characters.ramp
        var tint = [UInt8](repeating: 255, count: cols * rows * 4)
        for row in 0..<rows {  // the bitmap's first row is the picture's top; Core Graphics counts from the bottom
            var line = ""
            for col in 0..<cols {
                let i = (row * cols + col) * 4
                let (r, g, b) = (Int(rgba[i]), Int(rgba[i + 1]), Int(rgba[i + 2]))
                line.append(ramp[(299 * r + 587 * g + 114 * b) / 1000 * (ramp.count - 1) / 255])
                // Full brightness: the character already shows how bright the cell is.
                let top = max(r, g, b, 1)
                (tint[i], tint[i + 1], tint[i + 2]) = (UInt8(r * 255 / top), UInt8(g * 255 / top), UInt8(b * 255 / top))
            }
            line.draw(at: CGPoint(x: 0, y: CGFloat(rows - 1 - row) * cell - cell / 4), withAttributes: attrs)
        }
        NSGraphicsContext.restoreGraphicsState()
        let text = CIImage(cgImage: cg.makeImage()!)
        let colours: CIImage
        if let fixed = colour.ns {
            colours = CIImage(color: CIColor(color: fixed)!)
        } else {
            colours = CIImage(
                bitmapData: Data(tint), bytesPerRow: cols * 4, size: CGSize(width: cols, height: rows),
                format: .RGBA8, colorSpace: sRGB
            )
            .samplingNearest().transformed(by: CGAffineTransform(scaleX: cell, y: cell))
            .clampedToExtent()
        }
        return text.applyingFilter("CIMultiplyCompositing", parameters: [kCIInputBackgroundImageKey: colours])
            .cropped(to: text.extent)
            .transformed(by: CGAffineTransform(translationX: rect.minX, y: rect.minY))
    }
}
