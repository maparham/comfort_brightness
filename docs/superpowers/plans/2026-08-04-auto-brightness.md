# Auto Brightness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A macOS menu-bar app that samples on-screen content and applies a bounded brightness offset on top of the user's chosen backlight level, so a near-white page dims and a dark full-screen video brightens.

**Architecture:** A `Sendable`, dependency-free core (`AutoBrightnessCore`) holds the two pieces that determine whether the product feels good — the luminance analyzer and the control law — as pure value types with no I/O, fully testable without a display. A thin app layer wires ScreenCaptureKit into the core at 2 Hz and writes the result through a private brightness API behind a protocol. The coordinator's baseline tracking is what lets the app coexist with the user's own brightness adjustments.

**Tech Stack:** Swift 6.3 / swift-tools-version 6.0, SwiftPM, Swift Testing (`import Testing`), ScreenCaptureKit, AppKit (`NSStatusItem`) + SwiftUI popover, `DisplayServices` private framework via `dlopen`.

## Global Constraints

- Target platform: `.macOS(.v15)`. Verified toolchain: Swift 6.3.3, Xcode 26.6, macOS 26.5, arm64.
- `AutoBrightnessCore` must not import AppKit, ScreenCaptureKit, or CoreGraphics-display APIs. It is pure computation. This is what keeps the control law testable.
- All brightness values are `Double` in `0.0...1.0`, matching the `DisplayServices` scale.
- Luminance averaging happens in **linear** space; comparison against the neutral point and the applied gain happen in **perceptual** space (`L = L_linear^(1/2.2)`). Getting this backwards makes the app brighten dark-mode content persistently.
- Measured hardware facts (do not re-derive): brightness read-back is bit-exact with no quantization and no smoothing; the brightness keys step by 1/16 = 0.0625.
- Defaults: `strength` 0.45, `maxOffset` 0.20, `neutral` 0.50, `deadband` 0.02, slew 0.10/sec (0.05 per 2 Hz tick), `minBrightness` 0.05.
- **A test run reporting "0 tests" is a failure, not a pass.** `swift test` exits 0 when it selects nothing, so every verification step below states an expected test count — check the count, not just the exit status.
- No network access anywhere in this project. Screen samples never leave the process and are never written to disk.
- Commit after every task.

**Reference spec:** `docs/superpowers/specs/2026-08-04-auto-brightness-design.md`

---

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` | Package manifest, three targets |
| `Sources/AutoBrightnessCore/Frame.swift` | `Frame` value type (BGRA pixel buffer) |
| `Sources/AutoBrightnessCore/Luminance.swift` | sRGB→linear conversion, Rec.709 weighting |
| `Sources/AutoBrightnessCore/LuminanceAnalyzer.swift` | Frame → perceptual content luminance |
| `Sources/AutoBrightnessCore/Letterbox.swift` | Black-bar detection and cropping |
| `Sources/AutoBrightnessCore/Controller.swift` | Control law: transient rejection, offset, deadband, slew, clamp |
| `Sources/AutoBrightnessCore/BrightnessControlling.swift` | Actuator protocol |
| `Sources/AutoBrightnessCore/Coordinator.swift` | Baseline tracking, pause state, per-tick orchestration |
| `Sources/AutoBrightnessApp/DisplayServicesBrightness.swift` | Private-API actuator implementation |
| `Sources/AutoBrightnessApp/ScreenSampler.swift` | ScreenCaptureKit stream → `Frame` |
| `Sources/AutoBrightnessApp/PauseMonitor.swift` | Sleep/lock/wake notifications |
| `Sources/AutoBrightnessApp/AppModel.swift` | Observable state binding coordinator to UI |
| `Sources/AutoBrightnessApp/SettingsView.swift` | SwiftUI popover contents |
| `Sources/AutoBrightnessApp/main.swift` | `NSApplication` bootstrap, status item |
| `Sources/ALSProbe/main.swift` | Standalone diagnostic for ambient-sensor interaction |
| `Tests/AutoBrightnessCoreTests/*` | Tests for every core type |
| `Resources/Info.plist` | Bundle metadata |
| `Scripts/make-bundle.sh` | Assemble and ad-hoc sign `AutoBrightness.app` |

---

### Task 1: Package skeleton and linear luminance

**Files:**
- Create: `Package.swift`
- Create: `Sources/AutoBrightnessCore/Frame.swift`
- Create: `Sources/AutoBrightnessCore/Luminance.swift`
- Test: `Tests/AutoBrightnessCoreTests/LuminanceTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `Frame(width:height:bgra:)` with properties `width: Int`, `height: Int`, `bgra: [UInt8]`; `Luminance.linearize(_ c: Double) -> Double`; `Luminance.relative(r: UInt8, g: UInt8, b: UInt8) -> Double`

- [ ] **Step 1: Create the package manifest**

`Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AutoBrightness",
    platforms: [.macOS(.v15)],
    targets: [
        .target(name: "AutoBrightnessCore"),
        .executableTarget(
            name: "AutoBrightnessApp",
            dependencies: ["AutoBrightnessCore"]
        ),
        .executableTarget(
            name: "ALSProbe",
            dependencies: ["AutoBrightnessCore"]
        ),
        .testTarget(
            name: "AutoBrightnessCoreTests",
            dependencies: ["AutoBrightnessCore"]
        ),
    ]
)
```

- [ ] **Step 2: Create placeholder sources so the package builds**

The two executable targets need a `main.swift` to compile. Create stubs that later tasks replace.

`Sources/AutoBrightnessApp/main.swift`:

```swift
print("AutoBrightness: not yet implemented")
```

`Sources/ALSProbe/main.swift`:

```swift
print("ALSProbe: not yet implemented")
```

- [ ] **Step 3: Write the failing test**

`Tests/AutoBrightnessCoreTests/LuminanceTests.swift`:

```swift
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
```

- [ ] **Step 4: Run the test to verify it fails**

Run: `swift test`
Expected: FAIL — compile error, `cannot find 'Luminance' in scope`.

- [ ] **Step 5: Implement `Frame`**

`Sources/AutoBrightnessCore/Frame.swift`:

```swift
/// A downscaled screen capture. Pixels are BGRA, 8 bits per channel,
/// row-major, tightly packed: `bgra.count == width * height * 4`.
public struct Frame: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public let bgra: [UInt8]

    public init(width: Int, height: Int, bgra: [UInt8]) {
        self.width = width
        self.height = height
        self.bgra = bgra
    }
}
```

- [ ] **Step 6: Implement `Luminance`**

`Sources/AutoBrightnessCore/Luminance.swift`:

```swift
import Foundation

/// Conversions between sRGB encoding and linear light.
///
/// Averaging must happen on linear values. Averaging gamma-encoded values
/// systematically misjudges dark content, which is exactly the case this app
/// needs to get right.
public enum Luminance {
    /// Inverse sRGB transfer function. Input and output are 0...1.
    public static func linearize(_ c: Double) -> Double {
        if c <= 0.04045 {
            return c / 12.92
        }
        return pow((c + 0.055) / 1.055, 2.4)
    }

    /// Rec. 709 relative luminance of an 8-bit sRGB pixel, in 0...1 linear light.
    public static func relative(r: UInt8, g: UInt8, b: UInt8) -> Double {
        0.2126 * linearize(Double(r) / 255.0)
            + 0.7152 * linearize(Double(g) / 255.0)
            + 0.0722 * linearize(Double(b) / 255.0)
    }
}
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `swift test`
Expected: PASS. This task adds 4 tests; the suite total is now 4.

- [ ] **Step 8: Commit**

```bash
git add Package.swift Sources Tests
git commit -m "feat: package skeleton and linear luminance conversion"
```

---

### Task 2: Letterbox detection and cropping

**Files:**
- Create: `Sources/AutoBrightnessCore/Letterbox.swift`
- Test: `Tests/AutoBrightnessCoreTests/LetterboxTests.swift`

**Interfaces:**
- Consumes: nothing (operates on a plain `[[Double]]` luminance grid)
- Produces: `Letterbox.crop(_ map: [[Double]], threshold: Double = 0.02, maxFraction: Double = 0.25) -> [[Double]]`; `Letterbox.median(_ values: [Double]) -> Double`

The grid is row-major: `map[row][column]`, each value a linear luminance in 0...1.

- [ ] **Step 1: Write the failing test**

`Tests/AutoBrightnessCoreTests/LetterboxTests.swift`:

```swift
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
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test`
Expected: FAIL — `cannot find 'Letterbox' in scope`.

- [ ] **Step 3: Implement `Letterbox`**

`Sources/AutoBrightnessCore/Letterbox.swift`:

```swift
/// Detects and removes uniform dark borders — letterbox bars on film, pillarbox
/// bars on 4:3 content, and any padding the capture pipeline adds.
///
/// Without this, a letterboxed movie's black bars drag the frame average down and
/// the controller *raises* brightness, which is the opposite of what a dark video
/// needs.
public enum Letterbox {
    /// Upper median: for even counts this is the higher of the two middle values.
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Removes dark rows from the top and bottom and dark columns from each side.
    ///
    /// A row counts as a bar when its *median* luminance is below `threshold`.
    /// The median rather than a high percentile: at 64px wide a subtitle
    /// downscales to a smear covering a substantial fraction of a row, and a p90
    /// test tolerates only 10% bright pixels. No subtitle spans half a row.
    ///
    /// At most `maxFraction` of each dimension is removed from each edge, so a
    /// fully black frame still yields a non-empty result.
    public static func crop(
        _ map: [[Double]],
        threshold: Double = 0.02,
        maxFraction: Double = 0.25
    ) -> [[Double]] {
        guard let first = map.first, !first.isEmpty else { return map }
        let rows = map.count
        let cols = first.count

        let maxRowCrop = Int(Double(rows) * maxFraction)
        var top = 0
        while top < maxRowCrop, median(map[top]) < threshold { top += 1 }
        var bottom = rows - 1
        var bottomCropped = 0
        while bottomCropped < maxRowCrop, median(map[bottom]) < threshold {
            bottom -= 1
            bottomCropped += 1
        }
        guard top <= bottom else { return map }
        let rowSlice = Array(map[top...bottom])

        let maxColCrop = Int(Double(cols) * maxFraction)
        var left = 0
        while left < maxColCrop, median(column(rowSlice, left)) < threshold { left += 1 }
        var right = cols - 1
        var rightCropped = 0
        while rightCropped < maxColCrop, median(column(rowSlice, right)) < threshold {
            right -= 1
            rightCropped += 1
        }
        guard left <= right else { return rowSlice }

        return rowSlice.map { Array($0[left...right]) }
    }

    private static func column(_ map: [[Double]], _ index: Int) -> [Double] {
        map.map { $0[index] }
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test`
Expected: PASS. This task adds 6 tests; the suite total is now 10.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessCore/Letterbox.swift Tests/AutoBrightnessCoreTests/LetterboxTests.swift
git commit -m "feat: letterbox detection using row median"
```

---

### Task 3: Luminance analyzer

**Files:**
- Create: `Sources/AutoBrightnessCore/LuminanceAnalyzer.swift`
- Test: `Tests/AutoBrightnessCoreTests/LuminanceAnalyzerTests.swift`

**Interfaces:**
- Consumes: `Frame`, `Luminance.relative(r:g:b:)`, `Letterbox.crop(_:threshold:maxFraction:)`
- Produces: `LuminanceAnalyzer.analyze(_ frame: Frame) -> Double` returning **perceptual** content luminance in 0...1; `LuminanceAnalyzer.luminanceMap(_ frame: Frame) -> [[Double]]`; `LuminanceAnalyzer.percentile(_ sorted: [Double], _ fraction: Double) -> Double`

- [ ] **Step 1: Write the failing test**

`Tests/AutoBrightnessCoreTests/LuminanceAnalyzerTests.swift`:

```swift
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
    // 32 white rows over 32 black rows. Note the crop runs first and removes 16
    // of the 32 black rows (the 25% cap), so the mean is 256/384 = 0.667, not
    // 0.5. With p75 saturated at white: 0.6 + 0.4*0.667 = 0.867 linear, which is
    // 0.937 perceptual. Half a screen of glaring white should dim, and this pins
    // that intent.
    let grays: [UInt8] = Array(repeating: 255, count: 32) + Array(repeating: 0, count: 32)
    let value = LuminanceAnalyzer.analyze(rows(grays, width: 8))
    #expect(abs(value - 0.937) < 0.01)
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

@Test("Percentile picks the nearest rank")
func percentileRanks() {
    let sorted = [0.0, 0.25, 0.5, 0.75, 1.0]
    #expect(LuminanceAnalyzer.percentile(sorted, 0.0) == 0.0)
    #expect(LuminanceAnalyzer.percentile(sorted, 1.0) == 1.0)
    #expect(LuminanceAnalyzer.percentile(sorted, 0.75) == 0.75)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test`
Expected: FAIL — `cannot find 'LuminanceAnalyzer' in scope`.

- [ ] **Step 3: Implement `LuminanceAnalyzer`**

`Sources/AutoBrightnessCore/LuminanceAnalyzer.swift`:

```swift
import Foundation

/// Reduces a captured frame to a single perceptual luminance value in 0...1.
///
/// Pure computation: no I/O, no display access, no state.
public enum LuminanceAnalyzer {
    /// Weight given to the 75th percentile; the remainder goes to the mean.
    /// The percentile tracks the content the user is actually looking at, while
    /// the mean stops a small bright region from dominating.
    static let percentileWeight = 0.6
    static let percentileFraction = 0.75

    /// Per-pixel linear luminance, row-major.
    public static func luminanceMap(_ frame: Frame) -> [[Double]] {
        guard frame.width > 0, frame.height > 0 else { return [] }
        var map: [[Double]] = []
        map.reserveCapacity(frame.height)
        for row in 0..<frame.height {
            var values = [Double](repeating: 0, count: frame.width)
            for col in 0..<frame.width {
                let index = (row * frame.width + col) * 4
                guard index + 2 < frame.bgra.count else { break }
                values[col] = Luminance.relative(
                    r: frame.bgra[index + 2],
                    g: frame.bgra[index + 1],
                    b: frame.bgra[index]
                )
            }
            map.append(values)
        }
        return map
    }

    /// Nearest-rank percentile over an already-sorted array. `fraction` is 0...1.
    public static func percentile(_ sorted: [Double], _ fraction: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let index = Int((Double(sorted.count - 1) * fraction).rounded())
        return sorted[min(max(index, 0), sorted.count - 1)]
    }

    /// Perceptual content luminance in 0...1, on roughly the same scale as the
    /// macOS brightness setting.
    public static func analyze(_ frame: Frame) -> Double {
        let cropped = Letterbox.crop(luminanceMap(frame))
        let values = cropped.flatMap { $0 }
        guard !values.isEmpty else { return 0.5 }

        let sorted = values.sorted()
        let p75 = percentile(sorted, percentileFraction)
        let mean = values.reduce(0, +) / Double(values.count)
        let linear = percentileWeight * p75 + (1 - percentileWeight) * mean

        // Back to perceptual space. The controller compares against a neutral
        // point and applies a gain, and both of those are only meaningful
        // perceptually.
        return pow(max(linear, 0), 1.0 / 2.2)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test`
Expected: PASS. This task adds 7 tests; the suite total is now 17.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessCore/LuminanceAnalyzer.swift Tests/AutoBrightnessCoreTests/LuminanceAnalyzerTests.swift
git commit -m "feat: luminance analyzer with perceptual output"
```

---

### Task 4: Control law

**Files:**
- Create: `Sources/AutoBrightnessCore/Controller.swift`
- Test: `Tests/AutoBrightnessCoreTests/ControllerTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `ControllerSettings` (a `Sendable` struct with `strength`, `maxOffset`, `neutral`, `deadband`, `slewPerTick`, `minBrightness`, all `Double`, plus `static let `defaults`); `Controller` with `mutating func update(luminance: Double, baseline: Double, settings: ControllerSettings) -> Double`, `mutating func reset()`, and `var appliedOffset: Double { get }`

- [ ] **Step 1: Write the failing test**

`Tests/AutoBrightnessCoreTests/ControllerTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

/// Feeds one luminance value repeatedly until the controller settles, returning
/// the final offset.
private func settle(
    _ controller: inout Controller,
    luminance: Double,
    baseline: Double = 0.5,
    ticks: Int = 20
) -> Double {
    var last = 0.0
    for _ in 0..<ticks {
        last = controller.update(
            luminance: luminance,
            baseline: baseline,
            settings: .defaults
        )
    }
    return last
}

@Test("A white page drives the offset to the negative clamp and no further")
func whitePageClamps() {
    var controller = Controller()
    let target = settle(&controller, luminance: 0.95)
    #expect(abs(controller.appliedOffset - (-0.20)) < 1e-6)
    #expect(abs(target - 0.30) < 1e-6)
}

@Test("A dark film scene brightens, bounded by the clamp")
func darkSceneBrightens() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.17)
    #expect(controller.appliedOffset > 0.13)
    #expect(controller.appliedOffset <= 0.20)
}

@Test("Mid-gray content produces no offset")
func midGrayIsNeutral() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.50)
    #expect(controller.appliedOffset == 0.0)
}

@Test("A dark-mode editor is not treated like a dark film")
func darkModeEditorIsModest() {
    // L = 0.30 is a dark IDE. It should lift the screen a little, nowhere near
    // the clamp — otherwise anyone working in dark mode gets a persistently
    // brighter screen than they chose.
    var controller = Controller()
    _ = settle(&controller, luminance: 0.30)
    #expect(abs(controller.appliedOffset - 0.09) < 0.01)
}

@Test("A one-tick spike is ignored")
func transientRejected() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.50)
    for luminance in [0.95, 0.50, 0.50] {
        _ = controller.update(luminance: luminance, baseline: 0.5, settings: .defaults)
    }
    #expect(controller.appliedOffset == 0.0)
}

@Test("A step change takes at least 1.8 seconds to complete")
func slewLimited() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.50)
    var ticks = 0
    while abs(controller.appliedOffset - (-0.20)) > 1e-6 && ticks < 100 {
        _ = controller.update(luminance: 0.95, baseline: 0.5, settings: .defaults)
        ticks += 1
    }
    // 2 Hz sampling, so 1.8 seconds is at least 4 ticks.
    #expect(ticks >= 4)
    #expect(ticks < 100)
}

@Test("Small changes inside the deadband do not move the offset")
func deadbandHolds() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.50)
    // 0.52 maps to an offset of -0.009, inside the 0.02 deadband.
    for _ in 0..<10 {
        _ = controller.update(luminance: 0.52, baseline: 0.5, settings: .defaults)
    }
    #expect(controller.appliedOffset == 0.0)
}

@Test("Target brightness never leaves the safe range")
func targetIsClamped() {
    var controller = Controller()
    let dark = settle(&controller, luminance: 0.95, baseline: 0.10)
    #expect(dark >= 0.05)

    var other = Controller()
    let bright = settle(&other, luminance: 0.10, baseline: 0.98)
    #expect(bright <= 1.0)
}

@Test("Reset clears both the offset and the sample history")
func resetClearsState() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.95)
    #expect(controller.appliedOffset != 0.0)
    controller.reset()
    #expect(controller.appliedOffset == 0.0)
    // With history cleared, one white sample must not move anything yet.
    _ = controller.update(luminance: 0.95, baseline: 0.5, settings: .defaults)
    #expect(abs(controller.appliedOffset) <= 0.05)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test`
Expected: FAIL — `cannot find 'Controller' in scope`.

- [ ] **Step 3: Implement `ControllerSettings` and `Controller`**

`Sources/AutoBrightnessCore/Controller.swift`:

```swift
/// Tunable parameters of the control law. All values are on the 0...1 brightness
/// scale unless noted.
public struct ControllerSettings: Sendable, Equatable, Codable {
    /// Gain applied to the perceptual error. Chosen so the response is graded
    /// rather than saturated: a light page yields a partial offset and only
    /// near-white content reaches the clamp.
    public var strength: Double
    /// Hard bound on how far the offset may move brightness in either direction.
    public var maxOffset: Double
    /// Perceptual luminance at which no adjustment is applied — sRGB mid-gray.
    public var neutral: Double
    /// Changes smaller than this are ignored entirely, which is what stops slow
    /// oscillation around a steady scene.
    public var deadband: Double
    /// Maximum offset movement per tick. At 2 Hz, 0.05 is 0.10 per second.
    public var slewPerTick: Double
    /// Floor, so the panel is never driven to black.
    public var minBrightness: Double

    public init(
        strength: Double = 0.45,
        maxOffset: Double = 0.20,
        neutral: Double = 0.50,
        deadband: Double = 0.02,
        slewPerTick: Double = 0.05,
        minBrightness: Double = 0.05
    ) {
        self.strength = strength
        self.maxOffset = maxOffset
        self.neutral = neutral
        self.deadband = deadband
        self.slewPerTick = slewPerTick
        self.minBrightness = minBrightness
    }

    public static let defaults = ControllerSettings()
}

/// The control law. Pure: every input is a value, and the only state is the
/// applied offset plus a short sample history.
public struct Controller: Sendable {
    /// Number of samples the median is taken over. Three samples at 2 Hz is 1.5
    /// seconds, enough to absorb scrolling past a bright image.
    static let historyLength = 3

    public private(set) var appliedOffset: Double = 0
    private var history: [Double] = []

    public init() {}

    /// Advances one tick and returns the brightness the actuator should be set to.
    public mutating func update(
        luminance: Double,
        baseline: Double,
        settings: ControllerSettings
    ) -> Double {
        history.append(luminance)
        if history.count > Self.historyLength {
            history.removeFirst()
        }
        let smoothed = Self.median(history)

        var raw = -settings.strength * (smoothed - settings.neutral)
        raw = min(max(raw, -settings.maxOffset), settings.maxOffset)

        if abs(raw - appliedOffset) >= settings.deadband {
            let delta = raw - appliedOffset
            let step = min(max(delta, -settings.slewPerTick), settings.slewPerTick)
            appliedOffset += step
        }

        return min(max(baseline + appliedOffset, settings.minBrightness), 1.0)
    }

    /// Drops the offset and the history. Used on resume, so the app ramps in from
    /// the user's current level rather than snapping to a stale offset.
    public mutating func reset() {
        appliedOffset = 0
        history.removeAll()
    }

    /// Upper median of the sample history.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test`
Expected: PASS. This task adds 9 tests; the suite total is now 26.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessCore/Controller.swift Tests/AutoBrightnessCoreTests/ControllerTests.swift
git commit -m "feat: control law with deadband, slew limit and transient rejection"
```

---

### Task 5: Actuator protocol and private-API implementation

**Files:**
- Create: `Sources/AutoBrightnessCore/BrightnessControlling.swift`
- Create: `Sources/AutoBrightnessApp/DisplayServicesBrightness.swift`
- Test: `Tests/AutoBrightnessCoreTests/FakeBrightnessTests.swift`

**Interfaces:**
- Consumes: nothing
- Produces: `protocol BrightnessControlling: AnyObject` with `var canControl: Bool { get }`, `func read() -> Double?`, `func write(_ value: Double)`; `final class FakeBrightness: BrightnessControlling` with `var value: Double`, `var writes: [Double]`, `var canControl: Bool`; `final class DisplayServicesBrightness: BrightnessControlling` with `init(displayID: CGDirectDisplayID)`

`FakeBrightness` lives in the library (not the test target) because later tasks' tests and the ALS probe both use it.

- [ ] **Step 1: Write the failing test**

`Tests/AutoBrightnessCoreTests/FakeBrightnessTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

@Test("The fake records writes and reads them back")
func fakeRoundTrips() {
    let fake = FakeBrightness(value: 0.5)
    #expect(fake.read() == 0.5)
    fake.write(0.7)
    #expect(fake.read() == 0.7)
    #expect(fake.writes == [0.7])
}

@Test("The fake clamps writes to the valid range")
func fakeClamps() {
    let fake = FakeBrightness(value: 0.5)
    fake.write(1.5)
    #expect(fake.read() == 1.0)
    fake.write(-0.5)
    #expect(fake.read() == 0.0)
}

@Test("An uncontrollable fake reports so and ignores writes")
func fakeCanBeUnavailable() {
    let fake = FakeBrightness(value: 0.5, canControl: false)
    #expect(fake.canControl == false)
    fake.write(0.9)
    #expect(fake.read() == 0.5)
    #expect(fake.writes.isEmpty)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test`
Expected: FAIL — `cannot find 'FakeBrightness' in scope`.

- [ ] **Step 3: Implement the protocol and the fake**

`Sources/AutoBrightnessCore/BrightnessControlling.swift`:

```swift
/// Abstraction over the display backlight.
///
/// The real implementation calls private system APIs, so everything above this
/// protocol is tested against `FakeBrightness` and needs no display.
public protocol BrightnessControlling: AnyObject {
    /// False when the underlying API could not be resolved — expected on a future
    /// macOS release that removes it. The app must degrade cleanly, not crash.
    var canControl: Bool { get }
    func read() -> Double?
    func write(_ value: Double)
}

/// In-memory actuator for tests and diagnostics.
public final class FakeBrightness: BrightnessControlling {
    public private(set) var value: Double
    public private(set) var writes: [Double] = []
    public let canControl: Bool

    public init(value: Double = 0.5, canControl: Bool = true) {
        self.value = value
        self.canControl = canControl
    }

    public func read() -> Double? { value }

    public func write(_ newValue: Double) {
        guard canControl else { return }
        let clamped = min(max(newValue, 0.0), 1.0)
        value = clamped
        writes.append(clamped)
    }

    /// Simulates an external change — a brightness key press or the ambient
    /// sensor — without recording it as one of our writes.
    public func externalChange(to newValue: Double) {
        value = min(max(newValue, 0.0), 1.0)
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test`
Expected: PASS. This task adds 3 tests; the suite total is now 29.

- [ ] **Step 5: Implement the real actuator**

`Sources/AutoBrightnessApp/DisplayServicesBrightness.swift`:

```swift
import AutoBrightnessCore
import CoreGraphics
import Foundation

private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias DSCan = @convention(c) (CGDirectDisplayID) -> Int32
private typealias CDGet = @convention(c) (CGDirectDisplayID) -> Double
private typealias CDSet = @convention(c) (CGDirectDisplayID, Double) -> Void

/// Reads and writes the built-in panel's backlight through private frameworks.
///
/// There is no public API for this. Symbols are resolved at runtime rather than
/// linked, so a future macOS that removes them yields `canControl == false`
/// instead of a launch failure.
public final class DisplayServicesBrightness: BrightnessControlling {
    private let displayID: CGDirectDisplayID
    private let dsGet: DSGet?
    private let dsSet: DSSet?
    private let cdGet: CDGet?
    private let cdSet: CDSet?

    public init(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.displayID = displayID

        let displayServices = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        func ds(_ name: String) -> UnsafeMutableRawPointer? {
            guard let handle = displayServices else { return nil }
            return dlsym(handle, name)
        }

        var canChange = true
        if let symbol = ds("DisplayServicesCanChangeBrightness") {
            let fn = unsafeBitCast(symbol, to: DSCan.self)
            canChange = fn(displayID) != 0
        }

        if canChange,
           let get = ds("DisplayServicesGetBrightness"),
           let set = ds("DisplayServicesSetBrightness") {
            dsGet = unsafeBitCast(get, to: DSGet.self)
            dsSet = unsafeBitCast(set, to: DSSet.self)
        } else {
            dsGet = nil
            dsSet = nil
        }

        // Fallback path, used only if DisplayServices is unavailable.
        let coreDisplay = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            RTLD_LAZY
        )
        func cd(_ name: String) -> UnsafeMutableRawPointer? {
            guard let handle = coreDisplay else { return nil }
            return dlsym(handle, name)
        }
        if let get = cd("CoreDisplay_Display_GetUserBrightness"),
           let set = cd("CoreDisplay_Display_SetUserBrightness") {
            cdGet = unsafeBitCast(get, to: CDGet.self)
            cdSet = unsafeBitCast(set, to: CDSet.self)
        } else {
            cdGet = nil
            cdSet = nil
        }
    }

    public var canControl: Bool {
        (dsGet != nil && dsSet != nil) || (cdGet != nil && cdSet != nil)
    }

    public func read() -> Double? {
        if let dsGet {
            var value: Float = 0
            if dsGet(displayID, &value) == 0 {
                return Double(value)
            }
        }
        if let cdGet {
            return cdGet(displayID)
        }
        return nil
    }

    public func write(_ value: Double) {
        let clamped = min(max(value, 0.0), 1.0)
        if let dsSet {
            _ = dsSet(displayID, Float(clamped))
            return
        }
        cdSet?(displayID, clamped)
    }
}
```

- [ ] **Step 6: Verify the real actuator builds and works**

Run: `swift build`
Expected: builds with no errors.

Then confirm against the hardware with a throwaway check. Add this temporarily to `Sources/AutoBrightnessApp/main.swift`, run it, and revert the file afterwards:

```swift
import AutoBrightnessCore

let control = DisplayServicesBrightness()
print("canControl:", control.canControl)
guard let original = control.read() else {
    fatalError("could not read brightness")
}
print("original:", original)
control.write(min(original + 0.05, 1.0))
Thread.sleep(forTimeInterval: 0.3)
print("after write:", control.read() ?? -1)
control.write(original)
Thread.sleep(forTimeInterval: 0.3)
print("restored:", control.read() ?? -1)
```

Run: `swift run AutoBrightnessApp`
Expected: `canControl: true`, the brightness visibly moves and returns, and `restored` matches `original`.

Then restore the stub:

```bash
git checkout Sources/AutoBrightnessApp/main.swift
```

- [ ] **Step 7: Commit**

```bash
git add Sources/AutoBrightnessCore/BrightnessControlling.swift Sources/AutoBrightnessApp/DisplayServicesBrightness.swift Tests/AutoBrightnessCoreTests/FakeBrightnessTests.swift
git commit -m "feat: brightness actuator protocol and DisplayServices implementation"
```

---

### Task 6: Ambient-sensor interaction probe

This task answers a question the spec deliberately left open: whether writing brightness at 2 Hz makes macOS's ambient auto-brightness drift.

**Its outcome is documentation-only.** No code in Tasks 7–10 changes either way; a positive result adds a warning to the menu (Task 9) and to the README (Task 10), telling the user to turn "Automatically adjust brightness" off. It runs here rather than at the end so the finding is in hand before anyone spends time tuning the control law against a moving baseline.

**Files:**
- Modify: `Sources/ALSProbe/main.swift`
- Create: `docs/superpowers/notes/als-probe-result.md`

**Interfaces:**
- Consumes: `DisplayServicesBrightness` — but `ALSProbe` cannot import `AutoBrightnessApp` (executables are not importable), so the probe resolves the symbols itself in a small self-contained block.
- Produces: a written finding; no code other tasks depend on.

- [ ] **Step 1: Write the probe**

`Sources/ALSProbe/main.swift`:

```swift
import CoreGraphics
import Foundation

// Self-contained symbol resolution: executable targets cannot import each other,
// so this duplicates the few lines it needs rather than restructuring the app.
private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32

let handle = dlopen(
    "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
    RTLD_LAZY
)
guard let handle,
      let getSymbol = dlsym(handle, "DisplayServicesGetBrightness"),
      let setSymbol = dlsym(handle, "DisplayServicesSetBrightness") else {
    fatalError("DisplayServices brightness symbols unavailable")
}
let get = unsafeBitCast(getSymbol, to: DSGet.self)
let set = unsafeBitCast(setSymbol, to: DSSet.self)
let display = CGMainDisplayID()

func brightness() -> Double {
    var value: Float = 0
    _ = get(display, &value)
    return Double(value)
}

let original = brightness()
print("""
ALS interaction probe
=====================
Before starting: turn ON "Automatically adjust brightness" in
System Settings > Displays, hold the lighting in the room steady, and leave a
static window on screen. Do not touch the brightness keys while this runs.

Original brightness: \(String(format: "%.4f", original))
Holding brightness at \(String(format: "%.4f", original)) with 2 Hz writes for 3 minutes.
If the ambient controller fights us, the observed value will drift away from the
written value between writes.
""")

var maxDrift = 0.0
let ticks = 360  // 3 minutes at 2 Hz
for tick in 0..<ticks {
    let observed = brightness()
    let drift = observed - original
    maxDrift = max(maxDrift, abs(drift))
    if tick % 20 == 0 {
        print(String(
            format: "t=%5.1fs  observed=%.4f  drift=%+.4f",
            Double(tick) / 2.0, observed, drift
        ))
    }
    set(display, Float(original))
    Thread.sleep(forTimeInterval: 0.5)
}

set(display, Float(original))
print(String(format: "\nMax drift observed: %.4f", maxDrift))
print(maxDrift < 0.01
    ? "RESULT: no meaningful interference. Coexistence holds."
    : "RESULT: drift detected. The app must tell the user to disable auto-brightness.")
```

- [ ] **Step 2: Run the probe**

Run: `swift run ALSProbe`

This takes 3 minutes and holds the backlight at its current level. Follow the on-screen setup instructions before starting.

Expected: a drift figure and a verdict line.

- [ ] **Step 3: Record the finding**

Create `docs/superpowers/notes/als-probe-result.md` with the date, the measured max drift, the verdict, and the raw output. If drift was detected, note that Task 9's menu must carry a warning telling the user to turn "Automatically adjust brightness" off — the app cannot detect the setting itself, since `DisplayServicesGetAutoBrightness` does not exist.

- [ ] **Step 4: Commit**

```bash
git add Sources/ALSProbe/main.swift docs/superpowers/notes/als-probe-result.md
git commit -m "test: measure ambient auto-brightness interaction"
```

---

### Task 7: Coordinator

**Files:**
- Create: `Sources/AutoBrightnessCore/Coordinator.swift`
- Test: `Tests/AutoBrightnessCoreTests/CoordinatorTests.swift`

**Interfaces:**
- Consumes: `Controller`, `ControllerSettings`, `BrightnessControlling`, `FakeBrightness`
- Produces: `final class Coordinator` with `init(brightness: BrightnessControlling, settings: ControllerSettings)`, `var settings: ControllerSettings`, `var isEnabled: Bool`, `var isPaused: Bool`, `private(set) var baseline: Double`, `private(set) var lastLuminance: Double`, `private(set) var appliedOffset: Double`, `func tick(luminance: Double)`, `func suspend()`, `func resume()`, `func restoreBaseline()`

Baseline tracking is the mechanism that lets the app coexist with the user: each tick it compares the hardware's actual brightness against what it last wrote, and any discrepancy is attributed to the user or the ambient sensor and folded into the baseline.

- [ ] **Step 1: Write the failing test**

`Tests/AutoBrightnessCoreTests/CoordinatorTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

@Test("A white page drives brightness below the starting point")
func dimsOnWhitePage() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(abs(coordinator.baseline - 0.60) < 1e-6)
    #expect(abs((fake.read() ?? 0) - 0.40) < 1e-6)
}

@Test("A pressed brightness key re-baselines instead of being fought")
func userAdjustmentRebaselines() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    // Settled: baseline 0.60, offset -0.20, hardware at 0.40.
    // The user presses brightness-up twice: 2 x 1/16.
    fake.externalChange(to: 0.525)
    coordinator.tick(luminance: 0.95)

    // Their adjustment must land exactly where they intended: total brightness
    // stays at what they set, and the content offset rides on top of it.
    #expect(abs(coordinator.baseline - 0.725) < 1e-6)
    #expect(abs((fake.read() ?? 0) - 0.525) < 1e-6)
}

@Test("Our own writes are not mistaken for user adjustments")
func ownWritesDoNotRebaseline() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(abs(coordinator.baseline - 0.60) < 1e-6)
}

@Test("Redundant writes are suppressed")
func noRedundantWrites() {
    let fake = FakeBrightness(value: 0.50)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<10 {
        coordinator.tick(luminance: 0.50)
    }
    // Mid-gray means zero offset, so nothing ever needs writing.
    #expect(fake.writes.isEmpty)
}

@Test("A disabled coordinator writes nothing")
func disabledDoesNothing() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    coordinator.isEnabled = false
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(fake.writes.isEmpty)
    #expect(fake.read() == 0.60)
}

@Test("Disabling restores the user's baseline")
func disablingRestores() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    coordinator.isEnabled = false
    #expect(abs((fake.read() ?? 0) - 0.60) < 1e-6)
}

@Test("Resume re-reads the baseline and ramps in from zero offset")
func resumeRampsIn() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    coordinator.suspend()

    // While asleep the user sets a very different level.
    fake.externalChange(to: 0.30)
    coordinator.resume()
    #expect(abs(coordinator.baseline - 0.30) < 1e-6)
    #expect(coordinator.appliedOffset == 0.0)

    // The first tick after resuming must not snap to the full offset.
    coordinator.tick(luminance: 0.95)
    #expect(abs(coordinator.appliedOffset) <= 0.05)
}

@Test("A suspended coordinator ignores ticks")
func suspendedIgnoresTicks() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    coordinator.suspend()
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(fake.writes.isEmpty)
}

@Test("An uncontrollable display is handled without crashing")
func unavailableDisplay() {
    let fake = FakeBrightness(value: 0.60, canControl: false)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(fake.writes.isEmpty)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test`
Expected: FAIL — `cannot find 'Coordinator' in scope`.

- [ ] **Step 3: Implement `Coordinator`**

`Sources/AutoBrightnessCore/Coordinator.swift`:

```swift
import Foundation

/// Owns the per-tick loop: read the hardware, work out what the user wants,
/// ask the controller for a target, and write it.
///
/// This class holds no display or capture dependency — it takes luminance as a
/// number and an actuator as a protocol — so its whole behavior is testable.
public final class Coordinator {
    /// A hardware/last-write discrepancy above this is attributed to the user or
    /// the ambient sensor. Read-back was measured to be bit-exact, and the
    /// brightness keys step by 1/16, so this threshold is not close to either.
    static let externalChangeThreshold = 0.01
    /// Writes smaller than this are pointless; suppressing them keeps the app
    /// from touching the hardware 2x per second while nothing is happening.
    static let minimumWriteDelta = 0.002

    private let brightness: BrightnessControlling
    private var controller = Controller()
    private var lastWritten: Double?

    public var settings: ControllerSettings
    public private(set) var baseline: Double
    public private(set) var lastLuminance: Double = 0.5
    public private(set) var isPaused = false

    public var appliedOffset: Double { controller.appliedOffset }

    /// Turning this off restores the user's baseline immediately.
    public var isEnabled: Bool = true {
        didSet {
            guard oldValue != isEnabled else { return }
            if isEnabled {
                resume()
            } else {
                restoreBaseline()
            }
        }
    }

    public init(brightness: BrightnessControlling, settings: ControllerSettings = .defaults) {
        self.brightness = brightness
        self.settings = settings
        self.baseline = brightness.read() ?? 0.5
    }

    /// Advances one 2 Hz tick with a freshly measured content luminance.
    public func tick(luminance: Double) {
        lastLuminance = luminance
        guard isEnabled, !isPaused, brightness.canControl else { return }
        guard let actual = brightness.read() else { return }

        // Anything we did not write ourselves is the user's intent — a brightness
        // key, or the ambient sensor. Fold it into the baseline so their
        // adjustment lands exactly where they meant it to, and let the content
        // offset continue to ride on top. A timed lockout would be worse: it
        // produces a visible jump the moment it expires.
        if let lastWritten, abs(actual - lastWritten) > Self.externalChangeThreshold {
            baseline = actual - controller.appliedOffset
        } else if lastWritten == nil {
            baseline = actual
        }

        let target = controller.update(
            luminance: luminance,
            baseline: baseline,
            settings: settings
        )
        // Compare against `actual` when nothing has been written yet, so a scene
        // that needs no adjustment never touches the hardware at all.
        if abs(target - (lastWritten ?? actual)) >= Self.minimumWriteDelta {
            brightness.write(target)
            lastWritten = target
        }
    }

    /// Stops adjusting — display sleep, screen lock, or a manual pause.
    public func suspend() {
        guard !isPaused else { return }
        isPaused = true
        restoreBaseline()
    }

    /// Starts adjusting again, re-reading the baseline first. The offset restarts
    /// at zero so the app ramps in from wherever the user is now.
    public func resume() {
        isPaused = false
        controller.reset()
        lastWritten = nil
        if let actual = brightness.read() {
            baseline = actual
        }
    }

    /// Returns the panel to the user's level and forgets the applied offset.
    public func restoreBaseline() {
        guard brightness.canControl else { return }
        if lastWritten != nil {
            brightness.write(baseline)
        }
        lastWritten = nil
        controller.reset()
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `swift test`
Expected: PASS. This task adds 9 tests; the suite total is now 26.

- [ ] **Step 5: Run the whole suite**

Run: `swift test`
Expected: PASS, all tests from Tasks 1–7.

- [ ] **Step 6: Commit**

```bash
git add Sources/AutoBrightnessCore/Coordinator.swift Tests/AutoBrightnessCoreTests/CoordinatorTests.swift
git commit -m "feat: coordinator with baseline tracking and pause handling"
```

---

### Task 8: Screen sampler

**Files:**
- Create: `Sources/AutoBrightnessApp/ScreenSampler.swift`
- Modify: `Sources/AutoBrightnessApp/main.swift` (temporary harness, reverted in this task)

**Interfaces:**
- Consumes: `Frame`, `LuminanceAnalyzer`
- Produces: `enum SamplerStatus { case idle, running, permissionDenied, noDisplay, failed(String) }`; `@MainActor final class ScreenSampler` with `init(onFrame: @escaping @MainActor (Frame) -> Void, onStatus: @escaping @MainActor (SamplerStatus) -> Void)`, `func start() async`, `func stop() async`

There is no unit test here — this class is a thin adapter over a system framework, and the logic worth testing (the luminance math) already has one. It is verified by a manual harness instead.

- [ ] **Step 1: Implement `ScreenSampler`**

`Sources/AutoBrightnessApp/ScreenSampler.swift`:

```swift
import AutoBrightnessCore
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

public enum SamplerStatus: Equatable {
    case idle
    case running
    case permissionDenied
    case noDisplay
    case failed(String)
}

/// Captures the built-in display at 2 fps, downscaled to a thumbnail, and hands
/// each frame to the analyzer.
///
/// The capture size is tiny on purpose: the compositor does the downscale on the
/// GPU, so a 64x40 frame costs almost nothing and still carries all the
/// information the luminance statistic needs.
@MainActor
public final class ScreenSampler: NSObject {
    /// Capture width in pixels. Height is derived from the display's aspect
    /// ratio — a fixed 16:9 size on a 16:10 panel would make ScreenCaptureKit pad
    /// the frame, and that padding is indistinguishable from real letterboxing.
    static let captureWidth = 64

    private var stream: SCStream?
    private let outputQueue = DispatchQueue(label: "com.mahmoudparham.autobrightness.capture")
    private let onFrame: @MainActor (Frame) -> Void
    private let onStatus: @MainActor (SamplerStatus) -> Void

    public init(
        onFrame: @escaping @MainActor (Frame) -> Void,
        onStatus: @escaping @MainActor (SamplerStatus) -> Void
    ) {
        self.onFrame = onFrame
        self.onStatus = onStatus
        super.init()
    }

    public func start() async {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            onStatus(.permissionDenied)
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: false
            )
            let mainID = CGMainDisplayID()
            guard let display = content.displays.first(where: { $0.displayID == mainID })
                ?? content.displays.first else {
                onStatus(.noDisplay)
                return
            }

            let configuration = SCStreamConfiguration()
            configuration.width = Self.captureWidth
            let aspect = Double(display.height) / Double(display.width)
            configuration.height = max(Int((Double(Self.captureWidth) * aspect).rounded()), 1)
            configuration.pixelFormat = kCVPixelFormatType_32BGRA
            configuration.minimumFrameInterval = CMTime(value: 1, timescale: 2)
            configuration.queueDepth = 1
            configuration.showsCursor = false
            configuration.capturesAudio = false

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
            try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
            try await stream.startCapture()
            self.stream = stream
            onStatus(.running)
        } catch {
            onStatus(.failed(error.localizedDescription))
        }
    }

    public func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        onStatus(.idle)
    }
}

extension ScreenSampler: SCStreamOutput {
    public nonisolated func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              sampleBuffer.isValid,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let frame = Self.makeFrame(from: imageBuffer) else { return }
        Task { @MainActor in
            self.onFrame(frame)
        }
    }

    /// Copies a `CVPixelBuffer` into a tightly packed `Frame`.
    ///
    /// The buffer's `bytesPerRow` is usually larger than `width * 4` because of
    /// alignment padding, so rows must be copied individually — reading it as one
    /// contiguous block would skew every row and corrupt the luminance reading.
    nonisolated static func makeFrame(from buffer: CVPixelBuffer) -> Frame? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
        let pointer = base.assumingMemoryBound(to: UInt8.self)

        var bgra = [UInt8]()
        bgra.reserveCapacity(width * height * 4)
        for row in 0..<height {
            let start = row * bytesPerRow
            for column in 0..<(width * 4) {
                bgra.append(pointer[start + column])
            }
        }
        return Frame(width: width, height: height, bgra: bgra)
    }
}
```

- [ ] **Step 2: Add a temporary harness to verify capture works**

Replace `Sources/AutoBrightnessApp/main.swift` with:

```swift
import AppKit
import AutoBrightnessCore

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

Task { @MainActor in
    let sampler = ScreenSampler(
        onFrame: { frame in
            let luminance = LuminanceAnalyzer.analyze(frame)
            print(String(format: "%dx%d  L=%.3f", frame.width, frame.height, luminance))
        },
        onStatus: { status in
            print("status:", status)
        }
    )
    await sampler.start()
}

app.run()
```

- [ ] **Step 3: Run the harness and confirm the numbers respond to content**

Run: `swift run AutoBrightnessApp`

macOS will prompt for Screen Recording permission on first run; grant it and run again. With the harness running, put a blank white window on screen, then a dark full-screen window.

Expected: `status: running`, frames reported as `64x41` (or whatever matches the panel's aspect ratio), roughly two lines per second, `L` above 0.9 on a white window and below 0.35 on a dark one. Stop with Ctrl-C.

If `L` does not move, or the dimensions look wrong, that is a real defect — do not proceed until the numbers track what is on screen.

- [ ] **Step 4: Revert the harness**

```bash
git checkout Sources/AutoBrightnessApp/main.swift
```

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessApp/ScreenSampler.swift
git commit -m "feat: ScreenCaptureKit sampler at 2 fps"
```

---

### Task 9: Menu bar application

**Files:**
- Create: `Sources/AutoBrightnessApp/PauseMonitor.swift`
- Create: `Sources/AutoBrightnessApp/AppModel.swift`
- Create: `Sources/AutoBrightnessApp/SettingsView.swift`
- Modify: `Sources/AutoBrightnessApp/main.swift`

**Interfaces:**
- Consumes: `Coordinator`, `ControllerSettings`, `DisplayServicesBrightness`, `ScreenSampler`, `SamplerStatus`, `LuminanceAnalyzer`
- Produces: `@MainActor final class PauseMonitor` with `init(onSuspend: @escaping @MainActor () -> Void, onResume: @escaping @MainActor () -> Void)` and `func start()`; `@MainActor @Observable final class AppModel` with `var isEnabled: Bool`, `var strength: Double`, `var maxOffset: Double`, `var launchAtLogin: Bool`, `var status: SamplerStatus`, `var luminance: Double`, `var offset: Double`, `var baseline: Double`, `func start() async`, `func pauseForAnHour()`, `func quit()`; `struct SettingsView: View`

- [ ] **Step 1: Implement `PauseMonitor`**

`Sources/AutoBrightnessApp/PauseMonitor.swift`:

```swift
import AppKit
import Foundation

/// Watches for the conditions under which adjusting brightness is pointless or
/// unwelcome: the display asleep, the screen locked, the machine suspended.
@MainActor
public final class PauseMonitor {
    private let onSuspend: @MainActor () -> Void
    private let onResume: @MainActor () -> Void

    public init(
        onSuspend: @escaping @MainActor () -> Void,
        onResume: @escaping @MainActor () -> Void
    ) {
        self.onSuspend = onSuspend
        self.onResume = onResume
    }

    public func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend() }
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume() }
        }
        workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend() }
        }
        workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume() }
        }

        // Screen lock is only published on the distributed centre.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend() }
        }
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume() }
        }
    }
}
```

- [ ] **Step 2: Implement `AppModel`**

`Sources/AutoBrightnessApp/AppModel.swift`:

```swift
import AppKit
import AutoBrightnessCore
import Foundation
import Observation
import ServiceManagement

/// Binds the core coordinator to the sampler, the pause monitor, and the UI.
@MainActor
@Observable
public final class AppModel {
    private let coordinator: Coordinator
    private var sampler: ScreenSampler?
    private var pauseMonitor: PauseMonitor?
    private var pauseTimer: Timer?

    public var status: SamplerStatus = .idle
    public private(set) var luminance: Double = 0.5
    public private(set) var offset: Double = 0
    public private(set) var baseline: Double = 0.5
    public private(set) var pausedUntilLabel: String?
    public let canControlBrightness: Bool

    public var isEnabled: Bool {
        didSet {
            coordinator.isEnabled = isEnabled
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            refreshReadouts()
        }
    }

    public var strength: Double {
        didSet {
            coordinator.settings.strength = strength
            UserDefaults.standard.set(strength, forKey: "strength")
        }
    }

    public var maxOffset: Double {
        didSet {
            coordinator.settings.maxOffset = maxOffset
            UserDefaults.standard.set(maxOffset, forKey: "maxOffset")
        }
    }

    public var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("launch at login failed: \(error.localizedDescription)")
            }
        }
    }

    public init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "isEnabled": true,
            "strength": ControllerSettings.defaults.strength,
            "maxOffset": ControllerSettings.defaults.maxOffset,
        ])

        var settings = ControllerSettings.defaults
        settings.strength = defaults.double(forKey: "strength")
        settings.maxOffset = defaults.double(forKey: "maxOffset")

        let brightness = DisplayServicesBrightness()
        canControlBrightness = brightness.canControl
        coordinator = Coordinator(brightness: brightness, settings: settings)

        isEnabled = defaults.bool(forKey: "isEnabled")
        strength = settings.strength
        maxOffset = settings.maxOffset
        launchAtLogin = SMAppService.mainApp.status == .enabled

        coordinator.isEnabled = isEnabled
        baseline = coordinator.baseline
    }

    public func start() async {
        let monitor = PauseMonitor(
            onSuspend: { [weak self] in self?.coordinator.suspend() },
            onResume: { [weak self] in self?.coordinator.resume() }
        )
        monitor.start()
        pauseMonitor = monitor

        let sampler = ScreenSampler(
            onFrame: { [weak self] frame in
                guard let self else { return }
                let value = LuminanceAnalyzer.analyze(frame)
                self.coordinator.tick(luminance: value)
                self.refreshReadouts()
            },
            onStatus: { [weak self] status in
                self?.status = status
            }
        )
        self.sampler = sampler
        await sampler.start()
    }

    /// Stops adjusting for an hour, then resumes on its own.
    public func pauseForAnHour() {
        coordinator.suspend()
        pausedUntilLabel = Self.timeFormatter.string(
            from: Date().addingTimeInterval(3600)
        )
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator.resume()
                self?.pausedUntilLabel = nil
            }
        }
    }

    public func endPause() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntilLabel = nil
        coordinator.resume()
    }

    public func quit() {
        coordinator.restoreBaseline()
        NSApplication.shared.terminate(nil)
    }

    private func refreshReadouts() {
        luminance = coordinator.lastLuminance
        offset = coordinator.appliedOffset
        baseline = coordinator.baseline
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
```

- [ ] **Step 3: Implement `SettingsView`**

`Sources/AutoBrightnessApp/SettingsView.swift`:

```swift
import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showDebug = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Adjust brightness to content", isOn: $model.isEnabled)
                .toggleStyle(.switch)

            if !model.canControlBrightness {
                Label(
                    "Brightness control is unavailable on this system.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            statusLabel

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Strength")
                Slider(value: $model.strength, in: 0.2...0.9)
                Text("How strongly content pulls brightness away from your setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Maximum change: \(Int(model.maxOffset * 100))%")
                Slider(value: $model.maxOffset, in: 0.05...0.35)
            }

            Divider()

            if let label = model.pausedUntilLabel {
                HStack {
                    Text("Paused until \(label)")
                        .font(.caption)
                    Spacer()
                    Button("Resume", action: model.endPause)
                }
            } else {
                Button("Pause for 1 hour", action: model.pauseForAnHour)
            }

            Toggle("Open at login", isOn: $model.launchAtLogin)

            DisclosureGroup("Details", isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Screen luminance: %.3f", model.luminance))
                    Text(String(format: "Applied offset: %+.3f", model.offset))
                    Text(String(format: "Your baseline: %.3f", model.baseline))
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button("Quit", action: model.quit)
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.status {
        case .running:
            EmptyView()
        case .idle:
            Text("Starting…").font(.caption).foregroundStyle(.secondary)
        case .permissionDenied:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Screen Recording permission is required.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Open System Settings") {
                    let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    )!
                    NSWorkspace.shared.open(url)
                }
                .font(.caption)
            }
        case .noDisplay:
            Text("No built-in display found.").font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            Text("Capture failed: \(message)").font(.caption).foregroundStyle(.orange)
        }
    }
}
```

- [ ] **Step 4: Implement the app bootstrap**

`Sources/AutoBrightnessApp/main.swift`:

```swift
import AppKit
import SwiftUI

/// Status-item bootstrap rather than SwiftUI's `MenuBarExtra`: a SwiftPM
/// executable is not a bundle at build time, and driving `NSStatusItem`
/// directly keeps the app working whether or not it has been bundled yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sun.max",
            accessibilityDescription: "Auto Brightness"
        )
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: SettingsView(model: model)
        )
        self.popover = popover

        Task { await model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.quit()
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
```

- [ ] **Step 5: Build and run**

Run: `swift build && swift run AutoBrightnessApp`

Expected: a sun icon appears in the menu bar; clicking it opens the settings popover; the Details section shows a luminance figure that changes as you switch between light and dark windows, and brightness visibly follows.

- [ ] **Step 6: Verify the behavior the app exists for**

With the app running, check each of these by eye:

1. Open a blank white document full screen. Brightness drops over ~2 seconds and settles.
2. Play a dark video full screen. Brightness rises.
3. Play a **letterboxed** dark video full screen. Brightness rises — it must not fall. This is the case the letterbox crop exists for.
4. Press a brightness key. The panel moves by the full amount you asked for and stays there; the app does not fight you.
5. Scroll quickly through a document with mixed light and dark images. Brightness does not visibly twitch.
6. Toggle the app off. Brightness returns to your baseline.
7. Quit the app. Brightness returns to your baseline.

If any of these fail, fix before continuing.

- [ ] **Step 7: Commit**

```bash
git add Sources/AutoBrightnessApp
git commit -m "feat: menu bar app with settings, pause handling and debug readout"
```

---

### Task 10: Bundling and documentation

**Files:**
- Create: `Resources/Info.plist`
- Create: `Scripts/make-bundle.sh`
- Create: `README.md`

**Interfaces:**
- Consumes: the built `AutoBrightnessApp` executable
- Produces: `AutoBrightness.app` in the repository root (git-ignored)

- [ ] **Step 1: Create the bundle metadata**

`Resources/Info.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>AutoBrightness</string>
    <key>CFBundleDisplayName</key>
    <string>Auto Brightness</string>
    <key>CFBundleIdentifier</key>
    <string>com.mahmoudparham.AutoBrightness</string>
    <key>CFBundleExecutable</key>
    <string>AutoBrightness</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSScreenCaptureUsageDescription</key>
    <string>Auto Brightness samples the screen at a low resolution to measure how bright the displayed content is. Nothing is recorded, stored, or sent anywhere.</string>
</dict>
</plist>
```

- [ ] **Step 2: Create the bundling script**

`Scripts/make-bundle.sh`:

```bash
#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

APP="AutoBrightness.app"

swift build -c release --product AutoBrightnessApp

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/AutoBrightnessApp "$APP/Contents/MacOS/AutoBrightness"
cp Resources/Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature. macOS ties Screen Recording permission to the code signature,
# so a rebuild can re-trigger the permission prompt. If that becomes tiresome,
# sign with a free personal development certificate for a stable identity.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Install with: cp -R $APP /Applications/"
```

Make it executable:

```bash
chmod +x Scripts/make-bundle.sh
```

- [ ] **Step 3: Confirm build outputs are ignored**

`.gitignore` already contains `.build/` and `*.app/`. Verify with:

Run: `git status --porcelain` after a build
Expected: no `.build` or `AutoBrightness.app` entries listed.

- [ ] **Step 4: Build and install the bundle**

Run: `./Scripts/make-bundle.sh && cp -R AutoBrightness.app /Applications/ && open /Applications/AutoBrightness.app`

Expected: the app launches with no dock icon, prompts for Screen Recording permission if it has not been granted to this signature, and the menu bar icon appears.

- [ ] **Step 5: Write the README**

`README.md` covering: what the app does; the ±20% offset model and why it rides on top of your own brightness rather than replacing it; the Screen Recording requirement and why the app needs it; the finding from Task 6 about macOS auto-brightness (including, if drift was measured, the instruction to turn "Automatically adjust brightness" off); build and install instructions; the note that this uses private APIs and may break on a future macOS release; and the fact that rebuilding can re-trigger the permission prompt because of ad-hoc signing.

- [ ] **Step 6: Run the full test suite one last time**

Run: `swift test`
Expected: PASS, all tests.

- [ ] **Step 7: Commit**

```bash
git add Resources Scripts README.md .gitignore
git commit -m "feat: app bundling script and documentation"
```

---

## Verification Summary

When every task is complete, all of the following must hold:

- `swift test` passes.
- A blank white full-screen window visibly dims the display within ~3 seconds.
- A letterboxed dark video visibly brightens the display — this is the regression the analyzer's crop step exists to prevent.
- A dark-mode editor produces only a small lift, not the same treatment as a dark film.
- Pressing a brightness key moves the panel by the full requested amount and is not undone.
- Toggling the app off, pausing it, or quitting it all return the panel to the user's baseline.
- The Task 6 finding about ambient auto-brightness is recorded and reflected in the README.
