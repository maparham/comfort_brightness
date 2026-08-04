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
