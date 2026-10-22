import Testing
@testable import AutoBrightnessCore

private func makeBrightness(level: Int = 50, maximum: Int = 100) -> (FakeMonitor, VirtualDDCLink, DDCBrightness) {
    let monitor = FakeMonitor(level: level, maximum: maximum)
    let link = VirtualDDCLink(monitor: monitor)
    let ddc = DDCBrightness(link: link, seed: DDCReading(current: level, maximum: maximum))
    return (monitor, link, ddc)
}

@Test("Before any write, read is the probe's level")
func readsSeedFirst() {
    let (_, _, ddc) = makeBrightness(level: 37)
    #expect(ddc.read() == 0.37)
}

@Test("Own writes read back exactly, rounding and all")
func ownWritesExact() {
    let (monitor, link, ddc) = makeBrightness()
    ddc.write(0.497)
    link.advance(by: 2)
    #expect(monitor.level == 50)
    #expect(ddc.read() == 0.497)
}

@Test("A one-step press after a request that rounded down reads as exactly one step")
func oneStepDownFromRoundedDown() {
    let (monitor, link, ddc) = makeBrightness()
    ddc.write(0.497)
    link.advance(by: 0.5)
    monitor.press(to: 49)
    link.advance(by: 1)
    #expect(abs((ddc.read() ?? 0) - 0.487) < 1e-12)
}

@Test("A one-step press after a request that rounded up reads as exactly one step")
func oneStepUpFromRoundedUp() {
    let (monitor, link, ddc) = makeBrightness()
    ddc.write(0.503)
    link.advance(by: 0.5)
    monitor.press(to: 51)
    link.advance(by: 1)
    #expect(abs((ddc.read() ?? 0) - 0.513) < 1e-12)
}

@Test("A press before any write is measured from the probe's level")
func pressBeforeWrite() {
    let (monitor, link, ddc) = makeBrightness()
    monitor.press(to: 52)
    link.advance(by: 1.1)
    #expect(abs((ddc.read() ?? 0) - 0.52) < 1e-12)
}

@Test("Observations add up until the next write")
func observationsAccumulate() {
    let (monitor, link, ddc) = makeBrightness()
    monitor.press(to: 49)
    link.advance(by: 1.1)
    monitor.press(to: 47)
    link.advance(by: 1.0)
    #expect(abs((ddc.read() ?? 0) - 0.47) < 1e-12)
}

@Test("The threshold is half a step of the monitor's own scale")
func thresholdIsHalfAStep() {
    #expect(makeBrightness().2.externalChangeThreshold == 0.005)
    #expect(makeBrightness(level: 128, maximum: 255).2.externalChangeThreshold == 0.5 / 255)
}

@Test("A dropout is reported but keeps control, so a restore can still be queued")
func dropoutKeepsControl() {
    let (monitor, link, ddc) = makeBrightness()
    var changes = 0
    ddc.onControlChange = { changes += 1 }
    monitor.isOff = true
    link.advance(by: 5.5)
    #expect(!ddc.isResponding)
    #expect(ddc.canControl)
    #expect(changes == 1)
}

@Test("A monitor that ignores writes loses control")
func unwritableLosesControl() {
    let (monitor, link, ddc) = makeBrightness()
    monitor.ignoresWrites = true
    for i in 0..<3 {
        ddc.write(i.isMultiple(of: 2) ? 0.60 : 0.40)
        link.advance(by: 1.0)
    }
    #expect(!ddc.canControl)
}

@Test("Invalidated, it stops reading, writing and calling back")
func invalidateStopsEverything() {
    let (monitor, link, ddc) = makeBrightness()
    var changes = 0
    ddc.onControlChange = { changes += 1 }
    ddc.invalidate()
    #expect(!ddc.canControl)
    #expect(ddc.read() == nil)
    ddc.write(0.9)
    monitor.isOff = true
    link.advance(by: 6)
    #expect(monitor.writes.isEmpty)
    #expect(changes == 0)
}
