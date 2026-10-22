import AppKit
import SwiftUI

/// Status-item bootstrap rather than SwiftUI's `MenuBarExtra`: a SwiftPM
/// executable is not a bundle at build time, and driving `NSStatusItem`
/// directly keeps the app working whether or not it has been bundled yet.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    /// The way back in when the status item is not in the menu bar. Held rather
    /// than rebuilt so reopening twice does not stack windows.
    private var settingsWindow: NSWindow?
    /// The pending re-check for a status item macOS is not currently showing.
    /// Held so a stale chain can be cancelled rather than left to run alongside
    /// a newer one.
    private var statusItemRetry: Task<Void, Never>?
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

    /// Opening the app while it is already running puts its settings — and its
    /// Quit button — on screen.
    ///
    /// Without this the app can become unreachable. macOS drops status items it
    /// has no room for rather than shrinking the bar, and a crowded menu bar on
    /// a notched display reaches that point easily. An accessory app whose item
    /// was dropped has no window, no Dock tile and no menu, so there is nothing
    /// left to click — while it goes on adjusting brightness and holding a
    /// screen-recording session. Reopening is the one gesture macOS still
    /// routes to a running accessory app, so it has to lead somewhere.
    ///
    /// A window rather than the popover, because the popover is anchored to the
    /// status item, and the case this exists for is the status item not being
    /// there to anchor to.
    func applicationShouldHandleReopen(
        _ sender: NSApplication,
        hasVisibleWindows: Bool
    ) -> Bool {
        if settingsWindow == nil {
            let hosting = NSHostingController(rootView: SettingsView(model: model))
            hosting.sizingOptions = .preferredContentSize
            let window = NSWindow(contentViewController: hosting)
            window.title = "Auto Brightness"
            window.styleMask = [.titled, .closable]
            // Closing it must not deallocate it: this object holds the only
            // reference, and an over-release would take the app down on the
            // second close.
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        // Not `model.quit()`: that would call `terminate(_:)` again, which
        // AppKit is already in the middle of. `prepareForTermination()` only
        // restores the baseline (idempotently, so the Quit-button path that
        // already restored it is a no-op here), covering termination paths
        // that never went through `quit()` at all — logout, Activity Monitor.
        model.prepareForTermination()
    }

    /// Shows the app glyph and the main display's brightness as a percentage.
    /// The glyph is hidden when the user turns it off, and the percentage is
    /// dropped when no display's brightness can be read.
    /// `withObservationTracking` fires once per change, so each update re-arms
    /// it.
    ///
    /// Nothing here may return without leaving exactly one thing pending — an
    /// observation or a retry. This is the only thing that schedules the next
    /// update, so a path that leaves none freezes the status item on whatever
    /// it last showed, permanently rather than until the next change; and a
    /// path that leaves two makes the pending updates accumulate for as long
    /// as that path keeps being taken.
    private func updateStatusItem() {
        // A status item has no button while macOS is not showing it — evicted
        // for want of menu-bar room, for one. Retrying rather than giving up is
        // what lets the item come back when the room does; observation would
        // not, since eviction is not a model change. Deliberately without
        // arming the observation as well: that is the second pending update
        // the note above rules out.
        guard let button = statusItem?.button else {
            // An observation armed before the item went away can land here too,
            // so this replaces the pending retry rather than adding to it.
            statusItemRetry?.cancel()
            statusItemRetry = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .seconds(2))
                self?.updateStatusItem()
            }
            return
        }
        // Reaching the button means any retry chain has served its purpose.
        statusItemRetry?.cancel()
        statusItemRetry = nil
        let (brightness, showsIcon) = withObservationTracking {
            (model.menuBarBrightness, model.showsMenuBarIcon)
        } onChange: {
            Task { @MainActor [weak self] in
                self?.updateStatusItem()
            }
        }
        // The glyph is unconditional when there is no percentage: a status item
        // with neither image nor title collapses to nothing the user can click.
        button.image = (showsIcon || brightness == nil) ? makeStatusGlyph() : nil
        button.title = brightness.map { "\(Int(($0 * 100).rounded()))%" } ?? ""
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
