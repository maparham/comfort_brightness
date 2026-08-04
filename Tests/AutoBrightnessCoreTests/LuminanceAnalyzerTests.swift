import Testing
@testable import AutoBrightnessCore

/// Builds a solid-color BGRA frame.
private func solid(width: Int, height: Int, r: UInt8, g: UInt8, b: UInt8) -> Frame {
    var bgra: [UInt8] = []
    bgra.reserveCapacity(width * height * 4)
    for _ in 0..<(width * height) {
        bgra.append(contentsOf: [b, g, r, 255])
    }
    return Frame(width: width, height: height, bgra: bgra)
}

/// Builds a frame from a per-row gray value (0...255).
private func rows(_ grays: [UInt8], width: Int) -> Frame {
    var bgra: [UInt8] = []
    for gray in grays {
        for _ in 0..<width {
            bgra.append(contentsOf: [gray, gray, gray, 255])
        }
    }
    return Frame(width: width, height: grays.count, bgra: bgra)
}

@Test("Solid white reads near 1.0 and solid black near 0.0")
func solidExtremes() {
    #expect(abs(LuminanceAnalyzer.analyze(solid(width: 8, height: 8, r: 255, g: 255, b: 255)) - 1.0) < 0.01)
    #expect(LuminanceAnalyzer.analyze(solid(width: 8, height: 8, r: 0, g: 0, b: 0)) < 0.01)
}

@Test("sRGB mid-gray reads as perceptually neutral")
func midGrayIsNeutral() {
    // The output is perceptual, so mid-gray must land near 0.50 — the
    // controller's neutral point. If this reads ~0.216 the final gamma
    // re-encode is missing, and every dark-mode window would brighten the screen.
    let value = LuminanceAnalyzer.analyze(solid(width: 8, height: 8, r: 128, g: 128, b: 128))
    #expect(abs(value - 0.50) < 0.02)
}

@Test("A half-white frame dims substantially")
func halfWhiteFrame() {
    // 32 white rows over 32 black rows. The black half is at one edge only, so
    // it is content rather than a bar and nothing is cropped: mean 0.5, p75
    // saturated at white, 0.6 + 0.4*0.5 = 0.80 linear = 0.903 perceptual, an
    // offset of -0.18. Half a screen of glaring white should dim, and this pins
    // that intent.
    //
    // (Before the crop was gated on opposing edges this read 0.937, because the
    // crop ate 16 of the black rows. The intent is unchanged; the number moved
    // because a one-sided dark region is no longer eroded.)
    let grays: [UInt8] = Array(repeating: 255, count: 32) + Array(repeating: 0, count: 32)
    let value = LuminanceAnalyzer.analyze(rows(grays, width: 8))
    #expect(abs(value - 0.903) < 0.01)
}

@Test("A mostly black frame with a small bright region stays dark")
func smallBrightRegion() {
    var grays = [UInt8](repeating: 0, count: 40)
    grays[20] = 255
    let value = LuminanceAnalyzer.analyze(rows(grays, width: 8))
    #expect(value < 0.35)
}

@Test("Letterboxing does not change the reading")
func letterboxingIsNeutral() {
    // Same dark content, once bare and once with black bars. If these diverge,
    // full-screen video gets the wrong adjustment.
    let content = [UInt8](repeating: 40, count: 24)
    let bare = LuminanceAnalyzer.analyze(rows(content, width: 8))
    let barred = [UInt8](repeating: 0, count: 8) + content + [UInt8](repeating: 0, count: 8)
    let boxed = LuminanceAnalyzer.analyze(rows(barred, width: 8))
    #expect(abs(bare - boxed) < 0.02)
}

@Test("A subtitle over the black bar does not change the reading")
func subtitleIsNeutral() {
    let content = [UInt8](repeating: 40, count: 24)
    let bare = LuminanceAnalyzer.analyze(rows(content, width: 8))

    var bgra: [UInt8] = []
    let grays = [UInt8](repeating: 0, count: 8) + content + [UInt8](repeating: 0, count: 8)
    for (index, gray) in grays.enumerated() {
        for col in 0..<8 {
            // Row 35 is inside the lower bar; light up 3 of 8 columns.
            let value: UInt8 = (index == 35 && col < 3) ? 255 : gray
            bgra.append(contentsOf: [value, value, value, 255])
        }
    }
    let subtitled = LuminanceAnalyzer.analyze(Frame(width: 8, height: grays.count, bgra: bgra))
    #expect(abs(bare - subtitled) < 0.02)
}

/// A full-screen dark editor at capture resolution: title strip, line-number
/// gutter, and text lines. At 64px wide a glyph run downscales into a smear
/// covering part of the row rather than individual characters.
private func darkEditor(background: UInt8) -> Frame {
    let width = 64
    let height = 40
    var bgra: [UInt8] = []
    bgra.reserveCapacity(width * height * 4)
    for row in 0..<height {
        for col in 0..<width {
            var gray = background
            if row < 2 {
                gray = background &+ 6  // slightly lighter title bar
            } else if row >= 4, row.isMultiple(of: 2) {
                if col >= 2, col < 5 {
                    gray = 90  // line numbers
                } else if col >= 8, col < 58, (col * 7 + row * 3) % 10 < 4 {
                    gray = 170  // text
                }
            }
            bgra.append(contentsOf: [gray, gray, gray, 255])
        }
    }
    return Frame(width: width, height: height, bgra: bgra)
}

/// A dark film scene, optionally inside black bars, at capture resolution.
private func filmScene(barRows: Int) -> Frame {
    let width = 64
    let picture = 24
    let height = picture + 2 * barRows
    var bgra: [UInt8] = []
    for row in 0..<height {
        let pictureRow = row - barRows
        for col in 0..<width {
            var gray: UInt8 = 0
            if pictureRow >= 0, pictureRow < picture {
                // A dark scene with one small highlight — a lit face, a lamp.
                let lit = pictureRow >= 8 && pictureRow < 16 && col >= 26 && col < 36
                gray = lit ? 120 : 40
            }
            bgra.append(contentsOf: [gray, gray, gray, 255])
        }
    }
    return Frame(width: width, height: height, bgra: bgra)
}

/// Settles the controller on one luminance value and returns the offset.
private func offset(for luminance: Double) -> Double {
    var controller = Controller()
    for _ in 0..<40 {
        _ = controller.update(luminance: luminance, baseline: 0.5, settings: .defaults)
    }
    return controller.appliedOffset
}

@Test("A full-screen dark editor reads as dark UI, not as a dark film")
func darkEditorFrame() {
    // The seam the review found untested: a dark-editor *frame* through
    // `analyze`, not a hand-picked luminance through `Controller`. Before the
    // crop was gated, this frame lost a quarter of every edge, the text-dense
    // centre survived, and L came out around 0.51 — brighter than mid-gray, so
    // the app would have *dimmed* a dark editor.
    let value = LuminanceAnalyzer.analyze(darkEditor(background: 30))  // #1e1e1e
    #expect(value > 0.15)
    #expect(value < 0.45)
    let lift = offset(for: value)
    #expect(lift > 0.02)
    #expect(lift < 0.15)  // modest, well short of the ±0.20 clamp
}

@Test("Sweeping a dark editor's background produces no cliff")
func darkEditorSweepIsContinuous() {
    // The reviewer's measured discontinuity: at 8-bit gray 38 the old crop fired
    // and at 40 it did not, so L jumped from 0.234 to 0.510 — a 0.12 swing in
    // offset that the deadband cannot suppress and the slew limit only stretches
    // into a visible ramp. Neighbouring backgrounds must now read alike.
    let low = LuminanceAnalyzer.analyze(darkEditor(background: 38))
    let high = LuminanceAnalyzer.analyze(darkEditor(background: 40))
    #expect(abs(low - high) < 0.02)

    // And nowhere else across the range of plausible dark themes.
    var previous = LuminanceAnalyzer.analyze(darkEditor(background: 16))
    for background in stride(from: UInt8(18), through: UInt8(60), by: 2) {
        let value = LuminanceAnalyzer.analyze(darkEditor(background: background))
        #expect(abs(value - previous) < 0.03)
        previous = value
    }
}

@Test("A letterboxed dark film is still cropped and still brightens")
func letterboxedFilmStillCrops() {
    // The case the crop exists for. Black bars must not be measured as part of
    // the picture, so the boxed and unboxed readings must agree, and the scene
    // must still call for a real lift.
    let boxed = LuminanceAnalyzer.analyze(filmScene(barRows: 8))
    let bare = LuminanceAnalyzer.analyze(filmScene(barRows: 0))
    #expect(abs(boxed - bare) < 0.02)
    #expect(offset(for: boxed) > 0.10)
}

@Test("Percentile picks the nearest rank")
func percentileRanks() {
    let sorted = [0.0, 0.25, 0.5, 0.75, 1.0]
    #expect(LuminanceAnalyzer.percentile(sorted, 0.0) == 0.0)
    #expect(LuminanceAnalyzer.percentile(sorted, 1.0) == 1.0)
    #expect(LuminanceAnalyzer.percentile(sorted, 0.75) == 0.75)
}
