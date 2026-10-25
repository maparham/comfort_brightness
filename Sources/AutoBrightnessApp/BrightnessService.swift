import AutoBrightnessCore
import Foundation

/// macOS's brightness daemon, corebrightnessd, as far as this app depends on
/// it. Everything that reaches DisplayServices or CoreDisplay goes through it.
enum BrightnessService {
    /// One gate for the whole process. There is one daemon behind every
    /// display, and its client library serializes calls process-wide anyway,
    /// so separate gates would only queue behind each other's hung calls.
    ///
    /// A healthy daemon answers in milliseconds. One second is far past that,
    /// and short enough that the single stall it costs the main thread, once
    /// per episode, is merely noticeable.
    static let gate = ServiceGate(
        label: "com.mahmoudparham.autobrightness.brightness-service",
        timeout: 1
    )

    /// Asks the daemon one cheap question, off the main thread. Run at launch
    /// and on wake, which is when it has been seen to get stuck, so that a
    /// stuck daemon is noticed even when no display is driven through it: lid
    /// closed with only DDC monitors attached, say.
    static func probe() {
        DispatchQueue.global(qos: .utility).async {
            DisplayServicesBrightness.probe(through: gate)
        }
    }

    enum RestartOutcome: Sendable {
        case restarted
        case cancelled
        case failed(String)
    }

    /// Kills corebrightnessd, which launchd relaunches at once. That is the
    /// only cure known for a stuck daemon short of a reboot, and it also
    /// makes the call the gate is waiting on fail, which is what clears it.
    ///
    /// A polite terminate first, which is what cured it by hand. A daemon too
    /// wedged to act on that is force-killed two seconds later, by the process
    /// IDs taken up front, so the fresh daemon launchd has started in the
    /// meantime is never touched. Each ID is checked to still be
    /// corebrightnessd first: a kill sent as root to a reused ID would land
    /// on whatever process now holds it.
    ///
    /// The daemon runs as root, so this asks for an administrator password
    /// through the standard macOS dialog. Restarting it briefly resets Night
    /// Shift and the ambient-light curve, which is harmless.
    static func restart() async -> RestartOutcome {
        let script = """
            do shell script "p=$(/usr/bin/pgrep -x corebrightnessd) || exit 3; /bin/kill $p; /bin/sleep 2; for i in $p; do /usr/bin/pgrep -x corebrightnessd | /usr/bin/grep -qx $i && /bin/kill -9 $i; done; exit 0" \
            with prompt "Auto Brightness wants to restart the macOS brightness service, which has stopped responding." \
            with administrator privileges
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice

        let (status, message) = await withCheckedContinuation { continuation in
            process.terminationHandler = { finished in
                let data = errors.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                continuation.resume(returning: (finished.terminationStatus, text))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }

        if status == 0 { return .restarted }
        if message.contains("(3)") { return .failed("corebrightnessd isn't running.") }
        // -128 is AppleScript's "User canceled", from the password dialog.
        if message.contains("-128") { return .cancelled }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return .failed(trimmed.isEmpty ? "osascript exited with status \(status)" : trimmed)
    }
}
