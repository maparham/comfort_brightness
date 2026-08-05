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
    /// How long a full-size adjustment takes to arrive, in seconds. One knob for
    /// the two things that make an adjustment feel abrupt: how big a step the
    /// offset may take each tick, and how long new content must hold before it is
    /// believed at all. Both are derived from it below.
    public var responseSeconds: Double
    /// Floor, so the panel is never driven to black.
    public var minBrightness: Double

    /// The rate the sampler delivers frames at, and so the rate the control law
    /// ticks at. Not a setting: it is a property of the capture configuration.
    static let tickRate = 2.0

    /// Guards the derivations below against a zero or negative value arriving
    /// from a decoded or hand-edited setting, which would otherwise divide by
    /// zero and freeze the offset.
    private var seconds: Double { Swift.max(responseSeconds, 0.5) }

    /// Maximum offset movement per tick, sized so a full-size adjustment lands in
    /// `responseSeconds` whatever the clamp is set to. A smaller `maxOffset`
    /// therefore takes smaller steps rather than arriving sooner: the setting is
    /// how long an adjustment takes, not how fast the panel moves.
    public var slewPerTick: Double { maxOffset / (seconds * Self.tickRate) }

    /// Number of samples the median is taken over. A change must hold for more
    /// than half of them before it moves the offset at all, which is what makes a
    /// quick flick through a bright window cost nothing. Three samples at 2 Hz is
    /// 1.5 seconds, enough to absorb scrolling past a bright image; the floor
    /// keeps that much rejection even at the shortest setting.
    public var historyLength: Int {
        Swift.min(Swift.max(Int((seconds * 1.5).rounded()), 3), 12)
    }

    public init(
        strength: Double = 0.45,
        maxOffset: Double = 0.20,
        neutral: Double = 0.50,
        deadband: Double = 0.02,
        responseSeconds: Double = 2.0,
        minBrightness: Double = 0.05
    ) {
        self.strength = strength
        self.maxOffset = maxOffset
        self.neutral = neutral
        self.deadband = deadband
        self.responseSeconds = responseSeconds
        self.minBrightness = minBrightness
    }

    public static let defaults = ControllerSettings()
}

/// The control law. Pure: every input is a value, and the only state is the
/// applied offset plus a short sample history.
public struct Controller: Sendable {
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
        // A loop, not a single drop: shortening the setting must take effect on
        // the next tick rather than decaying one stale sample at a time.
        while history.count > settings.historyLength {
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
