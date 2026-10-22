import AutoBrightnessCore
import CoreGraphics
import Foundation

private typealias DSGet = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32
private typealias DSSet = @convention(c) (CGDirectDisplayID, Float) -> Int32
private typealias DSCan = @convention(c) (CGDirectDisplayID) -> Int32
private typealias CDGet = @convention(c) (CGDirectDisplayID) -> Double
private typealias CDSet = @convention(c) (CGDirectDisplayID, Double) -> Void

/// Reads and writes its display's brightness through private frameworks: the
/// built-in panel, or an Apple external such as a Studio Display.
///
/// There is no public API for this. Symbols are resolved at runtime rather than
/// linked, so a future macOS that removes them yields `canControl == false`
/// instead of a launch failure.
///
/// Each instance drives exactly one display for its whole life. An earlier
/// version fell back to the built-in panel whenever its display was not
/// built-in; with one instance per display, that fallback would have a Studio
/// Display's unit driving the laptop panel, with two coordinators fighting
/// over it. While its display is not active, `canControl` is false.
///
/// Symbols are resolved lazily against that display, never at launch against
/// whatever happens to be main: probing the wrong display gets the wrong
/// answer from `DisplayServicesCanChangeBrightness`.
public final class DisplayServicesBrightness: BrightnessControlling {
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

    /// Resolves the private symbols against the panel we are actually going to
    /// drive, redoing the work if that panel has changed since last time. Cheap
    /// enough to sit in front of every call: `dlopen` of an already-loaded
    /// framework is a lookup, and after the first call the guard exits at once.
    private func resolveSymbolsIfNeeded(for id: CGDirectDisplayID) {
        guard resolvedForDisplayID != id else { return }
        resolvedForDisplayID = id

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
            canChange = fn(id) != 0
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

    /// Its display while active, with symbols resolved against it; else nil.
    private var controllableDisplayID: CGDirectDisplayID? {
        guard let id = displayID else { return nil }
        resolveSymbolsIfNeeded(for: id)
        return id
    }

    public var canControl: Bool {
        guard controllableDisplayID != nil else { return false }
        return (dsGet != nil && dsSet != nil) || (cdGet != nil && cdSet != nil)
    }

    public func read() -> Double? {
        guard let displayID = controllableDisplayID else { return nil }
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
        guard let displayID = controllableDisplayID else { return }
        let clamped = min(max(value, 0.0), 1.0)
        if let dsSet {
            _ = dsSet(displayID, Float(clamped))
            return
        }
        cdSet?(displayID, clamped)
    }
}
