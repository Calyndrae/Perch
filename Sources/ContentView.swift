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
                            case .extensionMissing, .chromeNotRunning:
                                Button(state.isLaunchingChrome
                                       ? "Starting Chrome…" : "Set Up Chrome Now") {
                                    state.relaunchChromeWithExtension()
                                }
                                .disabled(state.isLaunchingChrome)
                                .keyboardShortcut(.defaultAction)
                            }
                        }
                    }
                    .padding(14)
                    .background(Color(nsColor: .controlBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }

                Button("Check Again") { Task { await state.refreshAll() } }

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
            HStack(spacing: 8) {
                Text("Chrome windows").font(.headline)
                Text("updates automatically")
                    .font(.caption).foregroundStyle(.tertiary)
                Spacer()
                // A labelled button, not a bare icon. The icon alone was easy
                // to miss, so a stale list just looked like a broken app.
                Button {
                    Task { await state.refreshWindows() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 10)

            if state.windows.isEmpty {
                emptyState.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(state.windows) { window in
                    let mirrored = state.mirroredWindowID == window.id
                    HStack(spacing: 10) {
                        Image(systemName: mirrored ? "dot.radiowaves.left.and.right" : "macwindow")
                            .foregroundStyle(mirrored ? Color.accentColor : .secondary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(window.title).lineLimit(1)
                            Text("\(Int(window.frame.width)) × \(Int(window.frame.height))")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if mirrored {
                            Text("Mirroring").font(.caption).foregroundStyle(Color.accentColor)
                            Button("Stop") { state.stopMirroring() }
                        } else {
                            Button("Mirror") { state.startMirroring(window.id) }
                                .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .listStyle(.inset)
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                if let error = state.lastError {
                    Banner(icon: "xmark.octagon.fill", tint: .red,
                           title: "Something went wrong", message: error) {
                        Button("Dismiss") { state.lastError = nil }
                        Button("Restart Chrome") { state.relaunchChromeWithExtension() }
                            .disabled(state.isLaunchingChrome)
                    }
                }

                HStack(spacing: 14) {
                    StatusDot(ok: state.extensionPresent,
                              label: state.extensionPresent ? "Extension connected"
                                                            : "Extension not connected")
                    StatusDot(ok: state.managedChromeRunning,
                              label: state.managedChromeRunning ? "Perch's Chrome running"
                                                                : "Chrome not started by Perch")
                    Spacer()
                    if state.isMirroring {
                        Button("Stop Mirroring") { state.stopMirroring() }
                    }
                }
            }
            .padding(16)
        }
    }

    /// The old empty state said "open a window in Chrome, then refresh", which
    /// is the wrong advice when the real problem is that Perch never started
    /// Chrome — and no amount of refreshing would ever have fixed it.
    @ViewBuilder private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "macwindow")
                .font(.system(size: 30)).foregroundStyle(.tertiary)
            if state.managedChromeRunning {
                Text("No Chrome windows yet").foregroundStyle(.secondary)
                Text("Open a window in Perch's Chrome — this list updates on its own.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
            } else {
                Text("Perch hasn't started Chrome yet").foregroundStyle(.secondary)
                Text("Only a Chrome that Perch started carries the extension, so that's "
                   + "the one it can mirror. Your everyday Chrome is left alone.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 340)
                Button(state.isLaunchingChrome ? "Starting Chrome…" : "Open Perch's Chrome") {
                    state.relaunchChromeWithExtension()
                }
                .disabled(state.isLaunchingChrome)
                .keyboardShortcut(.defaultAction)
                .padding(.top, 4)
            }
        }
        .padding(24)
    }
}

struct StatusDot: View {
    let ok: Bool
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(ok ? .green : .red).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct Banner<Actions: View>: View {
    let icon: String
    let tint: Color
    let title: String
    let message: String
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon).foregroundStyle(tint)
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.callout).bold()
                Text(message).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack { actions }.controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .background(tint.opacity(0.10))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
