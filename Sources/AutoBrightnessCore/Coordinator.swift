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
    /// How close two consecutive discrepancies must be to count as "the same
    /// discrepancy again", which is what makes an actuator bias worth testing
    /// for. Deliberately tight: read-back on the measured path is bit-exact, so
    /// anything above float noise is movement, not instrumentation.
    static let repeatedDiscrepancyTolerance = 0.002

    private let brightness: BrightnessControlling
    private var controller = Controller()
    private var lastWritten: Double?
    /// The previous tick's raw hardware-versus-last-write discrepancy. Kept so
    /// that a tick on which nothing was written still yields the movement over
    /// that one interval rather than the total since the last write.
    private var lastRawDiscrepancy: Double = 0
    /// True when `lastWritten` was refreshed on the previous tick, i.e. the
    /// discrepancy measured now covers exactly one tick.
    private var didRefreshAnchor = false
    /// Unexplained movement since the baseline last followed the panel. Summing
    /// it is what lets a drift too slow to clear `externalChangeThreshold` on any
    /// single tick still be followed, instead of being overwritten each tick.
    private var externalMovement: Double = 0
    /// The previous tick's one-interval movement, used only to notice that the
    /// same movement is repeating and is therefore worth testing.
    private var lastMovement: Double?
    /// True on the tick after we deliberately withheld a write in order to see
    /// whether the panel keeps moving on its own. See `tick(luminance:)`.
    private var isProbingActuator = false
    /// Learned constant offset between what we write and what the actuator reads
    /// back. Subtracted from every discrepancy, so a lying actuator is measured
    /// once and then compensated instead of being re-absorbed twice a second.
    private var biasEstimate: Double = 0
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
            isCatchingUp = moveBaseline(toward: actual - biasEstimate - controller.appliedOffset)
            resetExternalTracking()
        } else if let lastWritten {
            let rawDiscrepancy = actual - lastWritten
            // How far the panel currently sits from where we put it, net of the
            // actuator's bias: the part of the external movement still visible.
            let visible = rawDiscrepancy - biasEstimate
            // Movement over the last interval alone. When our own write refreshed
            // the anchor, that is the whole discrepancy less the actuator's known
            // bias; when it did not, the bias is already in the previous reading
            // and cancels in the difference.
            let movement = didRefreshAnchor
                ? rawDiscrepancy - biasEstimate
                : rawDiscrepancy - lastRawDiscrepancy
            lastRawDiscrepancy = rawDiscrepancy
            externalMovement += movement

            if abs(externalMovement) > Self.externalChangeThreshold {
                if isProbingActuator {
                    // Last tick we withheld the write. Whatever the panel did
                    // while our hands were off it is the answer.
                    isProbingActuator = false
                    if abs(movement) <= Self.repeatedDiscrepancyTolerance {
                        // It stayed exactly where our last write left it, so
                        // nothing external is moving: the discrepancy is the
                        // actuator reading back something other than what it was
                        // given. Record it once and subtract it from here on,
                        // rather than folding it into the baseline twice a second
                        // until the panel hits a rail.
                        biasEstimate = rawDiscrepancy
                        externalMovement = 0
                        lastMovement = nil
                    } else {
                        // It kept moving on its own: real. Withholding one write
                        // delayed the response by half a second and lost none of
                        // the movement, because it is still there to be measured.
                        followPanel(actual: actual, visibleDisplacement: visible)
                        lastMovement = movement
                    }
                } else if let previous = lastMovement,
                          abs(movement) > Self.repeatedDiscrepancyTolerance,
                          abs(movement - previous) <= Self.repeatedDiscrepancyTolerance {
                    // The same movement two ticks running. While we write every
                    // tick our own write re-anchors the panel, so a constant
                    // read-back bias and a steady external ramp produce *identical*
                    // readings — no passive statistic can tell them apart. So stop
                    // writing for exactly one tick and look: a bias stays put, a
                    // ramp keeps going.
                    isProbingActuator = true
                    lastMovement = movement
                    didRefreshAnchor = false
                    return
                } else {
                    followPanel(actual: actual, visibleDisplacement: visible)
                    lastMovement = movement
                }
            } else {
                isProbingActuator = false
                lastMovement = movement
            }
        } else {
            baseline = actual - biasEstimate
            resetExternalTracking()
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
            lastRawDiscrepancy = 0
            didRefreshAnchor = true
            return
        }
        // Compare against `actual` when nothing has been written yet, so a scene
        // that needs no adjustment never touches the hardware at all.
        if abs(target - (lastWritten ?? actual)) >= Self.minimumWriteDelta {
            brightness.write(target)
            lastWritten = target
            lastRawDiscrepancy = 0
            didRefreshAnchor = true
        } else {
            didRefreshAnchor = false
        }
    }

    /// Takes the panel's current level as the user's intent, net of the offset we
    /// put there ourselves and of the actuator's measured bias.
    ///
    /// Movement slow enough to stay under `externalChangeThreshold` on a single
    /// tick is physically erased by our own next write, so the panel no longer
    /// shows it. `externalMovement` remembers it; adding back the part that is no
    /// longer visible is what makes a slow ambient ramp followed in full rather
    /// than a third at a time. When nothing was erased this reduces exactly to
    /// "the panel's level, less our offset".
    private func followPanel(actual: Double, visibleDisplacement: Double) {
        let erased = externalMovement - visibleDisplacement
        isCatchingUp = moveBaseline(
            toward: actual - biasEstimate - controller.appliedOffset + erased
        )
        externalMovement = 0
    }

    /// Forgets everything about external movement. Used wherever the anchor is
    /// about to be re-established from scratch.
    private func resetExternalTracking() {
        externalMovement = 0
        lastMovement = nil
        lastRawDiscrepancy = 0
        isProbingActuator = false
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
        resetExternalTracking()
        didRefreshAnchor = false
        isCatchingUp = false
        // `biasEstimate` deliberately survives: it describes the actuator, not
        // the session. Forgetting it would make the app re-learn — and re-absorb
        // — the same bias after every sleep/wake.
        if let actual = brightness.read() {
            // Read in the actuator's terms, stored in the terms we write in —
            // the same conversion the first tick after a reset applies. Without
            // it, every suspend/resume cycle would re-import the bias into the
            // baseline it was just removed from.
            baseline = actual - biasEstimate
        }
    }

    /// Returns the panel to the user's level and forgets the applied offset.
    public func restoreBaseline() {
        guard brightness.canControl else { return }
        if lastWritten != nil {
            brightness.write(baseline)
        }
        lastWritten = nil
        resetExternalTracking()
        didRefreshAnchor = false
        isCatchingUp = false
        controller.reset()
    }
}
