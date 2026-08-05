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
            do {
                if launchAtLogin {
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("launch at login failed: \(error.localizedDescription)")
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
        ])

        var settings = ControllerSettings.defaults
        settings.strength = defaults.double(forKey: "strength")
        settings.maxOffset = defaults.double(forKey: "maxOffset")

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
                self?.refreshReadouts()
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
        isManuallyPaused = true
        pausedUntilLabel = Self.timeFormatter.string(
            from: Date().addingTimeInterval(3600)
        )
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
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntilLabel = nil
        applyRunState()
    }

    /// The single place that decides whether the app is watching the screen and
    /// whether it is adjusting. Every input — the toggle, a manual pause, system
    /// sleep, sampler health — funnels through here, so the two can never
    /// disagree (capturing while disabled, or adjusting on a frozen measurement).
    private func applyRunState() {
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

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        return formatter
    }()
}
