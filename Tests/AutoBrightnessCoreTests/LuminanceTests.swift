import Testing
@testable import AutoBrightnessCore

@Test("Black and white linearize to the endpoints")
func linearizeEndpoints() {
    #expect(Luminance.linearize(0.0) == 0.0)
    #expect(abs(Luminance.linearize(1.0) - 1.0) < 1e-9)
}

@Test("sRGB mid-gray linearizes to about 0.216, not 0.5")
func linearizeMidGray() {
    // This is the whole reason the analyzer works in linear space. If this
    // value comes out near 0.5, the conversion is missing.
    let value = Luminance.linearize(128.0 / 255.0)
    #expect(abs(value - 0.2158) < 0.001)
}

@Test("Relative luminance uses Rec. 709 weights")
func relativeWeights() {
    #expect(abs(Luminance.relative(r: 255, g: 255, b: 255) - 1.0) < 1e-9)
    #expect(Luminance.relative(r: 0, g: 0, b: 0) == 0.0)
    // Pure green must dominate pure blue by roughly 10x.
    let green = Luminance.relative(r: 0, g: 255, b: 0)
    let blue = Luminance.relative(r: 0, g: 0, b: 255)
    #expect(abs(green - 0.7152) < 1e-6)
    #expect(abs(blue - 0.0722) < 1e-6)
}

@Test("Frame reports its dimensions")
func frameDimensions() {
    let frame = Frame(width: 2, height: 1, bgra: [0, 0, 0, 255, 255, 255, 255, 255])
    #expect(frame.width == 2)
    #expect(frame.height == 1)
    #expect(frame.bgra.count == 8)
}
