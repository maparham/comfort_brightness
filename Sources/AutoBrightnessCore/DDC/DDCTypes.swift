import Foundation

/// One answer to "what is your brightness?" from a DDC monitor. The maximum
/// is the monitor's own and is not assumed to be 100.
public struct DDCReading: Equatable, Sendable {
    public var current: Int
    public var maximum: Int

    public init(current: Int, maximum: Int) {
        self.current = current
        self.maximum = maximum
    }
}

/// The wire to one monitor. Both calls block for as long as the bus takes,
/// which is why they are only ever made off the main thread.
public protocol DDCTransport: AnyObject {
    /// VCP 0x10's current and maximum, or nil on any failure.
    func readBrightness() -> DDCReading?
    /// True when the monitor acknowledged the write.
    func writeBrightness(_ value: Int) -> Bool
}

/// What the queue side tells the main thread.
public enum DDCEvent: Equatable, Sendable {
    /// The monitor shows `level` where we believed it showed `expected`, and
    /// nothing we sent explains the difference: someone pressed its buttons.
    /// `count` numbers the observations, so a write computed before this one
    /// was seen can be recognised and dropped.
    case observed(level: Int, expected: Int, maximum: Int, count: Int)
    /// The monitor stopped or started answering.
    case responding(Bool)
    /// The monitor acknowledges writes but never applies them.
    case unwritable
}

/// The main thread's handle on the queue side. `DDCQueueLink` in the app;
/// a virtual-time harness in the tests.
public protocol DDCLink: AnyObject {
    /// Set by `DDCBrightness`. Always called on the main thread.
    var onEvent: ((DDCEvent) -> Void)? { get set }
    func submit(level: Double, seenObservations: Int)
    /// Termination only: send the final target now, without gliding.
    func startFlush()
    /// Blocks until the flush has been sent or `deadline` passes.
    func waitForFlush(deadline: DispatchTime)
    /// Stops all work and all callbacks for good.
    func invalidate()
}
