import AppKit
import SwiftUI

/// Status-item bootstrap rather than SwiftUI's `MenuBarExtra`: a SwiftPM
/// executable is not a bundle at build time, and driving `NSStatusItem`
/// directly keeps the app working whether or not it has been bundled yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item
        updateStatusItem()

        let popover = NSPopover()
        popover.behavior = .transient
        // No hard-coded contentSize: the view's height varies with the
        // "Details" disclosure, and a mismatched initial size makes AppKit
        // resize the shown popover from its bottom edge, detaching it from
        // the status item. `.preferredContentSize` keeps the popover sized
        // to the SwiftUI content instead.
        let hosting = NSHostingController(rootView: SettingsView(model: model))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        self.popover = popover

        model.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Not `model.quit()`: that would call `terminate(_:)` again, which
        // AppKit is already in the middle of. `prepareForTermination()` only
        // restores the baseline (idempotently, so the Quit-button path that
        // already restored it is a no-op here), covering termination paths
        // that never went through `quit()` at all — logout, Activity Monitor.
        model.prepareForTermination()
    }

    /// Shows the panel's brightness as a percentage, falling back to the sun
    /// icon when it cannot be read (no built-in panel, clamshell, symbols
    /// gone). `withObservationTracking` fires once per change, so each update
    /// re-arms it.
    private func updateStatusItem() {
        guard let button = statusItem?.button else { return }
        let brightness = withObservationTracking {
            model.displayBrightness
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
            }
        }
        if let brightness {
            button.image = nil
            button.title = "\(Int((brightness * 100).rounded()))%"
        } else {
            button.title = ""
            button.image = NSImage(
                systemSymbolName: "sun.max",
                accessibilityDescription: "Auto Brightness"
            )
        }
    }

    @objc private func togglePopover() {
        guard let popover, let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let delegate = AppDelegate()
application.delegate = delegate
application.run()
