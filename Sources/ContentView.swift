import SwiftUI

struct ContentView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !state.gateFailures.isEmpty {
                GateView(state: state)
            } else {
                PickerView(state: state)
            }
        }
        .frame(minWidth: 460, minHeight: 420)
    }
}

// MARK: - Gate

struct GateView: View {
    @ObservedObject var state: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange).font(.title2)
                    Text("Setup needed").font(.title2).bold()
                }

                ForEach(state.gateFailures, id: \.self) { failure in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(failure.title).font(.headline)
                        Text(failure.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack {
                            switch failure {
                            case .screenRecordingDenied:
                                // Settings is always offered because it is the
                                // only route that actually grants this one.
                                // Re-asking is offered only while macOS would
                                // still show a dialog — after that it is a
                                // silent no-op and the button would be a lie.
                                Button("Open Screen Recording Settings") {
                                    state.openScreenRecordingSettings()
                                }
                                .keyboardShortcut(.defaultAction)

                                if state.canPromptScreenRecording {
                                    Button("Ask Again") { state.requestScreenRecording() }
                                }
                                if state.shouldOfferRelaunch {
                                    Button("Relaunch Perch") { state.relaunchPerch() }
                                        .help("Already switched it on? Perch needs a restart "
                                            + "to pick the permission up.")
                                }
                            case .extensionMissing:
                                Button(state.isLaunchingChrome
                                       ? "Restarting Chrome…" : "Set Up Chrome Now") {
                                    state.relaunchChromeWithExtension()
                                }
                                .disabled(state.isLaunchingChrome)
                                .keyboardShortcut(.defaultAction)
                            case .chromeNotRunning:
                                EmptyView()
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button("Check Again") { Task { await state.refreshAll() } }
                    .keyboardShortcut(.defaultAction)

                Spacer(minLength: 0)
            }
            .padding(22)
        }
    }
}

// MARK: - Picker

struct PickerView: View {
    @ObservedObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Chrome windows").font(.headline)
                Spacer()
                Button {
                    Task { await state.refreshWindows() }
                } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh the list")
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            if state.windows.isEmpty {
                VStack(spacing: 6) {
                    Text("No Chrome windows found").foregroundStyle(.secondary)
                    Text("Open a window in Chrome, then refresh.")
                        .font(.caption).foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.windows, selection: $state.selectedWindowID) { window in
                    HStack(spacing: 10) {
                        Image(systemName: "macwindow").foregroundStyle(.secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.title).lineLimit(1)
                            Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Mirror") { state.startMirroring(window.id) }
                            .buttonStyle(.borderedProminent)
                    }
                    .padding(.vertical, 3)
                    .tag(window.id)
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let error = state.lastError {
                    Banner(icon: "xmark.octagon.fill", tint: .red,
                           title: "Something went wrong", message: error)
                }

                HStack {
                    Circle().fill(state.extensionPresent ? .green : .red).frame(width: 8, height: 8)
                    Text(state.extensionPresent ? "Extension connected" : "Extension not connected")
                        .font(.caption).foregroundStyle(.secondary)

                    Spacer()

                    if state.isMirroring {
                        Button("Stop Mirroring") { state.stopMirroring() }
                    }
                }
            }
            .padding(16)
        }
    }
}

struct Banner: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout).bold()
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
