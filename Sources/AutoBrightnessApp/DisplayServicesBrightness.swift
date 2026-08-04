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
    private let displayID: CGDirectDisplayID
    private let dsGet: DSGet?
    private let dsSet: DSSet?
    private let cdGet: CDGet?
    private let cdSet: CDSet?

    public init(displayID: CGDirectDisplayID = CGMainDisplayID()) {
        self.displayID = displayID

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
            canChange = fn(displayID) != 0
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

        // Fallback path, used only if DisplayServices is unavailable.
        let coreDisplay = dlopen(
            "/System/Library/Frameworks/CoreDisplay.framework/CoreDisplay",
            RTLD_LAZY
        )
        func cd(_ name: String) -> UnsafeMutableRawPointer? {
            guard let handle = coreDisplay else { return nil }
            return dlsym(handle, name)
        }
        if let get = cd("CoreDisplay_Display_GetUserBrightness"),
           let set = cd("CoreDisplay_Display_SetUserBrightness") {
            cdGet = unsafeBitCast(get, to: CDGet.self)
            cdSet = unsafeBitCast(set, to: CDSet.self)
        } else {
            cdGet = nil
            cdSet = nil
        }
    }

    public var canControl: Bool {
        (dsGet != nil && dsSet != nil) || (cdGet != nil && cdSet != nil)
    }

    public func read() -> Double? {
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
        let clamped = min(max(value, 0.0), 1.0)
        if let dsSet {
            _ = dsSet(displayID, Float(clamped))
            return
        }
        cdSet?(displayID, clamped)
    }
}
