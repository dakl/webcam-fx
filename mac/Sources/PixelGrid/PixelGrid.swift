/// Pixel art on a grid of blocks: each block takes a palette colour, keeps it while the picture
/// barely changes, and a lone block takes its neighbours' colour.

/// A named set of colours, 0–255 RGB.
public struct Palette: Equatable, Sendable {
    public let name: String
    public let colours: [SIMD3<Float>]

    public init(name: String, hex: [UInt32]) {
        self.name = name
        colours = hex.map { SIMD3(Float($0 >> 16 & 0xFF), Float($0 >> 8 & 0xFF), Float($0 & 0xFF)) }
    }

    public static let all: [Palette] = [
        Palette(
            name: "ENDESGA 32",
            hex: [
                0xBE4A2F, 0xD77643, 0xEAD4AA, 0xE4A672, 0xB86F50, 0x733E39, 0x3E2731, 0xA22633,
                0xE43B44, 0xF77622, 0xFEAE34, 0xFEE761, 0x63C74D, 0x3E8948, 0x265C42, 0x193C3E,
                0x124E89, 0x0099DB, 0x2CE8F5, 0xFFFFFF, 0xC0CBDC, 0x8B9BB4, 0x5A6988, 0x3A4466,
                0x262B44, 0x181425, 0xFF0044, 0x68386C, 0xB55088, 0xF6757A, 0xE8B796, 0xC28569,
            ]),
        Palette(
            name: "Sweetie 16",
            hex: [
                0x1A1C2C, 0x5D275D, 0xB13E53, 0xEF7D57, 0xFFCD75, 0xA7F070, 0x38B764, 0x257179,
                0x29366F, 0x3B5DC9, 0x41A6F6, 0x73EFF7, 0xF4F4F4, 0x94B0C2, 0x566C86, 0x333C57,
            ]),
        Palette(
            name: "PICO-8",
            hex: [
                0x000000, 0x1D2B53, 0x7E2553, 0x008751, 0xAB5236, 0x5F574F, 0xC2C3C7, 0xFFF1E8,
                0xFF004D, 0xFFA300, 0xFFEC27, 0x00E436, 0x29ADFF, 0x83769C, 0xFF77A8, 0xFFCCAA,
            ]),
        Palette(name: "Game Boy", hex: [0x0F380F, 0x306230, 0x8BAC0F, 0x9BBC0F]),
        Palette(name: "1-bit", hex: [0x000000, 0xFFFFFF]),
    ]
}

/// Colour distance weighted for how eyes see it ("redmean"): closer to perceived difference
/// than plain RGB distance, at the same cost.
public func colourDistance(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
    let meanRed = (a.x + b.x) / 2
    let d = a - b
    let w = SIMD3(2 + meanRed / 256, 4, 2 + (255 - meanRed) / 256)
    return (w * d * d).sum().squareRoot()
}

public func nearest(_ colour: SIMD3<Float>, in palette: Palette) -> Int {
    palette.colours.indices.min { colourDistance(colour, palette.colours[$0]) < colourDistance(colour, palette.colours[$1]) }!
}

/// One block that matches none of its eight neighbours takes the colour most of them share
/// (at least five), which clears single-block noise without rounding off corners.
public func despeckle(_ grid: [Int], cols: Int, rows: Int) -> [Int] {
    var out = grid
    for r in 0..<rows {
        for c in 0..<cols {
            var counts: [Int: Int] = [:]
            var matches = 0
            for dr in -1...1 {
                for dc in -1...1 where !(dr == 0 && dc == 0) {
                    let (nr, nc) = (r + dr, c + dc)
                    guard nr >= 0, nr < rows, nc >= 0, nc < cols else { continue }
                    let n = grid[nr * cols + nc]
                    if n == grid[r * cols + c] { matches += 1 }
                    counts[n, default: 0] += 1
                }
            }
            if matches == 0, let (colour, count) = counts.max(by: { $0.value < $1.value }), count >= 5 {
                out[r * cols + c] = colour
            }
        }
    }
    return out
}

/// Palette colours for a grid of blocks, frame after frame.
public struct PixelGrid {
    /// A block keeps its colour unless another is closer by more than this (redmean units, 0–765).
    public var steadiness: Float = 24

    private var previous: [Int] = []
    private var shape = (cols: 0, rows: 0, palette: "")

    public init() {}

    /// The palette index of each block (`colours` row by row, 0–255 RGB), after the steadiness rule
    /// and despeckling. A new grid size or palette starts afresh.
    public mutating func quantize(_ colours: [SIMD3<Float>], cols: Int, rows: Int, palette: Palette) -> [Int] {
        if (shape.cols, shape.rows, shape.palette) != (cols, rows, palette.name) {
            previous = []
            shape = (cols, rows, palette.name)
        }
        var grid = colours.map { nearest($0, in: palette) }
        if previous.count == grid.count {
            for i in grid.indices where grid[i] != previous[i] {
                let keep = colourDistance(colours[i], palette.colours[previous[i]])
                let best = colourDistance(colours[i], palette.colours[grid[i]])
                if keep - best <= steadiness { grid[i] = previous[i] }
            }
        }
        previous = grid
        return despeckle(grid, cols: cols, rows: rows)
    }
}
