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
    /// How many ticks a measured actuator bias stays trusted before it has to be
    /// re-earned by another withheld write. A bias hypothesis explains a ramp of
    /// exactly that rate perfectly, so an unchallenged one can blind the app to
    /// real movement; three seconds is short enough that it cannot do so for
    /// long.
    static let biasRecheckInterval = 6
    /// How many consecutive intervals the panel must sit still, with the app
    /// writing nothing at all, before its stillness is accepted as an actuator
    /// bias. One interval is not enough: an external ramp that happens to pause
    /// for half a second looks exactly the same, and half of all ramp episodes
    /// end that way. Two seconds of genuine stillness is a different claim, and
    /// a stepped ramp — which is the shape the ambient controller produces —
    /// cannot fake it.
    static let probeStillIntervalsRequired = 4

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
    /// Consecutive intervals the panel has been observed still during the
    /// current withheld-write probe.
    private var probeStillIntervals = 0
    /// Ticks of trust left in `biasEstimate` before another withheld write has
    /// to confirm it.
    private var biasTrustRemaining = 0
    /// How much apparent movement `biasEstimate` has explained away since it was
    /// last confirmed. If the bias turns out to have been a ramp all along, this
    /// is exactly the movement it swallowed, and is handed back.
    private var biasExplained: Double = 0
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
            // Movement over the last interval alone. When our own write refreshed
            // the anchor, that is the whole discrepancy less the actuator's known
            // bias; when it did not, the bias is already in the previous reading
            // and cancels in the difference — which is why a withheld tick
            // measures the truth even while a wrong bias is being subtracted.
            let movement = didRefreshAnchor
                ? rawDiscrepancy - biasEstimate
                : rawDiscrepancy - lastRawDiscrepancy
            lastRawDiscrepancy = rawDiscrepancy

            if isProbingActuator {
                // A probe in progress: we are writing nothing at all, which is the
                // only condition under which movement can be measured rather than
                // overwritten. It runs until the answer is unambiguous — either
                // the panel moves, or it holds still for long enough that a ramp
                // pausing cannot account for it.
                externalMovement += movement
                if abs(movement) <= Self.repeatedDiscrepancyTolerance {
                    probeStillIntervals += 1
                    guard probeStillIntervals >= Self.probeStillIntervalsRequired else {
                        didRefreshAnchor = false
                        return
                    }
                    // Still, with our hands off it, for two solid seconds: the
                    // discrepancy is the actuator reading back something other
                    // than what it was given. Record it and subtract it, so it
                    // cannot fold itself into the baseline twice a second until
                    // the panel hits a rail — but only on trust, which expires
                    // (see `biasRecheckInterval`).
                    isProbingActuator = false
                    probeStillIntervals = 0
                    biasEstimate = rawDiscrepancy
                    biasTrustRemaining = Self.biasRecheckInterval
                    biasExplained = 0
                    externalMovement = 0
                    lastMovement = nil
                } else {
                    isProbingActuator = false
                    probeStillIntervals = 0
                    // It kept moving with our hands off it: real.
                    if biasEstimate != 0, biasExplained * movement > 0 {
                        // And it was moving in the direction the "bias" was
                        // pulling, which means the bias was this same movement
                        // misread as instrumentation — a ramp that happened to
                        // pause on the tick we last looked. Everything it
                        // explained away was real; hand it back.
                        externalMovement += biasExplained
                    }
                    biasEstimate = 0
                    biasExplained = 0
                    // With the bias now zero, the whole discrepancy is visible
                    // external displacement.
                    followPanel(actual: actual, visibleDisplacement: rawDiscrepancy)
                    lastMovement = movement
                }
            } else if biasEstimate != 0, biasTrustRemaining <= 0 {
                // Trust has run out. A bias of ε and a ramp of ε per tick produce
                // identical readings, so an unchallenged bias is indistinguishable
                // from being blind to a ramp at exactly that rate. Withhold a
                // write and make it prove itself again.
                isProbingActuator = true
                probeStillIntervals = 0
                didRefreshAnchor = false
                return
            } else {
                externalMovement += movement
                if didRefreshAnchor, biasEstimate != 0 {
                    biasExplained += biasEstimate
                    biasTrustRemaining -= 1
                }

                if abs(externalMovement) > Self.externalChangeThreshold {
                    if let previous = lastMovement,
                       abs(movement) > Self.repeatedDiscrepancyTolerance,
                       abs(movement - previous) <= Self.repeatedDiscrepancyTolerance {
                        // The same movement two ticks running. While we write every
                        // tick our own write re-anchors the panel, so a constant
                        // read-back bias and a steady external ramp produce
                        // *identical* readings — no passive statistic can tell them
                        // apart. So stop writing for exactly one tick and look: a
                        // bias stays put, a ramp keeps going.
                        isProbingActuator = true
                        probeStillIntervals = 0
                        lastMovement = movement
                        didRefreshAnchor = false
                        return
                    }
                    followPanel(
                        actual: actual,
                        visibleDisplacement: rawDiscrepancy - biasEstimate
                    )
                    lastMovement = movement
                } else {
                    lastMovement = movement
                }
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
        probeStillIntervals = 0
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
        // Only the write is conditional. An actuator that has gone away — the
        // lid closed on a docked machine — is a reason not to touch hardware,
        // never a reason to keep a stale offset and anchor on the books.
        if brightness.canControl, lastWritten != nil {
            brightness.write(baseline)
        }
        lastWritten = nil
        resetExternalTracking()
        didRefreshAnchor = false
        isCatchingUp = false
        controller.reset()
    }
}
