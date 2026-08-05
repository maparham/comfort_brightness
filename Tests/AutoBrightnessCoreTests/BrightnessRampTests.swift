import Testing
@testable import AutoBrightnessCore

@Test("Steps end exactly on the target and never include the start")
func stepsHitTargetExactly() {
    let steps = BrightnessRamp.steps(from: 0.5, to: 0.55, count: 20)
    #expect(steps.count == 20)
    #expect(steps.last == 0.55)
    #expect(steps.first != 0.5)
}

@Test("Steps are monotonic in the direction of travel, both ways")
func stepsAreMonotonic() {
    let up = BrightnessRamp.steps(from: 0.3, to: 0.5, count: 20)
    #expect(zip(up, up.dropFirst()).allSatisfy { $0 <= $1 })
    let down = BrightnessRamp.steps(from: 0.5, to: 0.3, count: 20)
    #expect(zip(down, down.dropFirst()).allSatisfy { $0 >= $1 })
}

@Test("No single step exceeds the eased per-step bound")
func stepsStaySmall() {
    // Smoothstep's steepest slope is 1.5x linear, at the midpoint.
    let distance = 0.20
    let steps = BrightnessRamp.steps(from: 0.4, to: 0.6, count: 20)
    let deltas = zip([0.4] + steps, steps).map { abs($1 - $0) }
    #expect(deltas.allSatisfy { $0 <= distance * 1.5 / 20 + 1e-12 })
}

@Test("A zero-distance ramp is all target values")
func zeroDistance() {
    let steps = BrightnessRamp.steps(from: 0.5, to: 0.5, count: 5)
    #expect(steps == [0.5, 0.5, 0.5, 0.5, 0.5])
}

@Test("A single-step ramp is just the target")
func singleStep() {
    #expect(BrightnessRamp.steps(from: 0.2, to: 0.8, count: 1) == [0.8])
}
