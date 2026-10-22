import Testing
@testable import AutoBrightnessCore

/// An actuator that can only show coarse steps, so it asks the coordinator to
/// notice smaller movements than the built-in panel needs to.
private final class CoarseBrightness: BrightnessControlling {
    var value: Double
    let canControl = true
    let externalChangeThreshold = 0.005
    init(value: Double) { self.value = value }
    func read() -> Double? { value }
    func write(_ newValue: Double) { value = newValue }
}

@Test("The default threshold is the coordinator's 0.01")
func defaultThresholdUnchanged() {
    #expect(FakeBrightness().externalChangeThreshold == Coordinator.externalChangeThreshold)
}

@Test("RampingBrightness forwards the wrapped threshold")
func rampingForwardsThreshold() {
    let ramping = RampingBrightness(
        wrapping: CoarseBrightness(value: 0.5),
        scheduler: ManualRampScheduler()
    )
    #expect(ramping.externalChangeThreshold == 0.005)
}

@Test("A move between the backend's threshold and 0.01 is followed")
func backendThresholdIsUsed() {
    // Settle on a white page first, so there is a write of ours to measure
    // movement against: before the first write, any level is simply adopted.
    let coarse = CoarseBrightness(value: 0.50)
    let coordinator = Coordinator(brightness: coarse)
    for _ in 0..<20 { coordinator.tick(luminance: 0.95) }
    #expect(abs(coarse.value - 0.30) < 1e-9)
    coarse.value -= 0.007   // under 0.01, over 0.005
    coordinator.tick(luminance: 0.95)
    #expect(abs(coordinator.baseline - 0.493) < 1e-9)
}

@Test("The same move is ignored under the default threshold")
func defaultThresholdIgnoresSmallMove() {
    let fake = FakeBrightness(value: 0.50)
    let coordinator = Coordinator(brightness: fake)
    for _ in 0..<20 { coordinator.tick(luminance: 0.95) }
    fake.externalChange(to: (fake.read() ?? 0) - 0.007)
    coordinator.tick(luminance: 0.95)
    #expect(abs(coordinator.baseline - 0.50) < 1e-9)
}
