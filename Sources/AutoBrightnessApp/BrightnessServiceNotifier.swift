import AppKit
import UserNotifications

/// Says, outside the popover, that the macOS brightness service is stuck.
/// The user will most likely meet the problem as brightness keys that do
/// nothing, not by opening this app, so the app has to come to them.
@MainActor
final class BrightnessServiceNotifier: NSObject, UNUserNotificationCenterDelegate {
    /// Called when the user clicks the notification.
    var onOpen: (() -> Void)?

    private var pendingPost: Task<Void, Never>?
    private static let identifier = "brightness-service-stuck"
    /// The service is reported in the popover and the menu bar at once. The
    /// notification waits this long so that a daemon merely slow to answer
    /// right after wake, which clears itself, never interrupts anyone.
    private static let delay: Duration = .seconds(10)

    /// The notification center raises an exception in a process that is not
    /// an app bundle, which is what `swift run` produces.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleURL.pathExtension == "app" ? .current() : nil
    }

    func update(isStuck: Bool) {
        pendingPost?.cancel()
        pendingPost = nil
        guard let center else { return }
        if isStuck {
            pendingPost = Task { [weak self] in
                try? await Task.sleep(for: Self.delay)
                guard !Task.isCancelled else { return }
                await self?.post()
            }
        } else {
            center.removeDeliveredNotifications(withIdentifiers: [Self.identifier])
        }
    }

    private func post() async {
        guard let center else { return }
        center.delegate = self
        // Asked here rather than at launch: most people never see this
        // notification, and should not be asked to allow one they never get.
        guard (try? await center.requestAuthorization(options: [.alert])) == true else { return }
        let content = UNMutableNotificationContent()
        content.title = "Brightness controls stopped working"
        content.body = "The macOS brightness service isn't responding. Click to restart it."
        let request = UNNotificationRequest(identifier: Self.identifier, content: content, trigger: nil)
        try? await center.add(request)
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        await MainActor.run { onOpen?() }
    }

    /// Shown even while the app is active: an accessory app counts as active
    /// whenever its popover is open.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner]
    }
}
