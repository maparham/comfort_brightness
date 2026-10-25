import Foundation

/// Bounds calls into a system service that can stop answering without failing.
///
/// macOS's brightness daemon, corebrightnessd, has been seen to come out of a
/// long sleep still accepting connections but never replying. Its client
/// library waits for that reply synchronously and with no deadline, so a
/// thread that asks it anything stops for good. On the main thread that froze
/// the whole app for as long as the daemon stayed stuck: over an hour, ended
/// only by killing the daemon by hand.
///
/// Each call runs on the gate's own serial queue while the caller waits at
/// most `timeout`. A call that overruns is abandoned where it is, and the gate
/// declares the service stuck. From then on calls fail at once rather than
/// queueing behind the one that never came back. When that call does return,
/// because the daemon was restarted or merely answered late, the service is
/// declared healthy again.
public final class ServiceGate: @unchecked Sendable {
    private let timeout: TimeInterval
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var stuck = false
    private var stuckHandler: (@Sendable (Bool) -> Void)?

    public init(label: String, timeout: TimeInterval) {
        self.timeout = timeout
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// True from the moment a call overruns until that call returns.
    public var isStuck: Bool { lock.withLock { stuck } }

    /// Told the new state each time it changes. Called on whichever thread
    /// noticed the change, never with the gate's lock held; a UI listener has
    /// to hop to the main actor itself.
    public var onStuckChange: (@Sendable (Bool) -> Void)? {
        get { lock.withLock { stuckHandler } }
        set { lock.withLock { stuckHandler = newValue } }
    }

    /// Runs `work` and returns its result, or nil if the service is stuck or
    /// `work` did not finish within the timeout. `work` must not touch state
    /// the caller relies on afterwards: an abandoned call runs on to
    /// completion whenever the service lets it.
    public func call<T: Sendable>(_ work: @escaping @Sendable () -> T) -> T? {
        if isStuck { return nil }
        let pending = Pending<T>()
        let done = DispatchSemaphore(value: 0)
        queue.async { [self] in
            // A call its caller gave up on while it waited in the queue is
            // stale: a brightness write would land long after it was wanted,
            // over whatever the user has set since. Reaching it at all means
            // the queue is moving again, which is the same news as a hung call
            // returning, so it clears the gate just the same.
            guard pending.start() else {
                setStuck(false)
                return
            }
            let result = work()
            let wasAbandoned = pending.finish(with: result)
            done.signal()
            if wasAbandoned { setStuck(false) }
        }
        if done.wait(timeout: .now() + timeout) == .success {
            return pending.result
        }
        // The call may have finished between the deadline and here. Then it
        // was merely slow, and its answer is as good as any.
        guard pending.abandon() else { return pending.result }
        setStuck(true)
        return nil
    }

    private func setStuck(_ newValue: Bool) {
        let handler: (@Sendable (Bool) -> Void)? = lock.withLock {
            guard stuck != newValue else { return nil }
            stuck = newValue
            return stuckHandler
        }
        handler?(newValue)
    }
}

/// One call's outcome, settled exactly once by whichever comes first: the
/// work finishing, or the caller giving up on it.
private final class Pending<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T?
    private var isFinished = false
    private var isAbandoned = false

    var result: T? { lock.withLock { value } }

    /// Claims the call for running. Returns false if the caller had already
    /// given up on it, in which case it must not run.
    func start() -> Bool {
        lock.withLock { !isAbandoned }
    }

    /// Records the result. Returns true if the caller had already given up,
    /// in which case the gate was declared stuck on this call's account.
    func finish(with result: T) -> Bool {
        lock.withLock {
            value = result
            isFinished = true
            return isAbandoned
        }
    }

    /// Gives up on the call. Returns false if it had in fact just finished.
    func abandon() -> Bool {
        lock.withLock {
            guard !isFinished else { return false }
            isAbandoned = true
            return true
        }
    }
}
