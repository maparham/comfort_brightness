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
