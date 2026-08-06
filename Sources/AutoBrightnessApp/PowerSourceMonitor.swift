import Foundation
import IOKit.ps

/// Watches for the machine's power source flipping between AC and battery,
/// which is the moment macOS steps the panel's brightness on its own (dim on
/// unplug, partial restore on replug). Telling the coordinator about it is
/// what stops that step being read as the user choosing a level.
@MainActor
public final class PowerSourceMonitor {
    private let onChange: @MainActor () -> Void
    /// IOKit fires this for every power-source detail — battery percentage
    /// ticks included — so the last seen source is kept to forward only actual
    /// AC/battery flips. Nil until a read has succeeded; the first successful
    /// read only establishes the reference and is never itself a flip.
    private var lastSource: String?
    private var runLoopSource: CFRunLoopSource?

    public init(onChange: @escaping @MainActor () -> Void) {
        self.onChange = onChange
        lastSource = Self.currentSource()
    }

    public func start() {
        // Guards a second start from scheduling a duplicate source, which
        // would double every callback.
        guard runLoopSource == nil else { return }
        // Unretained is a lifetime contract, not an oversight: the monitor is
        // owned by AppModel for the life of the process and there is
        // deliberately no stop() — the same arrangement PauseMonitor has with
        // its observers. Deallocating it while the source stays scheduled
        // would leave the callback a dangling pointer.
        let context = Unmanaged.passUnretained(self).toOpaque()
        // A nil here (no power-source facility) degrades to the old behavior:
        // the dim is classified by size alone. Acceptable, and nothing useful
        // to report.
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            let monitor = Unmanaged<PowerSourceMonitor>.fromOpaque(context)
                .takeUnretainedValue()
            // IOKit delivers on the run loop the source is scheduled on, which
            // is the main one below.
            MainActor.assumeIsolated { monitor.sourcesChanged() }
        }, context)?.takeRetainedValue() else { return }
        runLoopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
    }

    private func sourcesChanged() {
        // A transient read failure must not count as a flip: recording it
        // would make the next successful read look like one, opening a grace
        // window nothing asked for.
        guard let source = Self.currentSource() else { return }
        guard let previous = lastSource else {
            lastSource = source
            return
        }
        guard source != previous else { return }
        lastSource = source
        onChange()
    }

    private static func currentSource() -> String? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeRetainedValue() else {
            return nil
        }
        return type as String
    }
}
