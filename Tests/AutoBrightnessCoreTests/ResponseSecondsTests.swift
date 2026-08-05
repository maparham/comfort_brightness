import Testing
@testable import AutoBrightnessCore

/// Ticks a white page until the offset stops moving, returning how many ticks
/// that took and where it landed. It settles a little short of the clamp rather
/// than exactly on it: the last step is inside the deadband, which is what stops
/// the offset hunting. 100 is a bailout, not an expectation.
private func settleOnWhite(_ settings: ControllerSettings) -> (ticks: Int, offset: Double) {
    var controller = Controller()
    var ticks = 0
    while ticks < 100 {
        let before = controller.appliedOffset
        _ = controller.update(luminance: 0.95, baseline: 0.5, settings: settings)
        if controller.appliedOffset == before { break }
        ticks += 1
    }
    return (ticks, controller.appliedOffset)
}

@Test("The default response reproduces the rates the app shipped with")
func defaultsAreUnchanged() {
    // These two numbers were the hard-coded constants before the setting existed.
    // Anyone moving the default is changing behaviour the app already shipped.
    #expect(abs(ControllerSettings.defaults.slewPerTick - 0.05) < 1e-9)
    #expect(ControllerSettings.defaults.historyLength == 3)
}

@Test("A longer response takes proportionally longer to arrive")
func longerResponseTakesLonger() {
    var slow = ControllerSettings.defaults
    slow.responseSeconds = 8.0

    let quick = settleOnWhite(.defaults)
    let gradual = settleOnWhite(slow)
    #expect(gradual.ticks < 100)
    // Four times the seconds, so roughly four times the ticks. The deadband ends
    // the slow one an extra step early, so this asks for the proportion rather
    // than an exact multiple.
    #expect(gradual.ticks >= quick.ticks * 3)
    // And it still gets the user essentially the same adjustment, just later.
    #expect(abs(gradual.offset - quick.offset) <= slow.deadband)
}

@Test("An adjustment takes responseSeconds whatever the clamp is set to")
func durationIsIndependentOfClamp() {
    var small = ControllerSettings.defaults
    small.maxOffset = 0.05
    // A quarter of the travel at a quarter of the step: the same time, give or
    // take where the deadband happens to stop each one.
    #expect(abs(settleOnWhite(small).ticks - settleOnWhite(.defaults).ticks) <= 1)
    #expect(abs(small.slewPerTick - 0.05 / 4) < 1e-9)
}

@Test("At a long response a two-second window switch is ignored entirely")
func longResponseRejectsAWindowFlick() {
    var slow = ControllerSettings.defaults
    slow.responseSeconds = 8.0

    var controller = Controller()
    for _ in 0..<12 {
        _ = controller.update(luminance: 0.50, baseline: 0.5, settings: slow)
    }
    // Four ticks of white — two seconds on a bright window — inside a 12-sample
    // median cannot move it.
    for _ in 0..<4 {
        _ = controller.update(luminance: 0.95, baseline: 0.5, settings: slow)
    }
    #expect(controller.appliedOffset == 0.0)

    // Content that stays, however, still gets its adjustment.
    for _ in 0..<40 {
        _ = controller.update(luminance: 0.95, baseline: 0.5, settings: slow)
    }
    #expect(abs(controller.appliedOffset + slow.maxOffset) <= slow.deadband)
}

@Test("Shortening the response trims the history on the very next tick")
func shorteningTrimsImmediately() {
    var slow = ControllerSettings.defaults
    slow.responseSeconds = 8.0

    var controller = Controller()
    for _ in 0..<12 {
        _ = controller.update(luminance: 0.50, baseline: 0.5, settings: slow)
    }

    // Back to the 3-sample default. Two white samples are then a majority, so the
    // offset must move — which it could not do if the nine stale mid-gray samples
    // were still being dropped one per tick.
    for _ in 0..<2 {
        _ = controller.update(luminance: 0.95, baseline: 0.5, settings: .defaults)
    }
    #expect(controller.appliedOffset < 0.0)
}

@Test("The slowest, smallest corner of the two sliders still moves the panel")
func slowestSmallestCornerStillAdjusts() {
    // The least motion the sliders can be asked for: the smallest clamp at the
    // longest response. Its step must stay above the Coordinator's
    // minimum-write threshold, or every write is suppressed and the feature
    // quietly does nothing at that corner.
    var corner = ControllerSettings.defaults
    corner.maxOffset = 0.05
    corner.responseSeconds = 8.0
    #expect(corner.slewPerTick > Coordinator.minimumWriteDelta)

    let settled = settleOnWhite(corner)
    #expect(settled.ticks < 100)
    #expect(settled.offset < 0)
}

@Test("A nonsense response value cannot freeze or invert the offset")
func nonPositiveSecondsIsGuarded() {
    var broken = ControllerSettings.defaults
    broken.responseSeconds = 0
    #expect(broken.slewPerTick > 0)
    #expect(broken.historyLength >= 3)
    #expect(settleOnWhite(broken).offset < 0)
}
