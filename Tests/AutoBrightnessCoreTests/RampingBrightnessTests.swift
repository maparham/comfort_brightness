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
