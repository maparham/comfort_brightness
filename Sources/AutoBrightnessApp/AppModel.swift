import AppKit
import AutoBrightnessCore
import Foundation
import Observation
import ServiceManagement

/// Binds the core coordinator to the sampler, the pause monitor, and the UI.
@MainActor
@Observable
public final class AppModel {
    private let brightness: RampingBrightness
    private let coordinator: Coordinator
    private var sampler: ScreenSampler?
    private var pauseMonitor: PauseMonitor?
    private var pauseTimer: Timer?
    /// Keeps the brightness readout honest while nothing else is ticking:
    /// paused, disabled, or sampler down, the user can still change brightness
    /// with the hardware keys, and the readout must follow.
    private var readoutTimer: Timer?
    /// True while the system has told us adjusting is pointless: display asleep,
    /// screen locked, machine suspended.
    private var isSystemPaused = false
    /// What we last asked the sampler to do, so `applyRunState` does not thrash
    /// it — the sampler reports status changes, which lands us back here.
    private var isSamplingRequested = false
    /// The last start/stop handed to the sampler. Each new one waits for it, so
    /// that flipping the toggle twice quickly cannot run the stop before the
    /// start it was meant to undo — unstructured tasks have no ordering of their
    /// own, and that ordering is the difference between the capture stopping and
    /// the screen-recording indicator staying lit indefinitely.
    private var samplerTask: Task<Void, Never>?
    /// Watches for displays arriving and leaving, so that a lid opened in
    /// clamshell mode is noticed. This is deliberately independent of the
    /// sampler's own observer: when brightness control is unavailable the
    /// sampler is stopped and its observer is gone, which is exactly the state
    /// this has to recover from.
    private var displayObserver: (any NSObjectProtocol)?
    /// True while a user-requested "pause for 1 hour" is in effect. This is
    /// tracked separately from `Coordinator.isPaused` because system sleep/wake
    /// and the `isEnabled` toggle also drive `Coordinator.suspend()`/`resume()`
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

    public private(set) var status: SamplerStatus = .idle
    /// The panel's actual brightness as last read, or nil when unreadable.
    public private(set) var displayBrightness: Double?
    public private(set) var luminance: Double = 0.5
    public private(set) var offset: Double = 0
    public private(set) var baseline: Double = 0.5
    public private(set) var pausedUntilLabel: String?
    public private(set) var canControlBrightness: Bool
    /// Set when registering or unregistering the login item failed, so the UI
    /// can say so rather than leave a switch showing a state that was never
    /// achieved.
    public private(set) var launchAtLoginError: String?

    public var isEnabled: Bool {
        didSet {
            coordinator.isEnabled = isEnabled
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            applyRunState()
        }
    }

    public var strength: Double {
        didSet {
            coordinator.settings.strength = strength
            UserDefaults.standard.set(strength, forKey: "strength")
        }
    }

    public var maxOffset: Double {
        didSet {
            coordinator.settings.maxOffset = maxOffset
            UserDefaults.standard.set(maxOffset, forKey: "maxOffset")
        }
    }

    public var responseSeconds: Double {
        didSet {
            coordinator.settings.responseSeconds = responseSeconds
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
    /// `didSet` carries the value through to the coordinator and to
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
        var settings = ControllerSettings.defaults
        settings.strength = Self.strengthRange.clamping(defaults.double(forKey: "strength"))
        settings.maxOffset = Self.maxOffsetRange.clamping(defaults.double(forKey: "maxOffset"))
        settings.responseSeconds = Self.responseSecondsRange.clamping(
            defaults.double(forKey: "responseSeconds")
        )

        let brightness = RampingBrightness(
            wrapping: DisplayServicesBrightness(),
            scheduler: TimerRampScheduler()
        )
        self.brightness = brightness
        canControlBrightness = brightness.canControl
        coordinator = Coordinator(brightness: brightness, settings: settings)

        isEnabled = defaults.bool(forKey: "isEnabled")
        showsMenuBarIcon = defaults.bool(forKey: "showsMenuBarIcon")
        strength = settings.strength
        maxOffset = settings.maxOffset
        responseSeconds = settings.responseSeconds
        launchAtLogin = SMAppService.mainApp.status == .enabled

        coordinator.isEnabled = isEnabled
        baseline = coordinator.baseline
    }

    public func start() {
        let monitor = PauseMonitor(
            onSuspend: { [weak self] in
                self?.isSystemPaused = true
                self?.applyRunState()
            },
            onResume: { [weak self] in
                self?.isSystemPaused = false
                self?.applyRunState()
            }
        )
        monitor.start()
        pauseMonitor = monitor

        sampler = ScreenSampler(
            onFrame: { [weak self] frame in
                guard let self else { return }
                let value = LuminanceAnalyzer.analyze(frame)
                self.coordinator.tick(luminance: value)
                self.refreshReadouts()
            },
            onStatus: { [weak self] status in
                guard let self else { return }
                self.status = status
                // A stream that has stopped or stalled delivers no more ticks, so
                // the offset it left behind would never be unwound. Treat it like
                // any other pause: hand the panel back to the user's baseline
                // until frames are flowing again.
                self.applyRunState()
            }
        )

        // Unconditional on purpose. Plugging in a display, unplugging one, or
        // opening the lid changes whether there is a built-in panel to control
        // at all, and when there is not, nothing else in the app is running to
        // notice that one has appeared.
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
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

        applyRunState()
    }

    /// Re-attempts capture, for the case where the user has just granted Screen
    /// Recording permission.
    public func retrySampling() {
        guard let sampler else { return }
        Task { await sampler.retry() }
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

    /// The single place that decides whether the app is watching the screen and
    /// whether it is adjusting. Every input — the toggle, a manual pause, system
    /// sleep, sampler health — funnels through here, so the two can never
    /// disagree (capturing while disabled, or adjusting on a frozen measurement).
    private func applyRunState() {
        // Waking from sleep lands here, and it is the one moment an expired
        // pause is most likely to be sitting unnoticed. `endPause` re-enters
        // this method with the deadline already cleared, so this cannot loop.
        if endPauseIfExpired() { return }
        canControlBrightness = brightness.canControl
        let userWantsIt = isEnabled && !isManuallyPaused && !isSystemPaused

        // Capture only while the app would actually act on a frame. A user who
        // turns this off expects the screen-recording indicator to go out.
        let shouldSample = userWantsIt && canControlBrightness
        if shouldSample != isSamplingRequested, let sampler {
            isSamplingRequested = shouldSample
            let previous = samplerTask
            samplerTask = Task {
                await previous?.value
                shouldSample ? await sampler.start() : await sampler.stop()
            }
        }

        if userWantsIt && status == .running {
            if coordinator.isPaused {
                coordinator.resume()
            }
        } else {
            coordinator.suspend()
        }
        refreshReadouts()
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
        coordinator.restoreBaseline()
        // The restore write itself starts a glide; landing it synchronously is
        // what keeps process exit from stranding the panel mid-ramp.
        brightness.flush()
    }

    private func refreshReadouts() {
        displayBrightness = brightness.read()
        luminance = coordinator.lastLuminance
        offset = coordinator.appliedOffset
        baseline = coordinator.baseline
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
