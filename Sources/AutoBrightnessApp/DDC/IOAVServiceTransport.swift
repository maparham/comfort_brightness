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
