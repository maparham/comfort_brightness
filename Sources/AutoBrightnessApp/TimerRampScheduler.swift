import AutoBrightnessCore
import Foundation

/// Drives a ramp with a repeating run-loop timer. Created and used only on
/// the main thread; `@unchecked Sendable` because `Timer`'s block is
/// `@Sendable`.
final class TimerRampScheduler: RampScheduling, @unchecked Sendable {
    private var timer: Timer?

    func start(interval: TimeInterval, tick: @escaping @Sendable () -> Void) {
        dispatchPrecondition(condition: .onQueue(.main))
        cancel()
        let timer = Timer(timeInterval: interval, repeats: true) { _ in
            tick()
        }
        // Common modes, not the default mode: the control loop's ticks arrive
        // through the main dispatch queue, which keeps draining during event
        // tracking (holding the status-item button, scrolling the popover). A
        // default-mode timer freezes then while ticks keep writing — the panel
        // sits still under withheld-write probes and the Coordinator learns a
        // phantom actuator bias.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func cancel() {
        dispatchPrecondition(condition: .onQueue(.main))
        timer?.invalidate()
        timer = nil
    }
}
