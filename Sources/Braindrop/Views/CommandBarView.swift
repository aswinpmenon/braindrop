import SwiftUI
import AppKit

// MARK: - State

enum BarState: Equatable {
    case idle
    case generating
    case preview
    case executing
    case result(String)
    case error(String)
}

// MARK: - ViewModel

@MainActor
class CommandBarViewModel: ObservableObject {

    // UI state
    @Published var query       = ""
    @Published var barState: BarState = .idle
    @Published var command     = ""
    @Published var prediction  = PreviewResult()
    @Published var files: [FileContext] = []
    @Published var workingDir: String?  = nil
    @Published var historyIndex = -1

    // Drives panel height from outside
    @Published var idealHeight: CGFloat = BraindropPanel.barRowHeight

    var onClose:        (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let ollama    = OllamaService.shared
    private let executor  = CommandExecutor.shared
    private let previewer = CommandPreview.shared
    private let history   = CommandHistory.shared
    private let settings  = AppSettings.shared

    // Called from AppDelegate BEFORE panel takes focus, so Finder context is still live.
    func onAppear(files: [FileContext], workingDir: String?) {
        query        = ""
        command      = ""
        prediction   = PreviewResult()
        historyIndex = -1
        barState     = .idle
        self.files      = files
        self.workingDir = workingDir
        updateHeight()
    }

    func reset() {
        barState = .idle
        query    = ""
        command  = ""
        prediction = PreviewResult()
        updateHeight()
    }

    // MARK: - Actions

    func generate() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        barState = .generating
        updateHeight()
        let fs = files; let wd = workingDir
        Task {
            do {
                let cmd  = try await ollama.generateCommand(query: q, files: fs, workingDirectory: wd)
                let prev = previewer.analyze(command: cmd, context: fs)
                command    = cmd
                prediction = prev
                barState   = .preview
                updateHeight()
                if shouldAutoRun(prev.category) { await run() }
            } catch {
                barState = .error(error.localizedDescription)
                updateHeight()
            }
        }
    }

    func run() async {
        barState = .executing
        updateHeight()
        history.add(query: query, command: command, files: files.map(\.path))
        do {
            let r = try await executor.execute(command: command, workingDirectory: workingDir)
            let out = r.displayOutput.isEmpty
                ? (r.succeeded ? "Done." : "Exited with code \(r.exitCode)")
                : r.displayOutput
            if r.succeeded {
                barState = .result(out)
            } else {
                barState = .error(r.error.isEmpty ? "Command failed (exit \(r.exitCode))" : r.error)
            }
        } catch {
            barState = .error(error.localizedDescription)
        }
        updateHeight()
    }

    func reject() {
        barState = .idle
        command = ""
        prediction = PreviewResult()
        updateHeight()
    }

    func cancelExecution() {
        executor.cancel()
        barState = .idle
        updateHeight()
    }

    func historyUp() {
        let next = historyIndex + 1
        if next < history.entries.count { historyIndex = next; query = history.entries[next].query }
    }

    func historyDown() {
        if historyIndex > 0 { historyIndex -= 1; query = history.entries[historyIndex].query }
        else if historyIndex == 0 { historyIndex = -1; query = "" }
    }

    // MARK: - Height calculation

    func updateHeight() {
        idealHeight = computeHeight()
    }

    private func computeHeight() -> CGFloat {
        let row = BraindropPanel.barRowHeight
        switch barState {
        case .idle:
            return row
        case .generating:
            return row
        case .preview:
            let effectRows = CGFloat(max(1, prediction.effects.count))
            let warnRows   = CGFloat(prediction.warnings.count)
            // bar row + divider + command block + divider + effects + warnings + divider + button row
            return row + 1 + 44 + 1 + effectRows * 28 + warnRows * 22 + 1 + 52
        case .executing:
            return row + 1 + 44
        case .result(let out):
            let lines = CGFloat(out.components(separatedBy: "\n").prefix(6).count)
            return row + 1 + max(40, lines * 18 + 16) + 1 + 36
        case .error:
            return row + 1 + 52
        }
    }

    private func shouldAutoRun(_ cat: CommandCategory) -> Bool {
        switch cat {
        case .readOnly:           return settings.autoRunReadOnly
        case .fileCreation:       return settings.autoRunFileCreation
        case .fileDeletion:       return settings.autoRunFileDeletion
        case .systemModification: return settings.autoRunSystemModification
        case .unknown:            return false
        }
    }
}

// MARK: - Root view

struct CommandBarView: View {
    @ObservedObject var viewModel: CommandBarViewModel
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            // Window chrome: white card with shadow border
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
                )

            VStack(spacing: 0) {
                barRow
                    .frame(height: BraindropPanel.barRowHeight)

                if viewModel.barState != .idle && viewModel.barState != .generating {
                    Divider()
                    expandedSection
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .onAppear {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { focused = true }
        }
        .onKeyPress(.escape) { viewModel.onClose?(); return .handled }
    }

    // MARK: Bar row
    private var barRow: some View {
        HStack(spacing: 0) {

            // Left: status dot + file count or folder name
            HStack(spacing: 5) {
                Circle()
                    .fill(dotColor)
                    .frame(width: 8, height: 8)
                if !viewModel.files.isEmpty {
                    Text("\(viewModel.files.count) item\(viewModel.files.count == 1 ? "" : "s")")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else if let cwd = viewModel.workingDir {
                    Text(URL(fileURLWithPath: cwd).lastPathComponent)
                        .font(.system(size: 12))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(width: 90, alignment: .leading)
            .padding(.leading, 14)

            // Center: text field (takes remaining space)
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )

                HStack(spacing: 6) {
                    if viewModel.barState == .generating {
                        ProgressView()
                            .scaleEffect(0.55)
                            .progressViewStyle(.circular)
                    }
                    TextField("Enter query or command", text: $viewModel.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { viewModel.generate() }
                        .onKeyPress(.upArrow)   { viewModel.historyUp();   return .handled }
                        .onKeyPress(.downArrow) { viewModel.historyDown(); return .handled }
                        .disabled(viewModel.barState == .generating || viewModel.barState == .executing)
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 26)
            .padding(.horizontal, 10)

            // Right: model name + icons
            HStack(spacing: 10) {
                modelButton
                Button { CommandHistory.shared.entries.isEmpty ? () : viewModel.historyUp() } label: {
                    Image(systemName: "clock")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Command history (↑)")

                Button { viewModel.onOpenSettings?() } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.trailing, 12)
        }
    }

    private var dotColor: Color {
        switch viewModel.barState {
        case .idle:
            if !viewModel.files.isEmpty { return .red }
            if viewModel.workingDir != nil { return .blue }
            return Color(nsColor: .tertiaryLabelColor)
        case .generating: return .orange
        case .preview:    return .blue
        case .executing:  return .orange
        case .result:     return .green
        case .error:      return .red
        }
    }

    private var modelButton: some View {
        Menu {
            Text("LLM Model")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Divider()
            ForEach(["llama3.2", "llama3.1", "mistral", "phi3", "gemma2"], id: \.self) { m in
                Button(m) { AppSettings.shared.ollamaModel = m }
            }
            Divider()
            Button("Settings…") { viewModel.onOpenSettings?() }
        } label: {
            HStack(spacing: 3) {
                Text(AppSettings.shared.ollamaModel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    // MARK: Expanded section
    @ViewBuilder
    private var expandedSection: some View {
        switch viewModel.barState {
        case .preview:    previewSection
        case .executing:  executingSection
        case .result(let o): resultSection(output: o)
        case .error(let e):  errorSection(message: e)
        default: EmptyView()
        }
    }

    // MARK: Preview
    private var previewSection: some View {
        VStack(spacing: 0) {
            // Command line
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(viewModel.command)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                Spacer()
                copyButton
            }
            .padding(.horizontal, 14)
            .frame(height: 44)

            if !viewModel.prediction.effects.isEmpty || !viewModel.prediction.warnings.isEmpty {
                Divider()
                effectsList
            }

            Divider()
            actionButtons
                .frame(height: 52)
        }
    }

    private var effectsList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.prediction.effects) { effect in
                HStack(spacing: 8) {
                    Image(systemName: effect.symbol)
                        .font(.system(size: 10))
                        .foregroundStyle(effectColor(effect))
                        .frame(width: 14)
                    Text(effect.verb)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(effectColor(effect))
                        .frame(width: 44, alignment: .leading)
                    Text(effect.label)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 28)
            }
            ForEach(viewModel.prediction.warnings, id: \.self) { w in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text(w)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 22)
            }
        }
    }

    private var actionButtons: some View {
        HStack(spacing: 10) {
            Spacer()
            Button("Cancel") { viewModel.reject() }
                .buttonStyle(BarSecondaryButtonStyle())
                .keyboardShortcut(.cancelAction)
            Button(viewModel.prediction.isDestructive ? "Run anyway" : "Run") {
                Task { await viewModel.run() }
            }
            .buttonStyle(BarPrimaryButtonStyle(destructive: viewModel.prediction.isDestructive))
            .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 14)
    }

    // MARK: Executing
    private var executingSection: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6)
            Text("Running…")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(viewModel.command)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            Button("Cancel") { viewModel.cancelExecution() }
                .buttonStyle(BarSecondaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: Result
    private func resultSection(output: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Done").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Dismiss") { viewModel.reset() }
                    .buttonStyle(BarSecondaryButtonStyle())
            }
            .padding(.horizontal, 14)
            .frame(height: 36)

            if output != "Done." {
                Divider()
                ScrollView {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                }
                .frame(maxHeight: 90)
            }
        }
    }

    // MARK: Error
    private func errorSection(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                .padding(.top, 1)
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .lineLimit(3)
            Spacer()
            Button("Dismiss") { viewModel.reset() }
                .buttonStyle(BarSecondaryButtonStyle())
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 14)
    }

    // MARK: Helpers
    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(viewModel.command, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain)
        .help("Copy command")
    }

    private func effectColor(_ e: FileEffect) -> Color {
        switch e {
        case .created: return .green
        case .modified: return .orange
        case .deleted: return .red
        case .moved: return .blue
        case .read: return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Button styles

struct BarPrimaryButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(destructive ? Color.red : Color.accentColor))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct BarSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(Color(nsColor: .controlColor)))
            .foregroundStyle(Color(nsColor: .labelColor))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
