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
