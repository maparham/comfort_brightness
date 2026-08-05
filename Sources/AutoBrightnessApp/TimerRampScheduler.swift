import AutoBrightnessCore
import Foundation

/// Drives a ramp with a repeating run-loop timer. Created and used only on
/// the main thread; `@unchecked Sendable` because `Timer`'s block is
/// `@Sendable`.
final class TimerRampScheduler: RampScheduling, @unchecked Sendable {
    private var timer: Timer?

    func start(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
        cancel()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            tick()
        }
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}
