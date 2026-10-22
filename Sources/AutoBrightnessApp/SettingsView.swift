import AppKit
import SwiftUI

public struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var showDebug = false

    public init(model: AppModel) {
        self.model = model
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Adjust brightness to content", isOn: $model.isEnabled)
                .toggleStyle(.switch)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(model.units, id: \.displayID) { unit in
                    DisplayRow(unit: unit, isEnabled: model.isEnabled)
                }
                ForEach(model.otherDisplays) { other in
                    HStack {
                        Label(other.name, systemImage: "display")
                        Spacer()
                        Text(other.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Spacer()
                // Shown whether or not the app is enabled: a user who pauses and
                // then switches the toggle off must still be able to see that a
                // pause is in effect, and cancel it.
                if let label = model.pausedUntilLabel {
                    Text("Paused until \(label)")
                        .font(.caption)
                    Button("Resume", action: model.endPause)
                } else if model.isEnabled {
                    Button("Pause for 1 hour", action: model.pauseForAnHour)
                }
            }

            if !model.hasAdjustableDisplay && !model.isCheckingDisplays {
                Label("No adjustable displays", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            if model.needsScreenRecordingPermission {
                permissionNotice
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Sensitivity to screen content: \(Int(model.strength * 100))%")
                Slider(value: $model.strength, in: AppModel.strengthRange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Maximum change: \(Int(model.maxOffset * 100))%")
                Slider(value: $model.maxOffset, in: AppModel.maxOffsetRange)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "Time to adjust: %.1f seconds", model.responseSeconds))
                Slider(value: $model.responseSeconds, in: AppModel.responseSecondsRange)
            }

            HStack {
                Spacer()
                Button("Reset to defaults", action: model.resetTuning)
                    .disabled(model.isAtDefaultTuning)
            }
            .font(.caption)

            Divider()

            Toggle("Show icon in menu bar", isOn: $model.showsMenuBarIcon)

            Toggle("Open at login", isOn: $model.launchAtLogin)

            // The toggle has already snapped back to what the system reports,
            // so without this the failure would look like a switch that
            // silently refuses to move.
            if let error = model.launchAtLoginError {
                Text("Could not change the login item: \(error)")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            DisclosureGroup("Details", isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.units, id: \.displayID) { unit in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(unit.name).fontWeight(.semibold)
                            Text(String(format: "Screen luminance: %.3f", unit.luminance))
                            Text(String(format: "Applied offset: %+.3f", unit.offset))
                            Text(String(format: "Your baseline: %.3f", unit.baseline))
                        }
                    }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            HStack {
                Button("Quit", action: model.quit)
                Spacer()
                if let version = Self.versionLabel {
                    Text(version)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
        .padding(16)
        .frame(width: 300)
    }

    /// "1.0 (1)" from the bundle. Nil when run straight out of `swift build`,
    /// where there is no Info.plist to read and a version would be a fiction.
    private static let versionLabel: String? = {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String else { return nil }
        guard let build = info?["CFBundleVersion"] as? String, build != short else {
            return "Version \(short)"
        }
        return "Version \(short) (\(build))"
    }()

    private var permissionNotice: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(
                "Screen Recording permission is required.",
                systemImage: "exclamationmark.triangle"
            )
            .font(.caption)
            .foregroundStyle(.orange)
            HStack {
                Button("Open System Settings") {
                    let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    )!
                    NSWorkspace.shared.open(url)
                }
                Button("Try Again", action: model.retrySampling)
            }
            .font(.caption)
            // macOS usually only honours a screen-capture grant for a process
            // that started after it, so say so rather than leaving the user
            // pressing a button that cannot work.
            Text("After granting permission, quit and reopen Auto Brightness if it does not start on its own.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

/// One adjustable display: its name, its brightness, and anything wrong with
/// its capture. Permission problems are left to the single notice above.
private struct DisplayRow: View {
    let unit: DisplayUnit
    let isEnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Label(unit.name, systemImage: unit.isBuiltin ? "laptopcomputer" : "display")
                Spacer()
                if !unit.isResponding {
                    Text("Not responding")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else if let brightness = unit.displayBrightness {
                    Text("\(Int((brightness * 100).rounded()))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }
            if let note = statusNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusNote: String? {
        switch unit.status {
        case .running, .permissionDenied:
            nil
        case .idle:
            isEnabled ? "Starting…" : nil
        case .stalled:
            "Reconnecting to the display…"
        case .noDisplay:
            "This display isn't available for capture."
        case .failed(let message):
            "Capture failed: \(message)"
        }
    }
}
