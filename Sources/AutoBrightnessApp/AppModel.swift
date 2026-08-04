import AppKit
import AutoBrightnessCore
import Foundation
import Observation
import ServiceManagement

/// Binds the core coordinator to the sampler, the pause monitor, and the UI.
@MainActor
@Observable
public final class AppModel {
    private let coordinator: Coordinator
    private var sampler: ScreenSampler?
    private var pauseMonitor: PauseMonitor?
    private var pauseTimer: Timer?

    public var status: SamplerStatus = .idle
    public private(set) var luminance: Double = 0.5
    public private(set) var offset: Double = 0
    public private(set) var baseline: Double = 0.5
    public private(set) var pausedUntilLabel: String?
    public let canControlBrightness: Bool

    public var isEnabled: Bool {
        didSet {
            coordinator.isEnabled = isEnabled
            UserDefaults.standard.set(isEnabled, forKey: "isEnabled")
            refreshReadouts()
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
            "strength": ControllerSettings.defaults.strength,
            "maxOffset": ControllerSettings.defaults.maxOffset,
        ])

        var settings = ControllerSettings.defaults
        settings.strength = defaults.double(forKey: "strength")
        settings.maxOffset = defaults.double(forKey: "maxOffset")

        let brightness = DisplayServicesBrightness()
        canControlBrightness = brightness.canControl
        coordinator = Coordinator(brightness: brightness, settings: settings)

        isEnabled = defaults.bool(forKey: "isEnabled")
        strength = settings.strength
        maxOffset = settings.maxOffset
        launchAtLogin = SMAppService.mainApp.status == .enabled

        coordinator.isEnabled = isEnabled
        baseline = coordinator.baseline
    }

    public func start() async {
        let monitor = PauseMonitor(
            onSuspend: { [weak self] in self?.coordinator.suspend() },
            onResume: { [weak self] in self?.coordinator.resume() }
        )
        monitor.start()
        pauseMonitor = monitor

        let sampler = ScreenSampler(
            onFrame: { [weak self] frame in
                guard let self else { return }
                let value = LuminanceAnalyzer.analyze(frame)
                self.coordinator.tick(luminance: value)
                self.refreshReadouts()
            },
            onStatus: { [weak self] status in
                self?.status = status
            }
        )
        self.sampler = sampler
        await sampler.start()
    }

    /// Stops adjusting for an hour, then resumes on its own.
    public func pauseForAnHour() {
        coordinator.suspend()
        pausedUntilLabel = Self.timeFormatter.string(
            from: Date().addingTimeInterval(3600)
        )
        pauseTimer?.invalidate()
        pauseTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.coordinator.resume()
                self?.pausedUntilLabel = nil
            }
        }
    }

    public func endPause() {
        pauseTimer?.invalidate()
        pauseTimer = nil
        pausedUntilLabel = nil
        coordinator.resume()
    }

    public func quit() {
        coordinator.restoreBaseline()
        NSApplication.shared.terminate(nil)
    }

    private func refreshReadouts() {
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
