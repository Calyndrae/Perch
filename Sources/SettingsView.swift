import SwiftUI

struct SettingsView: View {
    @ObservedObject var state: AppState

    @State private var items: [Uninstaller.Item] = []
    @State private var extras: [UserExtensions.Item] = []
    @State private var extraError: String?
    @State private var removeProfile = false
    @State private var confirming = false
    @State private var busy = false
    @State private var report: String?

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

            extensionsSection

            uninstallSection
        }
        .formStyle(.grouped)
        .frame(width: 540, height: 620)
        .task {
            await state.refreshAll()
            items = Uninstaller.inventory()
            reloadExtras()
        }
        .alert("Move Perch to the Trash?", isPresented: $confirming) {
            Button("Move to Trash", role: .destructive) { runUninstall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(removeProfile
                 ? "Everything listed goes to the Trash, including Perch's Chrome profile — "
                 + "you'll be signed out of sites you signed into there. Perch's Chrome will "
                 + "be closed first.\n\nNothing is erased; you can put it all back from the "
                 + "Trash."
                 : "Everything listed goes to the Trash. Perch's Chrome profile is kept, so "
                 + "your logins there survive.\n\nNothing is erased; you can put it back "
                 + "from the Trash.")
        }
    }

    // MARK: - Your extensions

    @ViewBuilder private var extensionsSection: some View {
        Section {
            if extras.isEmpty {
                Text("Perch's Chrome runs on its own profile, so extensions you have in your "
                   + "everyday Chrome aren't there. Add them here and they'll be loaded every "
                   + "time Perch starts Chrome.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(extras) { item in
                    HStack(spacing: 10) {
                        Toggle("", isOn: Binding(
                            get: { item.enabled },
                            set: { UserExtensions.setEnabled(item, $0); reloadExtras() }
                        ))
                        .labelsHidden()
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.name).lineLimit(1)
                            Text("version \(item.version)")
                                .font(.caption).foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Button("Remove") {
                            try? UserExtensions.remove(item)
                            reloadExtras()
                        }
                    }
                }
            }

            if let extraError {
                Text(extraError).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Add Extension…") { pickExtension() }
                Spacer()
                if !extras.isEmpty {
                    Text("Applied next time Chrome starts")
                        .font(.caption).foregroundStyle(.tertiary)
                }
            }

            Text("A folder, a .zip or a .crx all work. Anything you add can read and change "
               + "pages in Perch's Chrome, exactly as it could in any browser — so only add "
               + "extensions you'd install normally.")
                .font(.caption).foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Your extensions")
        }
    }

    private func reloadExtras() { extras = UserExtensions.installed() }

    private func pickExtension() {
        extraError = nil
        let panel = NSOpenPanel()
        panel.message = "Choose an unpacked extension folder, or a .zip or .crx file"
        panel.prompt = "Add"
        panel.canChooseDirectories = true
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try UserExtensions.add(from: url)
            reloadExtras()
        } catch {
            extraError = error.localizedDescription
        }
    }

    // MARK: - Uninstall

    @ViewBuilder private var uninstallSection: some View {
        Section {
            if let report {
                Text(report).font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Show Trash") { Uninstaller.revealTrash() }
                    Button("Open Screen Recording Settings") {
                        Uninstaller.openScreenRecordingSettings()
                    }
                    Spacer()
                    Button("Quit Perch") { NSApp.terminate(nil) }
                }
            } else {
                ForEach(items) { item in
                    if !item.isProfile {
                        LabeledContent(item.label) {
                            Text(item.readableSize).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                if let profile = items.first(where: { $0.isProfile }) {
                    Toggle(isOn: $removeProfile) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Also remove Perch's Chrome profile (\(profile.readableSize))")
                            Text("This is the browser profile Perch made — the sites you signed "
                               + "into there, your history and cookies. Leave it off and it "
                               + "stays, ready if you reinstall.")
                                .font(.caption).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }

                Text("Everything goes to the Trash, not deleted — you can put it back. "
                   + "macOS keeps the Screen Recording permission in its own database that "
                   + "no app may edit, so switch Perch off there yourself afterwards.")
                    .font(.caption).foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                Button(busy ? "Removing…" : "Uninstall Perch…") { confirming = true }
                    .disabled(busy || items.isEmpty)
            }
        } header: {
            Text("Uninstall")
        }
    }

    private func runUninstall() {
        busy = true
        Uninstaller.uninstall(includeChromeProfile: removeProfile) { outcome in
            busy = false
            switch outcome {
            case .chromeStillRunning:
                report = "Perch's Chrome wouldn't close, so nothing was touched — its profile "
                       + "would have been left half-written. Quit that Chrome window and try again."
            case let .done(trashed, failed):
                var text = "Moved \(trashed) item\(trashed == 1 ? "" : "s") to the Trash."
                if !failed.isEmpty {
                    text += "\n\nCouldn't move: " + failed.joined(separator: "; ")
                }
                text += "\n\nOne thing left for you: macOS still lists Perch under Screen "
                      + "Recording. No app can remove that entry, so switch it off there."
                report = text
            }
        }
    }
}
