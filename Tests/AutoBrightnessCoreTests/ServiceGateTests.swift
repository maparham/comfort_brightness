import Foundation
import Testing
@testable import AutoBrightnessCore

/// Collects what a gate reports, from whichever thread it reports on.
private final class Recorder<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []
    func append(_ value: Value) { lock.withLock { stored.append(value) } }
    var values: [Value] { lock.withLock { stored } }
}

/// Polls until `condition` holds or `seconds` pass. The gate recovers on its
/// own queue, so a test has to wait for it rather than assume it.
private func waitUntil(_ seconds: Double = 2, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        Thread.sleep(forTimeInterval: 0.005)
    }
    return condition()
}

/// A gate with one call hung inside it, released by `release`.
private func stuckGate(
    timeout: Double = 0.05
) -> (ServiceGate, release: DispatchSemaphore, changes: Recorder<Bool>) {
    let gate = ServiceGate(label: "test", timeout: timeout)
    let changes = Recorder<Bool>()
    gate.onStuckChange = { changes.append($0) }
    let release = DispatchSemaphore(value: 0)
    _ = gate.call { release.wait(); return 0 }
    return (gate, release, changes)
}

@Test("A call that answers in time returns its result and leaves the service healthy")
func gateReturnsTimelyResult() {
    let gate = ServiceGate(label: "test", timeout: 1)
    #expect(gate.call { 42 } == 42)
    #expect(!gate.isStuck)
}

@Test("A call that overruns is abandoned at the deadline and the service declared stuck")
func gateAbandonsOverrunningCall() {
    let gate = ServiceGate(label: "test", timeout: 0.05)
    let changes = Recorder<Bool>()
    gate.onStuckChange = { changes.append($0) }
    let release = DispatchSemaphore(value: 0)
    defer { release.signal() }

    let started = Date()
    let result = gate.call { release.wait(); return 1 }

    #expect(result == nil)
    #expect(Date().timeIntervalSince(started) < 0.5)
    #expect(gate.isStuck)
    #expect(changes.values == [true])
}

@Test("While stuck, calls fail at once and never run")
func gateFailsFastWhileStuck() {
    let (gate, release, _) = stuckGate(timeout: 0.2)
    defer { release.signal() }
    let ran = Recorder<Bool>()

    let started = Date()
    let result = gate.call { ran.append(true); return 2 }

    #expect(result == nil)
    // Well under the timeout: it was refused, not queued behind the hung call.
    #expect(Date().timeIntervalSince(started) < 0.1)
    release.signal()
    #expect(waitUntil { !gate.isStuck })
    #expect(ran.values.isEmpty)
}

@Test("When the hung call finally returns, the service is healthy again")
func gateRecoversWhenHungCallReturns() {
    let (gate, release, changes) = stuckGate()
    #expect(gate.isStuck)

    release.signal()

    #expect(waitUntil { !gate.isStuck })
    #expect(changes.values == [true, false])
    #expect(gate.call { 3 } == 3)
}

@Test("A gate that goes stuck again after recovering reports it again")
func gateReportsEachEpisode() {
    let (gate, firstRelease, changes) = stuckGate()
    firstRelease.signal()
    #expect(waitUntil { !gate.isStuck })

    let secondRelease = DispatchSemaphore(value: 0)
    defer { secondRelease.signal() }
    #expect(gate.call { secondRelease.wait(); return 4 } == nil)

    #expect(gate.isStuck)
    #expect(changes.values == [true, false, true])
}

@Test("An optional result passes through unchanged")
func gatePassesOptionalResult() {
    let gate = ServiceGate(label: "test", timeout: 1)
    let missing: Double?? = gate.call { nil as Double? }
    #expect(missing == .some(nil))
    #expect(!gate.isStuck)
}

@Test("A call given up on while queued behind a hung one never runs")
func gateDropsAbandonedQueuedCall() {
    let gate = ServiceGate(label: "test", timeout: 0.1)
    let release = DispatchSemaphore(value: 0)
    let hungStarted = DispatchSemaphore(value: 0)
    let ran = Recorder<Bool>()
    let queuedDone = DispatchSemaphore(value: 0)

    // A hung call on one thread, and a second call made from another thread
    // before the gate knows it is stuck, so it queues behind the first.
    DispatchQueue.global().async {
        _ = gate.call { hungStarted.signal(); release.wait(); return 0 }
    }
    hungStarted.wait()
    DispatchQueue.global().async {
        _ = gate.call { ran.append(true); return 1 }
        queuedDone.signal()
    }
    queuedDone.wait()
    #expect(gate.isStuck)

    // The service comes back. The queued call is stale by now: a write
    // would move the panel to a level nobody wants any more.
    release.signal()
    #expect(waitUntil { !gate.isStuck })
    Thread.sleep(forTimeInterval: 0.05)
    #expect(ran.values.isEmpty)
    #expect(gate.call { 2 } == 2)
}
