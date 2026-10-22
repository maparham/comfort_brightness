# External Displays Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Adjust every active display's brightness independently from its own content. That covers the built-in panel, Apple externals via DisplayServices, and third-party monitors via DDC/CI over `IOAVService`.

**Architecture:** One `DisplayUnit` per display (sampler → coordinator → backend), managed by a `DisplayManager` that reconciles with the active display set. The DDC backend is split by thread. `DDCBrightness` is the main-thread `BrightnessControlling`. `DDCQueueLink` runs a pure `DDCEngine` state machine on a serial queue against an `IOAVServiceTransport`. `Coordinator` gains one thing: a backend-supplied external-change threshold.

**Tech Stack:** Swift 6 (tools 6.0, strict concurrency), SwiftPM + XcodeGen, Swift Testing, AppKit/SwiftUI, ScreenCaptureKit, IOKit private `IOAVService*`, CoreDisplay private `CoreDisplay_DisplayCreateInfoDictionary`, DisplayServices private framework.

**Spec:** `docs/superpowers/specs/2026-10-22-external-displays-design.md`. Read it before starting any task. It explains *why* each DDC rule exists, and the plan's code depends on those reasons.

## Global Constraints

- macOS 15.0 deployment target; `swift-tools-version: 6.0`; no new package dependencies.
- DDC is Apple Silicon only; Intel, DisplayLink, AirPlay, Sidecar and mirrored sets are out of scope.
- `Controller`, `LuminanceAnalyzer`, `Letterbox`, `BrightnessRamp` must not change. `Coordinator`'s only change is reading `brightness.externalChangeThreshold`.
- DisplayServices displays keep `RampingBrightness(stepCount: 20, stepInterval: 1/60)`; DDC displays get **no** `RampingBrightness` (the engine glides).
- DDC timing (`DDCEngine.Timing.standard`): spacing 0.05 s, settleWindow 0.3 s, refreshInterval 1.0 s — replaced by Task 1's measured values if they differ.
- DDC limits: glide in ≤ 4 sends; 5 consecutive failures → not responding; 3 unapplied reads → unwritable; failed read retried ≥ 0.25 s later; termination flush deadline 0.5 s shared.
- Not-adjustable reasons, exact copy: `"Checking…"`, `"No DDC connection"`, `"Can't tell which connection is this display"`, `"Didn't respond to DDC"`, `"Doesn't accept brightness changes"`, `"DDC isn't available on this Mac"`, `"Brightness can't be changed"`.
- Other UI copy: `"Not responding"`, `"No adjustable displays"`, `"This display isn't available for capture."`.
- Re-probe backoff for "Didn't respond to DDC": 5 s, 10 s, 20 s, then every 60 s, plus on wake.
- Comments follow the repo's style: explain *why*, in full sentences, at the density of the surrounding code.
- Commit messages: conventional prefix (`feat:`, `fix:`, `test:`, `build:`, `docs:`), ending with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **Several button presses between two reads** (49 then 47). Expected: one observation, and the full 3 steps followed. Pinned in Task 5 (`rapidPressesAccumulate`) and Task 6 (`observationsAccumulate`).
2. **The monitor is switched off with its own power button mid-session, then back on.** Expected: adjustment stops, and on return the monitor goes back to the user's baseline, not to a level carrying a stale offset. Pinned in Task 7 (`dropoutKeepsBaseline`).
3. **Quitting during a DDC glide.** Expected: the final target is written once, immediately. Pinned in Task 5 (`flushSendsFinalTarget`).
4. **A monitor whose brightness maximum isn't 100** (some report 255 or 50). Expected: levels scale by the reported maximum, and the threshold is half of one of its steps. Pinned in Task 5 (`nonHundredMaximumScales`) and Task 6 (`thresholdIsHalfAStep`).
5. **Two identical monitors on a dock** (EDID serial 0 on both). Expected: each display matches its own service by framebuffer node, never by serial. Pinned in Task 4 (`twoMonitorsMatchByNode`).

---

### Task 1: Measure DDC writes on the real monitor (gate)

Nothing has written to the monitor over DDC yet. This task measures write latency and spacing, and **stops the plan if writes don't apply**.

**Files:**
- Create: `Sources/DDCProbe/main.swift`
- Modify: `Package.swift` (add executable target)
- Modify: `docs/superpowers/specs/2026-10-22-external-displays-design.md` ("Measured facts" section)

**Interfaces:**
- Consumes: nothing.
- Produces: measured `spacing` and `settleWindow` values for Task 5's `DDCEngine.Timing.standard`.

- [ ] **Step 1: Add the target to `Package.swift`**

Add after the `ALSProbe` target:

```swift
        // Standalone for the same reason as ALSProbe: it measures the hardware
        // the app is built on, so it must not depend on that app.
        .executableTarget(name: "DDCProbe"),
```

- [ ] **Step 2: Write the probe**

`Sources/DDCProbe/main.swift`:

```swift
// Measures how the first external monitor handles DDC brightness writes: how
// long a write takes to show up in read-back, and how closely two writes may
// follow each other. It changes the monitor's brightness while it runs and
// puts the original level back at the end.
import Foundation
import IOKit

typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
      let createSymbol = dlsym(iokit, "IOAVServiceCreateWithService"),
      let writeSymbol = dlsym(iokit, "IOAVServiceWriteI2C"),
      let readSymbol = dlsym(iokit, "IOAVServiceReadI2C") else {
    print("FAIL: IOAVService symbols are missing on this macOS")
    exit(1)
}
let create = unsafeBitCast(createSymbol, to: Create.self)
let writeI2C = unsafeBitCast(writeSymbol, to: Transfer.self)
let readI2C = unsafeBitCast(readSymbol, to: Transfer.self)

func firstExternalService() -> CFTypeRef? {
    var iterator: io_iterator_t = 0
    guard IOServiceGetMatchingServices(
        kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
    ) == KERN_SUCCESS else { return nil }
    defer { IOObjectRelease(iterator) }
    var service = IOIteratorNext(iterator)
    while service != 0 {
        defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
        let location = IORegistryEntryCreateCFProperty(
            service, "Location" as CFString, kCFAllocatorDefault, 0
        )?.takeRetainedValue() as? String
        if location == "External", let handle = create(kCFAllocatorDefault, service)?.takeRetainedValue() {
            return handle
        }
    }
    return nil
}

guard let monitor = firstExternalService() else {
    print("FAIL: no external DDC service found")
    exit(1)
}

func sealed(_ body: [UInt8]) -> [UInt8] { body + [body.reduce(0x6E ^ 0x51, ^)] }

func readLevel() -> Int? {
    var request = sealed([0x82, 0x01, 0x10])
    guard writeI2C(monitor, 0x37, 0x51, &request, UInt32(request.count)) == kIOReturnSuccess else { return nil }
    usleep(50_000)
    var reply = [UInt8](repeating: 0, count: 12)
    guard readI2C(monitor, 0x37, 0x51, &reply, UInt32(reply.count)) == kIOReturnSuccess,
          reply[2] == 0x02, reply[3] == 0x00, reply[4] == 0x10,
          reply[0..<10].reduce(UInt8(0x50), ^) == reply[10] else { return nil }
    return Int(reply[8]) << 8 | Int(reply[9])
}

func writeLevel(_ value: Int) -> Bool {
    var packet = sealed([0x84, 0x03, 0x10, UInt8(value >> 8), UInt8(value & 0xFF)])
    return writeI2C(monitor, 0x37, 0x51, &packet, UInt32(packet.count)) == kIOReturnSuccess
}

func uptime() -> Double { ProcessInfo.processInfo.systemUptime }

guard let original = readLevel() else {
    print("FAIL: could not read the current brightness")
    exit(1)
}
print("original level: \(original)")

// 1. How long until a write shows up in read-back.
var worstDelay = 0.0
var failures = 0
for target in [20, 80, 35, 65, 50, 10, 90, 40, 60, 45] {
    let start = uptime()
    guard writeLevel(target) else {
        print("write \(target): NOT acknowledged")
        failures += 1
        continue
    }
    var seenAfter: Double?
    while uptime() - start < 1.0 {
        if readLevel() == target {
            seenAfter = uptime() - start
            break
        }
    }
    if let seenAfter {
        worstDelay = max(worstDelay, seenAfter)
        print(String(format: "write %3d: read back after %4.0f ms", target, seenAfter * 1000))
    } else {
        print("write \(target): never read back within 1 s")
        failures += 1
    }
    usleep(200_000)
}

// 2. How closely a second write may follow the first and still be honoured.
var minimumGap: Int?
for gap in [0, 10, 20, 30, 50, 80] {
    _ = writeLevel(30)
    usleep(useconds_t(gap * 1000))
    _ = writeLevel(70)
    usleep(500_000)
    let level = readLevel()
    let honoured = level == 70
    if honoured && minimumGap == nil { minimumGap = gap }
    if !honoured { minimumGap = nil }
    print("gap \(gap) ms: second write \(honoured ? "honoured" : "LOST (read \(level.map(String.init) ?? "nil"))")")
    usleep(200_000)
}

_ = writeLevel(original)
print("restored level \(original)")

if failures == 0, worstDelay <= 0.5 {
    let settle = Int((worstDelay * 1000).rounded(.up)) + 100
    let spacing = max(minimumGap ?? 80, 50)
    print("PASS: settleWindow = \(settle) ms, spacing = \(spacing) ms")
} else {
    print("FAIL: \(failures) writes did not apply; worst delay \(Int(worstDelay * 1000)) ms")
}
```

- [ ] **Step 3: Build**

Run: `swift build --product DDCProbe`
Expected: `Build complete!` (warnings are acceptable, errors are not).

- [ ] **Step 4: Run it on the monitor**

Tell the user first: "The external monitor's brightness will jump around for about 15 seconds." Then run:

Run: `swift run DDCProbe`
Expected: a list of writes with read-back delays, a list of gaps, `restored level N`, and a final `PASS:` or `FAIL:` line.

- [ ] **Step 5: Decide**

- `FAIL:` → **stop the plan.** Report the full output to the user. The monitor does not apply DDC writes over this connection, and nothing after this task can work on it.
- `PASS:` → note the two values. If `settleWindow` differs from 300 or `spacing` from 50, use the measured values in Task 5 Step 3's `Timing.standard`.

- [ ] **Step 6: Record the measurement in the spec**

In `docs/superpowers/specs/2026-10-22-external-displays-design.md`, replace the paragraph starting `No DDC *write* has been made yet.` with:

```markdown
DDC writes, measured with `swift run DDCProbe` on 2026-10-22: every write was
acknowledged; read-back matched after at most <worst> ms; a second write
<minimum gap> ms after the first was honoured. `Timing.standard` uses
settleWindow <settle> ms and spacing <spacing> ms.
```

Fill each `<…>` with the numbers from Step 4.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/DDCProbe/main.swift docs/superpowers/specs/2026-10-22-external-displays-design.md
git commit -m "build: add DDCProbe to measure DDC write behaviour on a real monitor

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: Backend-supplied external-change threshold

**Files:**
- Modify: `Sources/AutoBrightnessCore/BrightnessControlling.swift`
- Modify: `Sources/AutoBrightnessCore/Coordinator.swift:237`
- Modify: `Sources/AutoBrightnessCore/RampingBrightness.swift`
- Create: `Tests/AutoBrightnessCoreTests/ExternalChangeThresholdTests.swift`

**Interfaces:**
- Produces: `BrightnessControlling.externalChangeThreshold: Double` (protocol requirement, default `Coordinator.externalChangeThreshold` = 0.01). Task 6's `DDCBrightness` overrides it.

- [ ] **Step 1: Write the failing test**

`Tests/AutoBrightnessCoreTests/ExternalChangeThresholdTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

/// An actuator that can only show coarse steps, so it asks the coordinator to
/// notice smaller movements than the built-in panel needs to.
private final class CoarseBrightness: BrightnessControlling {
    var value: Double
    let canControl = true
    let externalChangeThreshold = 0.005
    init(value: Double) { self.value = value }
    func read() -> Double? { value }
    func write(_ newValue: Double) { value = newValue }
}

@Test("The default threshold is the coordinator's 0.01")
func defaultThresholdUnchanged() {
    #expect(FakeBrightness().externalChangeThreshold == Coordinator.externalChangeThreshold)
}

@Test("RampingBrightness forwards the wrapped threshold")
func rampingForwardsThreshold() {
    let ramping = RampingBrightness(
        wrapping: CoarseBrightness(value: 0.5),
        scheduler: ManualRampScheduler()
    )
    #expect(ramping.externalChangeThreshold == 0.005)
}

@Test("A move between the backend's threshold and 0.01 is followed")
func backendThresholdIsUsed() {
    // Settle on a white page first, so there is a write of ours to measure
    // movement against: before the first write, any level is simply adopted.
    let coarse = CoarseBrightness(value: 0.50)
    let coordinator = Coordinator(brightness: coarse)
    for _ in 0..<20 { coordinator.tick(luminance: 0.95) }
    #expect(abs(coarse.value - 0.30) < 1e-9)
    coarse.value -= 0.007   // under 0.01, over 0.005
    coordinator.tick(luminance: 0.95)
    #expect(abs(coordinator.baseline - 0.493) < 1e-9)
}

@Test("The same move is ignored under the default threshold")
func defaultThresholdIgnoresSmallMove() {
    let fake = FakeBrightness(value: 0.50)
    let coordinator = Coordinator(brightness: fake)
    for _ in 0..<20 { coordinator.tick(luminance: 0.95) }
    fake.externalChange(to: (fake.read() ?? 0) - 0.007)
    coordinator.tick(luminance: 0.95)
    #expect(abs(coordinator.baseline - 0.50) < 1e-9)
}
```

- [ ] **Step 2: Run it to verify it fails**

Run: `swift test --filter ExternalChangeThresholdTests`
Expected: compile error, `value of type 'FakeBrightness' has no member 'externalChangeThreshold'`.

- [ ] **Step 3: Add the requirement**

In `Sources/AutoBrightnessCore/BrightnessControlling.swift`, add inside `protocol BrightnessControlling` after `var canControl: Bool { get }`:

```swift
    /// The smallest unexplained movement the coordinator treats as someone
    /// else moving the display. The built-in panel reads back exactly, so the
    /// default sits well above noise; a DDC monitor only holds whole steps and
    /// asks for half of one, so that a single button press is never lost.
    var externalChangeThreshold: Double { get }
```

and after the protocol's closing brace:

```swift
public extension BrightnessControlling {
    var externalChangeThreshold: Double { Coordinator.externalChangeThreshold }
}
```

- [ ] **Step 4: Use it in the coordinator**

In `Sources/AutoBrightnessCore/Coordinator.swift` line 237, replace

```swift
                if abs(externalMovement) > Self.externalChangeThreshold {
```

with

```swift
                if abs(externalMovement) > brightness.externalChangeThreshold {
```

and in the doc comment of `static let externalChangeThreshold` (lines 9-11), append one sentence:

```swift
    /// This is the default; a backend whose read-back is coarser supplies its
    /// own through `BrightnessControlling.externalChangeThreshold`.
```

- [ ] **Step 5: Forward it through the ramp**

In `Sources/AutoBrightnessCore/RampingBrightness.swift`, after `public var canControl: Bool { wrapped.canControl }` add:

```swift
    public var externalChangeThreshold: Double { wrapped.externalChangeThreshold }
```

- [ ] **Step 6: Run the whole suite**

Run: `swift test`
Expected: all tests pass, including the four new ones and every existing `CoordinatorTests` test.

- [ ] **Step 7: Commit**

```bash
git add Sources/AutoBrightnessCore Tests/AutoBrightnessCoreTests/ExternalChangeThresholdTests.swift
git commit -m "feat: let the brightness backend set the external-change threshold

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: DDC packets

**Files:**
- Create: `Sources/AutoBrightnessCore/DDC/DDCTypes.swift`
- Create: `Sources/AutoBrightnessCore/DDC/DDCPacket.swift`
- Create: `Tests/AutoBrightnessCoreTests/DDCPacketTests.swift`

**Interfaces:**
- Produces:
  - `public struct DDCReading: Equatable, Sendable { public var current: Int; public var maximum: Int; public init(current: Int, maximum: Int) }`
  - `public protocol DDCTransport: AnyObject { func readBrightness() -> DDCReading?; func writeBrightness(_ value: Int) -> Bool }`
  - `public enum DDCEvent: Equatable, Sendable { case observed(level: Int, expected: Int, maximum: Int, count: Int); case responding(Bool); case unwritable }`
  - `public protocol DDCLink: AnyObject { var onEvent: ((DDCEvent) -> Void)? { get set }; func submit(level: Double, seenObservations: Int); func startFlush(); func waitForFlush(deadline: DispatchTime); func invalidate() }`
  - `DDCPacket.chipAddress: UInt32`, `.dataAddress: UInt32`, `.replyLength: Int`, `.brightnessRequest() -> [UInt8]`, `.brightnessWrite(_ value: Int) -> [UInt8]`, `.parseBrightnessReply(_ reply: [UInt8]) -> DDCReading?`

- [ ] **Step 1: Write the shared types**

`Sources/AutoBrightnessCore/DDC/DDCTypes.swift`:

```swift
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
```

- [ ] **Step 2: Write the failing packet tests**

`Tests/AutoBrightnessCoreTests/DDCPacketTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

/// The reply a Lenovo P24h-30 actually sent to "get brightness", recorded
/// while designing this: current 100, maximum 100.
private let recordedReply: [UInt8] = [0x6E, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x64, 0xA4, 0x00]

@Test("The brightness request carries its checksum")
func requestBytes() {
    #expect(DDCPacket.brightnessRequest() == [0x82, 0x01, 0x10, 0xAC])
}

@Test("A brightness write encodes the value big-endian with its checksum")
func writeBytes() {
    #expect(DDCPacket.brightnessWrite(70) == [0x84, 0x03, 0x10, 0x00, 0x46, 0xEE])
}

@Test("The recorded reply parses")
func parsesRecordedReply() {
    #expect(DDCPacket.parseBrightnessReply(recordedReply) == DDCReading(current: 100, maximum: 100))
}

@Test("A reply with a bad checksum is rejected")
func rejectsBadChecksum() {
    var reply = recordedReply
    reply[10] ^= 0x01
    #expect(DDCPacket.parseBrightnessReply(reply) == nil)
}

@Test("A reply reporting an unsupported code is rejected")
func rejectsErrorResult() {
    var reply = recordedReply
    reply[3] = 0x01
    reply[10] = reply[0..<10].reduce(UInt8(0x50), ^)
    #expect(DDCPacket.parseBrightnessReply(reply) == nil)
}

@Test("A reply for a different VCP code is rejected")
func rejectsOtherCode() {
    var reply = recordedReply
    reply[4] = 0x12
    reply[10] = reply[0..<10].reduce(UInt8(0x50), ^)
    #expect(DDCPacket.parseBrightnessReply(reply) == nil)
}

@Test("A short reply is rejected")
func rejectsShortReply() {
    #expect(DDCPacket.parseBrightnessReply(Array(recordedReply.prefix(8))) == nil)
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter DDCPacketTests`
Expected: compile error, `cannot find 'DDCPacket' in scope`.

- [ ] **Step 4: Implement the packets**

`Sources/AutoBrightnessCore/DDC/DDCPacket.swift`:

```swift
/// DDC/CI framing for the one feature this app uses, VCP 0x10 (brightness).
///
/// Pure byte work, kept apart from the IOKit transport so it can be checked
/// against a reply recorded from real hardware.
public enum DDCPacket {
    /// The monitor's DDC/CI I²C address.
    public static let chipAddress: UInt32 = 0x37
    /// The host's sub-address every DDC/CI message is sent to.
    public static let dataAddress: UInt32 = 0x51
    /// Bytes to read for a "get VCP" reply. Eleven carry meaning; reading one
    /// more is what the transport was first proven with.
    public static let replyLength = 12

    private static let brightnessCode: UInt8 = 0x10

    /// "Get VCP feature 0x10".
    public static func brightnessRequest() -> [UInt8] {
        sealed([0x82, 0x01, brightnessCode])
    }

    /// "Set VCP feature 0x10 to `value`".
    public static func brightnessWrite(_ value: Int) -> [UInt8] {
        let clamped = UInt16(clamping: value)
        return sealed([0x84, 0x03, brightnessCode, UInt8(clamped >> 8), UInt8(clamped & 0xFF)])
    }

    /// Current and maximum from a "get VCP" reply, or nil for anything that is
    /// not a well-formed, successful brightness reply.
    public static func parseBrightnessReply(_ reply: [UInt8]) -> DDCReading? {
        guard reply.count >= 11,
              reply[2] == 0x02,              // "VCP feature reply"
              reply[3] == 0x00,              // result: no error
              reply[4] == brightnessCode,
              reply[0..<10].reduce(UInt8(0x50), ^) == reply[10] else { return nil }
        let maximum = Int(reply[6]) << 8 | Int(reply[7])
        let current = Int(reply[8]) << 8 | Int(reply[9])
        return DDCReading(current: current, maximum: maximum)
    }

    /// Appends the host-to-display checksum: the XOR of the destination
    /// address (0x6E), the source address (0x51) and every body byte.
    private static func sealed(_ body: [UInt8]) -> [UInt8] {
        body + [body.reduce(UInt8(0x6E ^ 0x51), ^)]
    }
}
```

- [ ] **Step 5: Run them to verify they pass**

Run: `swift test --filter DDCPacketTests`
Expected: 7 tests pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/AutoBrightnessCore/DDC Tests/AutoBrightnessCoreTests/DDCPacketTests.swift
git commit -m "feat: DDC/CI brightness packets and the types the DDC backend shares

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Matching a display to its IOAVService

**Files:**
- Create: `Sources/AutoBrightnessCore/DDC/AVServiceMatcher.swift`
- Create: `Tests/AutoBrightnessCoreTests/AVServiceMatcherTests.swift`

**Interfaces:**
- Produces:
  - `public enum AVServiceMatch: Equatable, Sendable { case matched(serviceIndex: Int); case noService; case ambiguous }`
  - `AVServiceMatcher.framebufferNode(displayLocation: String) -> String?`
  - `AVServiceMatcher.framebufferNodes(servicePath: String) -> Set<String>`
  - `AVServiceMatcher.match(displayLocations: [UInt32: String], servicePaths: [String]) -> [UInt32: AVServiceMatch]`. Keys are `CGDirectDisplayID`s; every key of `displayLocations` gets an entry.

- [ ] **Step 1: Write the failing tests**

`Tests/AutoBrightnessCoreTests/AVServiceMatcherTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

// Recorded on the development machine (M2, P24h-30).
private let realLocation =
    "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dispext0@70000000/AppleCLCD2"
private let realServicePath =
    "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dcpext@71C00000/AppleASCWrapV4/iop-dcpext-nub/RTBuddy(DCPEXT)/DCPEXTEndpoint9/AFKDCPEXTEndpoint9/AFKEPInterfaceServiceKextV2/dispext0:dcpav-service-epic:0/DCPAVServiceProxy"

private func servicePath(node: String) -> String {
    "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/dcpext@71C00000/AFKEPInterfaceServiceKextV2/\(node):dcpav-service-epic:0/DCPAVServiceProxy"
}

private func location(node: String) -> String {
    "IOService:/AppleARMPE/arm-io@10F00000/AppleT811xIO/\(node)@70000000/AppleCLCD2"
}

@Test("The framebuffer node comes from the component before the last")
func nodeFromLocation() {
    #expect(AVServiceMatcher.framebufferNode(displayLocation: realLocation) == "dispext0")
    #expect(AVServiceMatcher.framebufferNode(displayLocation: "") == nil)
    #expect(AVServiceMatcher.framebufferNode(displayLocation: "IOService:/@1/AppleCLCD2") == nil)
}

@Test("Service paths yield the nodes of their dcpav-service components")
func nodesFromServicePath() {
    #expect(AVServiceMatcher.framebufferNodes(servicePath: realServicePath) == ["dispext0"])
    #expect(AVServiceMatcher.framebufferNodes(servicePath: "IOService:/dcpext@71C00000/Foo").isEmpty)
}

@Test("The real display matches the real service")
func realPathsMatch() {
    let result = AVServiceMatcher.match(displayLocations: [2: realLocation], servicePaths: [realServicePath])
    #expect(result == [2: .matched(serviceIndex: 0)])
}

@Test("Two identical monitors each match their own service by node")
func twoMonitorsMatchByNode() {
    let result = AVServiceMatcher.match(
        displayLocations: [5: location(node: "dispext0"), 6: location(node: "dispext1")],
        servicePaths: [servicePath(node: "dispext1"), servicePath(node: "dispext0")]
    )
    #expect(result == [5: .matched(serviceIndex: 1), 6: .matched(serviceIndex: 0)])
}

@Test("A display with no service carrying its node has no DDC connection")
func noServiceForNode() {
    let result = AVServiceMatcher.match(
        displayLocations: [7: location(node: "dispext2")],
        servicePaths: [servicePath(node: "dispext0")]
    )
    #expect(result == [7: .noService])
}

@Test("Two services claiming one node make that display ambiguous")
func duplicateServicesAreAmbiguous() {
    let result = AVServiceMatcher.match(
        displayLocations: [8: location(node: "dispext0")],
        servicePaths: [servicePath(node: "dispext0"), servicePath(node: "dispext0")]
    )
    #expect(result == [8: .ambiguous])
}

@Test("Two displays claiming one node are both ambiguous")
func crossClaimedNodeIsAmbiguous() {
    let result = AVServiceMatcher.match(
        displayLocations: [9: location(node: "dispext0"), 10: location(node: "dispext0")],
        servicePaths: [servicePath(node: "dispext0")]
    )
    #expect(result == [9: .ambiguous, 10: .ambiguous])
}

@Test("An unparseable location has no DDC connection")
func garbageLocation() {
    let result = AVServiceMatcher.match(displayLocations: [11: ""], servicePaths: [realServicePath])
    #expect(result == [11: .noService])
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter AVServiceMatcherTests`
Expected: compile error, `cannot find 'AVServiceMatcher' in scope`.

- [ ] **Step 3: Implement the matcher**

`Sources/AutoBrightnessCore/DDC/AVServiceMatcher.swift`:

```swift
/// The outcome of looking for a display's DDC connection.
public enum AVServiceMatch: Equatable, Sendable {
    case matched(serviceIndex: Int)
    case noService
    /// More than one candidate, either way round. Driving a guess could take
    /// the content of one monitor and set the brightness of another.
    case ambiguous
}

/// Pairs displays with their `DCPAVServiceProxy` by framebuffer node name.
///
/// The display's `IODisplayLocation` ends `…/dispext0@70000000/AppleCLCD2`,
/// and its DDC service lives under a component `dispext0:dcpav-service-…`.
/// The node name is what links them. EDID serials cannot do it: the monitor
/// this was designed on reports serial 0, as do many others, so two identical
/// monitors would be indistinguishable.
///
/// Pure string work, with no regular expressions, so it can be tested on
/// recorded paths without the hardware.
public enum AVServiceMatcher {
    /// `…/dispext0@70000000/AppleCLCD2` → `dispext0`. The last component is
    /// not inspected; `AppleCLCD2` is what one machine shows, not a promise.
    public static func framebufferNode(displayLocation: String) -> String? {
        let components = displayLocation.split(separator: "/")
        guard components.count >= 2 else { return nil }
        let parent = components[components.count - 2]
        let node = parent.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)[0]
        return node.isEmpty ? nil : String(node)
    }

    /// The node names of every `<node>:…dcpav-service…` component in a
    /// service-plane path.
    public static func framebufferNodes(servicePath: String) -> Set<String> {
        Set(servicePath.split(separator: "/").compactMap { component -> String? in
            guard component.contains("dcpav-service") else { return nil }
            let parts = component.split(separator: ":", maxSplits: 1)
            return parts.count == 2 && !parts[0].isEmpty ? String(parts[0]) : nil
        })
    }

    /// A result for every display in `displayLocations`.
    public static func match(
        displayLocations: [UInt32: String],
        servicePaths: [String]
    ) -> [UInt32: AVServiceMatch] {
        let serviceNodes = servicePaths.map { framebufferNodes(servicePath: $0) }
        let displayNodes = displayLocations.mapValues { framebufferNode(displayLocation: $0) }
        var result: [UInt32: AVServiceMatch] = [:]
        for (display, node) in displayNodes {
            guard let node else {
                result[display] = .noService
                continue
            }
            let sharers = displayNodes.values.filter { $0 == node }.count
            let candidates = serviceNodes.indices.filter { serviceNodes[$0].contains(node) }
            switch (candidates.count, sharers) {
            case (0, _): result[display] = .noService
            case (1, 1): result[display] = .matched(serviceIndex: candidates[0])
            default: result[display] = .ambiguous
            }
        }
        return result
    }
}
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter AVServiceMatcherTests`
Expected: 8 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessCore/DDC/AVServiceMatcher.swift Tests/AutoBrightnessCoreTests/AVServiceMatcherTests.swift
git commit -m "feat: match displays to their DDC service by framebuffer node

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: DDCEngine

**Files:**
- Create: `Sources/AutoBrightnessCore/DDC/DDCEngine.swift`
- Create: `Tests/AutoBrightnessCoreTests/DDCTestDoubles.swift`
- Create: `Tests/AutoBrightnessCoreTests/DDCEngineTests.swift`

**Interfaces:**
- Consumes: `DDCTransport`, `DDCReading`, `DDCEvent` (Task 3).
- Produces:
  - `DDCEngine(transport: DDCTransport, seed: DDCReading, timing: DDCEngine.Timing = .standard, now: Double)`
  - `DDCEngine.Timing` (`spacing`, `settleWindow`, `refreshInterval`, `.standard`), `DDCEngine.Action` (`.send`, `.read`, `.wait(until: Double)`)
  - `submit(level: Double, seenObservations: Int)`, `nextAction(now: Double) -> Action`, `performSend(now: Double) -> [DDCEvent]`, `performRead(now: Double) -> [DDCEvent]`, `performFlush(now: Double)`, `replaceTransport(_ transport: DDCTransport)`
  - read-only state: `timing`, `maximum`, `lastKnown`, `target`, `observations`, `lastSendAt`, `isResponding`, `isUnwritable`
  - `static func integer(_ level: Double, maximum: Int) -> Int`
  - Test doubles used by Tasks 6–7: `FakeMonitor`, `VirtualDDCLink`, `EventLog`

- [ ] **Step 1: Write the test doubles**

`Tests/AutoBrightnessCoreTests/DDCTestDoubles.swift`:

```swift
import Foundation
@testable import AutoBrightnessCore

/// A monitor at the other end of a DDC cable.
final class FakeMonitor: DDCTransport {
    var level: Int
    var maximum: Int
    /// Every call fails, as for a monitor in standby or unplugged.
    var isOff = false
    /// Acknowledges writes and ignores them.
    var ignoresWrites = false
    /// The next this-many writes fail.
    var failingWrites = 0
    private(set) var writes: [Int] = []

    init(level: Int = 50, maximum: Int = 100) {
        self.level = level
        self.maximum = maximum
    }

    func readBrightness() -> DDCReading? {
        isOff ? nil : DDCReading(current: level, maximum: maximum)
    }

    func writeBrightness(_ value: Int) -> Bool {
        guard !isOff else { return false }
        if failingWrites > 0 {
            failingWrites -= 1
            return false
        }
        writes.append(value)
        if !ignoresWrites { level = value }
        return true
    }

    /// Someone pressing the monitor's own brightness buttons.
    func press(to newLevel: Int) { level = newLevel }
}

/// Runs a real `DDCEngine` inline in virtual time, the way `DDCQueueLink`
/// runs it on its queue in real time.
final class VirtualDDCLink: DDCLink {
    let engine: DDCEngine
    private(set) var now: Double = 0
    var onEvent: ((DDCEvent) -> Void)?
    /// When true, events wait in `heldEvents` until `deliver()`, standing in
    /// for the hop to the main thread arriving late.
    var holdsEvents = false
    private(set) var heldEvents: [DDCEvent] = []
    private(set) var log: [(time: Double, action: String)] = []
    /// How long a read occupies the bus: request, the 50 ms wait, the reply.
    static let readCost = 0.07

    init(monitor: FakeMonitor, timing: DDCEngine.Timing = .standard) {
        engine = DDCEngine(
            transport: monitor,
            seed: DDCReading(current: monitor.level, maximum: monitor.maximum),
            timing: timing,
            now: 0
        )
    }

    func submit(level: Double, seenObservations: Int) {
        engine.submit(level: level, seenObservations: seenObservations)
    }

    func startFlush() { engine.performFlush(now: now) }
    func waitForFlush(deadline: DispatchTime) {}
    func invalidate() { onEvent = nil }

    /// Moves virtual time forward by `seconds`, doing whatever the engine asks
    /// for on the way.
    func advance(by seconds: Double) {
        let end = now + seconds
        while true {
            switch engine.nextAction(now: now) {
            case .send:
                log.append((now, "send"))
                emit(engine.performSend(now: now))
            case .read:
                log.append((now, "read"))
                emit(engine.performRead(now: now))
                now += Self.readCost
            case .wait(let until):
                guard until <= end else {
                    now = max(now, end)
                    return
                }
                now = max(now, until)
            }
        }
    }

    func deliver() {
        let events = heldEvents
        heldEvents = []
        events.forEach { onEvent?($0) }
    }

    private func emit(_ events: [DDCEvent]) {
        if holdsEvents {
            heldEvents += events
        } else {
            events.forEach { onEvent?($0) }
        }
    }
}

/// Collects what a link reports.
final class EventLog {
    var events: [DDCEvent] = []
    var observedCount: Int {
        events.filter { if case .observed = $0 { true } else { false } }.count
    }
}
```

- [ ] **Step 2: Write the failing engine tests**

`Tests/AutoBrightnessCoreTests/DDCEngineTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

private func makeLink(level: Int = 50, maximum: Int = 100) -> (FakeMonitor, VirtualDDCLink, EventLog) {
    let monitor = FakeMonitor(level: level, maximum: maximum)
    let link = VirtualDDCLink(monitor: monitor)
    let log = EventLog()
    link.onEvent = { log.events.append($0) }
    return (monitor, link, log)
}

@Test("A target the monitor already shows is not sent")
func equalTargetNotSent() {
    let (monitor, link, _) = makeLink()
    link.submit(level: 0.503, seenObservations: 0)   // rounds to 50
    link.advance(by: 2)
    #expect(monitor.writes.isEmpty)
}

@Test("A level established by a read is not sent again")
func levelFromReadNotResent() {
    let (monitor, link, log) = makeLink()
    monitor.press(to: 40)
    link.advance(by: 1.1)
    link.submit(level: 0.40, seenObservations: log.observedCount)
    link.advance(by: 1)
    #expect(monitor.writes.isEmpty)
}

@Test("A glide is checked by a read, then reaches its target in four spaced sends")
func glideInFourSends() {
    let (monitor, link, _) = makeLink()
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.writes == [53, 56, 59, 60])
    #expect(link.log.first?.action == "read")
    let sends = link.log.filter { $0.action == "send" }.map(\.time)
    for (a, b) in zip(sends, sends.dropFirst()) {
        #expect(b - a >= DDCEngine.Timing.standard.spacing - 1e-9)
    }
}

@Test("A newer target takes over mid-glide from where the monitor is")
func newerTargetMidGlide() {
    let (monitor, link, _) = makeLink()
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 0.13)
    #expect(monitor.writes == [53, 56])
    link.submit(level: 0.40, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.writes == [53, 56, 52, 48, 44, 40])
}

@Test("A failed send leaves the known level alone and is retried")
func failedSendRetried() {
    let (monitor, link, log) = makeLink()
    monitor.failingWrites = 1
    link.submit(level: 0.51, seenObservations: 0)
    link.advance(by: 0.1)
    #expect(link.engine.lastKnown == 50)
    link.advance(by: 1.5)
    #expect(monitor.level == 51)
    #expect(log.events.isEmpty)
}

@Test("Reads keep happening while writes keep coming, and only once sends have settled")
func quietBarrier() {
    let (_, link, log) = makeLink()
    for i in 0..<30 {
        link.submit(level: i.isMultiple(of: 2) ? 0.40 : 0.60, seenObservations: 0)
        link.advance(by: 0.1)
    }
    let timing = DDCEngine.Timing.standard
    let reads = link.log.filter { $0.action == "read" }.map(\.time)
    let sends = link.log.filter { $0.action == "send" }.map(\.time)
    #expect(reads.count >= 3)
    for read in reads {
        if let lastSend = sends.filter({ $0 < read }).max() {
            #expect(read - lastSend >= timing.settleWindow - 1e-9)
        }
    }
    let longestGap = timing.refreshInterval + timing.settleWindow + VirtualDDCLink.readCost + timing.spacing
    for (a, b) in zip(reads, reads.dropFirst()) {
        #expect(b - a <= longestGap + 1e-9)
    }
    #expect(log.events.isEmpty)
}

@Test("A press is observed, and a write computed before it was seen is dropped")
func staleSubmitIgnored() {
    let (monitor, link, log) = makeLink()
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 0.5)
    monitor.press(to: 45)
    link.advance(by: 0.6)
    #expect(log.events == [.observed(level: 45, expected: 60, maximum: 100, count: 1)])
    link.submit(level: 0.70, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.level == 45)
    link.submit(level: 0.70, seenObservations: 1)
    link.advance(by: 0.5)
    #expect(monitor.level == 70)
}

@Test("A press just before a write is seen by the glide's check and not overwritten")
func pressBeforeGlideSurvives() {
    let (monitor, link, log) = makeLink()
    monitor.press(to: 30)
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 1)
    #expect(monitor.writes.isEmpty)
    #expect(monitor.level == 30)
    #expect(log.events == [.observed(level: 30, expected: 50, maximum: 100, count: 1)])
}

@Test("Several presses between two reads are one observation of the total")
func rapidPressesAccumulate() {
    let (monitor, link, log) = makeLink()
    monitor.press(to: 49)
    monitor.press(to: 47)
    link.advance(by: 1.1)
    #expect(log.events == [.observed(level: 47, expected: 50, maximum: 100, count: 1)])
}

@Test("A monitor that goes away stops being written, and a restore queued meanwhile lands first on return")
func dropoutAndRecovery() {
    let (monitor, link, log) = makeLink()
    monitor.isOff = true
    link.advance(by: 5.5)
    #expect(log.events == [.responding(false)])
    link.submit(level: 0.70, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.writes.isEmpty)
    monitor.isOff = false
    monitor.press(to: 20)   // came back at a level of its own
    link.advance(by: 1)
    #expect(log.events == [.responding(false), .responding(true)])
    #expect(monitor.level == 70)
}

@Test("A monitor that acknowledges writes but never applies them is given up on")
func unwritableDetected() {
    let (monitor, link, log) = makeLink()
    monitor.ignoresWrites = true
    for i in 0..<3 {
        link.submit(level: i.isMultiple(of: 2) ? 0.60 : 0.40, seenObservations: log.observedCount)
        link.advance(by: 1.0)
    }
    #expect(log.events.last == .unwritable)
    #expect(link.engine.isUnwritable)
}

@Test("A maximum other than 100 scales the levels")
func nonHundredMaximumScales() {
    let (monitor, link, _) = makeLink(level: 128, maximum: 255)
    link.submit(level: 0.60, seenObservations: 0)
    link.advance(by: 0.5)
    #expect(monitor.level == 153)
}

@Test("A reply with maximum 0 counts as a failure")
func zeroMaximumIsFailure() {
    let (monitor, link, log) = makeLink()
    monitor.maximum = 0
    link.advance(by: 5.5)
    #expect(log.events == [.responding(false)])
}

@Test("Flush sends the final target in one write")
func flushSendsFinalTarget() {
    let (monitor, link, _) = makeLink()
    link.submit(level: 0.90, seenObservations: 0)
    link.startFlush()
    #expect(monitor.writes == [90])
}
```

- [ ] **Step 3: Run them to verify they fail**

Run: `swift test --filter DDCEngineTests`
Expected: compile error, `cannot find 'DDCEngine' in scope`.

- [ ] **Step 4: Implement the engine**

`Sources/AutoBrightnessCore/DDC/DDCEngine.swift`. If Task 1 measured other values, use them in `Timing.standard`:

```swift
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
        public static let standard = Timing(spacing: 0.05, settleWindow: 0.3, refreshInterval: 1.0)
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
```

- [ ] **Step 5: Run the tests**

Run: `swift test --filter DDCEngineTests`
Expected: 14 tests pass. If one fails, step through it with the timeline in the test's comments and the rules in the spec's "Reading" section. Fix the engine, not the test, unless the test contradicts the spec.

- [ ] **Step 6: Commit**

```bash
git add Sources/AutoBrightnessCore/DDC/DDCEngine.swift Tests/AutoBrightnessCoreTests/DDCTestDoubles.swift Tests/AutoBrightnessCoreTests/DDCEngineTests.swift
git commit -m "feat: DDC engine that glides, checks before writing, and yields to button presses

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 6: DDCBrightness

**Files:**
- Create: `Sources/AutoBrightnessCore/DDC/DDCBrightness.swift`
- Create: `Tests/AutoBrightnessCoreTests/DDCBrightnessTests.swift`

**Interfaces:**
- Consumes: `DDCLink`, `DDCEvent`, `DDCReading` (Task 3), `DDCEngine.integer` (Task 5), `BrightnessControlling.externalChangeThreshold` (Task 2).
- Produces: `public final class DDCBrightness: BrightnessControlling` with `init(link: DDCLink, seed: DDCReading)`, `isResponding: Bool`, `onControlChange: (() -> Void)?`, `startFlush()`, `waitForFlush(deadline: DispatchTime)`, `invalidate()`.

- [ ] **Step 1: Write the failing tests**

`Tests/AutoBrightnessCoreTests/DDCBrightnessTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

private func makeBrightness(level: Int = 50, maximum: Int = 100) -> (FakeMonitor, VirtualDDCLink, DDCBrightness) {
    let monitor = FakeMonitor(level: level, maximum: maximum)
    let link = VirtualDDCLink(monitor: monitor)
    let ddc = DDCBrightness(link: link, seed: DDCReading(current: level, maximum: maximum))
    return (monitor, link, ddc)
}

@Test("Before any write, read is the probe's level")
func readsSeedFirst() {
    let (_, _, ddc) = makeBrightness(level: 37)
    #expect(ddc.read() == 0.37)
}

@Test("Own writes read back exactly, rounding and all")
func ownWritesExact() {
    let (monitor, link, ddc) = makeBrightness()
    ddc.write(0.497)
    link.advance(by: 2)
    #expect(monitor.level == 50)
    #expect(ddc.read() == 0.497)
}

@Test("A one-step press after a request that rounded down reads as exactly one step")
func oneStepDownFromRoundedDown() {
    let (monitor, link, ddc) = makeBrightness()
    ddc.write(0.497)
    link.advance(by: 0.5)
    monitor.press(to: 49)
    link.advance(by: 1)
    #expect(abs((ddc.read() ?? 0) - 0.487) < 1e-12)
}

@Test("A one-step press after a request that rounded up reads as exactly one step")
func oneStepUpFromRoundedUp() {
    let (monitor, link, ddc) = makeBrightness()
    ddc.write(0.503)
    link.advance(by: 0.5)
    monitor.press(to: 51)
    link.advance(by: 1)
    #expect(abs((ddc.read() ?? 0) - 0.513) < 1e-12)
}

@Test("A press before any write is measured from the probe's level")
func pressBeforeWrite() {
    let (monitor, link, ddc) = makeBrightness()
    monitor.press(to: 52)
    link.advance(by: 1.1)
    #expect(abs((ddc.read() ?? 0) - 0.52) < 1e-12)
}

@Test("Observations add up until the next write")
func observationsAccumulate() {
    let (monitor, link, ddc) = makeBrightness()
    monitor.press(to: 49)
    link.advance(by: 1.1)
    monitor.press(to: 47)
    link.advance(by: 1.0)
    #expect(abs((ddc.read() ?? 0) - 0.47) < 1e-12)
}

@Test("The threshold is half a step of the monitor's own scale")
func thresholdIsHalfAStep() {
    #expect(makeBrightness().2.externalChangeThreshold == 0.005)
    #expect(makeBrightness(level: 128, maximum: 255).2.externalChangeThreshold == 0.5 / 255)
}

@Test("A dropout is reported but keeps control, so a restore can still be queued")
func dropoutKeepsControl() {
    let (monitor, link, ddc) = makeBrightness()
    var changes = 0
    ddc.onControlChange = { changes += 1 }
    monitor.isOff = true
    link.advance(by: 5.5)
    #expect(!ddc.isResponding)
    #expect(ddc.canControl)
    #expect(changes == 1)
}

@Test("A monitor that ignores writes loses control")
func unwritableLosesControl() {
    let (monitor, link, ddc) = makeBrightness()
    monitor.ignoresWrites = true
    for i in 0..<3 {
        ddc.write(i.isMultiple(of: 2) ? 0.60 : 0.40)
        link.advance(by: 1.0)
    }
    #expect(!ddc.canControl)
}

@Test("Invalidated, it stops reading, writing and calling back")
func invalidateStopsEverything() {
    let (monitor, link, ddc) = makeBrightness()
    var changes = 0
    ddc.onControlChange = { changes += 1 }
    ddc.invalidate()
    #expect(!ddc.canControl)
    #expect(ddc.read() == nil)
    ddc.write(0.9)
    monitor.isOff = true
    link.advance(by: 6)
    #expect(monitor.writes.isEmpty)
    #expect(changes == 0)
}
```

- [ ] **Step 2: Run them to verify they fail**

Run: `swift test --filter DDCBrightnessTests`
Expected: compile error, `cannot find 'DDCBrightness' in scope`.

- [ ] **Step 3: Implement it**

`Sources/AutoBrightnessCore/DDC/DDCBrightness.swift`:

```swift
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
```

- [ ] **Step 4: Run them to verify they pass**

Run: `swift test --filter DDCBrightnessTests`
Expected: 10 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessCore/DDC/DDCBrightness.swift Tests/AutoBrightnessCoreTests/DDCBrightnessTests.swift
git commit -m "feat: DDCBrightness reports own writes exactly and presses in whole steps

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 7: Coordinator over DDC, end to end in virtual time

This task adds no production code. It shows that the real `Coordinator` behaves correctly on top of Tasks 5–6. If a test fails, the fix goes in `DDCEngine` or `DDCBrightness`. `Coordinator` is out of bounds (Global Constraints).

**Files:**
- Create: `Tests/AutoBrightnessCoreTests/DDCCoordinatorTests.swift`

**Interfaces:**
- Consumes: `Coordinator`, `DDCBrightness`, `FakeMonitor`, `VirtualDDCLink`.

- [ ] **Step 1: Write the tests**

`Tests/AutoBrightnessCoreTests/DDCCoordinatorTests.swift`:

```swift
import Testing
@testable import AutoBrightnessCore

/// The composition the app runs for a DDC display, ticking at 2 Hz in
/// virtual time.
private final class Rig {
    let monitor: FakeMonitor
    let link: VirtualDDCLink
    let ddc: DDCBrightness
    let coordinator: Coordinator

    init(level: Int = 50, holdsEvents: Bool = false) {
        monitor = FakeMonitor(level: level)
        link = VirtualDDCLink(monitor: monitor)
        link.holdsEvents = holdsEvents
        ddc = DDCBrightness(link: link, seed: DDCReading(current: level, maximum: 100))
        coordinator = Coordinator(brightness: ddc)
        // What DisplayUnit does: stop adjusting while the monitor is away.
        ddc.onControlChange = { [unowned self] in
            if self.ddc.isResponding {
                if self.coordinator.isPaused { self.coordinator.resume() }
            } else {
                self.coordinator.suspend()
            }
        }
    }

    /// One tick, then whatever the main thread was sent, then half a second
    /// of bus time. With `holdsEvents`, events seen during a tick's half
    /// second only reach the coordinator after its next write.
    func run(_ ticks: Range<Int>, luminance: (Int) -> Double) {
        for i in ticks {
            coordinator.tick(luminance: luminance(i))
            link.deliver()
            link.advance(by: 0.5)
        }
    }
}

/// Content that keeps the coordinator writing: dark and light alternating
/// every 1.5 s.
private func busy(_ i: Int) -> Double { (i / 3).isMultiple(of: 2) ? 0.15 : 0.85 }

@Test("Steady content stops sending once settled")
func steadyContentGoesQuiet() {
    let rig = Rig()
    rig.run(0..<20) { _ in 0.9 }
    let sent = rig.monitor.writes.count
    rig.run(20..<40) { _ in 0.9 }
    #expect(sent > 0)
    #expect(rig.monitor.writes.count == sent)
}

@Test("In steady state, a one-step press is followed and kept")
func steadyOneStepFollowed() {
    let rig = Rig()
    rig.run(0..<20) { _ in 0.9 }
    let settled = rig.monitor.level
    rig.monitor.press(to: settled - 1)
    rig.run(20..<30) { _ in 0.9 }
    #expect(abs(rig.coordinator.baseline - 0.49) < 1e-9)
    #expect(rig.monitor.level == settled - 1)
}

@Test("During continuous writes, a one-step press moves the baseline by one step and is never overwritten")
func busyOneStepFollowed() {
    let control = Rig()
    let pressed = Rig()
    control.run(0..<12, luminance: busy)
    pressed.run(0..<12, luminance: busy)
    pressed.monitor.press(to: pressed.monitor.level - 1)
    control.run(12..<40, luminance: busy)
    pressed.run(12..<40, luminance: busy)
    #expect(abs((pressed.coordinator.baseline - control.coordinator.baseline) + 0.01) < 1e-9)
    #expect(abs(pressed.coordinator.appliedOffset - control.coordinator.appliedOffset) < 1e-9)
    #expect(pressed.monitor.level == control.monitor.level - 1)
}

@Test("During continuous writes, a five-step press re-teaches the neutral")
func busyFiveStepReneutralizes() {
    let rig = Rig()
    rig.run(0..<2) { _ in 0.9 }   // the offset is still slewing
    rig.monitor.press(to: rig.monitor.level - 5)
    rig.run(2..<20) { _ in 0.9 }
    #expect(abs(rig.coordinator.appliedOffset) < 1e-9)
    #expect(rig.coordinator.baseline <= 0.45 + 1e-9)
    #expect(abs(Double(rig.monitor.level) / 100 - rig.coordinator.baseline) <= 0.005 + 1e-9)
}

@Test("A press whose observation arrives after a write was already sent still wins")
func lateObservationStillWins() {
    let control = Rig(holdsEvents: true)
    let pressed = Rig(holdsEvents: true)
    control.run(0..<12, luminance: busy)
    pressed.run(0..<12, luminance: busy)
    pressed.monitor.press(to: pressed.monitor.level - 2)
    control.run(12..<40, luminance: busy)
    pressed.run(12..<40, luminance: busy)
    #expect(abs((pressed.coordinator.baseline - control.coordinator.baseline) + 0.02) < 1e-9)
    #expect(pressed.monitor.level == control.monitor.level - 2)
}

@Test("A monitor switched off and on comes back to the user's baseline, not the offset level")
func dropoutKeepsBaseline() {
    let rig = Rig()
    rig.run(0..<20) { _ in 0.9 }
    #expect(rig.monitor.level == 30)
    rig.monitor.isOff = true
    rig.run(20..<32) { _ in 0.9 }
    #expect(rig.coordinator.isPaused)
    rig.monitor.isOff = false
    rig.run(32..<52) { _ in 0.9 }
    #expect(abs(rig.coordinator.baseline - 0.5) < 1e-9)
    #expect(rig.monitor.level == 30)
}
```

- [ ] **Step 2: Run them**

Run: `swift test --filter DDCCoordinatorTests`
Expected: 6 tests pass. If any fails:
1. Print the timeline: add `print(rig.link.log, rig.monitor.writes, rig.coordinator.baseline)` temporarily.
2. Find which spec rule the run broke ("Reading", "read()", "Failure, recovery and writability").
3. Fix `DDCEngine` or `DDCBrightness`, re-run Tasks 5–6's tests too, and remove the prints.

- [ ] **Step 3: Run the whole suite**

Run: `swift test`
Expected: everything passes.

- [ ] **Step 4: Commit**

```bash
git add Tests/AutoBrightnessCoreTests/DDCCoordinatorTests.swift
git commit -m "test: pin the coordinator's behaviour over a DDC monitor end to end

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 8: The app's DDC adapters

**Files:**
- Create: `Sources/AutoBrightnessApp/DDC/IOAVServiceTransport.swift`
- Create: `Sources/AutoBrightnessApp/DDC/DDCQueueLink.swift`
- Create: `Sources/AutoBrightnessApp/DDC/DisplayRegistry.swift`

**Interfaces:**
- Consumes: `DDCTransport`, `DDCReading`, `DDCLink`, `DDCEvent`, `DDCPacket`, `DDCEngine`, `AVServiceMatcher`.
- Produces:
  - `final class IOAVServiceTransport: DDCTransport, @unchecked Sendable` — `init?(service: io_service_t)`, `static var isAvailable: Bool`
  - `final class DDCQueueLink: DDCLink, @unchecked Sendable` — `init(transport: IOAVServiceTransport, seed: DDCReading)`, `replaceTransport(_ transport: IOAVServiceTransport)`
  - `enum DisplayRegistry` — `enum DDCResolution { case transport(IOAVServiceTransport), noService, ambiguous, unavailable }`, `static func ddcResolutions(for displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCResolution]`, `@MainActor static func name(of id: CGDirectDisplayID) -> String`, `static func activeDisplayIDs() -> [CGDirectDisplayID]`

- [ ] **Step 1: Write the transport**

`Sources/AutoBrightnessApp/DDC/IOAVServiceTransport.swift`:

```swift
import AutoBrightnessCore
import Foundation
import IOKit

/// DDC/CI over Apple Silicon's `IOAVService`, a private IOKit API.
///
/// Resolved at runtime rather than linked, like the DisplayServices symbols, so
/// a macOS that removes it leaves DDC unavailable instead of failing to launch.
/// Both calls block on the bus for tens of milliseconds and are only made from
/// the DDC queue or the off-main probe.
final class IOAVServiceTransport: DDCTransport, @unchecked Sendable {
    private typealias Create = @convention(c) (CFAllocator?, io_service_t) -> Unmanaged<CFTypeRef>?
    private typealias Transfer = @convention(c) (CFTypeRef, UInt32, UInt32, UnsafeMutableRawPointer, UInt32) -> IOReturn

    private struct Symbols {
        let create: Create
        let write: Transfer
        let read: Transfer
    }

    nonisolated(unsafe) private static let symbols: Symbols? = {
        guard let iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY),
              let create = dlsym(iokit, "IOAVServiceCreateWithService"),
              let write = dlsym(iokit, "IOAVServiceWriteI2C"),
              let read = dlsym(iokit, "IOAVServiceReadI2C") else { return nil }
        return Symbols(
            create: unsafeBitCast(create, to: Create.self),
            write: unsafeBitCast(write, to: Transfer.self),
            read: unsafeBitCast(read, to: Transfer.self)
        )
    }()

    static var isAvailable: Bool { symbols != nil }

    /// DDC/CI asks for this long between a request and reading its reply.
    private static let replyDelay: useconds_t = 50_000

    private let symbols: Symbols
    private let service: io_service_t
    private let handle: CFTypeRef

    init?(service: io_service_t) {
        guard let symbols = Self.symbols,
              let handle = symbols.create(kCFAllocatorDefault, service)?.takeRetainedValue() else {
            return nil
        }
        IOObjectRetain(service)
        self.symbols = symbols
        self.service = service
        self.handle = handle
    }

    deinit {
        IOObjectRelease(service)
    }

    func readBrightness() -> DDCReading? {
        var request = DDCPacket.brightnessRequest()
        guard symbols.write(
            handle, DDCPacket.chipAddress, DDCPacket.dataAddress, &request, UInt32(request.count)
        ) == kIOReturnSuccess else { return nil }
        usleep(Self.replyDelay)
        var reply = [UInt8](repeating: 0, count: DDCPacket.replyLength)
        guard symbols.read(
            handle, DDCPacket.chipAddress, DDCPacket.dataAddress, &reply, UInt32(reply.count)
        ) == kIOReturnSuccess else { return nil }
        return DDCPacket.parseBrightnessReply(reply)
    }

    func writeBrightness(_ value: Int) -> Bool {
        var packet = DDCPacket.brightnessWrite(value)
        return symbols.write(
            handle, DDCPacket.chipAddress, DDCPacket.dataAddress, &packet, UInt32(packet.count)
        ) == kIOReturnSuccess
    }
}
```

- [ ] **Step 2: Write the queue link**

`Sources/AutoBrightnessApp/DDC/DDCQueueLink.swift`:

```swift
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
```

- [ ] **Step 3: Write the registry**

`Sources/AutoBrightnessApp/DDC/DisplayRegistry.swift`:

```swift
import AppKit
import AutoBrightnessCore
import CoreGraphics
import Foundation
import IOKit

/// Finds the displays, and the DDC connection behind each external one.
enum DisplayRegistry {
    enum DDCResolution {
        case transport(IOAVServiceTransport)
        case noService
        case ambiguous
        /// The private symbols this needs are gone on this macOS.
        case unavailable
    }

    private typealias InfoFunction = @convention(c) (CGDirectDisplayID) -> Unmanaged<CFDictionary>?

    nonisolated(unsafe) private static let displayInfo: InfoFunction? = {
        guard let coreDisplay = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay", RTLD_LAZY
        ), let symbol = dlsym(coreDisplay, "CoreDisplay_DisplayCreateInfoDictionary") else { return nil }
        return unsafeBitCast(symbol, to: InfoFunction.self)
    }()

    static func activeDisplayIDs() -> [CGDirectDisplayID] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return Array(ids.prefix(Int(count)))
    }

    @MainActor
    static func name(of id: CGDirectDisplayID) -> String {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        let screen = NSScreen.screens.first {
            ($0.deviceDescription[key] as? NSNumber)?.uint32Value == id
        }
        return screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "Built-in Display" : "Display")
    }

    /// A result for every display passed in. Matching considers them all at
    /// once, because ambiguity is a property of the whole set.
    static func ddcResolutions(for displays: [CGDirectDisplayID]) -> [CGDirectDisplayID: DDCResolution] {
        guard IOAVServiceTransport.isAvailable, let displayInfo else {
            return Dictionary(uniqueKeysWithValues: displays.map { ($0, DDCResolution.unavailable) })
        }
        var locations: [UInt32: String] = [:]
        for id in displays {
            let info = displayInfo(id)?.takeRetainedValue() as? [String: Any]
            if let location = info?["IODisplayLocation"] as? String {
                locations[id] = location
            }
        }
        let services = externalServices()
        defer { services.forEach { IOObjectRelease($0.service) } }
        let matches = AVServiceMatcher.match(
            displayLocations: locations,
            servicePaths: services.map(\.path)
        )
        var result: [CGDirectDisplayID: DDCResolution] = [:]
        for id in displays {
            switch matches[id] ?? .noService {
            case .matched(let index):
                result[id] = IOAVServiceTransport(service: services[index].service)
                    .map(DDCResolution.transport) ?? .unavailable
            case .noService:
                result[id] = .noService
            case .ambiguous:
                result[id] = .ambiguous
            }
        }
        return result
    }

    /// Every external `DCPAVServiceProxy` with its service-plane path. The
    /// caller releases the services.
    private static func externalServices() -> [(path: String, service: io_service_t)] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("DCPAVServiceProxy"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        var found: [(path: String, service: io_service_t)] = []
        var service = IOIteratorNext(iterator)
        while service != 0 {
            let location = IORegistryEntryCreateCFProperty(
                service, "Location" as CFString, kCFAllocatorDefault, 0
            )?.takeRetainedValue() as? String
            var path = [CChar](repeating: 0, count: 512)
            if location == "External",
               IORegistryEntryGetPath(service, kIOServicePlane, &path) == KERN_SUCCESS {
                found.append((String(cString: path), service))
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iterator)
        }
        return found
    }
}
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: `Build complete!`. Under Swift 6, any `Sendable` error points at a capture crossing a queue. Fix it by making the captured type `@unchecked Sendable` (with a comment on who owns its state) or by passing a `Sendable` value. Never use `nonisolated(unsafe)` on instance state.

- [ ] **Step 5: Commit**

```bash
git add Sources/AutoBrightnessApp/DDC
git commit -m "feat: IOAVService transport, DDC queue link and display registry

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 9: One pipeline per display

**Files:**
- Modify: `Sources/AutoBrightnessApp/DisplayServicesBrightness.swift`
- Modify: `Sources/AutoBrightnessApp/ScreenSampler.swift`
- Create: `Sources/AutoBrightnessApp/DisplayUnit.swift`
- Create: `Sources/AutoBrightnessApp/DisplayManager.swift`
- Modify (replace): `Sources/AutoBrightnessApp/AppModel.swift`
- Modify (replace): `Sources/AutoBrightnessApp/SettingsView.swift`
- Modify: `Sources/AutoBrightnessApp/main.swift:84-128`

**Interfaces:**
- Consumes: everything from Task 8; `DDCBrightness` (Task 6); `RampingBrightness`, `Coordinator`, `ControllerSettings`, `LuminanceAnalyzer`.
- Produces: `DisplayUnit`, `DisplayManager` (with `DisplayManager.OtherDisplay`, `DisplayManager.Note`), and the new `AppModel` surface used by the views (`units`, `otherDisplays`, `hasAdjustableDisplay`, `isCheckingDisplays`, `needsScreenRecordingPermission`, `menuBarBrightness`).

- [ ] **Step 1: Bind DisplayServicesBrightness to one display**

In `Sources/AutoBrightnessApp/DisplayServicesBrightness.swift`, replace the class doc comment's last paragraph (lines 17-23, starting `/// Resolution is re-done`) with:

```swift
/// Each instance drives exactly one display for its whole life. An earlier
/// version fell back to the built-in panel whenever its display was not
/// built-in; with one instance per display, that fallback would have a Studio
/// Display's unit driving the laptop panel, with two coordinators fighting
/// over it. While its display is not active, `canControl` is false.
///
/// Symbols are resolved lazily against that display, never at launch against
/// whatever happens to be main: probing the wrong display gets the wrong
/// answer from `DisplayServicesCanChangeBrightness`.
```

Then replace everything from `private var cachedDisplayID: CGDirectDisplayID?` through the end of `public init(...)` with the stored properties below. Keep `dsGet`, `dsSet`, `cdGet`, `cdSet` and `resolvedForDisplayID`, and delete `cachedDisplayID`, `builtinDisplayID()`, the old `displayID` getter and the old `init`:

```swift
    private let boundDisplayID: CGDirectDisplayID
    private var dsGet: DSGet?
    private var dsSet: DSSet?
    private var cdGet: CDGet?
    private var cdSet: CDSet?
    /// The display the current symbols were probed against, or nil if none have
    /// been resolved yet.
    private var resolvedForDisplayID: CGDirectDisplayID?

    /// The bound display while it is active, else nil.
    private var displayID: CGDirectDisplayID? {
        CGDisplayIsActive(boundDisplayID) != 0 ? boundDisplayID : nil
    }

    public init(displayID: CGDirectDisplayID) {
        boundDisplayID = displayID
    }
```

Run: `grep -rn "builtinDisplayID" Sources`
Expected: no matches. (`AppModel` is replaced in Step 5.)

- [ ] **Step 2: Bind ScreenSampler to one display**

In `Sources/AutoBrightnessApp/ScreenSampler.swift`:

1. Doc comment line `/// Captures the built-in display at 2 fps, downscaled to a thumbnail, and hands` → `/// Captures one display at 2 fps, downscaled to a thumbnail, and hands`.
2. Add after `private let onStatus: @MainActor (SamplerStatus) -> Void`:

```swift
    private let displayID: CGDirectDisplayID
```

3. Replace the initializer's signature and first lines with:

```swift
    public init(
        displayID: CGDirectDisplayID,
        onFrame: @escaping @MainActor (Frame) -> Void,
        onStatus: @escaping @MainActor (SamplerStatus) -> Void
    ) {
        self.displayID = displayID
        self.onFrame = onFrame
```

4. Replace the block from `// Built-in only, as specified.` through the closing `}` of its `guard … else { status = .noDisplay; return }` with:

```swift
            // The one display this sampler serves. ScreenCaptureKit not
            // offering it (mirrored, or gone mid-reconfiguration) is reported
            // rather than quietly measuring a different display.
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else {
                status = .noDisplay
                return
            }
```

- [ ] **Step 3: Write DisplayUnit**

`Sources/AutoBrightnessApp/DisplayUnit.swift`:

```swift
import AutoBrightnessCore
import CoreGraphics
import Foundation
import Observation

/// One display's whole pipeline: capture, the control loop, and the backend
/// that moves its brightness.
///
/// `AppModel` decides *whether* the app should be adjusting at all. Each unit
/// works out what that means for its own display, by the same rules the app
/// applied when it had only one: sample only while wanted and controllable,
/// and adjust only while frames are actually arriving.
@MainActor
@Observable
final class DisplayUnit {
    enum Backend {
        /// The built-in panel and Apple externals. Glides on the main run loop.
        case displayServices(RampingBrightness)
        /// Third-party monitors. Glides on the DDC queue.
        case ddc(DDCBrightness, DDCQueueLink)
    }

    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool

    private(set) var status: SamplerStatus = .idle
    /// False while a DDC monitor is not answering. Always true otherwise.
    private(set) var isResponding = true
    private(set) var displayBrightness: Double?
    private(set) var luminance = 0.5
    private(set) var offset = 0.0
    private(set) var baseline = 0.5

    /// Called when the backend finds the display cannot be driven at all, so
    /// the manager can retire the unit and say why.
    @ObservationIgnored var onUnusable: (() -> Void)?

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let control: BrightnessControlling
    @ObservationIgnored private let coordinator: Coordinator
    @ObservationIgnored private var sampler: ScreenSampler?
    @ObservationIgnored private var userWantsIt = false
    /// See `AppModel`'s former `isSamplingRequested`: what we last asked the
    /// sampler to do, so status reports landing back here do not thrash it.
    @ObservationIgnored private var isSamplingRequested = false
    /// Each start/stop waits for the previous one, so two quick flips cannot
    /// run out of order and leave the capture indicator lit.
    @ObservationIgnored private var samplerTask: Task<Void, Never>?

    init(displayID: CGDirectDisplayID, name: String, backend: Backend) {
        self.displayID = displayID
        self.name = name
        isBuiltin = CGDisplayIsBuiltin(displayID) != 0
        self.backend = backend
        let control: BrightnessControlling
        switch backend {
        case .displayServices(let ramping): control = ramping
        case .ddc(let ddc, _): control = ddc
        }
        self.control = control
        coordinator = Coordinator(brightness: control)
        baseline = coordinator.baseline

        sampler = ScreenSampler(
            displayID: displayID,
            onFrame: { [weak self] frame in
                guard let self else { return }
                self.coordinator.tick(luminance: LuminanceAnalyzer.analyze(frame))
                self.refreshReadouts()
            },
            onStatus: { [weak self] status in
                guard let self else { return }
                self.status = status
                // A stream that has stopped or stalled delivers no more ticks,
                // so the offset it left behind would never be unwound.
                self.apply(userWantsIt: self.userWantsIt)
            }
        )

        if case .ddc(let ddc, _) = backend {
            ddc.onControlChange = { [weak self] in self?.controlChanged() }
        }
    }

    var usesDDC: Bool {
        if case .ddc = backend { true } else { false }
    }

    var settings: ControllerSettings {
        get { coordinator.settings }
        set { coordinator.settings = newValue }
    }

    var isEnabled: Bool {
        get { coordinator.isEnabled }
        set { coordinator.isEnabled = newValue }
    }

    func apply(userWantsIt: Bool) {
        self.userWantsIt = userWantsIt
        let controllable = control.canControl && isResponding
        let shouldSample = userWantsIt && controllable
        if shouldSample != isSamplingRequested, let sampler {
            isSamplingRequested = shouldSample
            let previous = samplerTask
            samplerTask = Task {
                await previous?.value
                shouldSample ? await sampler.start() : await sampler.stop()
            }
        }
        if shouldSample && status == .running {
            if coordinator.isPaused { coordinator.resume() }
        } else {
            coordinator.suspend()
        }
        refreshReadouts()
    }

    /// Only the built-in panel is dimmed by the OS on a power-source change.
    func notePowerSourceChange() {
        guard isBuiltin else { return }
        coordinator.notePowerSourceChange()
    }

    func retry() {
        guard let sampler else { return }
        Task { await sampler.retry() }
    }

    func replaceTransport(_ transport: IOAVServiceTransport) {
        guard case .ddc(_, let link) = backend else { return }
        link.replaceTransport(transport)
    }

    func refreshReadouts() {
        displayBrightness = control.read()
        luminance = coordinator.lastLuminance
        offset = coordinator.appliedOffset
        baseline = coordinator.baseline
    }

    /// The display has gone, or has been given up on.
    func tearDown() {
        userWantsIt = false
        if let sampler {
            isSamplingRequested = false
            let previous = samplerTask
            samplerTask = Task {
                await previous?.value
                await sampler.stop()
            }
        }
        coordinator.restoreBaseline()
        switch backend {
        case .displayServices(let ramping): ramping.flush()
        case .ddc(let ddc, _): ddc.invalidate()
        }
    }

    /// First half of quitting: put the display back and start any DDC write
    /// on its way. The second half waits, for all DDC displays at once.
    func restoreForTermination() {
        coordinator.restoreBaseline()
        switch backend {
        case .displayServices(let ramping): ramping.flush()
        case .ddc(let ddc, _): ddc.startFlush()
        }
    }

    func waitForTermination(deadline: DispatchTime) {
        guard case .ddc(let ddc, _) = backend else { return }
        ddc.waitForFlush(deadline: deadline)
    }

    private func controlChanged() {
        guard case .ddc(let ddc, _) = backend else { return }
        isResponding = ddc.isResponding
        guard ddc.canControl else {
            onUnusable?()
            return
        }
        apply(userWantsIt: userWantsIt)
    }
}
```

- [ ] **Step 4: Write DisplayManager**

`Sources/AutoBrightnessApp/DisplayManager.swift`:

```swift
import AutoBrightnessCore
import CoreGraphics
import Foundation
import Observation

/// Keeps one `DisplayUnit` per adjustable display, and a note for every
/// display that is not adjustable, in step with the displays actually
/// connected.
@MainActor
@Observable
final class DisplayManager {
    struct OtherDisplay: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let note: String
    }

    enum Note {
        static let checking = "Checking…"
        static let noService = "No DDC connection"
        static let ambiguous = "Can't tell which connection is this display"
        static let noResponse = "Didn't respond to DDC"
        static let unwritable = "Doesn't accept brightness changes"
        static let unavailable = "DDC isn't available on this Mac"
        static let fixed = "Brightness can't be changed"
    }

    /// Built-in first, then by display ID, so rows do not jump around.
    private(set) var units: [DisplayUnit] = []
    private(set) var others: [OtherDisplay] = []

    /// Lets `AppModel` hand a new unit the current settings and run state.
    @ObservationIgnored var onUnitAdded: ((DisplayUnit) -> Void)?

    /// Bumped by every reconcile. A probe started under an older generation
    /// is about a display set that no longer exists, and must not add a unit.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retries: [CGDirectDisplayID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryAttempts: [CGDirectDisplayID: Int] = [:]
    /// A monitor still waking up at login answers a few seconds later; one
    /// that never answers is tried once a minute rather than given up on.
    static let retryDelays: [Double] = [5, 10, 20, 60]

    func reconcile() {
        generation += 1
        let active = DisplayRegistry.activeDisplayIDs()
        for unit in units where !active.contains(unit.displayID) { unit.tearDown() }
        units.removeAll { !active.contains($0.displayID) }
        retries.values.forEach { $0.cancel() }
        retries = [:]
        retryAttempts = [:]
        // Everything not being driven is worked out again from scratch: a
        // reconfiguration is exactly when an earlier answer may have changed.
        others = []

        let ddc = DisplayRegistry.ddcResolutions(for: Self.externals(of: active))
        // DCP services can be recreated across a reconfiguration, and an old
        // handle is then dead.
        for unit in units where unit.usesDDC {
            if case .transport(let transport) = ddc[unit.displayID] {
                unit.replaceTransport(transport)
            }
        }
        for id in active where !units.contains(where: { $0.displayID == id }) {
            resolve(id, ddc: ddc[id] ?? .noService)
        }
    }

    /// The machine woke: retry monitors that had not answered, and give DDC
    /// units that stopped answering a fresh handle.
    func noteWake() {
        for other in others where other.note == Note.noResponse {
            retryProbe(other.id)
        }
        let stale = units.filter { $0.usesDDC && !$0.isResponding }
        guard !stale.isEmpty else { return }
        let ddc = DisplayRegistry.ddcResolutions(for: Self.externals(of: DisplayRegistry.activeDisplayIDs()))
        for unit in stale {
            if case .transport(let transport) = ddc[unit.displayID] {
                unit.replaceTransport(transport)
            }
        }
    }

    private func resolve(_ id: CGDirectDisplayID, ddc: DisplayRegistry.DDCResolution) {
        let name = DisplayRegistry.name(of: id)
        let services = DisplayServicesBrightness(displayID: id)
        if services.canControl {
            let ramping = RampingBrightness(wrapping: services, scheduler: TimerRampScheduler())
            add(DisplayUnit(displayID: id, name: name, backend: .displayServices(ramping)))
            return
        }
        guard CGDisplayIsBuiltin(id) == 0 else {
            setNote(id, name: name, Note.fixed)
            return
        }
        switch ddc {
        case .transport(let transport): probe(id, name: name, transport: transport)
        case .noService: setNote(id, name: name, Note.noService)
        case .ambiguous: setNote(id, name: name, Note.ambiguous)
        case .unavailable: setNote(id, name: name, Note.unavailable)
        }
    }

    /// One read, off the main thread, to see whether the monitor answers at
    /// all before anything is built on it.
    private func probe(_ id: CGDirectDisplayID, name: String, transport: IOAVServiceTransport) {
        let generation = self.generation
        setNote(id, name: name, Note.checking)
        Task { [weak self] in
            let reading = await Self.read(transport)
            guard let self, generation == self.generation else { return }
            self.others.removeAll { $0.id == id }
            guard let reading else {
                self.setNote(id, name: name, Note.noResponse)
                self.scheduleRetry(id)
                return
            }
            self.retryAttempts[id] = nil
            let link = DDCQueueLink(transport: transport, seed: reading)
            let ddc = DDCBrightness(link: link, seed: reading)
            self.add(DisplayUnit(displayID: id, name: name, backend: .ddc(ddc, link)))
        }
    }

    nonisolated private static func read(_ transport: IOAVServiceTransport) async -> DDCReading? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: transport.readBrightness())
            }
        }
    }

    private func scheduleRetry(_ id: CGDirectDisplayID) {
        let attempt = retryAttempts[id, default: 0]
        retryAttempts[id] = attempt + 1
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        retries[id]?.cancel()
        retries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryProbe(id)
        }
    }

    private func retryProbe(_ id: CGDirectDisplayID) {
        retries[id] = nil
        guard others.contains(where: { $0.id == id && $0.note == Note.noResponse }) else { return }
        let active = DisplayRegistry.activeDisplayIDs()
        guard active.contains(id) else { return }
        let ddc = DisplayRegistry.ddcResolutions(for: Self.externals(of: active))
        others.removeAll { $0.id == id }
        resolve(id, ddc: ddc[id] ?? .noService)
    }

    private func add(_ unit: DisplayUnit) {
        unit.onUnusable = { [weak self, weak unit] in
            guard let self, let unit else { return }
            unit.tearDown()
            self.units.removeAll { $0 === unit }
            self.setNote(unit.displayID, name: unit.name, Note.unwritable)
        }
        units.append(unit)
        units.sort { ($0.isBuiltin ? 0 : 1, $0.displayID) < ($1.isBuiltin ? 0 : 1, $1.displayID) }
        onUnitAdded?(unit)
    }

    private func setNote(_ id: CGDirectDisplayID, name: String, _ note: String) {
        others.removeAll { $0.id == id }
        others.append(OtherDisplay(id: id, name: name, note: note))
        others.sort { $0.id < $1.id }
    }

    private static func externals(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID] {
        displays.filter { CGDisplayIsBuiltin($0) == 0 }
    }
}
```

- [ ] **Step 5: Replace AppModel**

Replace `Sources/AutoBrightnessApp/AppModel.swift` with the following. Everything not shown as changed is carried over verbatim from the current file, including the comments on `isAtDefaultTuning`, `resetTuning`, `showsMenuBarIcon`, `launchAtLogin`, the pause handling and the ranges.

```swift
import AppKit
import AutoBrightnessCore
import CoreGraphics
import Foundation
import Observation
import ServiceManagement

/// Binds the displays to the pause monitor and the UI.
///
/// Decides *whether* the app should be adjusting — the toggle, a manual pause,
/// system sleep — and hands that to every display; each `DisplayUnit` works
/// out what it means for its own display.
@MainActor
@Observable
public final class AppModel {
    let displays = DisplayManager()
    private var pauseMonitor: PauseMonitor?
    private var powerSourceMonitor: PowerSourceMonitor?
    private var pauseTimer: Timer?
    /// Keeps the brightness readouts honest while nothing else is ticking:
    /// paused, disabled, or sampler down, the user can still change brightness
    /// with the hardware keys or the monitor's buttons, and the readout must
    /// follow.
    private var readoutTimer: Timer?
    /// True while the system has told us adjusting is pointless: display asleep,
    /// screen locked, machine suspended.
    private var isSystemPaused = false
    /// Watches for displays arriving and leaving. Unconditional: when nothing
    /// is adjustable, nothing else is running to notice a display appearing.
    private var displayObserver: (any NSObjectProtocol)?
    /// True while a user-requested "pause for 1 hour" is in effect. This is
    /// tracked separately from each coordinator's `isPaused` because system
    /// sleep/wake and the `isEnabled` toggle also drive `suspend()`/`resume()`
    /// — without this flag, a system wake or a disable/re-enable would silently
    /// cancel a manual pause early.
    private var isManuallyPaused = false
    /// When the manual pause is due to end. The `Timer` alone cannot be trusted
    /// with this: it does not fire while the machine is asleep and comes back
    /// late by however long the sleep lasted, so a pause taken at 14:00 and
    /// labelled "until 15:00" would really run to 18:00 after a three-hour lid
    /// close. The deadline is the truth; the timer only saves us from polling
    /// when nothing interrupts it.
    private var pauseDeadline: Date?
    /// Suppresses the `launchAtLogin` `didSet` while it is reverting itself
    /// after a failed registration.
    private var isRevertingLaunchAtLogin = false
    /// Guards the restore-and-terminate sequence so it runs exactly once
    /// whether it is entered via the Quit button or via
    /// `applicationWillTerminate` (logout, Activity Monitor, etc).
    private var hasRestoredBaseline = false

    public private(set) var pausedUntilLabel: String?
    /// Set when registering or unregistering the login item failed, so the UI
    /// can say so rather than leave a switch showing a state that was never
    /// achieved.
    public private(set) var launchAtLoginError: String?

    var units: [DisplayUnit] { displays.units }
    var otherDisplays: [DisplayManager.OtherDisplay] { displays.others }
    var hasAdjustableDisplay: Bool { !displays.units.isEmpty }
    var isCheckingDisplays: Bool {
        displays.others.contains { $0.note == DisplayManager.Note.checking }
    }
    /// One grant covers every display, so it is asked for once, not per row.
    var needsScreenRecordingPermission: Bool {
        displays.units.contains { $0.status == .permissionDenied }
    }
    /// The menu bar sits on the main display, so that is the one it reports;
    /// failing that, the first adjustable display; failing that, nothing, and
    /// the status item shows its glyph alone.
    var menuBarBrightness: Double? {
        let main = CGMainDisplayID()
        let unit = displays.units.first { $0.displayID == main } ?? displays.units.first
        return unit?.displayBrightness
    }

    public var isEnabled: Bool {
        didSet {
            for unit in displays.units { unit.isEnabled = isEnabled }
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            applyRunState()
        }
    }

    public var strength: Double {
        didSet {
            applyTuning()
            UserDefaults.standard.set(strength, forKey: "strength")
        }
    }

    public var maxOffset: Double {
        didSet {
            applyTuning()
            UserDefaults.standard.set(maxOffset, forKey: "maxOffset")
        }
    }

    public var responseSeconds: Double {
        didSet {
            applyTuning()
            UserDefaults.standard.set(responseSeconds, forKey: "responseSeconds")
        }
    }

    // isAtDefaultTuning, resetTuning(), showsMenuBarIcon, launchAtLogin:
    // carried over verbatim from the current file, comments included.

    /// The tuning every display runs with, kept in one place so a display that
    /// appears later starts from the same values as the rest.
    private var tuning: ControllerSettings {
        var settings = ControllerSettings.defaults
        settings.strength = strength
        settings.maxOffset = maxOffset
        settings.responseSeconds = responseSeconds
        return settings
    }

    private var userWantsIt: Bool { isEnabled && !isManuallyPaused && !isSystemPaused }

    public init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "isEnabled": true,
            "showsMenuBarIcon": true,
            "strength": ControllerSettings.defaults.strength,
            "maxOffset": ControllerSettings.defaults.maxOffset,
            "responseSeconds": ControllerSettings.defaults.responseSeconds,
        ])

        // Clamped, not trusted: the sliders bound what a user can choose, but a
        // value carried over from an older build or edited by hand is not
        // bounded by anything, and an out-of-range strength would drive the
        // control law well past what was ever tuned for.
        isEnabled = defaults.bool(forKey: "isEnabled")
        showsMenuBarIcon = defaults.bool(forKey: "showsMenuBarIcon")
        strength = Self.strengthRange.clamping(defaults.double(forKey: "strength"))
        maxOffset = Self.maxOffsetRange.clamping(defaults.double(forKey: "maxOffset"))
        responseSeconds = Self.responseSecondsRange.clamping(defaults.double(forKey: "responseSeconds"))
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    public func start() {
        displays.onUnitAdded = { [weak self] unit in self?.configure(unit) }

        let monitor = PauseMonitor(
            onSuspend: { [weak self] in
                self?.isSystemPaused = true
                self?.applyRunState()
            },
            onResume: { [weak self] in
                self?.isSystemPaused = false
                self?.displays.noteWake()
                self?.applyRunState()
            }
        )
        monitor.start()
        pauseMonitor = monitor

        let powerMonitor = PowerSourceMonitor(onChange: { [weak self] in
            self?.displays.units.forEach { $0.notePowerSourceChange() }
        })
        powerMonitor.start()
        powerSourceMonitor = powerMonitor

        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displays.reconcile()
                self?.applyRunState()
            }
        }

        readoutTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Also the backstop for an expired pause, for the wake that
                // arrives without a notification we observe.
                guard !self.endPauseIfExpired() else { return }
                self.refreshReadouts()
            }
        }

        displays.reconcile()
        applyRunState()
    }

    /// Re-attempts capture on every display, for the case where the user has
    /// just granted Screen Recording permission.
    public func retrySampling() {
        displays.units.forEach { $0.retry() }
    }

    // pauseForAnHour(), endPause(), endPauseIfExpired(): carried over verbatim.

    /// The single place that decides whether the app is watching and adjusting.
    /// Every input — the toggle, a manual pause, system sleep — funnels through
    /// here, and each display applies the answer to itself.
    private func applyRunState() {
        // Waking from sleep lands here, and it is the one moment an expired
        // pause is most likely to be sitting unnoticed. `endPause` re-enters
        // this method with the deadline already cleared, so this cannot loop.
        if endPauseIfExpired() { return }
        for unit in displays.units { unit.apply(userWantsIt: userWantsIt) }
    }

    private func configure(_ unit: DisplayUnit) {
        unit.settings = tuning
        unit.isEnabled = isEnabled
        unit.apply(userWantsIt: userWantsIt)
    }

    private func applyTuning() {
        for unit in displays.units { unit.settings = tuning }
    }

    // quit(), prepareForTermination(): carried over verbatim.

    private func restoreBaselineOnce() {
        guard !hasRestoredBaseline else { return }
        hasRestoredBaseline = true
        // Every display is put back and every DDC write started before any is
        // waited on, so several monitors share one deadline rather than
        // queueing behind each other.
        for unit in displays.units { unit.restoreForTermination() }
        let deadline = DispatchTime.now() + 0.5
        for unit in displays.units { unit.waitForTermination(deadline: deadline) }
    }

    private func refreshReadouts() {
        displays.units.forEach { $0.refreshReadouts() }
    }

    // strengthRange, maxOffsetRange, responseSecondsRange, timeFormatter, and
    // the ClosedRange.clamping extension: carried over verbatim.
}
```

Lines starting `// … carried over verbatim` are instructions to you, not code. Paste the named members from the old file in their place, unchanged. Then check that nothing from the old single-display surface is left:

Run: `grep -n "Coordinator(\|brightness\.\|canControlBrightness\|isSamplingRequested\|samplerTask\|ScreenSampler" Sources/AutoBrightnessApp/AppModel.swift`
Expected: no matches.

- [ ] **Step 6: Replace SettingsView's display section**

Replace `Sources/AutoBrightnessApp/SettingsView.swift` with the following. The tuning sliders, reset button, toggles, login-item error, Quit row and `versionLabel` are unchanged and shown in full.

```swift
import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showDebug = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Adjust brightness to content", isOn: $model.isEnabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.units, id: \.displayID) { unit in
                    DisplayRow(unit: unit, isEnabled: model.isEnabled)
                }
                ForEach(model.otherDisplays) { other in
                    HStack {
                        Label(other.name, systemImage: "display")
                        Spacer()
                        Text(other.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                // Shown whether or not the app is enabled: a user who pauses and
                // then switches the toggle off must still be able to see that a
                // pause is in effect, and cancel it.
                if let label = model.pausedUntilLabel {
                    Text("Paused until \(label)")
                        .font(.caption)
                    Button("Resume", action: model.endPause)
                } else if model.isEnabled {
                    Button("Pause for 1 hour", action: model.pauseForAnHour)
                }
            }

            if !model.hasAdjustableDisplay && !model.isCheckingDisplays {
                Label("No adjustable displays", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.needsScreenRecordingPermission {
                permissionNotice
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Sensitivity to screen content: \(Int(model.strength * 100))%")
                Slider(value: $model.strength, in: AppModel.strengthRange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Maximum change: \(Int(model.maxOffset * 100))%")
                Slider(value: $model.maxOffset, in: AppModel.maxOffsetRange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "Time to adjust: %.1f seconds", model.responseSeconds))
                Slider(value: $model.responseSeconds, in: AppModel.responseSecondsRange)
            }

            HStack {
                Spacer()
                Button("Reset to defaults", action: model.resetTuning)
                    .disabled(model.isAtDefaultTuning)
            }
            .font(.caption)

            Divider()

            Toggle("Show icon in menu bar", isOn: $model.showsMenuBarIcon)

            Toggle("Open at login", isOn: $model.launchAtLogin)

            // The toggle has already snapped back to what the system reports,
            // so without this the failure would look like a switch that
            // silently refuses to move.
            if let error = model.launchAtLoginError {
                Text("Could not change the login item: \(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            DisclosureGroup("Details", isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.units, id: \.displayID) { unit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(unit.name).fontWeight(.semibold)
                            Text(String(format: "Screen luminance: %.3f", unit.luminance))
                            Text(String(format: "Applied offset: %+.3f", unit.offset))
                            Text(String(format: "Your baseline: %.3f", unit.baseline))
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button("Quit", action: model.quit)
                Spacer()
                if let version = Self.versionLabel {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// "1.0 (1)" from the bundle. Nil when run straight out of `swift build`,
    /// where there is no Info.plist to read and a version would be a fiction.
    private static let versionLabel: String? = {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return "Version \(short)"
        }
        return "Version \(short) (\(build))"
    }()

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "Screen Recording permission is required.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            HStack {
                Button("Open System Settings") {
                    let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    )!
                    NSWorkspace.shared.open(url)
                }
                Button("Try Again", action: model.retrySampling)
            }
            .font(.caption)
            // macOS usually only honours a screen-capture grant for a process
            // that started after it, so say so rather than leaving the user
            // pressing a button that cannot work.
            Text("After granting permission, quit and reopen Auto Brightness if it does not start on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One adjustable display: its name, its brightness, and anything wrong with
/// its capture. Permission problems are left to the single notice above.
private struct DisplayRow: View {
    let unit: DisplayUnit
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(unit.name, systemImage: unit.isBuiltin ? "laptopcomputer" : "display")
                Spacer()
                if !unit.isResponding {
                    Text("Not responding")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let brightness = unit.displayBrightness {
                    Text("\(Int((brightness * 100).rounded()))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
            if let note = statusNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusNote: String? {
        switch unit.status {
        case .running, .permissionDenied:
            nil
        case .idle:
            isEnabled ? "Starting…" : nil
        case .stalled:
            "Reconnecting to the display…"
        case .noDisplay:
            "This display isn't available for capture."
        case .failed(let message):
            "Capture failed: \(message)"
        }
    }
}
```

- [ ] **Step 7: Point the menu bar at the main display**

In `Sources/AutoBrightnessApp/main.swift`:

1. Line 120: `(model.displayBrightness, model.showsMenuBarIcon)` → `(model.menuBarBrightness, model.showsMenuBarIcon)`.
2. In the doc comment of `updateStatusItem()` (line 84 onwards), replace `/// Shows the app glyph and the panel's brightness as a percentage. The` … `/// symbols gone).` with:

```swift
    /// Shows the app glyph and the main display's brightness as a percentage.
    /// The glyph is hidden when the user turns it off, and the percentage is
    /// dropped when no display's brightness can be read.
```

- [ ] **Step 8: Build and test**

Run: `swift build && swift test`
Expected: `Build complete!`, then all tests pass.

- [ ] **Step 9: Smoke-run the app**

Run the app the way README's "Building and installing" section describes for development. Then check, with the lid closed and only the P24h-30 attached:
- The popover lists "P24h-30" with a percentage, and the old warning is gone.
- With white content full screen, the P24h-30 visibly dims within a few seconds. With dark content, it brightens.

If either fails, check Console.app for the process's log, fix it, and re-run before committing.

- [ ] **Step 10: Commit**

```bash
git add Sources/AutoBrightnessApp
git commit -m "feat: adjust every display independently, external monitors included

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

---

### Task 10: Documentation and hardware verification

**Files:**
- Modify: `README.md:100-110`
- Modify: `docs/superpowers/specs/2026-08-04-auto-brightness-design.md` (Non-Goals)
- Modify: `docs/superpowers/specs/2026-10-22-external-displays-design.md` (Status line)

- [ ] **Step 1: Update the README**

Replace the paragraph starting `Auto Brightness controls only the built-in display;` (through `before applying an offset.`) with:

```markdown
Auto Brightness adjusts every connected display it can drive, each from its
own content: dark content on one screen does not dim another. The built-in
panel and Apple's own displays (Studio Display, Pro Display XDR, LG
UltraFine) are driven through the same system interface as the brightness
keys. Other monitors are driven over DDC/CI, the standard most monitors
accept over USB-C, DisplayPort and HDMI, on Apple Silicon Macs only.

The popover lists each display. One that cannot be driven says why: no DDC
connection (DisplayLink docks, AirPlay, Sidecar, some hubs and KVMs), a
monitor that did not answer (check that DDC/CI is enabled in its own menu),
or one that accepts commands but ignores them. Pressing a monitor's own
brightness buttons is followed rather than fought, usually within a second.
Displays can come and go while the app runs; it picks them up without a
relaunch.
```

- [ ] **Step 2: Note the reversal in the original spec**

In `docs/superpowers/specs/2026-08-04-auto-brightness-design.md`, change the Non-Goals line `- External monitor control via DDC/CI` to:

```markdown
- ~~External monitor control via DDC/CI~~ — now in scope; see
  `2026-10-22-external-displays-design.md`.
```

- [ ] **Step 3: Verify on hardware**

Build and run the app as in Task 9 Step 9. Check each item and note pass or fail:

1. Lid closed, P24h-30 only: it adjusts with content, and there is no warning.
2. Lid open: both displays listed; full-screen white on one dims only that one; the menu bar percentage matches the main display.
3. With a video playing on the P24h-30, press its brightness-down button twice: the level stays down (the popover shows it), and content adjustment continues around the new level.
4. Quit: both displays return to their baselines (compare with the popover's "Your baseline" before quitting).
5. Unplug and replug the P24h-30 while running: it reappears and adjusts without a relaunch.
6. Sleep the display (Ctrl-Shift-Eject or the menu) and wake it: the P24h-30 comes back at its baseline.

Any fail: stop, report it with what you saw, and fix it before Step 4.

- [ ] **Step 4: Mark the spec implemented**

In `docs/superpowers/specs/2026-10-22-external-displays-design.md`, change `Status: draft (revised after review)` to `Status: implemented`.

- [ ] **Step 5: Commit**

```bash
git add README.md docs/superpowers/specs
git commit -m "docs: describe external display support and mark the spec implemented

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```
