# Smooth Brightness Ramp Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn each discrete 2 Hz brightness write into a short eased glide so adjustments look continuous instead of popping.

**Architecture:** A pure step generator (`BrightnessRamp`) in Core computes eased intermediate values; a decorator (`RampingBrightness`) implementing `BrightnessControlling` wraps `DisplayServicesBrightness` and plays those values on a scheduler abstraction. `AppModel` wires in a run-loop-timer scheduler and flushes on termination. `Coordinator` is untouched.

**Tech Stack:** Swift 6 (strict concurrency), SwiftPM, Swift Testing (`import Testing`, `#expect`), Foundation `Timer`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-05-smooth-brightness-ramp-design.md`.
- Every ramp must complete in under ~500 ms (one 2 Hz tick), or `Coordinator`'s external-change detection breaks. Defaults: 20 steps × 1/60 s ≈ 333 ms. Do not raise these past 500 ms.
- The final ramp step must write the target bit-exactly — `Coordinator` relies on read-back equaling what it wrote.
- Swift 6 strict concurrency: `Timer.scheduledTimer` blocks are `@Sendable`, so the scheduler's tick closure is `@Sendable` and classes capturing state into it are `@unchecked Sendable` with a comment stating main-run-loop confinement.
- Tests run with `swift test`. Build with `swift build`.
- Never drop a write: any failure path falls back to a direct `wrapped.write`.

---

### Task 1: `BrightnessRamp` step generator (Core)

**Files:**
- Create: `Sources/AutoBrightnessCore/BrightnessRamp.swift`
- Test: `Tests/AutoBrightnessCoreTests/BrightnessRampTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `BrightnessRamp.minimumRampDistance: Double` (= 0.01) and `BrightnessRamp.steps(from: Double, to: Double, count: Int) -> [Double]` — `count` values easing from just past `from` to exactly `to`. Task 2 calls both.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AutoBrightnessCoreTests/BrightnessRampTests.swift
import Testing
@testable import AutoBrightnessCore

@Test("Steps end exactly on the target and never include the start")
func stepsHitTargetExactly() {
    let steps = BrightnessRamp.steps(from: 0.5, to: 0.55, count: 20)
    #expect(steps.count == 20)
    #expect(steps.last == 0.55)
    #expect(steps.first != 0.5)
}

@Test("Steps are monotonic in the direction of travel, both ways")
func stepsAreMonotonic() {
    let up = BrightnessRamp.steps(from: 0.3, to: 0.5, count: 20)
    #expect(zip(up, up.dropFirst()).allSatisfy { $0 <= $1 })
    let down = BrightnessRamp.steps(from: 0.5, to: 0.3, count: 20)
    #expect(zip(down, down.dropFirst()).allSatisfy { $0 >= $1 })
}

@Test("No single step exceeds the eased per-step bound")
func stepsStaySmall() {
    // Smoothstep's steepest slope is 1.5x linear, at the midpoint.
    let distance = 0.20
    let steps = BrightnessRamp.steps(from: 0.4, to: 0.6, count: 20)
    let deltas = zip([0.4] + steps, steps).map { abs($1 - $0) }
    #expect(deltas.allSatisfy { $0 <= distance * 1.5 / 20 + 1e-12 })
}

@Test("A zero-distance ramp is all target values")
func zeroDistance() {
    let steps = BrightnessRamp.steps(from: 0.5, to: 0.5, count: 5)
    #expect(steps == [0.5, 0.5, 0.5, 0.5, 0.5])
}

@Test("A single-step ramp is just the target")
func singleStep() {
    #expect(BrightnessRamp.steps(from: 0.2, to: 0.8, count: 1) == [0.8])
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BrightnessRampTests`
Expected: compile FAILURE — `BrightnessRamp` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AutoBrightnessCore/BrightnessRamp.swift

/// Pure math for gliding between two brightness levels.
public enum BrightnessRamp {
    /// Below this distance a direct write is already imperceptible, so no
    /// ramp is worth its writes.
    public static let minimumRampDistance = 0.01

    /// `count` eased values from `start` to `target`: the start itself is
    /// excluded, the last value is `target` bit-exactly. Smoothstep easing,
    /// so the glide begins and ends gently rather than at constant velocity.
    public static func steps(from start: Double, to target: Double, count: Int) -> [Double] {
        guard count > 1 else { return [target] }
        return (1...count).map { i in
            guard i < count else { return target }
            let t = Double(i) / Double(count)
            let eased = t * t * (3 - 2 * t)
            return start + (target - start) * eased
        }
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BrightnessRampTests`
Expected: 5 tests PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessCore/BrightnessRamp.swift Tests/AutoBrightnessCoreTests/BrightnessRampTests.swift
git commit -m "feat: eased step generator for brightness ramps"
```

---

### Task 2: `RampingBrightness` decorator and scheduler abstraction (Core)

**Files:**
- Create: `Sources/AutoBrightnessCore/RampingBrightness.swift`
- Test: `Tests/AutoBrightnessCoreTests/RampingBrightnessTests.swift`

**Interfaces:**
- Consumes: `BrightnessRamp.steps(from:to:count:)`, `BrightnessRamp.minimumRampDistance` (Task 1); `BrightnessControlling`, `FakeBrightness` (existing, `Sources/AutoBrightnessCore/BrightnessControlling.swift`).
- Produces: `RampScheduling` protocol (`start(interval:tick:)`, `cancel()`); `RampingBrightness` class — `init(wrapping:scheduler:stepCount:stepInterval:)`, `canControl`, `read()`, `write(_:)`, `flush()`. Task 3 constructs it and calls `flush()`.

- [ ] **Step 1: Write the failing tests**

```swift
// Tests/AutoBrightnessCoreTests/RampingBrightnessTests.swift
import Testing
@testable import AutoBrightnessCore

/// Hand-pumped stand-in for the run-loop timer.
final class ManualRampScheduler: RampScheduling, @unchecked Sendable {
    private(set) var tick: (@Sendable () -> Void)?
    private(set) var interval: Double?
    func start(interval: Double, tick: @escaping @Sendable () -> Void) {
        self.interval = interval
        self.tick = tick
    }
    func cancel() { tick = nil }
    var isRunning: Bool { tick != nil }
    func pump(_ times: Int = 1) {
        for _ in 0..<times { tick?() }
    }
}

/// An actuator whose read path has failed.
final class NilReadBrightness: BrightnessControlling {
    let canControl = true
    private(set) var writes: [Double] = []
    func read() -> Double? { nil }
    func write(_ value: Double) { writes.append(value) }
}

@Test("A write beyond the threshold becomes a ramp that lands exactly on target")
func writeRampsToTarget() {
    let fake = FakeBrightness(value: 0.5)
    let scheduler = ManualRampScheduler()
    let ramping = RampingBrightness(wrapping: fake, scheduler: scheduler, stepCount: 20)
    ramping.write(0.55)
    #expect(fake.writes.isEmpty)          // nothing until the timer fires
    #expect(scheduler.isRunning)
    scheduler.pump(20)
    #expect(fake.writes.count == 20)
    #expect(fake.read() == 0.55)          // bit-exact landing
    #expect(!scheduler.isRunning)         // timer cancelled at the end
}

@Test("A tiny write goes straight through with no ramp")
func tinyWriteIsDirect() {
    let fake = FakeBrightness(value: 0.5)
    let scheduler = ManualRampScheduler()
    let ramping = RampingBrightness(wrapping: fake, scheduler: scheduler)
    ramping.write(0.505)
    #expect(fake.writes == [0.505])
    #expect(!scheduler.isRunning)
}

@Test("A failed read falls back to a direct write, never dropping it")
func nilReadFallsBack() {
    let broken = NilReadBrightness()
    let ramping = RampingBrightness(wrapping: broken, scheduler: ManualRampScheduler())
    ramping.write(0.7)
    #expect(broken.writes == [0.7])
}

@Test("A second write supersedes an in-flight ramp")
func secondWriteSupersedes() {
    let fake = FakeBrightness(value: 0.5)
    let scheduler = ManualRampScheduler()
    let ramping = RampingBrightness(wrapping: fake, scheduler: scheduler, stepCount: 20)
    ramping.write(0.6)
    scheduler.pump(5)
    ramping.write(0.4)
    scheduler.pump(20)
    #expect(fake.read() == 0.4)
    #expect(!scheduler.isRunning)
}

@Test("Flush lands an in-flight ramp on its final target immediately")
func flushLandsTarget() {
    let fake = FakeBrightness(value: 0.5)
    let scheduler = ManualRampScheduler()
    let ramping = RampingBrightness(wrapping: fake, scheduler: scheduler, stepCount: 20)
    ramping.write(0.6)
    scheduler.pump(3)
    ramping.flush()
    #expect(fake.read() == 0.6)
    #expect(!scheduler.isRunning)
    let countAfterFlush = fake.writes.count
    ramping.flush()                       // idle flush writes nothing
    #expect(fake.writes.count == countAfterFlush)
}

@Test("Read and canControl forward to the wrapped control")
func forwarding() {
    let fake = FakeBrightness(value: 0.42)
    let ramping = RampingBrightness(wrapping: fake, scheduler: ManualRampScheduler())
    #expect(ramping.read() == 0.42)
    #expect(ramping.canControl)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter RampingBrightnessTests`
Expected: compile FAILURE — `RampScheduling` / `RampingBrightness` not defined.

- [ ] **Step 3: Write the implementation**

```swift
// Sources/AutoBrightnessCore/RampingBrightness.swift
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
        self.wrapped = wrapping
        self.scheduler = scheduler
        self.stepCount = stepCount
        self.stepInterval = stepInterval
    }

    public var canControl: Bool { wrapped.canControl }

    public func read() -> Double? { wrapped.read() }

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
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter RampingBrightnessTests`
Expected: 6 tests PASS.

- [ ] **Step 5: Run the full suite to check nothing regressed**

Run: `swift test`
Expected: all tests PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/AutoBrightnessCore/RampingBrightness.swift Tests/AutoBrightnessCoreTests/RampingBrightnessTests.swift
git commit -m "feat: ramping decorator glides brightness writes"
```

---

### Task 3: Timer scheduler and app wiring

**Files:**
- Create: `Sources/AutoBrightnessApp/TimerRampScheduler.swift`
- Modify: `Sources/AutoBrightnessApp/AppModel.swift` (init at ~line 88–112; `restoreBaselineOnce` at ~line 237–241)

**Interfaces:**
- Consumes: `RampScheduling`, `RampingBrightness` (Task 2); existing `DisplayServicesBrightness`, `Coordinator`.
- Produces: nothing further — this completes the wiring.

- [ ] **Step 1: Write the timer scheduler**

```swift
// Sources/AutoBrightnessApp/TimerRampScheduler.swift
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
```

- [ ] **Step 2: Wire the decorator into AppModel**

In `Sources/AutoBrightnessApp/AppModel.swift`, change the stored property (currently `private let brightness: DisplayServicesBrightness`) to:

```swift
private let brightness: RampingBrightness
```

In `init()`, replace:

```swift
let brightness = DisplayServicesBrightness()
self.brightness = brightness
```

with:

```swift
let brightness = RampingBrightness(
    wrapping: DisplayServicesBrightness(),
    scheduler: TimerRampScheduler()
)
self.brightness = brightness
```

(`canControlBrightness = brightness.canControl` and the `Coordinator` construction below it are unchanged — the decorator forwards `canControl` and conforms to `BrightnessControlling`.)

In `restoreBaselineOnce()`, add the flush after the restore so termination cannot exit mid-glide:

```swift
private func restoreBaselineOnce() {
    guard !hasRestoredBaseline else { return }
    hasRestoredBaseline = true
    coordinator.restoreBaseline()
    brightness.flush()
}
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build && swift test`
Expected: clean build, all tests PASS.

- [ ] **Step 4: Manual smoke check (best-effort)**

If running interactively on the Mac with the app buildable: `swift run AutoBrightnessApp`, switch between a dark and a bright window, and confirm brightness glides instead of stepping. If the environment cannot run the GUI app, note that and rely on the test suite.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessApp/TimerRampScheduler.swift Sources/AutoBrightnessApp/AppModel.swift
git commit -m "feat: glide brightness writes instead of stepping"
```
