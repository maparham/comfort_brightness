import AppKit
import AutoBrightnessCore
import CoreGraphics
import Foundation
import Observation
import ServiceManagement

/// Binds the displays to the pause monitor and the UI.
///
/// Decides *whether* the app should be adjusting — the toggle, a manual pause,
/// system sleep — and hands that to every display; each `DisplayUnit` works
/// out what it means for its own display.
@MainActor
@Observable
public final class AppModel {
    let displays = DisplayManager()
    private var pauseMonitor: PauseMonitor?
    private var powerSourceMonitor: PowerSourceMonitor?
    private var pauseTimer: Timer?
    /// Keeps the brightness readouts honest while nothing else is ticking:
    /// paused, disabled, or sampler down, the user can still change brightness
    /// with the hardware keys or the monitor's buttons, and the readout must
    /// follow.
    private var readoutTimer: Timer?
    /// True while the system has told us adjusting is pointless: display asleep,
    /// screen locked, machine suspended.
    private var isSystemPaused = false
    /// Watches for displays arriving and leaving. Unconditional: when nothing
    /// is adjustable, nothing else is running to notice a display appearing.
    private var displayObserver: (any NSObjectProtocol)?
    /// True while a user-requested "pause for 1 hour" is in effect. This is
    /// tracked separately from each coordinator's `isPaused` because system
    /// sleep/wake and the `isEnabled` toggle also drive `suspend()`/`resume()`
    /// — without this flag, a system wake or a disable/re-enable would silently
    /// cancel a manual pause early.
    private var isManuallyPaused = false
    /// When the manual pause is due to end. The `Timer` alone cannot be trusted
    /// with this: it does not fire while the machine is asleep and comes back
    /// late by however long the sleep lasted, so a pause taken at 14:00 and
    /// labelled "until 15:00" would really run to 18:00 after a three-hour lid
    /// close. The deadline is the truth; the timer only saves us from polling
    /// when nothing interrupts it.
    private var pauseDeadline: Date?
    /// Suppresses the `launchAtLogin` `didSet` while it is reverting itself
    /// after a failed registration.
    private var isRevertingLaunchAtLogin = false
    /// Guards the restore-and-terminate sequence so it runs exactly once
    /// whether it is entered via the Quit button or via
    /// `applicationWillTerminate` (logout, Activity Monitor, etc).
    private var hasRestoredBaseline = false

    public private(set) var pausedUntilLabel: String?
    /// Set when registering or unregistering the login item failed, so the UI
    /// can say so rather than leave a switch showing a state that was never
    /// achieved.
    public private(set) var launchAtLoginError: String?
    /// True while the macOS brightness service is not answering. Mirrors
    /// `BrightnessService.gate` on the main actor, for the UI.
    public private(set) var isBrightnessServiceStuck = false
    public private(set) var isRestartingBrightnessService = false
    /// Why the last restart did not help, shown until the service recovers.
    public private(set) var brightnessServiceError: String?
    /// Asks the app delegate to put the settings on screen.
    @ObservationIgnored var onShowSettings: (() -> Void)?
    @ObservationIgnored private let serviceNotifier = BrightnessServiceNotifier()

    var units: [DisplayUnit] { displays.units }
    var otherDisplays: [DisplayManager.OtherDisplay] { displays.others }
    var hasAdjustableDisplay: Bool { !displays.units.isEmpty }
    var isCheckingDisplays: Bool {
        displays.others.contains { $0.note == DisplayManager.Note.checking }
    }
    /// One grant covers every display, so it is asked for once, not per row.
    var needsScreenRecordingPermission: Bool {
        displays.units.contains { $0.status == .permissionDenied }
    }
    /// The menu bar sits on the main display, so that is the one it reports;
    /// failing that, the first adjustable display; failing that, nothing, and
    /// the status item shows its glyph alone.
    var menuBarBrightness: Double? {
        let main = CGMainDisplayID()
        let unit = displays.units.first { $0.displayID == main } ?? displays.units.first
        return unit?.displayBrightness
    }

    public var isEnabled: Bool {
        didSet {
            for unit in displays.units { unit.isEnabled = isEnabled }
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            applyRunState()
        }
    }

    public var strength: Double {
        didSet {
            applyTuning()
            UserDefaults.standard.set(strength, forKey: "strength")
        }
    }

    public var maxOffset: Double {
        didSet {
            applyTuning()
            UserDefaults.standard.set(maxOffset, forKey: "maxOffset")
        }
    }

    public var responseSeconds: Double {
        didSet {
            applyTuning()
            UserDefaults.standard.set(responseSeconds, forKey: "responseSeconds")
        }
    }

    /// True when the three tuning sliders already sit at the values the app
    /// ships with, so the reset button can show there is nothing to undo rather
    /// than looking like a button that did nothing.
    public var isAtDefaultTuning: Bool {
        strength == ControllerSettings.defaults.strength
            && maxOffset == ControllerSettings.defaults.maxOffset
            && responseSeconds == ControllerSettings.defaults.responseSeconds
    }

    /// Puts the tuning sliders back to what the app ships with. Each property's
    /// `didSet` carries the value through to every display's coordinator and to
    /// `UserDefaults`, so there is nothing else to keep in step here.
    ///
    /// The toggles are deliberately left alone. Enabling, the menu bar icon and
    /// the login item are states the user chose rather than tuning they would
    /// want undone, and the last of the three registers with the system —
    /// unregistering it from a button labelled "reset" would reach outside the
    /// app for something the user did not ask to change.
    public func resetTuning() {
        strength = ControllerSettings.defaults.strength
        maxOffset = ControllerSettings.defaults.maxOffset
        responseSeconds = ControllerSettings.defaults.responseSeconds
    }

    /// Whether the menu bar shows the app's glyph next to the brightness
    /// percentage. Hiding it leaves the percentage alone as the click target;
    /// `updateStatusItem` shows the glyph anyway when there is no percentage to
    /// show, so the status item can never end up empty and unclickable.
    public var showsMenuBarIcon: Bool {
        didSet {
            UserDefaults.standard.set(showsMenuBarIcon, forKey: "showsMenuBarIcon")
        }
    }

    public var launchAtLogin: Bool {
        didSet {
            // The revert below assigns to this property; without the guard it
            // would re-enter and try to register all over again.
            guard !isRevertingLaunchAtLogin else { return }
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
                launchAtLoginError = nil
            } catch {
                NSLog("launch at login failed: \(error.localizedDescription)")
                // Registration genuinely fails when the app is not in a
                // launchable location. Leaving the switch on would claim
                // something that never happened, so put it back where the
                // system says it actually is.
                launchAtLoginError = error.localizedDescription
                isRevertingLaunchAtLogin = true
                launchAtLogin = SMAppService.mainApp.status == .enabled
                isRevertingLaunchAtLogin = false
            }
        }
    }

    /// The tuning every display runs with, kept in one place so a display that
    /// appears later starts from the same values as the rest.
    private var tuning: ControllerSettings {
        var settings = ControllerSettings.defaults
        settings.strength = strength
        settings.maxOffset = maxOffset
        settings.responseSeconds = responseSeconds
        return settings
    }

    private var userWantsIt: Bool { isEnabled && !isManuallyPaused && !isSystemPaused }

    public init() {
        let defaults = UserDefaults.standard
        defaults.register(defaults: [
            "isEnabled": true,
            "showsMenuBarIcon": true,
            "strength": ControllerSettings.defaults.strength,
            "maxOffset": ControllerSettings.defaults.maxOffset,
            "responseSeconds": ControllerSettings.defaults.responseSeconds,
        ])

        // Clamped, not trusted: the sliders bound what a user can choose, but a
        // value carried over from an older build or edited by hand is not
        // bounded by anything, and an out-of-range strength would drive the
        // control law well past what was ever tuned for.
        isEnabled = defaults.bool(forKey: "isEnabled")
        showsMenuBarIcon = defaults.bool(forKey: "showsMenuBarIcon")
        strength = Self.strengthRange.clamping(defaults.double(forKey: "strength"))
        maxOffset = Self.maxOffsetRange.clamping(defaults.double(forKey: "maxOffset"))
        responseSeconds = Self.responseSecondsRange.clamping(defaults.double(forKey: "responseSeconds"))
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    public func start() {
        displays.onUnitAdded = { [weak self] unit in self?.configure(unit) }

        // Installed before anything first reaches the service, so a daemon
        // already stuck at launch is reported like one that gets stuck later.
        BrightnessService.gate.onStuckChange = { [weak self] _ in
            Task { @MainActor in self?.syncBrightnessServiceState() }
        }
        serviceNotifier.onOpen = { [weak self] in self?.onShowSettings?() }
        serviceNotifier.start()
        BrightnessService.probe()

        let monitor = PauseMonitor(
            onSuspend: { [weak self] in
                self?.isSystemPaused = true
                self?.applyRunState()
            },
            onResume: { [weak self] in
                // Waking is when the daemon has been seen to get stuck.
                BrightnessService.probe()
                self?.isSystemPaused = false
                self?.displays.noteWake()
                self?.applyRunState()
            }
        )
        monitor.start()
        pauseMonitor = monitor

        let powerMonitor = PowerSourceMonitor(onChange: { [weak self] in
            self?.displays.units.forEach { $0.notePowerSourceChange() }
        })
        powerMonitor.start()
        powerSourceMonitor = powerMonitor

        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.displays.reconcile()
                self?.applyRunState()
            }
        }

        readoutTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Also the backstop for an expired pause, for the wake that
                // arrives without a notification we observe.
                guard !self.endPauseIfExpired() else { return }
                self.refreshReadouts()
            }
        }

        displays.reconcile()
        applyRunState()
    }

    /// Takes the gate's state as it is now rather than as the notification
    /// said it was. Notifications from different threads can reach the main
    /// actor out of order, and the gate is the one source of truth.
    private func syncBrightnessServiceState() {
        let stuck = BrightnessService.gate.isStuck
        guard stuck != isBrightnessServiceStuck else { return }
        isBrightnessServiceStuck = stuck
        serviceNotifier.update(isStuck: stuck)
        if !stuck {
            brightnessServiceError = nil
            // A built-in panel that turned up while the service was stuck was
            // noted as such rather than driven. Look at every display afresh.
            displays.reconcile()
        }
        // Each display re-reads whether it can be controlled: units driven by
        // the service stop adjusting while it is stuck, and resume after.
        applyRunState()
    }

    /// Restarts the macOS brightness service, behind an administrator
    /// password prompt. Recovery itself is noticed by the gate, when the call
    /// it was waiting on fails along with the old daemon.
    public func restartBrightnessService() {
        guard !isRestartingBrightnessService else { return }
        isRestartingBrightnessService = true
        brightnessServiceError = nil
        Task {
            defer { isRestartingBrightnessService = false }
            switch await BrightnessService.restart() {
            case .restarted:
                // Give launchd a moment to bring the new daemon up, then ask
                // it something, in case it came up stuck as well.
                try? await Task.sleep(for: .seconds(2))
                BrightnessService.probe()
                try? await Task.sleep(for: .seconds(2))
                if BrightnessService.gate.isStuck {
                    brightnessServiceError =
                        "The brightness service still isn't responding. Restarting your Mac will clear it."
                }
            case .cancelled:
                break
            case .failed(let message):
                brightnessServiceError = "Couldn't restart the brightness service: \(message)"
            }
        }
    }

    /// Re-attempts capture on every display, for the case where the user has
    /// just granted Screen Recording permission.
    public func retrySampling() {
        displays.units.forEach { $0.retry() }
    }

    /// Stops adjusting for an hour, then resumes on its own.
    public func pauseForAnHour() {
        let deadline = Date().addingTimeInterval(3600)
        isManuallyPaused = true
        pauseDeadline = deadline
        pausedUntilLabel = Self.timeFormatter.string(from: deadline)
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.endPause()
            }
        }
        applyRunState()
    }

    public func endPause() {
        isManuallyPaused = false
        pauseDeadline = nil
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntilLabel = nil
        applyRunState()
    }

    /// Ends a manual pause whose deadline has already passed, which is what
    /// covers the case the timer cannot: it does not run while the machine is
    /// asleep. Returns true when it ended one — `endPause` re-applies the run
    /// state itself, so the caller has nothing left to do.
    @discardableResult
    private func endPauseIfExpired() -> Bool {
        guard let pauseDeadline, Date() >= pauseDeadline else { return false }
        endPause()
        return true
    }

    /// The single place that decides whether the app is watching and adjusting.
    /// Every input — the toggle, a manual pause, system sleep — funnels through
    /// here, and each display applies the answer to itself.
    private func applyRunState() {
        // Waking from sleep lands here, and it is the one moment an expired
        // pause is most likely to be sitting unnoticed. `endPause` re-enters
        // this method with the deadline already cleared, so this cannot loop.
        if endPauseIfExpired() { return }
        for unit in displays.units { unit.apply(userWantsIt: userWantsIt) }
    }

    private func configure(_ unit: DisplayUnit) {
        unit.settings = tuning
        unit.isEnabled = isEnabled
        unit.apply(userWantsIt: userWantsIt)
    }

    private func applyTuning() {
        for unit in displays.units { unit.settings = tuning }
    }

    public func quit() {
        restoreBaselineOnce()
        NSApplication.shared.terminate(nil)
    }

    /// Called from `applicationWillTerminate`, which fires both when the user
    /// quits normally (after `quit()` already restored the baseline) and when
    /// the process is terminated some other way (logout, Activity Monitor).
    /// Restoring here too, behind the same guard, covers that second case
    /// without double-restoring or re-entering `terminate(_:)`.
    public func prepareForTermination() {
        restoreBaselineOnce()
    }

    private func restoreBaselineOnce() {
        guard !hasRestoredBaseline else { return }
        hasRestoredBaseline = true
        // Every display is put back and every DDC write started before any is
        // waited on, so several monitors share one deadline rather than
        // queueing behind each other.
        for unit in displays.units { unit.restoreForTermination() }
        let deadline = DispatchTime.now() + 0.5
        for unit in displays.units { unit.waitForTermination(deadline: deadline) }
    }

    private func refreshReadouts() {
        displays.units.forEach { $0.refreshReadouts() }
    }

    /// The ranges the sliders offer and the only ranges the stored settings are
    /// allowed to take. Declared here rather than in the view so the bound and
    /// the clamp cannot drift apart.
    public static let strengthRange: ClosedRange<Double> = 0.2...0.9
    public static let maxOffsetRange: ClosedRange<Double> = 0.05...0.35
    public static let responseSecondsRange: ClosedRange<Double> = 1.0...8.0

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}

private extension ClosedRange where Bound == Double {
    func clamping(_ value: Double) -> Double {
        Swift.min(Swift.max(value, lowerBound), upperBound)
    }
}
