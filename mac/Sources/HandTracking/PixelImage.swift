import Foundation

/// A view of 8-bit BGRA pixels, as a camera delivers them. It does not own the memory.
public struct PixelImage {
    public let base: UnsafePointer<UInt8>
    public let width: Int
    public let height: Int
    public let bytesPerRow: Int

    public init(base: UnsafePointer<UInt8>, width: Int, height: Int, bytesPerRow: Int) {
        (self.base, self.width, self.height, self.bytesPerRow) = (base, width, height, bytesPerRow)
    }

    /// Fill `out` with a `size` x `size` RGB picture (0–1 floats, row by row), bilinear, black outside.
    ///
    /// `map` gives the image position, in pixels, of each output pixel's centre: x = a·u + b·v + c,
    /// y = d·u + e·v + f, where (u, v) is the output pixel centre.
    func sample(into out: inout [Float], size: Int, map m: (a: Float, b: Float, c: Float, d: Float, e: Float, f: Float)) {
        out.withUnsafeMutableBufferPointer { dst in
            var o = 0
            for j in 0..<size {
                let v = Float(j) + 0.5
                for i in 0..<size {
                    let u = Float(i) + 0.5
                    let x = m.a * u + m.b * v + m.c - 0.5
                    let y = m.d * u + m.e * v + m.f - 0.5
                    let x0 = Int(x.rounded(.down))
                    let y0 = Int(y.rounded(.down))
                    let fx = x - Float(x0)
                    let fy = y - Float(y0)
                    var r: Float = 0
                    var g: Float = 0
                    var b: Float = 0
                    @inline(__always) func tap(_ xx: Int, _ yy: Int, _ w: Float) {
                        guard xx >= 0, xx < width, yy >= 0, yy < height else { return }
                        let p = base + yy * bytesPerRow + xx * 4
                        b += w * Float(p[0])
                        g += w * Float(p[1])
                        r += w * Float(p[2])
                    }
                    tap(x0, y0, (1 - fx) * (1 - fy))
                    tap(x0 + 1, y0, fx * (1 - fy))
                    tap(x0, y0 + 1, (1 - fx) * fy)
                    tap(x0 + 1, y0 + 1, fx * fy)
                    dst[o] = r / 255
                    dst[o + 1] = g / 255
                    dst[o + 2] = b / 255
                    o += 3
                }
            }
        }
    }
}
