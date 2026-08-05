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

            if let brightness = model.displayBrightness {
                HStack {
                    Label("Brightness", systemImage: "sun.max")
                    Spacer()
                    Text("\(Int((brightness * 100).rounded()))%")
                        .fontWeight(.semibold)
                        .monospacedDigit()
                }
            }

            if !model.canControlBrightness {
                Label(
                    "Brightness control is unavailable on this system.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            statusLabel

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                Text("Strength")
                Slider(value: $model.strength, in: 0.2...0.9)
                Text("Sensitivity to screen content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Maximum change: \(Int(model.maxOffset * 100))%")
                Slider(value: $model.maxOffset, in: 0.05...0.35)
            }

            Divider()

            // Shown whether or not the app is enabled: a user who pauses and then
            // switches the toggle off must still be able to see that a pause is
            // in effect, and cancel it.
            if let label = model.pausedUntilLabel {
                HStack {
                    Text("Paused until \(label)")
                        .font(.caption)
                    Spacer()
                    Button("Resume", action: model.endPause)
                }
            } else if model.isEnabled {
                Button("Pause for 1 hour", action: model.pauseForAnHour)
            }

            Toggle("Open at login", isOn: $model.launchAtLogin)

            DisclosureGroup("Details", isExpanded: $showDebug) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: "Screen luminance: %.3f", model.luminance))
                    Text(String(format: "Applied offset: %+.3f", model.offset))
                    Text(String(format: "Your baseline: %.3f", model.baseline))
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button("Quit", action: model.quit)
        }
        .padding(16)
        .frame(width: 300)
    }

    @ViewBuilder
    private var statusLabel: some View {
        switch model.status {
        case .running:
            EmptyView()
        case .idle:
            Text(model.isEnabled ? "Starting…" : "Not watching the screen.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .stalled:
            Text("Reconnecting to the display…")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .permissionDenied:
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
        case .noDisplay:
            Text("No built-in display found. Auto Brightness only adjusts the built-in panel.")
                .font(.caption)
                .foregroundStyle(.orange)
        case .failed(let message):
            Text("Capture failed: \(message)").font(.caption).foregroundStyle(.orange)
        }
    }
}
