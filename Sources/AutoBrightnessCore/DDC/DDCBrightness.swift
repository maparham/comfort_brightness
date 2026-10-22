import Foundation

/// The main-thread face of a DDC monitor.
///
/// The coordinator was tuned against a panel that reads back exactly what it
/// was given. A DDC monitor holds whole steps only, so this reports what the
/// coordinator asked for, and moves that answer only by whole steps the monitor
/// was actually seen to move by someone else. Its own rounding therefore never
/// looks like drift, and a single button press always looks like exactly one
/// step. See the spec's "Read-back contract".
///
/// Lives on the main thread with the coordinator. The bus work happens behind
/// `DDCLink`, and nothing here ever waits on it, except the termination flush.
public final class DDCBrightness: BrightnessControlling {
    private let link: DDCLink
    private var maximum: Int
    private let seedLevel: Int
    private var requested: Double?
    /// Steps the monitor has been seen to move, by someone else, since our
    /// last write. Measured from what the monitor was actually showing, so a
    /// write of ours that a press cancelled is never counted as part of it.
    private var observedSteps = 0
    private var seenObservations = 0
    private var isUnwritable = false
    private var isInvalidated = false

    /// False while the monitor is not answering (asleep, unplugged, DDC
    /// switched off). Control is kept meanwhile, so a restore can be queued
    /// for when it returns.
    public private(set) var isResponding = true
    /// Called on every change of `isResponding` or `canControl`.
    public var onControlChange: (() -> Void)?

    public init(link: DDCLink, seed: DDCReading) {
        self.link = link
        maximum = max(seed.maximum, 1)
        seedLevel = seed.current
        link.onEvent = { [weak self] event in self?.handle(event) }
    }

    public var canControl: Bool { !isUnwritable && !isInvalidated }

    /// Half of one of the monitor's steps: a single press always clears it,
    /// and nothing smaller is ever reported.
    public var externalChangeThreshold: Double { 0.5 / Double(maximum) }

    public func read() -> Double? {
        guard !isInvalidated else { return nil }
        let base = requested ?? Double(seedLevel) / Double(maximum)
        return min(max(base + Double(observedSteps) / Double(maximum), 0), 1)
    }

    public func write(_ value: Double) {
        guard canControl else { return }
        let level = min(max(value, 0), 1)
        requested = level
        observedSteps = 0
        link.submit(level: level, seenObservations: seenObservations)
    }

    public func startFlush() { link.startFlush() }

    public func waitForFlush(deadline: DispatchTime) { link.waitForFlush(deadline: deadline) }

    /// The display is gone or has been given up on. Nothing may call back into
    /// a unit that has been dropped.
    public func invalidate() {
        isInvalidated = true
        onControlChange = nil
        link.onEvent = nil
        link.invalidate()
    }

    private func handle(_ event: DDCEvent) {
        guard !isInvalidated else { return }
        switch event {
        case let .observed(level, expected, maximum, count):
            self.maximum = max(maximum, 1)
            observedSteps += level - expected
            seenObservations = count
        case let .responding(responding):
            isResponding = responding
            onControlChange?()
        case .unwritable:
            isUnwritable = true
            onControlChange?()
        }
    }
}
