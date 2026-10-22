import Foundation
@testable import AutoBrightnessCore

/// A monitor at the other end of a DDC cable.
final class FakeMonitor: DDCTransport {
    var level: Int
    var maximum: Int
    /// Every call fails, as for a monitor in standby or unplugged.
    var isOff = false
    /// Acknowledges writes and ignores them.
    var ignoresWrites = false
    /// The next this-many writes fail.
    var failingWrites = 0
    private(set) var writes: [Int] = []

    init(level: Int = 50, maximum: Int = 100) {
        self.level = level
        self.maximum = maximum
    }

    func readBrightness() -> DDCReading? {
        isOff ? nil : DDCReading(current: level, maximum: maximum)
    }

    func writeBrightness(_ value: Int) -> Bool {
        guard !isOff else { return false }
        if failingWrites > 0 {
            failingWrites -= 1
            return false
        }
        writes.append(value)
        if !ignoresWrites { level = value }
        return true
    }

    /// Someone pressing the monitor's own brightness buttons.
    func press(to newLevel: Int) { level = newLevel }
}

/// Runs a real `DDCEngine` inline in virtual time, the way `DDCQueueLink`
/// runs it on its queue in real time.
final class VirtualDDCLink: DDCLink {
    let engine: DDCEngine
    private(set) var now: Double = 0
    var onEvent: ((DDCEvent) -> Void)?
    /// When true, events wait in `heldEvents` until `deliver()`, standing in
    /// for the hop to the main thread arriving late.
    var holdsEvents = false
    private(set) var heldEvents: [DDCEvent] = []
    private(set) var log: [(time: Double, action: String)] = []
    /// How long a read occupies the bus: request, the 50 ms wait, the reply.
    static let readCost = 0.07

    init(monitor: FakeMonitor, timing: DDCEngine.Timing = .standard) {
        engine = DDCEngine(
            transport: monitor,
            seed: DDCReading(current: monitor.level, maximum: monitor.maximum),
            timing: timing,
            now: 0
        )
    }

    func submit(level: Double, seenObservations: Int) {
        engine.submit(level: level, seenObservations: seenObservations)
    }

    func startFlush() { engine.performFlush(now: now) }
    func waitForFlush(deadline: DispatchTime) {}
    func invalidate() { onEvent = nil }

    /// Moves virtual time forward by `seconds`, doing whatever the engine asks
    /// for on the way.
    func advance(by seconds: Double) {
        let end = now + seconds
        while true {
            switch engine.nextAction(now: now) {
            case .send:
                log.append((now, "send"))
                emit(engine.performSend(now: now))
            case .read:
                log.append((now, "read"))
                emit(engine.performRead(now: now))
                now += Self.readCost
            case .wait(let until):
                guard until <= end else {
                    now = max(now, end)
                    return
                }
                now = max(now, until)
            }
        }
    }

    func deliver() {
        let events = heldEvents
        heldEvents = []
        events.forEach { onEvent?($0) }
    }

    private func emit(_ events: [DDCEvent]) {
        if holdsEvents {
            heldEvents += events
        } else {
            events.forEach { onEvent?($0) }
        }
    }
}

/// Collects what a link reports.
final class EventLog {
    var events: [DDCEvent] = []
    var observedCount: Int {
        events.filter { if case .observed = $0 { true } else { false } }.count
    }
}
