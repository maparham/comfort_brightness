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
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(
            systemSymbolName: "sun.max",
            accessibilityDescription: "Auto Brightness"
        )
        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        statusItem = item

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentSize = NSSize(width: 300, height: 460)
        popover.contentViewController = NSHostingController(
            rootView: SettingsView(model: model)
        )
        self.popover = popover

        Task { await model.start() }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Not `model.quit()`: that would call `terminate(_:)` again, which
        // AppKit is already in the middle of. `prepareForTermination()` only
        // restores the baseline (idempotently, so the Quit-button path that
        // already restored it is a no-op here), covering termination paths
        // that never went through `quit()` at all — logout, Activity Monitor.
        model.prepareForTermination()
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
