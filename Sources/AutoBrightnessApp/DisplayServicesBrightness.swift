import AutoBrightnessCore
import CoreGraphics
import Foundation

private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias DSCan = @convention(c) (CGDirectDisplayID) -> Int32
private typealias CDGet = @convention(c) (CGDirectDisplayID) -> Double
private typealias CDSet = @convention(c) (CGDirectDisplayID, Double) -> Void

/// Reads and writes the built-in panel's backlight through private frameworks.
///
/// There is no public API for this. Symbols are resolved at runtime rather than
/// linked, so a future macOS that removes them yields `canControl == false`
/// instead of a launch failure.
public final class DisplayServicesBrightness: BrightnessControlling {
    private var cachedDisplayID: CGDirectDisplayID?
    private let dsGet: DSGet?
    private let dsSet: DSSet?
    private let cdGet: CDGet?
    private let cdSet: CDSet?

    /// The built-in panel, or nil when there isn't one — no built-in display at
    /// all, or a laptop closed in clamshell mode. The spec is explicit that
    /// external monitors are never touched, so "no built-in" means "do nothing",
    /// not "fall back to whatever display is primary".
    public static func builtinDisplayID() -> CGDirectDisplayID? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        return ids.prefix(Int(count)).first { CGDisplayIsBuiltin($0) != 0 }
    }

    /// Re-resolved rather than captured once: a display can come and go while the
    /// app runs (clamshell open/close, undocking), and the ID is not stable.
    private var displayID: CGDirectDisplayID? {
        if let cachedDisplayID,
           CGDisplayIsActive(cachedDisplayID) != 0,
           CGDisplayIsBuiltin(cachedDisplayID) != 0 {
            return cachedDisplayID
        }
        cachedDisplayID = Self.builtinDisplayID()
        return cachedDisplayID
    }

    public init(displayID: CGDirectDisplayID? = DisplayServicesBrightness.builtinDisplayID()) {
        self.cachedDisplayID = displayID
        // Probe against whatever built-in panel exists now; if there is none, the
        // symbols still resolve and control becomes possible as soon as one
        // appears.
        let probeID = displayID ?? CGMainDisplayID()

        let displayServices = dlopen(
            "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices",
            RTLD_LAZY
        )
        func ds(_ name: String) -> UnsafeMutableRawPointer? {
            guard let handle = displayServices else { return nil }
            return dlsym(handle, name)
        }

        var canChange = true
        if let symbol = ds("DisplayServicesCanChangeBrightness") {
            let fn = unsafeBitCast(symbol, to: DSCan.self)
            canChange = fn(probeID) != 0
        }

        if canChange,
           let get = ds("DisplayServicesGetBrightness"),
           let set = ds("DisplayServicesSetBrightness") {
            dsGet = unsafeBitCast(get, to: DSGet.self)
            dsSet = unsafeBitCast(set, to: DSSet.self)
        } else {
            dsGet = nil
            dsSet = nil
        }

        // Fallback path, used only if the DisplayServices symbols are missing —
        // and only when the display has not said outright that its brightness
        // cannot be changed. Routing around that answer via another framework
        // would be ignoring the one piece of information the system gave us, and
        // this path's write/read fidelity has never been measured on real
        // hardware the way DisplayServices has.
        if canChange,
           let coreDisplay = dlopen(
               "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
               RTLD_LAZY
           ),
           let get = dlsym(coreDisplay, "CoreDisplay_Display_GetUserBrightness"),
           let set = dlsym(coreDisplay, "CoreDisplay_Display_SetUserBrightness") {
            cdGet = unsafeBitCast(get, to: CDGet.self)
            cdSet = unsafeBitCast(set, to: CDSet.self)
        } else {
            cdGet = nil
            cdSet = nil
        }
    }

    public var canControl: Bool {
        guard displayID != nil else { return false }
        return (dsGet != nil && dsSet != nil) || (cdGet != nil && cdSet != nil)
    }

    public func read() -> Double? {
        guard let displayID else { return nil }
        if let dsGet {
            var value: Float = 0
            if dsGet(displayID, &value) == 0 {
                return Double(value)
            }
        }
        if let cdGet {
            return cdGet(displayID)
        }
        return nil
    }

    public func write(_ value: Double) {
        guard let displayID else { return }
        let clamped = min(max(value, 0.0), 1.0)
        if let dsSet {
            _ = dsSet(displayID, Float(clamped))
            return
        }
        cdSet?(displayID, clamped)
    }
}
