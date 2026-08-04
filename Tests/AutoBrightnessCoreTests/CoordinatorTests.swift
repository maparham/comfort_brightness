import Testing
@testable import AutoBrightnessCore

@Test("A white page drives brightness below the starting point")
func dimsOnWhitePage() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(abs(coordinator.baseline - 0.60) < 1e-6)
    #expect(abs((fake.read() ?? 0) - 0.40) < 1e-6)
}

@Test("A pressed brightness key re-baselines instead of being fought")
func userAdjustmentRebaselines() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    // Settled: baseline 0.60, offset -0.20, hardware at 0.40.
    // The user presses brightness-up twice: 2 x 1/16.
    fake.externalChange(to: 0.525)
    coordinator.tick(luminance: 0.95)

    // Their adjustment must land exactly where they intended: total brightness
    // stays at what they set, and the content offset rides on top of it.
    #expect(abs(coordinator.baseline - 0.725) < 1e-6)
    #expect(abs((fake.read() ?? 0) - 0.525) < 1e-6)
}

@Test("Our own writes are not mistaken for user adjustments")
func ownWritesDoNotRebaseline() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(abs(coordinator.baseline - 0.60) < 1e-6)
}

@Test("Redundant writes are suppressed")
func noRedundantWrites() {
    let fake = FakeBrightness(value: 0.50)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<10 {
        coordinator.tick(luminance: 0.50)
    }
    // Mid-gray means zero offset, so nothing ever needs writing.
    #expect(fake.writes.isEmpty)
}

@Test("A disabled coordinator writes nothing")
func disabledDoesNothing() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    coordinator.isEnabled = false
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(fake.writes.isEmpty)
    #expect(fake.read() == 0.60)
}

@Test("Disabling restores the user's baseline")
func disablingRestores() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    coordinator.isEnabled = false
    #expect(abs((fake.read() ?? 0) - 0.60) < 1e-6)
}

@Test("Resume re-reads the baseline and ramps in from zero offset")
func resumeRampsIn() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    coordinator.suspend()

    // While asleep the user sets a very different level.
    fake.externalChange(to: 0.30)
    coordinator.resume()
    #expect(abs(coordinator.baseline - 0.30) < 1e-6)
    #expect(coordinator.appliedOffset == 0.0)

    // The first tick after resuming must not snap to the full offset.
    coordinator.tick(luminance: 0.95)
    #expect(abs(coordinator.appliedOffset) <= 0.05)
}

@Test("A suspended coordinator ignores ticks")
func suspendedIgnoresTicks() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    coordinator.suspend()
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(fake.writes.isEmpty)
}

/// An actuator whose read-back is systematically off from what was written —
/// the failure mode the CoreDisplay fallback path could plausibly have, since
/// only the DisplayServices path was ever measured bit-exact.
private final class LyingBrightness: BrightnessControlling {
    let canControl = true
    let bias: Double
    private(set) var value: Double
    private(set) var writes: [Double] = []

    init(value: Double, bias: Double) {
        self.value = value
        self.bias = bias
    }

    func read() -> Double? { value }

    func write(_ newValue: Double) {
        let clamped = min(max(newValue, 0.0), 1.0)
        writes.append(clamped)
        value = min(max(clamped + bias, 0.0), 1.0)
    }

    func externalChange(to newValue: Double) {
        value = min(max(newValue, 0.0), 1.0)
    }
}

@Test("A systematically lying actuator cannot walk the baseline away")
func biasedReadBackDoesNotWalkBaseline() {
    // Every read comes back 0.05 above what was written. Re-baselining on that
    // discrepancy once per tick would march the baseline to a rail in seconds.
    // The luminance varies throughout, because a static scene writes nothing and
    // would pass even with the bug.
    let fake = LyingBrightness(value: 0.60, bias: 0.05)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    let scene = [0.95, 0.20, 0.55, 0.80, 0.30, 0.50, 0.15, 0.70]
    for index in 0..<200 {
        coordinator.tick(luminance: scene[index % scene.count])
    }
    // The baseline may absorb the bias once; it must not accumulate.
    #expect(abs(coordinator.baseline - 0.60) < 0.15)
    #expect((fake.read() ?? 0) > 0.35)
    #expect((fake.read() ?? 0) < 0.95)
}

@Test("A negative read-back bias cannot walk the baseline to the floor")
func negativeBiasDoesNotWalkBaseline() {
    let fake = LyingBrightness(value: 0.60, bias: -0.05)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for index in 0..<200 {
        coordinator.tick(luminance: index.isMultiple(of: 3) ? 0.40 : 0.60)
    }
    #expect(abs(coordinator.baseline - 0.60) < 0.15)
    #expect((fake.read() ?? 0) > 0.35)
}

@Test("A genuine slow drift is still followed despite the bias guard")
func slowDriftStillRebaselines() {
    // The ambient sensor easing the panel down: 0.008 per tick, below the
    // detection threshold on any single tick. Because the reference is held
    // while a discrepancy looks static, the drift accumulates against it and is
    // picked up rather than ignored forever.
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    coordinator.tick(luminance: 0.50)
    var level = 0.60
    for _ in 0..<20 {
        level -= 0.008
        fake.externalChange(to: level)
        coordinator.tick(luminance: 0.50)
    }
    // Mid-gray means zero offset, so the baseline should have followed the panel.
    #expect(abs(coordinator.baseline - level) < 0.02)
}

@Test("A large external jump is followed over several ticks without fighting it")
func largeJumpIsFollowedGradually() {
    let fake = FakeBrightness(value: 0.30)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)  // settles at baseline 0.30, offset -0.20
    }
    let writesBefore = fake.writes.count

    // The user drags the brightness slider across most of its range in one tick.
    fake.externalChange(to: 0.95)
    coordinator.tick(luminance: 0.95)
    // The baseline steps at most 0.25, and nothing is written while catching up,
    // so the panel is not yanked back down under the user's hand.
    #expect(coordinator.baseline <= 0.30 + Coordinator.maxBaselineStepPerTick + 1e-9)
    #expect(fake.writes.count == writesBefore)
    #expect(abs((fake.read() ?? 0) - 0.95) < 1e-9)

    // It converges within a couple of seconds: baseline 0.95 - (-0.20) = 1.15,
    // clamped by the panel range, so total brightness ends up at the user's level
    // plus the content offset.
    for _ in 0..<6 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(coordinator.baseline > 0.95)
    #expect((fake.read() ?? 0) >= 0.94)
}

@Test("An uncontrollable display is handled without crashing")
func unavailableDisplay() {
    let fake = FakeBrightness(value: 0.60, canControl: false)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(fake.writes.isEmpty)
}
