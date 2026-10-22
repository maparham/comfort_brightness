import AutoBrightnessCore
import Foundation

/// Runs one monitor's `DDCEngine` on its own serial queue in real time.
///
/// The engine decides; this only carries out what it asks for, arms a timer
/// for its next wait, and posts its events to the main thread. Ownership is
/// split strictly: `engine`, `timer` and `isInvalidated` are touched only on
/// `queue`, and `onEvent` and `flushDone` only on main. That split is what the
/// `@unchecked Sendable` rests on.
///
/// Main is never waited on from here: events go with `main.async`, never
/// `main.sync`. That is what keeps the termination flush, which blocks main
/// while it waits on this queue, from deadlocking.
final class DDCQueueLink: DDCLink, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.mahmoudparham.autobrightness.ddc", qos: .utility)
    private let engine: DDCEngine
    private var timer: DispatchSourceTimer?
    private var isInvalidated = false
    private var flushDone: DispatchSemaphore?
    var onEvent: ((DDCEvent) -> Void)?

    init(transport: IOAVServiceTransport, seed: DDCReading) {
        engine = DDCEngine(transport: transport, seed: seed, now: Self.now())
        queue.async { self.pump() }
    }

    private static func now() -> Double { ProcessInfo.processInfo.systemUptime }

    func submit(level: Double, seenObservations: Int) {
        queue.async {
            self.engine.submit(level: level, seenObservations: seenObservations)
            self.pump()
        }
    }

    func replaceTransport(_ transport: IOAVServiceTransport) {
        queue.async {
            self.engine.replaceTransport(transport)
            self.pump()
        }
    }

    func startFlush() {
        let done = DispatchSemaphore(value: 0)
        flushDone = done
        queue.async {
            defer { done.signal() }
            guard !self.isInvalidated else { return }
            if let sent = self.engine.lastSendAt {
                let wait = sent + self.engine.timing.spacing - Self.now()
                if wait > 0 { usleep(useconds_t(wait * 1_000_000)) }
            }
            self.engine.performFlush(now: Self.now())
        }
    }

    func waitForFlush(deadline: DispatchTime) {
        _ = flushDone?.wait(timeout: deadline)
        flushDone = nil
    }

    func invalidate() {
        onEvent = nil
        queue.async {
            self.isInvalidated = true
            self.timer?.cancel()
            self.timer = nil
        }
    }

    /// Does everything the engine wants done now, then sleeps until it next
    /// wants something.
    private func pump() {
        dispatchPrecondition(condition: .onQueue(queue))
        guard !isInvalidated else { return }
        var events: [DDCEvent] = []
        while true {
            let now = Self.now()
            switch engine.nextAction(now: now) {
            case .send:
                events += engine.performSend(now: now)
            case .read:
                events += engine.performRead(now: now)
            case .wait(let until):
                arm(at: until, now: now)
                post(events)
                return
            }
        }
    }

    private func arm(at until: Double, now: Double) {
        timer?.cancel()
        timer = nil
        guard until.isFinite else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + max(0, until - now), leeway: .milliseconds(5))
        timer.setEventHandler { [weak self] in self?.pump() }
        timer.resume()
        self.timer = timer
    }

    private func post(_ events: [DDCEvent]) {
        guard !events.isEmpty else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            for event in events { self.onEvent?(event) }
        }
    }
}
