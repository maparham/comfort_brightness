import Testing
@testable import AutoBrightnessCore

/// The composition the app actually runs: `Coordinator` driving the panel
/// through `RampingBrightness`. The whole design rests on one claim — a ramp
/// that finishes between ticks is invisible to the Coordinator's read-back —
/// and these tests pin it.

@Test("A completed ramp between ticks is not mistaken for user input")
func rampIsInvisibleToCoordinator() {
    let fake = FakeBrightness(value: 0.6)
    let scheduler = ManualRampScheduler()
    let ramping = RampingBrightness(wrapping: fake, scheduler: scheduler, stepCount: 20)
    let coordinator = Coordinator(brightness: ramping)

    // Bright content: the controller dims below baseline, one slew step per
    // tick, each write playing out as a full ramp before the next tick reads.
    for _ in 0..<10 {
        coordinator.tick(luminance: 0.9)
        scheduler.pump(20)
    }

    // Every hardware movement came from our own ramps; none of it may have
    // been attributed to the user.
    #expect(coordinator.baseline == 0.6)
    #expect(abs(fake.value - (0.6 + coordinator.appliedOffset)) < 1e-9)
    #expect(coordinator.appliedOffset < 0)
}

@Test("A withheld-write probe stays quiet while no ramp is in flight")
func probeSeesStillPanelWithRamping() {
    let fake = FakeBrightness(value: 0.6)
    let scheduler = ManualRampScheduler()
    let ramping = RampingBrightness(wrapping: fake, scheduler: scheduler, stepCount: 20)
    let coordinator = Coordinator(brightness: ramping)

    // Settle on steady mid-gray content: after the first anchor-establishing
    // tick the offset is inside the deadband and nothing more is written.
    for _ in 0..<10 {
        coordinator.tick(luminance: 0.5)
        scheduler.pump(20)
    }
    let settledBaseline = coordinator.baseline
    let settledValue = fake.value

    // More steady ticks with no writes pending: the panel must hold still and
    // the baseline must not walk.
    for _ in 0..<10 {
        coordinator.tick(luminance: 0.5)
        #expect(!scheduler.isRunning)
        scheduler.pump(20)
    }
    #expect(coordinator.baseline == settledBaseline)
    #expect(fake.value == settledValue)
}

@Test("A real user change mid-composition is still followed exactly")
func userChangeStillFollowedThroughRamp() {
    let fake = FakeBrightness(value: 0.6)
    let scheduler = ManualRampScheduler()
    let ramping = RampingBrightness(wrapping: fake, scheduler: scheduler, stepCount: 20)
    let coordinator = Coordinator(brightness: ramping)

    for _ in 0..<6 {
        coordinator.tick(luminance: 0.9)
        scheduler.pump(20)
    }

    // A brightness-key press between ticks.
    fake.externalChange(to: fake.value + 0.1)
    for _ in 0..<6 {
        coordinator.tick(luminance: 0.9)
        scheduler.pump(20)
    }

    // The 0.1 the user asked for landed in the baseline, not in the offset.
    #expect(abs(coordinator.baseline - 0.7) < 1e-9)
}
