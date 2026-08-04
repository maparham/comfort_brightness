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
