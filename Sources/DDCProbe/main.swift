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

@MainActor
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

@MainActor
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

@MainActor
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
