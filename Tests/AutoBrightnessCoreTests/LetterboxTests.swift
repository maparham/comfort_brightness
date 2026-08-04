import Testing
@testable import AutoBrightnessCore

/// Builds a `rows` x `cols` grid filled with `fill`.
private func grid(rows: Int, cols: Int, fill: Double) -> [[Double]] {
    Array(repeating: Array(repeating: fill, count: cols), count: rows)
}

@Test("Median of an even-length row")
func medianEven() {
    #expect(Letterbox.median([0.0, 0.0, 1.0, 1.0]) == 1.0)
    #expect(Letterbox.median([0.0, 0.0, 0.0, 1.0]) == 0.0)
}

@Test("A frame with no dark bars is returned unchanged")
func noCropWhenNoBars() {
    let map = grid(rows: 40, cols: 64, fill: 0.5)
    let cropped = Letterbox.crop(map)
    #expect(cropped.count == 40)
    #expect(cropped[0].count == 64)
}

@Test("Horizontal black bars are cropped away")
func cropsHorizontalBars() {
    var map = grid(rows: 40, cols: 64, fill: 0.0)
    for row in 8..<32 {
        map[row] = Array(repeating: 0.05, count: 64)
    }
    let cropped = Letterbox.crop(map)
    #expect(cropped.count == 24)
    #expect(cropped[0].count == 64)
}

@Test("A subtitle in the lower bar does not defeat the crop")
func subtitleDoesNotDefeatCrop() {
    var map = grid(rows: 40, cols: 64, fill: 0.0)
    for row in 8..<32 {
        map[row] = Array(repeating: 0.05, count: 64)
    }
    // A subtitle smear across 24 of 64 columns in a bar row. A p90 test would
    // stop the crop here and the app would wrongly brighten the screen.
    for col in 20..<44 {
        map[35][col] = 1.0
    }
    let cropped = Letterbox.crop(map)
    #expect(cropped.count == 24)
}

@Test("Cropping never removes more than a quarter from an edge")
func cropIsBounded() {
    let map = grid(rows: 40, cols: 64, fill: 0.0)
    let cropped = Letterbox.crop(map)
    // All-black frame: 10 rows off the top and bottom, 16 columns each side.
    #expect(cropped.count == 20)
    #expect(cropped[0].count == 32)
}

@Test("Vertical pillarbox bars are cropped away")
func cropsVerticalBars() {
    var map = grid(rows: 40, cols: 64, fill: 0.0)
    for row in 0..<40 {
        for col in 10..<54 {
            map[row][col] = 0.4
        }
    }
    let cropped = Letterbox.crop(map)
    #expect(cropped.count == 40)
    #expect(cropped[0].count == 44)
}
