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
