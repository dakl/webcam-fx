import XCTest
@testable import PixelGrid

final class PixelGridTests: XCTestCase {
    private let blackWhite = Palette(name: "test", hex: [0x000000, 0xFFFFFF])
    private let greys = Palette(name: "greys", hex: [0x000000, 0x808080, 0xFFFFFF])

    func testDarkGreyMapsToBlack() {
        XCTAssertEqual(nearest(SIMD3(40, 40, 40), in: blackWhite), 0)
    }

    func testBlockKeepsItsColourWhenTheNewOneIsOnlySlightlyCloser() {
        var grid = PixelGrid()
        _ = grid.quantize([SIMD3(60, 60, 60)], cols: 1, rows: 1, palette: greys)  // black
        // 66 is now a little nearer grey (128) than black, within the steadiness margin.
        XCTAssertEqual(grid.quantize([SIMD3(66, 66, 66)], cols: 1, rows: 1, palette: greys), [0])
    }

    func testBlockChangesColourWhenThePictureClearlyChanges() {
        var grid = PixelGrid()
        _ = grid.quantize([SIMD3(60, 60, 60)], cols: 1, rows: 1, palette: greys)
        XCTAssertEqual(grid.quantize([SIMD3(230, 230, 230)], cols: 1, rows: 1, palette: greys), [2])
    }

    func testLoneBlockTakesItsNeighboursColour() {
        let grid = [0, 0, 0,
                    0, 1, 0,
                    0, 0, 0]
        XCTAssertEqual(despeckle(grid, cols: 3, rows: 3), Array(repeating: 0, count: 9))
    }

    func testBlockWithAMatchingNeighbourStays() {
        let grid = [0, 0, 0,
                    0, 1, 1,
                    0, 0, 0]
        XCTAssertEqual(despeckle(grid, cols: 3, rows: 3), grid)
    }

    func testEveryPaletteHasColours() {
        XCTAssertEqual(Palette.all.map(\.colours.count), [32, 16, 16, 4, 2])
    }
}
