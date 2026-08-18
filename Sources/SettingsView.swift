import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Let me click and scroll in the mirror", isOn: $state.forwardInput)

                if state.forwardInput && !state.accessibilityGranted {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("macOS needs Accessibility permission before Perch can pass your "
                           + "clicks through to Chrome.")
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Grant Accessibility Access") { state.requestAccessibility() }
                    }
                }

                Text("Clicks land in the real Chrome window without pulling Chrome to the front. "
                   + "Typing isn’t forwarded — click into Chrome itself to type.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                Text("Interaction")
            }

            Section {
                LabeledContent("Chrome extension") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(state.extensionPresent ? .green : .red)
                            .frame(width: 8, height: 8)
                        Text(state.extensionPresent ? "Connected" : "Not connected").font(.caption)
                    }
                }
                LabeledContent("Screen Recording") {
                    Text(state.screenRecordingGranted ? "Granted" : "Not granted").font(.caption)
                }
                LabeledContent("Accessibility") {
                    Text(state.accessibilityGranted ? "Granted" : "Not granted").font(.caption)
                }
                Button("Open Setup Instructions") { state.openSetupPage() }
            } header: {
                Text("Status")
            }
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
        .task { await state.refreshAll() }
    }
}
