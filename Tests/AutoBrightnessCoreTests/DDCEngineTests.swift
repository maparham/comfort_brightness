import Testing
@testable import AutoBrightnessCore

private func makeLink(level: Int = 50, maximum: Int = 100) -> (FakeMonitor, VirtualDDCLink, EventLog) {
    let monitor = FakeMonitor(level: level, maximum: maximum)
    let link = VirtualDDCLink(monitor: monitor)
    let log = EventLog()
    link.onEvent = { log.events.append($0) }
    return (monitor, link, log)
}

@Test("A target the monitor already shows is not sent")
func equalTargetNotSent() {
    let (monitor, link, _) = makeLink()
    link.submit(level: 0.503, seenObservations: 0)   // rounds to 50
    link.advance(by: 2)
    #expect(monitor.writes.isEmpty)
}

@Test("A level established by a read is not sent again")
func levelFromReadNotResent() {
    let (monitor, link, log) = makeLink()
    monitor.press(to: 40)
    link.advance(by: 1.1)
    link.submit(level: 0.40, seenObservations: log.observedCount)
    link.advance(by: 1)
    #expect(monitor.writes.isEmpty)
}

@Test("A glide is checked by a read, then reaches its target in four spaced sends")
func glideInFourSends() {
    let (monitor, link, _) = makeLink()
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.writes == [53, 56, 59, 60])
    #expect(link.log.first?.action == "read")
    let sends = link.log.filter { $0.action == "send" }.map(\.time)
    for (a, b) in zip(sends, sends.dropFirst()) {
        #expect(b - a >= DDCEngine.Timing.standard.spacing - 1e-9)
    }
}

@Test("A newer target takes over mid-glide from where the monitor is")
func newerTargetMidGlide() {
    let (monitor, link, _) = makeLink()
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 0.13)
    #expect(monitor.writes == [53, 56])
    link.submit(level: 0.40, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.writes == [53, 56, 52, 48, 44, 40])
}

@Test("A failed send leaves the known level alone and is retried")
func failedSendRetried() {
    let (monitor, link, log) = makeLink()
    monitor.failingWrites = 1
    link.submit(level: 0.51, seenObservations: 0)
    link.advance(by: 0.1)
    #expect(link.engine.lastKnown == 50)
    link.advance(by: 1.5)
    #expect(monitor.level == 51)
    #expect(log.events.isEmpty)
}

@Test("Reads keep happening while writes keep coming, and only once sends have settled")
func quietBarrier() {
    let (_, link, log) = makeLink()
    for i in 0..<30 {
        link.submit(level: i.isMultiple(of: 2) ? 0.40 : 0.60, seenObservations: 0)
        link.advance(by: 0.1)
    }
    let timing = DDCEngine.Timing.standard
    let reads = link.log.filter { $0.action == "read" }.map(\.time)
    let sends = link.log.filter { $0.action == "send" }.map(\.time)
    #expect(reads.count >= 3)
    for read in reads {
        if let lastSend = sends.filter({ $0 < read }).max() {
            #expect(read - lastSend >= timing.settleWindow - 1e-9)
        }
    }
    let longestGap = timing.refreshInterval + timing.settleWindow + VirtualDDCLink.readCost + timing.spacing
    for (a, b) in zip(reads, reads.dropFirst()) {
        #expect(b - a <= longestGap + 1e-9)
    }
    #expect(log.events.isEmpty)
}

@Test("A press is observed, and a write computed before it was seen is dropped")
func staleSubmitIgnored() {
    let (monitor, link, log) = makeLink()
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 0.5)
    monitor.press(to: 45)
    link.advance(by: 0.6)
    #expect(log.events == [.observed(level: 45, expected: 60, maximum: 100, count: 1)])
    link.submit(level: 0.70, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.level == 45)
    link.submit(level: 0.70, seenObservations: 1)
    link.advance(by: 0.5)
    #expect(monitor.level == 70)
}

@Test("A press just before a write is seen by the glide's check and not overwritten")
func pressBeforeGlideSurvives() {
    let (monitor, link, log) = makeLink()
    monitor.press(to: 30)
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 1)
    #expect(monitor.writes.isEmpty)
    #expect(monitor.level == 30)
    #expect(log.events == [.observed(level: 30, expected: 50, maximum: 100, count: 1)])
}

@Test("Several presses between two reads are one observation of the total")
func rapidPressesAccumulate() {
    let (monitor, link, log) = makeLink()
    monitor.press(to: 49)
    monitor.press(to: 47)
    link.advance(by: 1.1)
    #expect(log.events == [.observed(level: 47, expected: 50, maximum: 100, count: 1)])
}

@Test("A monitor that goes away stops being written, and a restore queued meanwhile lands first on return")
func dropoutAndRecovery() {
    let (monitor, link, log) = makeLink()
    monitor.isOff = true
    link.advance(by: 5.5)
    #expect(log.events == [.responding(false)])
    link.submit(level: 0.70, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.writes.isEmpty)
    monitor.isOff = false
    monitor.press(to: 20)   // came back at a level of its own
    link.advance(by: 1)
    #expect(log.events == [.responding(false), .responding(true)])
    #expect(monitor.level == 70)
}

@Test("A monitor that acknowledges writes but never applies them is given up on")
func unwritableDetected() {
    let (monitor, link, log) = makeLink()
    monitor.ignoresWrites = true
    for i in 0..<3 {
        link.submit(level: i.isMultiple(of: 2) ? 0.60 : 0.40, seenObservations: log.observedCount)
        link.advance(by: 1.0)
    }
    #expect(log.events.last == .unwritable)
    #expect(link.engine.isUnwritable)
}

@Test("A maximum other than 100 scales the levels")
func nonHundredMaximumScales() {
    let (monitor, link, _) = makeLink(level: 128, maximum: 255)
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.level == 153)
}

@Test("A reply with maximum 0 counts as a failure")
func zeroMaximumIsFailure() {
    let (monitor, link, log) = makeLink()
    monitor.maximum = 0
    link.advance(by: 5.5)
    #expect(log.events == [.responding(false)])
}

@Test("Flush sends the final target in one write")
func flushSendsFinalTarget() {
    let (monitor, link, _) = makeLink()
    link.submit(level: 0.90, seenObservations: 0)
    link.startFlush()
    #expect(monitor.writes == [90])
}
