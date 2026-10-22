import Testing
@testable import AutoBrightnessCore

/// The composition the app runs for a DDC display, ticking at 2 Hz in
/// virtual time.
private final class Rig {
    let monitor: FakeMonitor
    let link: VirtualDDCLink
    let ddc: DDCBrightness
    let coordinator: Coordinator

    init(level: Int = 50, holdsEvents: Bool = false) {
        monitor = FakeMonitor(level: level)
        link = VirtualDDCLink(monitor: monitor)
        link.holdsEvents = holdsEvents
        ddc = DDCBrightness(link: link, seed: DDCReading(current: level, maximum: 100))
        coordinator = Coordinator(brightness: ddc)
        // What DisplayUnit does: stop adjusting while the monitor is away.
        ddc.onControlChange = { [unowned self] in
            if self.ddc.isResponding {
                if self.coordinator.isPaused { self.coordinator.resume() }
            } else {
                self.coordinator.suspend()
            }
        }
    }

    /// One tick, then whatever the main thread was sent, then half a second
    /// of bus time. With `holdsEvents`, events seen during a tick's half
    /// second only reach the coordinator after its next write.
    func run(_ ticks: Range<Int>, luminance: (Int) -> Double) {
        for i in ticks {
            coordinator.tick(luminance: luminance(i))
            link.deliver()
            link.advance(by: 0.5)
        }
    }
}

/// Content that keeps the coordinator writing: dark and light alternating
/// every 1.5 s.
private func busy(_ i: Int) -> Double { (i / 3).isMultiple(of: 2) ? 0.15 : 0.85 }

@Test("Steady content stops sending once settled")
func steadyContentGoesQuiet() {
    let rig = Rig()
    rig.run(0..<20) { _ in 0.9 }
    let sent = rig.monitor.writes.count
    rig.run(20..<40) { _ in 0.9 }
    #expect(sent > 0)
    #expect(rig.monitor.writes.count == sent)
}

@Test("In steady state, a one-step press is followed and kept")
func steadyOneStepFollowed() {
    let rig = Rig()
    rig.run(0..<20) { _ in 0.9 }
    let settled = rig.monitor.level
    rig.monitor.press(to: settled - 1)
    rig.run(20..<30) { _ in 0.9 }
    #expect(abs(rig.coordinator.baseline - 0.49) < 1e-9)
    #expect(rig.monitor.level == settled - 1)
}

@Test("During continuous writes, a one-step press moves the baseline by one step and is never overwritten")
func busyOneStepFollowed() {
    let control = Rig()
    let pressed = Rig()
    control.run(0..<12, luminance: busy)
    pressed.run(0..<12, luminance: busy)
    pressed.monitor.press(to: pressed.monitor.level - 1)
    control.run(12..<40, luminance: busy)
    pressed.run(12..<40, luminance: busy)
    #expect(abs((pressed.coordinator.baseline - control.coordinator.baseline) + 0.01) < 1e-9)
    #expect(abs(pressed.coordinator.appliedOffset - control.coordinator.appliedOffset) < 1e-9)
    #expect(pressed.monitor.level == control.monitor.level - 1)
}

@Test("During continuous writes, a five-step press re-teaches the neutral")
func busyFiveStepReneutralizes() {
    let rig = Rig()
    rig.run(0..<2) { _ in 0.9 }   // the offset is still slewing
    rig.monitor.press(to: rig.monitor.level - 5)
    rig.run(2..<20) { _ in 0.9 }
    #expect(abs(rig.coordinator.appliedOffset) < 1e-9)
    #expect(rig.coordinator.baseline <= 0.45 + 1e-9)
    #expect(abs(Double(rig.monitor.level) / 100 - rig.coordinator.baseline) <= 0.005 + 1e-9)
}

@Test("A press whose observation arrives after a write was already sent still wins")
func lateObservationStillWins() {
    let control = Rig(holdsEvents: true)
    let pressed = Rig(holdsEvents: true)
    control.run(0..<12, luminance: busy)
    pressed.run(0..<12, luminance: busy)
    pressed.monitor.press(to: pressed.monitor.level - 2)
    control.run(12..<40, luminance: busy)
    pressed.run(12..<40, luminance: busy)
    #expect(abs((pressed.coordinator.baseline - control.coordinator.baseline) + 0.02) < 1e-9)
    #expect(pressed.monitor.level == control.monitor.level - 2)
}

@Test("A monitor switched off and on comes back to the user's baseline, not the offset level")
func dropoutKeepsBaseline() {
    let rig = Rig()
    rig.run(0..<20) { _ in 0.9 }
    // The offset at 0.9 is -0.45 * (0.9 - 0.5) = -0.18, inside the 0.20 clamp,
    // so the settled level is 0.5 - 0.18 = 32, not the clamp's 30. Coming back
    // to 32 after the dropout, with the baseline still 0.5, is the point: had
    // the offset level been taken as the baseline, the panel would head for 14.
    #expect(rig.monitor.level == 32)
    rig.monitor.isOff = true
    rig.run(20..<32) { _ in 0.9 }
    #expect(rig.coordinator.isPaused)
    rig.monitor.isOff = false
    rig.run(32..<52) { _ in 0.9 }
    #expect(abs(rig.coordinator.baseline - 0.5) < 1e-9)
    #expect(rig.monitor.level == 32)
}
