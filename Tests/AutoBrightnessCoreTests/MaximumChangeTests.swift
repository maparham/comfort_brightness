import Testing
@testable import AutoBrightnessCore

/// "Maximum change" is a promise about what the user sees: the panel may never
/// sit further than that from the level they last chose. The offset staying
/// inside the clamp is not the same promise — an offset applied when the user
/// set their level, and the opposite offset applied later, add up to twice it.
private func settings(maxOffset: Double) -> ControllerSettings {
    var settings = ControllerSettings.defaults
    settings.strength = 0.30
    settings.maxOffset = maxOffset
    return settings
}

@Test("Brightness set on dark content is not left twice the limit away on bright content")
func setPointBoundsBothDirections() {
    let fake = FakeBrightness(value: 0.80)
    let coordinator = Coordinator(brightness: fake, settings: settings(maxOffset: 0.10))

    // Dark desktop: the app has brightened by the full 10%.
    for _ in 0..<20 { coordinator.tick(luminance: 0.10) }
    #expect(abs(coordinator.appliedOffset - 0.10) < 1e-6)

    // The user sets 100% while looking at that dark desktop.
    fake.externalChange(to: 1.0)
    coordinator.tick(luminance: 0.10)
    #expect(abs((fake.read() ?? 0) - 1.0) < 1e-6)
    // What they set is the baseline, with nothing subtracted from it. This is
    // the number the Details panel shows, and showing anything else here reads
    // as the app having ignored them.
    #expect(abs(coordinator.baseline - 1.0) < 1e-6)
    #expect(abs(coordinator.appliedOffset) < 1e-6)

    // Switching to a bright desktop may cost at most the 10% they allowed.
    for _ in 0..<20 { coordinator.tick(luminance: 0.90) }
    #expect(abs((fake.read() ?? 0) - 0.90) < 1e-6)
}

@Test("A limit reached against the top rail does not widen the swing")
func topRailBoundsTheSwing() {
    let fake = FakeBrightness(value: 0.95)
    let coordinator = Coordinator(brightness: fake, settings: settings(maxOffset: 0.10))

    // Dark content asks for 1.05; the panel can only give 1.00.
    for _ in 0..<20 { coordinator.tick(luminance: 0.10) }
    #expect(abs((fake.read() ?? 0) - 1.0) < 1e-6)

    // Bright content must still measure its 10% from the 0.95 the user chose,
    // not from the 1.00 the rail happened to produce.
    for _ in 0..<20 { coordinator.tick(luminance: 0.90) }
    #expect(abs((fake.read() ?? 0) - 0.85) < 1e-6)
}

@Test("A new set point recentres the limit without moving the panel under the user")
func adjustingWhileBoundedRecentresTheLimit() {
    let fake = FakeBrightness(value: 0.80)
    let coordinator = Coordinator(brightness: fake, settings: settings(maxOffset: 0.10))

    for _ in 0..<20 { coordinator.tick(luminance: 0.10) }
    fake.externalChange(to: 1.0)
    coordinator.tick(luminance: 0.10)
    // Bounded: the app wants 0.80 and the limit holds it at 0.90.
    for _ in 0..<20 { coordinator.tick(luminance: 0.90) }
    #expect(abs((fake.read() ?? 0) - 0.90) < 1e-6)

    // The user takes it down to 70% here. Their adjustment must land where they
    // put it, not be met with the dimming the limit had been withholding.
    fake.externalChange(to: 0.70)
    coordinator.tick(luminance: 0.90)
    #expect(abs((fake.read() ?? 0) - 0.70) < 1e-6)

    // The limit now measures from 0.70. Set on bright content, that reads as
    // "this is my level when the screen is bright", so the app's remaining room
    // is upward — but never more than the 10% they allowed.
    for _ in 0..<20 { coordinator.tick(luminance: 0.10) }
    #expect(abs((fake.read() ?? 0) - 0.80) < 1e-6)
    for _ in 0..<20 { coordinator.tick(luminance: 0.90) }
    #expect(abs((fake.read() ?? 0) - 0.70) < 1e-6)
}

@Test("The limit never pulls the panel below the floor")
func limitDoesNotUndercutTheFloor() {
    // The floor above the panel's level is the case the bound can invert: the
    // limit measured from a very low set point sits entirely below it.
    var config = settings(maxOffset: 0.05)
    config.minBrightness = 0.20
    let fake = FakeBrightness(value: 0.10)
    let coordinator = Coordinator(brightness: fake, settings: config)

    for _ in 0..<20 { coordinator.tick(luminance: 0.90) }
    #expect((fake.read() ?? 0) >= 0.20 - 1e-9)
}

@Test("Tightening the limit pulls the panel back toward the level the user set")
func tighteningTheLimitPullsBack() {
    let fake = FakeBrightness(value: 0.80)
    let coordinator = Coordinator(brightness: fake, settings: settings(maxOffset: 0.10))

    for _ in 0..<20 { coordinator.tick(luminance: 0.10) }
    fake.externalChange(to: 1.0)
    coordinator.tick(luminance: 0.10)
    for _ in 0..<20 { coordinator.tick(luminance: 0.90) }
    #expect(abs((fake.read() ?? 0) - 0.90) < 1e-6)

    // The user drags "Maximum change" down to 5% while it is already binding.
    coordinator.settings.maxOffset = 0.05
    for _ in 0..<20 { coordinator.tick(luminance: 0.90) }
    #expect(abs((fake.read() ?? 0) - 0.95) < 1e-6)
}

@Test("No content sequence strays further than the limit from the level the user set")
func limitHoldsAcrossAContentSequence() {
    let fake = FakeBrightness(value: 0.60)
    let coordinator = Coordinator(brightness: fake, settings: settings(maxOffset: 0.15))
    var setPoint = 0.60

    // A deterministic wander through the luminance range, with the user
    // reaching for the keys partway through.
    var luminance = 0.05
    for step in 0..<200 {
        luminance += 0.037
        if luminance > 1.0 { luminance -= 1.0 }
        if step == 90 {
            setPoint = 0.55
            fake.externalChange(to: setPoint)
        }
        // A slider dragged across most of its range, which the baseline follows
        // over several ticks. The limit has to hold across those ticks too.
        if step == 140 {
            setPoint = 0.95
            fake.externalChange(to: setPoint)
        }
        coordinator.tick(luminance: luminance)
        let shown = fake.read() ?? 0
        #expect(shown <= setPoint + 0.15 + 1e-6)
        #expect(shown >= setPoint - 0.15 - 1e-6)
    }
}
