import AppKit
import Foundation

/// Watches for the conditions under which adjusting brightness is pointless or
/// unwelcome: the display asleep, the screen locked, the machine suspended.
@MainActor
public final class PauseMonitor {
    private let onSuspend: @MainActor () -> Void
    private let onResume: @MainActor () -> Void

    public init(
        onSuspend: @escaping @MainActor () -> Void,
        onResume: @escaping @MainActor () -> Void
    ) {
        self.onSuspend = onSuspend
        self.onResume = onResume
    }

    public func start() {
        let workspace = NSWorkspace.shared.notificationCenter
        workspace.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend() }
        }
        workspace.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume() }
        }
        workspace.addObserver(
            forName: NSWorkspace.screensDidSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend() }
        }
        workspace.addObserver(
            forName: NSWorkspace.screensDidWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume() }
        }

        // Screen lock is only published on the distributed centre.
        let distributed = DistributedNotificationCenter.default()
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsLocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onSuspend() }
        }
        distributed.addObserver(
            forName: Notification.Name("com.apple.screenIsUnlocked"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onResume() }
        }
    }
}
