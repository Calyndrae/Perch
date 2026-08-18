import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    var body: some View {
        Form {
            Section {
                Toggle("Let me click and scroll in the mirror", isOn: $state.forwardInput)

                Text("Clicks and scrolling go to the page over Chrome's own DevTools "
                   + "channel, so Chrome never comes to the front and no extra permission "
                   + "is needed. Page content only — not the tab strip or address bar. "
                   + "Typing isn’t forwarded.")
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
