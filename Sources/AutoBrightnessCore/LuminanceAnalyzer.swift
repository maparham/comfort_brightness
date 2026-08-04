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
