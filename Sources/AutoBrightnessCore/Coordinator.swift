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
    /// Hard bound on how far the baseline may move in one tick. A brightness key
    /// steps by 1/16, so no single real keypress comes near this; a larger jump
    /// (a slider dragged across its range) is followed over the next few ticks
    /// instead of in one leap, and nothing is written while catching up.
    static let maxBaselineStepPerTick = 0.25

    private let brightness: BrightnessControlling
    private var controller = Controller()
    private var lastWritten: Double?
    /// The previous tick's hardware-versus-last-write discrepancy, used to tell a
    /// user action from an actuator that simply reads back what it was not given.
    private var lastDiscrepancy: Double?
    /// True while the baseline is still stepping toward a large external move.
    private var isCatchingUp = false

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
        if isCatchingUp {
            // Still closing a gap opened by a large external move. Keep stepping
            // toward it and keep quiet until we arrive.
            isCatchingUp = moveBaseline(toward: actual - controller.appliedOffset)
            lastDiscrepancy = nil
        } else if let lastWritten {
            let discrepancy = actual - lastWritten
            if abs(discrepancy) > Self.externalChangeThreshold {
                // Distinguish intent from instrumentation. A user action is an
                // event: it appears once and the next read agrees with what we
                // then wrote. An actuator whose read-back is systematically off
                // by some fixed amount produces the *same* discrepancy on every
                // tick, forever. Re-baselining on that would walk the baseline by
                // that amount twice a second until the panel hits a rail.
                //
                // Holding `lastWritten` while we ignore it is what keeps this
                // safe: a genuine slow drift keeps accumulating against a frozen
                // reference and crosses back out of "unchanged" within a tick or
                // two, whereas a fixed read-back bias never grows.
                let isStatic = lastDiscrepancy.map {
                    abs(discrepancy - $0) <= Self.externalChangeThreshold
                } ?? false
                if !isStatic {
                    isCatchingUp = moveBaseline(toward: actual - controller.appliedOffset)
                }
                lastDiscrepancy = discrepancy
            } else {
                lastDiscrepancy = nil
            }
        } else {
            baseline = actual
            lastDiscrepancy = nil
        }

        let target = controller.update(
            luminance: luminance,
            baseline: baseline,
            settings: settings
        )
        // A move too large to absorb in one tick means the user is mid-gesture.
        // Adopt what they have set as the reference and write nothing this tick,
        // so catching up never turns into fighting them.
        if isCatchingUp {
            lastWritten = actual
            return
        }
        // Compare against `actual` when nothing has been written yet, so a scene
        // that needs no adjustment never touches the hardware at all.
        if abs(target - (lastWritten ?? actual)) >= Self.minimumWriteDelta {
            brightness.write(target)
            lastWritten = target
        }
    }

    /// Moves the baseline toward `desired`, at most `maxBaselineStepPerTick`.
    /// Returns true when the step was clamped, i.e. we have not arrived yet.
    private func moveBaseline(toward desired: Double) -> Bool {
        let step = desired - baseline
        guard abs(step) > Self.maxBaselineStepPerTick else {
            baseline = desired
            return false
        }
        baseline += step > 0 ? Self.maxBaselineStepPerTick : -Self.maxBaselineStepPerTick
        return true
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
        lastDiscrepancy = nil
        isCatchingUp = false
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
        lastDiscrepancy = nil
        isCatchingUp = false
        controller.reset()
    }
}
