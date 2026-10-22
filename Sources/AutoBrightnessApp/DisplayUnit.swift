import AutoBrightnessCore
import CoreGraphics
import Foundation
import Observation

/// One display's whole pipeline: capture, the control loop, and the backend
/// that moves its brightness.
///
/// `AppModel` decides *whether* the app should be adjusting at all. Each unit
/// works out what that means for its own display, by the same rules the app
/// applied when it had only one: sample only while wanted and controllable,
/// and adjust only while frames are actually arriving.
@MainActor
@Observable
final class DisplayUnit {
    enum Backend {
        /// The built-in panel and Apple externals. Glides on the main run loop.
        case displayServices(RampingBrightness)
        /// Third-party monitors. Glides on the DDC queue.
        case ddc(DDCBrightness, DDCQueueLink)
    }

    let displayID: CGDirectDisplayID
    let name: String
    let isBuiltin: Bool

    private(set) var status: SamplerStatus = .idle
    /// False while a DDC monitor is not answering. Always true otherwise.
    private(set) var isResponding = true
    private(set) var displayBrightness: Double?
    private(set) var luminance = 0.5
    private(set) var offset = 0.0
    private(set) var baseline = 0.5

    /// Called when the backend finds the display cannot be driven at all, so
    /// the manager can retire the unit and say why.
    @ObservationIgnored var onUnusable: (() -> Void)?

    @ObservationIgnored private let backend: Backend
    @ObservationIgnored private let control: BrightnessControlling
    @ObservationIgnored private let coordinator: Coordinator
    @ObservationIgnored private var sampler: ScreenSampler?
    @ObservationIgnored private var userWantsIt = false
    /// See `AppModel`'s former `isSamplingRequested`: what we last asked the
    /// sampler to do, so status reports landing back here do not thrash it.
    @ObservationIgnored private var isSamplingRequested = false
    /// Each start/stop waits for the previous one, so two quick flips cannot
    /// run out of order and leave the capture indicator lit.
    @ObservationIgnored private var samplerTask: Task<Void, Never>?

    init(displayID: CGDirectDisplayID, name: String, backend: Backend) {
        self.displayID = displayID
        self.name = name
        isBuiltin = CGDisplayIsBuiltin(displayID) != 0
        self.backend = backend
        let control: BrightnessControlling
        switch backend {
        case .displayServices(let ramping): control = ramping
        case .ddc(let ddc, _): control = ddc
        }
        self.control = control
        coordinator = Coordinator(brightness: control)
        baseline = coordinator.baseline

        sampler = ScreenSampler(
            displayID: displayID,
            onFrame: { [weak self] frame in
                guard let self else { return }
                self.coordinator.tick(luminance: LuminanceAnalyzer.analyze(frame))
                self.refreshReadouts()
            },
            onStatus: { [weak self] status in
                guard let self else { return }
                self.status = status
                // A stream that has stopped or stalled delivers no more ticks,
                // so the offset it left behind would never be unwound.
                self.apply(userWantsIt: self.userWantsIt)
            }
        )

        if case .ddc(let ddc, _) = backend {
            ddc.onControlChange = { [weak self] in self?.controlChanged() }
        }
    }

    var usesDDC: Bool {
        if case .ddc = backend { true } else { false }
    }

    var settings: ControllerSettings {
        get { coordinator.settings }
        set { coordinator.settings = newValue }
    }

    var isEnabled: Bool {
        get { coordinator.isEnabled }
        set { coordinator.isEnabled = newValue }
    }

    func apply(userWantsIt: Bool) {
        self.userWantsIt = userWantsIt
        let controllable = control.canControl && isResponding
        let shouldSample = userWantsIt && controllable
        if shouldSample != isSamplingRequested, let sampler {
            isSamplingRequested = shouldSample
            let previous = samplerTask
            samplerTask = Task {
                await previous?.value
                shouldSample ? await sampler.start() : await sampler.stop()
            }
        }
        if shouldSample && status == .running {
            if coordinator.isPaused { coordinator.resume() }
        } else {
            coordinator.suspend()
        }
        refreshReadouts()
    }

    /// Only the built-in panel is dimmed by the OS on a power-source change.
    func notePowerSourceChange() {
        guard isBuiltin else { return }
        coordinator.notePowerSourceChange()
    }

    func retry() {
        guard let sampler else { return }
        Task { await sampler.retry() }
    }

    func replaceTransport(_ transport: IOAVServiceTransport) {
        guard case .ddc(_, let link) = backend else { return }
        link.replaceTransport(transport)
    }

    func refreshReadouts() {
        displayBrightness = control.read()
        luminance = coordinator.lastLuminance
        offset = coordinator.appliedOffset
        baseline = coordinator.baseline
    }

    /// The display has gone, or has been given up on.
    func tearDown() {
        userWantsIt = false
        if let sampler {
            isSamplingRequested = false
            let previous = samplerTask
            samplerTask = Task {
                await previous?.value
                await sampler.stop()
            }
        }
        coordinator.restoreBaseline()
        switch backend {
        case .displayServices(let ramping): ramping.flush()
        case .ddc(let ddc, _): ddc.invalidate()
        }
    }

    /// First half of quitting: put the display back and start any DDC write
    /// on its way. The second half waits, for all DDC displays at once.
    func restoreForTermination() {
        coordinator.restoreBaseline()
        switch backend {
        case .displayServices(let ramping): ramping.flush()
        case .ddc(let ddc, _): ddc.startFlush()
        }
    }

    func waitForTermination(deadline: DispatchTime) {
        guard case .ddc(let ddc, _) = backend else { return }
        ddc.waitForFlush(deadline: deadline)
    }

    private func controlChanged() {
        guard case .ddc(let ddc, _) = backend else { return }
        isResponding = ddc.isResponding
        guard ddc.canControl else {
            onUnusable?()
            return
        }
        apply(userWantsIt: userWantsIt)
    }
}
