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
                Text("How strongly content pulls brightness away from your setting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Maximum change: \(Int(model.maxOffset * 100))%")
                Slider(value: $model.maxOffset, in: 0.05...0.35)
            }

            Divider()

            if let label = model.pausedUntilLabel {
                HStack {
                    Text("Paused until \(label)")
                        .font(.caption)
                    Spacer()
                    Button("Resume", action: model.endPause)
                }
            } else {
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
            Text("Starting…").font(.caption).foregroundStyle(.secondary)
        case .permissionDenied:
            VStack(alignment: .leading, spacing: 4) {
                Label(
                    "Screen Recording permission is required.",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(.orange)
                Button("Open System Settings") {
                    let url = URL(
                        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
                    )!
                    NSWorkspace.shared.open(url)
                }
                .font(.caption)
            }
        case .noDisplay:
            Text("No built-in display found.").font(.caption).foregroundStyle(.orange)
        case .failed(let message):
            Text("Capture failed: \(message)").font(.caption).foregroundStyle(.orange)
        }
    }
}
