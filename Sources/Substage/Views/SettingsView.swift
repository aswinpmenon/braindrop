import SwiftUI
import Carbon.HIToolbox

// MARK: - Root

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralTab()
                .tabItem { Label("General", systemImage: "gearshape") }
            AutoRunTab()
                .tabItem { Label("Auto-run", systemImage: "hare") }
            AIModelsTab()
                .tabItem { Label("AI Models", systemImage: "brain.head.profile") }
            AboutTab()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 540, height: 420)
    }
}

// MARK: - General tab

struct GeneralTab: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Shortcut")
                    Spacer()
                    Text(settings.hotkeyDisplayString)
                        .font(.system(size: 13, design: .monospaced))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 4)
                            .fill(Color(nsColor: .controlBackgroundColor))
                            .overlay(RoundedRectangle(cornerRadius: 4)
                                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)))
                }
                Text("Press ⌃Space anywhere to show/hide the Substage bar beneath the frontmost Finder window.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: { Text("Keyboard Shortcut") }

            Section {
                HStack {
                    Text("History")
                    Spacer()
                    Text("\(CommandHistory.shared.entries.count) commands")
                        .foregroundStyle(.secondary)
                    Button("Clear") { CommandHistory.shared.clear() }
                        .controlSize(.small)
                        .disabled(CommandHistory.shared.entries.isEmpty)
                }
                Text("Press ↑ / ↓ in the bar to navigate recent commands.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } header: { Text("History") }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
    }
}

// MARK: - Auto-run tab

struct AutoRunTab: View {
    @ObservedObject private var s = AppSettings.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Substage can run commands with or without confirmation")
                    .font(.system(size: 13, weight: .semibold))
                Text("What kinds of commands should run **without asking**?")
                    .font(.system(size: 13))

                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 10) {
                        AutoRunCheck(label: "Harmless commands",      on: $s.autoRunReadOnly)
                        AutoRunCheck(label: "Create new files",       on: $s.autoRunFileCreation)
                        AutoRunCheck(label: "Rename files",           on: $s.autoRunRename)
                        AutoRunCheck(label: "Move files",             on: $s.autoRunMove)
                        AutoRunCheck(label: "Modify files",           on: $s.autoRunModify)
                        AutoRunCheck(label: "Change files outside\ncurrent folder",
                                     on: $s.autoRunOutsideFolder)
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        AutoRunCheck(label: "Have minor side effects", on: $s.autoRunMinorSideEffects)
                        AutoRunCheck(label: "Have significant side effects", on: $s.autoRunSignificantSideEffects)
                        AutoRunCheck(label: "Move items to Trash",     on: $s.autoRunMoveToTrash)
                        AutoRunCheck(label: "Delete or overwrite files", on: $s.autoRunFileDeletion)
                        AutoRunCheck(label: "Run unknown scripts\nor commands", on: $s.autoRunSystemModification)
                        AutoRunCheck(label: "Commands with errors",    on: $s.autoRunCommandsWithErrors)
                    }
                }

                Divider()

                HStack(alignment: .top, spacing: 30) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Minor side effects include:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(["Opening an app or file", "Network access",
                                 "Reading from clipboard", "Long running commands"], id: \.self) {
                            Text("• \($0)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Significant side effects include:")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                        ForEach(["Modifying system settings", "Force-quitting an app",
                                 "Shutting down your Mac", "Indefinite running commands"], id: \.self) {
                            Text("• \($0)").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .padding(24)
        }
    }
}

struct AutoRunCheck: View {
    let label: String
    @Binding var on: Bool
    var body: some View {
        Toggle(isOn: $on) {
            Text(label)
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
        }
        .toggleStyle(.checkbox)
    }
}

// MARK: - AI Models tab

struct AIModelsTab: View {
    @ObservedObject private var s = AppSettings.shared
    @State private var models: [OllamaModel] = []
    @State private var loading = false
    @State private var status: ConnStatus = .unknown

    enum ConnStatus { case unknown, ok, fail }

    var body: some View {
        Form {
            Section {
                HStack {
                    Text("Server URL")
                    Spacer()
                    TextField("http://127.0.0.1:8080", text: $s.ollamaBaseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 220)
                        .font(.system(size: 12, design: .monospaced))
                    Button(action: testConn) {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(status == .ok ? Color.green : status == .fail ? Color.red : Color.gray)
                                .frame(width: 7, height: 7)
                            Text(status == .ok ? "Connected" : status == .fail ? "Offline" : "Test")
                                .font(.system(size: 12))
                        }
                    }
                    .buttonStyle(.plain)
                }

                HStack {
                    Text("Model")
                    Spacer()
                    if loading {
                        ProgressView().scaleEffect(0.6)
                    } else if models.isEmpty {
                        TextField("llama3.2", text: $s.ollamaModel)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 180)
                            .font(.system(size: 12, design: .monospaced))
                    } else {
                        Picker("", selection: $s.ollamaModel) {
                            ForEach(models) { m in Text(m.name).tag(m.name) }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                    }
                    Button { loadModels() } label: {
                        Image(systemName: "arrow.clockwise").font(.system(size: 12))
                    }
                    .buttonStyle(.plain)
                }

                VStack(alignment: .leading, spacing: 3) {
                    Text("Using llama-server (llama.cpp) — compatible with macOS 26.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                    Text("Start with: bash ~/Downloads/Substage/start-llama-server.sh")
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                }
            } header: { Text("Local LLM Server") }
        }
        .formStyle(.grouped)
        .padding(.top, 8)
        .onAppear { testConn() }
    }

    private func testConn() {
        status = .unknown
        Task {
            let ok = await OllamaService.shared.checkConnection()
            await MainActor.run {
                status = ok ? .ok : .fail
                if ok { loadModels() }
            }
        }
    }

    private func loadModels() {
        loading = true
        Task {
            let ms = (try? await OllamaService.shared.listModels()) ?? []
            await MainActor.run { models = ms; loading = false }
        }
    }
}

// MARK: - About tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "terminal.fill")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Substage")
                .font(.system(size: 20, weight: .semibold))
            Text("Natural language command bar for Finder")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Text("Version 1.0  •  Powered by llama.cpp")
                .font(.system(size: 12))
                .foregroundStyle(.tertiary)
            Divider().frame(width: 200)
            Text("Press ⌃Space to show the bar beneath any Finder window.\nType what you want to do in plain English.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }
}
