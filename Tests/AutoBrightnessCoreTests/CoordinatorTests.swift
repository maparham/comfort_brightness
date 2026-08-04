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

@Test("An uncontrollable display is handled without crashing")
func unavailableDisplay() {
    let fake = FakeBrightness(value: 0.60, canControl: false)
    let coordinator = Coordinator(brightness: fake, settings: .defaults)
    for _ in 0..<20 {
        coordinator.tick(luminance: 0.95)
    }
    #expect(fake.writes.isEmpty)
}
