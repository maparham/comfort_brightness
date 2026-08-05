import Testing
@testable import AutoBrightnessCore

/// Feeds one luminance value repeatedly until the controller settles, returning
/// the final offset.
private func settle(
    _ controller: inout Controller,
    luminance: Double,
    baseline: Double = 0.5,
    ticks: Int = 20
) -> Double {
    var last = 0.0
    for _ in 0..<ticks {
        last = controller.update(
            luminance: luminance,
            baseline: baseline,
            settings: .defaults
        )
    }
    return last
}

@Test("A white page drives the offset to the negative clamp and no further")
func whitePageClamps() {
    var controller = Controller()
    let target = settle(&controller, luminance: 0.95)
    #expect(abs(controller.appliedOffset - (-0.20)) < 1e-6)
    #expect(abs(target - 0.30) < 1e-6)
}

@Test("A dark film scene brightens, bounded by the clamp")
func darkSceneBrightens() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.17)
    #expect(controller.appliedOffset > 0.13)
    #expect(controller.appliedOffset <= 0.20)
}

@Test("Mid-gray content produces no offset")
func midGrayProducesNoOffset() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.50)
    #expect(controller.appliedOffset == 0.0)
}

@Test("A dark-mode editor is not treated like a dark film")
func darkModeEditorIsModest() {
    // L = 0.30 is a dark IDE. It should lift the screen a little, nowhere near
    // the clamp — otherwise anyone working in dark mode gets a persistently
    // brighter screen than they chose.
    var controller = Controller()
    _ = settle(&controller, luminance: 0.30)
    #expect(abs(controller.appliedOffset - 0.09) < 0.01)
}

@Test("A one-tick spike is ignored")
func transientRejected() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.50)
    for luminance in [0.95, 0.50, 0.50] {
        _ = controller.update(luminance: luminance, baseline: 0.5, settings: .defaults)
    }
    #expect(controller.appliedOffset == 0.0)
}

@Test("A step change takes at least 1.8 seconds to complete")
func slewLimited() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.50)
    var ticks = 0
    while abs(controller.appliedOffset - (-0.20)) > 1e-6 && ticks < 100 {
        _ = controller.update(luminance: 0.95, baseline: 0.5, settings: .defaults)
        ticks += 1
    }
    // 2 Hz sampling, so 1.8 seconds is at least 4 ticks.
    #expect(ticks >= 4)
    #expect(ticks < 100)
}

@Test("Small changes inside the deadband do not move the offset")
func deadbandHolds() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.50)
    // 0.52 maps to an offset of -0.009, inside the 0.02 deadband.
    for _ in 0..<10 {
        _ = controller.update(luminance: 0.52, baseline: 0.5, settings: .defaults)
    }
    #expect(controller.appliedOffset == 0.0)
}

@Test("Lowering the clamp by less than the deadband still pulls the offset back")
func loweredClampBeatsDeadband() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.95)
    #expect(abs(controller.appliedOffset - (-0.20)) < 1e-6)

    // 0.015 below the applied offset — inside the 0.02 deadband, which must not
    // shield an offset that now exceeds the user's limit.
    var settings = ControllerSettings.defaults
    settings.maxOffset = 0.185
    for _ in 0..<10 {
        _ = controller.update(luminance: 0.95, baseline: 0.5, settings: settings)
    }
    // Settled exactly at the new clamp — not merely inside it, and not moving.
    #expect(abs(controller.appliedOffset - (-0.185)) < 1e-6)
    _ = controller.update(luminance: 0.95, baseline: 0.5, settings: settings)
    #expect(abs(controller.appliedOffset - (-0.185)) < 1e-6)
}

@Test("Lowering the clamp pulls a positive offset back too")
func loweredClampPullsPositiveOffsetBack() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.17)
    #expect(controller.appliedOffset > 0.13)

    var settings = ControllerSettings.defaults
    settings.maxOffset = controller.appliedOffset - 0.015
    for _ in 0..<10 {
        _ = controller.update(luminance: 0.17, baseline: 0.5, settings: settings)
    }
    #expect(controller.appliedOffset <= settings.maxOffset + 1e-9)
}

@Test("Lowering the clamp eases the offset back at the slew rate, not in one snap")
func loweredClampSlewsBack() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.95)

    var settings = ControllerSettings.defaults
    settings.maxOffset = 0.05
    _ = controller.update(luminance: 0.95, baseline: 0.5, settings: settings)
    // One tick may move at most slewPerTick from -0.20.
    #expect(abs(controller.appliedOffset - (-0.15)) < 1e-6)
}

@Test("Target brightness never leaves the safe range")
func targetIsClamped() {
    var controller = Controller()
    let dark = settle(&controller, luminance: 0.95, baseline: 0.10)
    #expect(dark >= 0.05)

    var other = Controller()
    let bright = settle(&other, luminance: 0.10, baseline: 0.98)
    #expect(bright <= 1.0)
}

@Test("Reset clears both the offset and the sample history")
func resetClearsState() {
    var controller = Controller()
    _ = settle(&controller, luminance: 0.95)
    #expect(controller.appliedOffset != 0.0)
    controller.reset()
    #expect(controller.appliedOffset == 0.0)
    // With history cleared, one white sample must not move anything yet.
    _ = controller.update(luminance: 0.95, baseline: 0.5, settings: .defaults)
    #expect(abs(controller.appliedOffset) <= 0.05)
}
