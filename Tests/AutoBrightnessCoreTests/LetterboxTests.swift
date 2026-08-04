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
    // Bars deeper than the 25% cap: 15 black rows top and bottom around 10 rows
    // of content. The cap stops the crop at 10 rows per edge, so five bar rows
    // survive on each side rather than the crop eating into the content.
    var map = grid(rows: 40, cols: 64, fill: 0.0)
    for row in 15..<25 {
        map[row] = Array(repeating: 0.05, count: 64)
    }
    let cropped = Letterbox.crop(map)
    #expect(cropped.count == 20)
    #expect(cropped[0].count == 64)
}

@Test("A uniformly black frame is left alone rather than eroded")
func allBlackIsNotCropped() {
    // Nothing survives a crop here that is any brighter than what it removed, so
    // the frame is dark content, not a bordered picture. Eroding a quarter of
    // every edge would only concentrate whatever specks remain and report the
    // screen as brighter than it is.
    let map = grid(rows: 40, cols: 64, fill: 0.0)
    let cropped = Letterbox.crop(map)
    #expect(cropped.count == 40)
    #expect(cropped[0].count == 64)
}

@Test("A dark region on one edge only is not treated as a bar")
func singleEdgeIsNotCropped() {
    // A black dock, sidebar or terminal strip at one edge. Bars come in pairs;
    // one edge alone is just part of the content.
    var map = grid(rows: 40, cols: 64, fill: 0.3)
    for row in 34..<40 {
        map[row] = Array(repeating: 0.0, count: 64)
    }
    let cropped = Letterbox.crop(map)
    #expect(cropped.count == 40)
    #expect(cropped[0].count == 64)
}

@Test("A dark theme background is not mistaken for a black bar")
func darkThemeIsNotCropped() {
    // VS Code Dark+ #1e1e1e is 0.0129 linear — dark, but nowhere near the black
    // a letterbox bar is composited at. Cropping it would erode all four edges
    // of a full-screen editor and report it far brighter than it is.
    let map = grid(rows: 40, cols: 64, fill: 0.0129)
    let cropped = Letterbox.crop(map)
    #expect(cropped.count == 40)
    #expect(cropped[0].count == 64)
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
