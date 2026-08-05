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
    /// The content luminance the user last set their brightness against, once
    /// they have set it by hand. Choosing a level while looking at something is
    /// a statement that the level suits that something, which is a better point
    /// of no adjustment than a fixed mid-grey guess.
    private var learnedNeutral: Double?

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

        var raw = -settings.strength * (smoothed - (learnedNeutral ?? settings.neutral))
        raw = min(max(raw, -settings.maxOffset), settings.maxOffset)

        // The deadband must not shield an offset that exceeds the clamp — that
        // happens when the user lowers the limit below what is already applied.
        let exceedsClamp = abs(appliedOffset) > settings.maxOffset
        if exceedsClamp || abs(raw - appliedOffset) >= settings.deadband {
            let delta = raw - appliedOffset
            let step = min(max(delta, -settings.slewPerTick), settings.slewPerTick)
            appliedOffset += step
        }

        return min(max(baseline + appliedOffset, settings.minBrightness), 1.0)
    }

    /// Takes what is on screen now as the point of no adjustment and drops the
    /// offset to nothing, so the level the user just chose is left exactly as
    /// they chose it and the next adjustment is measured from there.
    public mutating func reneutralize() {
        learnedNeutral = history.isEmpty ? nil : Self.median(history)
        appliedOffset = 0
    }

    /// Drops the offset and the history. Used on resume, so the app ramps in from
    /// the user's current level rather than snapping to a stale offset.
    ///
    /// The learned neutral goes too, unlike the coordinator's actuator bias: a
    /// bias describes the hardware and stays true across a sleep, but a neutral
    /// describes what was on screen at one moment, and that is exactly what a
    /// sleep or a disable makes stale.
    public mutating func reset() {
        appliedOffset = 0
        history.removeAll()
        learnedNeutral = nil
    }

    /// Upper median of the sample history.
    static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}
