import Foundation

/// Repeatedly invokes a tick until cancelled. Abstracted so the ramp can be
/// driven by a run-loop timer in the app and pumped by hand in tests.
public protocol RampScheduling: AnyObject {
    func start(interval: TimeInterval, tick: @escaping @Sendable () -> Void)
    func cancel()
}

/// Decorator that turns each discrete brightness write into a short eased
/// glide, so the 2 Hz control loop's steps are not visible as pops.
///
/// The whole object lives on the main run loop; `@unchecked Sendable` exists
/// only because the scheduler's tick closure must be `@Sendable` under strict
/// concurrency. Every ramp finishes in `stepCount * stepInterval`, which must
/// stay under one 2 Hz tick (500 ms) — the `Coordinator` reads the panel back
/// each tick and attributes any shortfall from its last write to the user.
public final class RampingBrightness: BrightnessControlling, @unchecked Sendable {
    private let wrapped: BrightnessControlling
    private let scheduler: RampScheduling
    private let stepCount: Int
    private let stepInterval: TimeInterval
    private var remainingSteps: [Double] = []
    private var pendingTarget: Double?

    public init(
        wrapping: BrightnessControlling,
        scheduler: RampScheduling,
        stepCount: Int = 20,
        stepInterval: TimeInterval = 1.0 / 60.0
    ) {
        precondition(
            Double(stepCount) * stepInterval < 0.5,
            "a ramp must finish inside one 2 Hz tick or the Coordinator misreads it as user input"
        )
        self.wrapped = wrapping
        self.scheduler = scheduler
        self.stepCount = stepCount
        self.stepInterval = stepInterval
    }

    public var canControl: Bool { wrapped.canControl }
    public var externalChangeThreshold: Double { wrapped.externalChangeThreshold }

    /// While a ramp is in flight the target — not the step the panel happens to
    /// be sitting on — is the truthful answer to "where is this panel". The
    /// glide is ours and it is already committed, so reporting an intermediate
    /// step would make the `Coordinator` read a shortfall from its own last
    /// write as user input if the run loop ever ran late, and would make the
    /// menu-bar readout flicker through every step of every glide.
    public func read() -> Double? { pendingTarget ?? wrapped.read() }

    public func write(_ value: Double) {
        cancelRamp()
        guard let current = wrapped.read(),
              abs(value - current) >= BrightnessRamp.minimumRampDistance else {
            // Unreadable panel or an imperceptible distance: just write it.
            wrapped.write(value)
            return
        }
        remainingSteps = BrightnessRamp.steps(from: current, to: value, count: stepCount)
        pendingTarget = value
        scheduler.start(interval: stepInterval) { [weak self] in
            self?.stepOnce()
        }
    }

    /// Lands any in-flight ramp on its final target right now. Called before
    /// process exit, so quitting mid-glide cannot strand the panel between
    /// levels.
    public func flush() {
        let target = pendingTarget
        cancelRamp()
        if let target { wrapped.write(target) }
    }

    private func stepOnce() {
        guard !remainingSteps.isEmpty else {
            cancelRamp()
            return
        }
        wrapped.write(remainingSteps.removeFirst())
        if remainingSteps.isEmpty { cancelRamp() }
    }

    private func cancelRamp() {
        scheduler.cancel()
        remainingSteps = []
        pendingTarget = nil
    }
}
