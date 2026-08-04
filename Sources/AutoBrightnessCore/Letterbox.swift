/// Detects and removes uniform black borders — letterbox bars on film, pillarbox
/// bars on 4:3 content, and any padding the capture pipeline adds.
///
/// Why it matters: a dark film *should* raise brightness, but the black bars are
/// not part of the picture. Left in, they drag the measured luminance below what
/// the visible content warrants, and the lift comes out larger than the scene
/// actually calls for. The crop measures the picture, not the frame around it.
///
/// The crop is deliberately conservative, because engaging it is a *step* change
/// in the measurement: content drifting across a naive threshold would swing the
/// offset with no user-perceptible cause. Three gates keep it off everything but
/// real bars:
///
/// 1. **Black, not merely dark.** The threshold is 0.005 linear (8-bit gray ≈ 20).
///    Real bars are composited as pure black; dark UI themes are not — VS Code
///    Dark+ `#1e1e1e` is 0.013 linear and One Dark `#282c34` is 0.026, both clear
///    of it.
/// 2. **Opposing edges.** Bars come in pairs. A dark region on one edge only is a
///    dock, a sidebar or a terminal, and eroding it would merely center-weight the
///    measurement for no reason.
/// 3. **The remainder must not itself be bar-like.** If what survives the crop is
///    as dark as the bars, the frame is uniformly dark content — a black terminal,
///    a fade to black — and it must read as dark rather than have a quarter shaved
///    off every edge until only the text is left. This gate is also what makes the
///    crop safe at its own boundary: it can only disengage when the bars and the
///    content are indistinguishable, which is exactly when cropping or not
///    cropping makes no material difference to the result.
public enum Letterbox {
    /// Luminance below which a row or column counts as a black bar. Linear light.
    public static let barThreshold = 0.005

    /// Upper median: for even counts this is the higher of the two middle values.
    public static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }

    /// Removes black rows from the top and bottom and black columns from each
    /// side, subject to the three gates described above.
    ///
    /// A row counts as a bar when its *median* luminance is below `threshold`.
    /// The median rather than a high percentile: at 64px wide a subtitle
    /// downscales to a smear covering a substantial fraction of a row, and a p90
    /// test tolerates only 10% bright pixels. No subtitle spans half a row.
    ///
    /// At most `maxFraction` of each dimension is removed from each edge, so a
    /// bar deeper than the cap still leaves a usefully large region.
    public static func crop(
        _ map: [[Double]],
        threshold: Double = barThreshold,
        maxFraction: Double = 0.25
    ) -> [[Double]] {
        guard let first = map.first, !first.isEmpty else { return map }
        let rows = map.count
        let cols = first.count

        // Gate 2, horizontally: crop rows only when both the top and the bottom
        // are bars. One dark edge alone is UI chrome, not letterboxing.
        let maxRowCrop = Int(Double(rows) * maxFraction)
        let top = barDepth(count: rows, limit: maxRowCrop, threshold: threshold) {
            median(map[$0])
        }
        let bottom = barDepth(count: rows, limit: maxRowCrop, threshold: threshold) {
            median(map[rows - 1 - $0])
        }
        var result = map
        if top > 0, bottom > 0, top + bottom < rows {
            result = Array(map[top..<(rows - bottom)])
        }

        // Gate 2, vertically: the same rule for pillarbox bars.
        let maxColCrop = Int(Double(cols) * maxFraction)
        let slice = result
        let left = barDepth(count: cols, limit: maxColCrop, threshold: threshold) {
            median(column(slice, $0))
        }
        let right = barDepth(count: cols, limit: maxColCrop, threshold: threshold) {
            median(column(slice, cols - 1 - $0))
        }
        if left > 0, right > 0, left + right < cols {
            result = slice.map { Array($0[left..<(cols - right)]) }
        }

        // Gate 3: if what is left is as dark as the bars, this was not a bordered
        // picture but uniformly dark content. Measure it as it is.
        let retained = result.flatMap { $0 }
        guard !retained.isEmpty, median(retained) > threshold else { return map }
        return result
    }

    /// Counts consecutive bar-like lines inward from one edge, up to `limit`.
    private static func barDepth(
        count: Int,
        limit: Int,
        threshold: Double,
        lineMedian: (Int) -> Double
    ) -> Int {
        var depth = 0
        while depth < limit, depth < count, lineMedian(depth) < threshold {
            depth += 1
        }
        return depth
    }

    private static func column(_ map: [[Double]], _ index: Int) -> [Double] {
        map.map { $0[index] }
    }
}
