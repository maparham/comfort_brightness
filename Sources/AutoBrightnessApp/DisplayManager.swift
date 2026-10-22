import AutoBrightnessCore
import CoreGraphics
import Foundation
import Observation

/// Keeps one `DisplayUnit` per adjustable display, and a note for every
/// display that is not adjustable, in step with the displays actually
/// connected.
@MainActor
@Observable
final class DisplayManager {
    struct OtherDisplay: Identifiable, Equatable {
        let id: CGDirectDisplayID
        let name: String
        let note: String
    }

    enum Note {
        static let checking = "Checking…"
        static let noService = "No DDC connection"
        static let ambiguous = "Can't tell which connection is this display"
        static let noResponse = "Didn't respond to DDC"
        static let unwritable = "Doesn't accept brightness changes"
        static let unavailable = "DDC isn't available on this Mac"
        static let fixed = "Brightness can't be changed"
    }

    /// Built-in first, then by display ID, so rows do not jump around.
    private(set) var units: [DisplayUnit] = []
    private(set) var others: [OtherDisplay] = []

    /// Lets `AppModel` hand a new unit the current settings and run state.
    @ObservationIgnored var onUnitAdded: ((DisplayUnit) -> Void)?

    /// Bumped by every reconcile. A probe started under an older generation
    /// is about a display set that no longer exists, and must not add a unit.
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var retries: [CGDirectDisplayID: Task<Void, Never>] = [:]
    @ObservationIgnored private var retryAttempts: [CGDirectDisplayID: Int] = [:]
    /// A monitor still waking up at login answers a few seconds later; one
    /// that never answers is tried once a minute rather than given up on.
    static let retryDelays: [Double] = [5, 10, 20, 60]

    func reconcile() {
        generation += 1
        let active = DisplayRegistry.activeDisplayIDs()
        for unit in units where !active.contains(unit.displayID) { unit.tearDown() }
        units.removeAll { !active.contains($0.displayID) }
        retries.values.forEach { $0.cancel() }
        retries = [:]
        retryAttempts = [:]
        // Everything not being driven is worked out again from scratch: a
        // reconfiguration is exactly when an earlier answer may have changed.
        others = []

        let ddc = DisplayRegistry.ddcResolutions(for: Self.externals(of: active))
        // DCP services can be recreated across a reconfiguration, and an old
        // handle is then dead.
        for unit in units where unit.usesDDC {
            if case .transport(let transport) = ddc[unit.displayID] {
                unit.replaceTransport(transport)
            }
        }
        for id in active where !units.contains(where: { $0.displayID == id }) {
            resolve(id, ddc: ddc[id] ?? .noService)
        }
    }

    /// The machine woke: retry monitors that had not answered, and give DDC
    /// units that stopped answering a fresh handle.
    func noteWake() {
        for other in others where other.note == Note.noResponse {
            retryProbe(other.id)
        }
        let stale = units.filter { $0.usesDDC && !$0.isResponding }
        guard !stale.isEmpty else { return }
        let ddc = DisplayRegistry.ddcResolutions(for: Self.externals(of: DisplayRegistry.activeDisplayIDs()))
        for unit in stale {
            if case .transport(let transport) = ddc[unit.displayID] {
                unit.replaceTransport(transport)
            }
        }
    }

    private func resolve(_ id: CGDirectDisplayID, ddc: DisplayRegistry.DDCResolution) {
        let name = DisplayRegistry.name(of: id)
        let services = DisplayServicesBrightness(displayID: id)
        if services.canControl {
            let ramping = RampingBrightness(wrapping: services, scheduler: TimerRampScheduler())
            add(DisplayUnit(displayID: id, name: name, backend: .displayServices(ramping)))
            return
        }
        guard CGDisplayIsBuiltin(id) == 0 else {
            setNote(id, name: name, Note.fixed)
            return
        }
        switch ddc {
        case .transport(let transport): probe(id, name: name, transport: transport)
        case .noService: setNote(id, name: name, Note.noService)
        case .ambiguous: setNote(id, name: name, Note.ambiguous)
        case .unavailable: setNote(id, name: name, Note.unavailable)
        }
    }

    /// One read, off the main thread, to see whether the monitor answers at
    /// all before anything is built on it.
    private func probe(_ id: CGDirectDisplayID, name: String, transport: IOAVServiceTransport) {
        let generation = self.generation
        setNote(id, name: name, Note.checking)
        Task { [weak self] in
            let reading = await Self.read(transport)
            guard let self, generation == self.generation else { return }
            self.others.removeAll { $0.id == id }
            guard let reading else {
                self.setNote(id, name: name, Note.noResponse)
                self.scheduleRetry(id)
                return
            }
            self.retryAttempts[id] = nil
            let link = DDCQueueLink(transport: transport, seed: reading)
            let ddc = DDCBrightness(link: link, seed: reading)
            self.add(DisplayUnit(displayID: id, name: name, backend: .ddc(ddc, link)))
        }
    }

    nonisolated private static func read(_ transport: IOAVServiceTransport) async -> DDCReading? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: transport.readBrightness())
            }
        }
    }

    private func scheduleRetry(_ id: CGDirectDisplayID) {
        let attempt = retryAttempts[id, default: 0]
        retryAttempts[id] = attempt + 1
        let delay = Self.retryDelays[min(attempt, Self.retryDelays.count - 1)]
        retries[id]?.cancel()
        retries[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.retryProbe(id)
        }
    }

    private func retryProbe(_ id: CGDirectDisplayID) {
        // Cancelled, not just dropped: a wake can get here with a backoff
        // still pending, and an orphaned one would run a second retry chain.
        retries.removeValue(forKey: id)?.cancel()
        guard others.contains(where: { $0.id == id && $0.note == Note.noResponse }) else { return }
        let active = DisplayRegistry.activeDisplayIDs()
        guard active.contains(id) else { return }
        let ddc = DisplayRegistry.ddcResolutions(for: Self.externals(of: active))
        others.removeAll { $0.id == id }
        resolve(id, ddc: ddc[id] ?? .noService)
    }

    private func add(_ unit: DisplayUnit) {
        unit.onUnusable = { [weak self, weak unit] in
            guard let self, let unit else { return }
            unit.tearDown()
            self.units.removeAll { $0 === unit }
            self.setNote(unit.displayID, name: unit.name, Note.unwritable)
        }
        units.append(unit)
        units.sort { ($0.isBuiltin ? 0 : 1, $0.displayID) < ($1.isBuiltin ? 0 : 1, $1.displayID) }
        onUnitAdded?(unit)
    }

    private func setNote(_ id: CGDirectDisplayID, name: String, _ note: String) {
        others.removeAll { $0.id == id }
        others.append(OtherDisplay(id: id, name: name, note: note))
        others.sort { $0.id < $1.id }
    }

    private static func externals(of displays: [CGDirectDisplayID]) -> [CGDirectDisplayID] {
        displays.filter { CGDisplayIsBuiltin($0) == 0 }
    }
}
