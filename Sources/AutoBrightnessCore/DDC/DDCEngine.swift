import Foundation

/// The queue side of one DDC monitor: when to send, when to read, and what a
/// reading means.
///
/// DDC writes are absolute, and the monitor's own buttons move the same value
/// the app writes, so every rule here exists to keep a button press from being
/// silently overwritten. A glide is preceded by a read that checks the monitor
/// is where we left it. No read is trusted until our last send has settled. A
/// write computed before a press was seen is dropped rather than sent.
///
/// Not thread-safe, and touched from one queue only: `DDCQueueLink` in the
/// app, the test harness inline. Time is handed in rather than read, so the
/// whole thing runs in virtual time under test.
public final class DDCEngine {
    public struct Timing: Sendable, Equatable {
        /// Minimum time between two sends. DDC/CI asks for 50 ms.
        public var spacing: Double
        /// How long after a send a read is trusted. Monitors can go on
        /// reporting the level they had before a write for a short while.
        public var settleWindow: Double
        /// How often the monitor is read while nothing is being written.
        public var refreshInterval: Double

        public init(spacing: Double, settleWindow: Double, refreshInterval: Double) {
            self.spacing = spacing
            self.settleWindow = settleWindow
            self.refreshInterval = refreshInterval
        }

        /// Measured on the P24h-30 with `DDCProbe`; see the spec.
        public static let standard = Timing(spacing: 0.05, settleWindow: 0.226, refreshInterval: 1.0)
    }

    public enum Action: Equatable {
        case send
        case read
        case wait(until: Double)
    }

    /// A glide covers its distance in at most this many sends.
    static let glideSends = 4
    /// Consecutive transport failures before the monitor counts as gone.
    static let failureLimit = 5
    /// Reads in a row showing our sends were never applied before writing is
    /// given up on.
    static let unappliedLimit = 3
    /// Earliest retry after a failed read, so a glitch is not hammered.
    static let readRetryDelay = 0.25

    public let timing: Timing
    private var transport: DDCTransport
    public private(set) var maximum: Int
    /// The monitor's level as last established, by an acknowledged send or by
    /// a read. Everything is compared against this, never against the last
    /// value we happened to send.
    public private(set) var lastKnown: Int
    /// Where the current glide is heading, or nil when there is none.
    public private(set) var target: Int?
    private var stride = 1
    /// True once a read has confirmed, for the current glide, that the monitor
    /// is still where we left it.
    private var isGlideChecked = false
    /// The level the last successful read showed. Sends that leave a later read
    /// still showing it were not applied.
    private var confirmed: Int
    private var sentSinceRead = false
    private var unappliedReads = 0
    /// Observations posted so far. A submit made knowing fewer is stale.
    public private(set) var observations = 0
    public private(set) var lastSendAt: Double?
    private var lastReadAt: Double
    private var lastReadFailed = false
    private var failures = 0
    public private(set) var isResponding = true
    public private(set) var isUnwritable = false

    /// `seed` is the probe read that showed this monitor answers at all.
    public init(transport: DDCTransport, seed: DDCReading, timing: Timing = .standard, now: Double) {
        self.transport = transport
        self.timing = timing
        maximum = max(seed.maximum, 1)
        lastKnown = seed.current
        confirmed = seed.current
        lastReadAt = now
    }

    /// The IOAVService handle can be recreated across sleep and
    /// reconfiguration; the old one is then dead.
    public func replaceTransport(_ transport: DDCTransport) {
        self.transport = transport
    }

    public static func integer(_ level: Double, maximum: Int) -> Int {
        min(max(Int((level * Double(maximum)).rounded()), 0), maximum)
    }

    public func submit(level: Double, seenObservations: Int) {
        // Computed without knowing about a press we have already seen: sending
        // it would overwrite the press. The coordinator will see the press on
        // its next tick and write again.
        guard !isUnwritable, seenObservations >= observations else { return }
        let goal = Self.integer(level, maximum: maximum)
        guard goal != lastKnown else {
            target = nil
            return
        }
        if target == nil { isGlideChecked = false }
        aim(at: goal)
    }

    public func nextAction(now: Double) -> Action {
        if isUnwritable { return .wait(until: .infinity) }
        if let sent = lastSendAt, now < sent + timing.spacing {
            return .wait(until: sent + timing.spacing)
        }
        let refreshAt = lastReadAt + timing.refreshInterval
        // Away: only look for it to come back, at the normal cadence.
        if !isResponding {
            return now >= refreshAt ? .read : .wait(until: refreshAt)
        }
        let wantsRead = (target != nil && !isGlideChecked) || now >= refreshAt
        if wantsRead {
            if let sent = lastSendAt, now < sent + timing.settleWindow {
                return .wait(until: sent + timing.settleWindow)
            }
            if lastReadFailed, now < lastReadAt + Self.readRetryDelay {
                return .wait(until: lastReadAt + Self.readRetryDelay)
            }
            return .read
        }
        if target != nil { return .send }
        return .wait(until: refreshAt)
    }

    public func performSend(now: Double) -> [DDCEvent] {
        guard let target else { return [] }
        let next = lastKnown + max(-stride, min(stride, target - lastKnown))
        lastSendAt = now
        // A failed send changes nothing we believe about the monitor, so it can
        // never be reported as movement; the glide simply retries.
        guard transport.writeBrightness(next) else { return recordFailure() }
        failures = 0
        lastKnown = next
        sentSinceRead = true
        if next == target { self.target = nil }
        return []
    }

    public func performRead(now: Double) -> [DDCEvent] {
        lastReadAt = now
        guard let reading = transport.readBrightness(), reading.maximum > 0 else {
            lastReadFailed = true
            return recordFailure()
        }
        lastReadFailed = false
        failures = 0
        maximum = reading.maximum
        var events: [DDCEvent] = []

        if !isResponding {
            isResponding = true
            events.append(.responding(true))
            if let target {
                // A restore queued while the monitor was away goes out first.
                // Whatever the monitor kept meanwhile is not the user's doing.
                establish(reading.current)
                isGlideChecked = true
                aim(at: target)
                return events
            }
        }

        if reading.current == lastKnown {
            if sentSinceRead { unappliedReads = 0 }
            establish(reading.current)
            isGlideChecked = true
            return events
        }

        if sentSinceRead, reading.current == confirmed {
            unappliedReads += 1
            if unappliedReads >= Self.unappliedLimit {
                isUnwritable = true
                target = nil
                return events + [.unwritable]
            }
        } else {
            unappliedReads = 0
        }

        observations += 1
        events.append(.observed(
            level: reading.current,
            expected: lastKnown,
            maximum: reading.maximum,
            count: observations
        ))
        establish(reading.current)
        // The glide was aimed before the press; it would overwrite it.
        target = nil
        return events
    }

    /// Termination: the final target in one send, skipping the glide and the
    /// read barrier. The caller has already waited out `spacing`.
    public func performFlush(now: Double) {
        guard let target, isResponding, !isUnwritable else { return }
        lastSendAt = now
        if transport.writeBrightness(target) {
            lastKnown = target
            self.target = nil
        }
    }

    private func aim(at goal: Int) {
        target = goal
        let distance = Double(abs(goal - lastKnown))
        stride = max(1, Int((distance / Double(Self.glideSends)).rounded(.up)))
    }

    private func establish(_ level: Int) {
        lastKnown = level
        confirmed = level
        sentSinceRead = false
    }

    private func recordFailure() -> [DDCEvent] {
        failures += 1
        guard failures >= Self.failureLimit, isResponding else { return [] }
        isResponding = false
        return [.responding(false)]
    }
}
