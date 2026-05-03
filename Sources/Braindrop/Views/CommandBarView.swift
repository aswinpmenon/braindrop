import SwiftUI
import AppKit

// MARK: - State

enum BarState: Equatable {
    case idle
    case generating
    case probing(Int, String)   // step number, probe command
    case preview
    case executing
    case result(String)
    case error(String)

    static func == (lhs: BarState, rhs: BarState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.generating, .generating),
             (.preview, .preview), (.executing, .executing): return true
        case (.probing(let a, let b), .probing(let c, let d)): return a == c && b == d
        case (.result(let a), .result(let b)): return a == b
        case (.error(let a), .error(let b)): return a == b
        default: return false
        }
    }
}

// MARK: - ViewModel

@MainActor
class CommandBarViewModel: ObservableObject {

    @Published var query       = ""
    @Published var barState: BarState = .idle
    @Published var command     = ""
    @Published var prediction  = PreviewResult()
    @Published var agentSteps: [AgentStep] = []
    @Published var files: [FileContext] = []
    @Published var workingDir: String? = nil
    @Published var historyIndex = -1
    @Published var idealHeight: CGFloat = BraindropPanel.barRowHeight

    var onClose:        (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let agent    = AgentRunner.shared
    private let executor = CommandExecutor.shared
    private let previewer = CommandPreview.shared
    private let history  = CommandHistory.shared
    private let settings = AppSettings.shared

    func onAppear(files: [FileContext], workingDir: String?) {
        query        = ""
        command      = ""
        prediction   = PreviewResult()
        agentSteps   = []
        historyIndex = -1
        barState     = .idle
        self.files      = files
        self.workingDir = workingDir
        updateHeight()
    }

    func reset() {
        barState   = .idle
        query      = ""
        command    = ""
        prediction = PreviewResult()
        agentSteps = []
        updateHeight()
    }

    // MARK: - Actions

    func generate() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        barState   = .generating
        agentSteps = []
        updateHeight()
        let fs = files; let wd = workingDir
        Task {
            do {
                let result = try await agent.run(
                    query: q,
                    files: fs,
                    cwd: wd,
                    onProgress: { [weak self] progress in
                        guard let self = self else { return }
                        switch progress {
                        case .probing(let step, let cmd):
                            self.barState = .probing(step, cmd)
                            self.updateHeight()
                        case .finalizing:
                            self.barState = .generating
                            self.updateHeight()
                        }
                    }
                )
                command    = result.command
                prediction = previewer.analyze(command: result.command, context: fs)
                agentSteps = result.steps
                barState   = .preview
                updateHeight()
                if shouldAutoRun(prediction.category) { await run() }
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
            barState = r.succeeded ? .result(out) : .error(r.error.isEmpty ? "Command failed (exit \(r.exitCode))" : r.error)
        } catch {
            barState = .error(error.localizedDescription)
        }
        updateHeight()
    }

    func reject() {
        barState   = .idle
        command    = ""
        prediction = PreviewResult()
        agentSteps = []
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

    // MARK: - Height

    func updateHeight() { idealHeight = computeHeight() }

    private func computeHeight() -> CGFloat {
        let row = BraindropPanel.barRowHeight
        switch barState {
        case .idle, .generating:
            return row

        case .probing:
            return row + 1 + 44

        case .preview:
            let stepRows  = CGFloat(agentSteps.count) * 30
            let stepDivider: CGFloat = agentSteps.isEmpty ? 0 : (1 + stepRows + 1)
            let effectRows = CGFloat(max(1, prediction.effects.count))
            let warnRows   = CGFloat(prediction.warnings.count)
            return row + 1 + stepDivider + 44 + 1 + effectRows * 28 + warnRows * 22 + 1 + 52

        case .executing:
            return row + 1 + 44

        case .result(let out):
            let hasSteps = !agentSteps.isEmpty
            let stepH: CGFloat = hasSteps ? (1 + CGFloat(agentSteps.count) * 30 + 1) : 0
            let lines = CGFloat(out.components(separatedBy: "\n").prefix(6).count)
            return row + 1 + stepH + max(40, lines * 18 + 16) + 1 + 36

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
            RoundedRectangle(cornerRadius: 9)
                .fill(Color(nsColor: .windowBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .strokeBorder(Color(nsColor: .separatorColor).opacity(0.7), lineWidth: 0.5)
                )

            VStack(spacing: 0) {
                barRow.frame(height: BraindropPanel.barRowHeight)

                let isExpanded = viewModel.barState != .idle && viewModel.barState != .generating
                if isExpanded {
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

            // Left: dot + context label
            HStack(spacing: 5) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                if !viewModel.files.isEmpty {
                    fileCountLabel
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

            // Center: text field
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )

                HStack(spacing: 6) {
                    if viewModel.barState == .generating || viewModel.barState == .probing(0, "") {
                        ProgressView().scaleEffect(0.55).progressViewStyle(.circular)
                    } else if case .probing = viewModel.barState {
                        ProgressView().scaleEffect(0.55).progressViewStyle(.circular)
                    }
                    TextField("Ask anything about your files…", text: $viewModel.query)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13))
                        .focused($focused)
                        .onSubmit { viewModel.generate() }
                        .onKeyPress(.upArrow)   { viewModel.historyUp();   return .handled }
                        .onKeyPress(.downArrow) { viewModel.historyDown(); return .handled }
                        .disabled({
                            switch viewModel.barState {
                            case .generating, .probing, .executing: return true
                            default: return false
                            }
                        }())
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 26)
            .padding(.horizontal, 10)

            // Right: model + history + settings
            HStack(spacing: 10) {
                modelButton
                Button { CommandHistory.shared.entries.isEmpty ? () : viewModel.historyUp() } label: {
                    Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Command history (↑)")

                Button { viewModel.onOpenSettings?() } label: {
                    Image(systemName: "gearshape").font(.system(size: 13)).foregroundStyle(.secondary)
                }
                .buttonStyle(.plain).help("Settings")
            }
            .padding(.trailing, 12)
        }
    }

    // Rich file count label with type breakdown
    @ViewBuilder
    private var fileCountLabel: some View {
        let files = viewModel.files
        let byKind = Dictionary(grouping: files) { $0.fileKind ?? $0.ext.uppercased() }
        if byKind.keys.count == 1, let kind = byKind.keys.first {
            Text("\(files.count) \(kind)")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        } else {
            Text("\(files.count) files")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var dotColor: Color {
        switch viewModel.barState {
        case .idle:
            if !viewModel.files.isEmpty { return .red }
            if viewModel.workingDir != nil { return .blue }
            return Color(nsColor: .tertiaryLabelColor)
        case .generating: return .orange
        case .probing:    return .orange
        case .preview:    return .blue
        case .executing:  return .orange
        case .result:     return .green
        case .error:      return .red
        }
    }

    private var modelButton: some View {
        Menu {
            Text("Model").font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            ForEach([
                "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
                "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
                "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                "mlx-community/Qwen2.5-0.5B-Instruct-4bit"
            ], id: \.self) { m in
                Button(m.components(separatedBy: "/").last ?? m) { AppSettings.shared.ollamaModel = m }
            }
            Divider()
            Button("Settings…") { viewModel.onOpenSettings?() }
        } label: {
            HStack(spacing: 3) {
                Text(AppSettings.shared.ollamaModel.components(separatedBy: "/").last ?? AppSettings.shared.ollamaModel)
                    .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .medium)).foregroundStyle(.tertiary)
            }
        }
        .menuStyle(.borderlessButton).fixedSize()
    }

    // MARK: Expanded section

    @ViewBuilder
    private var expandedSection: some View {
        switch viewModel.barState {
        case .probing(let step, let cmd): probingSection(step: step, command: cmd)
        case .preview:    previewSection
        case .executing:  executingSection
        case .result(let o): resultSection(output: o)
        case .error(let e):  errorSection(message: e)
        default: EmptyView()
        }
    }

    // MARK: Probing

    private func probingSection(step: Int, command: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(step) · gathering information")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(command)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .frame(height: 44)
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(spacing: 0) {
            // Agent steps trail (shown if any probes were taken)
            if !viewModel.agentSteps.isEmpty {
                agentStepsList(viewModel.agentSteps)
                Divider()
            }

            // Final command line
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(viewModel.command)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.primary)
                    .lineLimit(2).textSelection(.enabled)
                Spacer()
                copyButton
            }
            .padding(.horizontal, 14).frame(height: 44)

            if !viewModel.prediction.effects.isEmpty || !viewModel.prediction.warnings.isEmpty {
                Divider()
                effectsList
            }

            Divider()
            actionButtons.frame(height: 52)
        }
    }

    private func agentStepsList(_ steps: [AgentStep]) -> some View {
        VStack(spacing: 0) {
            ForEach(steps) { step in
                HStack(spacing: 8) {
                    Text("\(step.index)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.orange.opacity(0.8)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.command)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(step.output.prefix(80))
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14)
                .frame(height: 30)
            }
        }
        .padding(.vertical, 4)
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
                        .lineLimit(1).truncationMode(.middle)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 28)
            }
            ForEach(viewModel.prediction.warnings, id: \.self) { w in
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10)).foregroundStyle(.orange)
                    Text(w).font(.system(size: 11)).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 22)
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
            Text("Running…").font(.system(size: 12)).foregroundStyle(.secondary)
            Text(viewModel.command)
                .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.middle)
            Spacer()
            Button("Cancel") { viewModel.cancelExecution() }.buttonStyle(BarSecondaryButtonStyle())
        }
        .padding(.horizontal, 14).frame(height: 44)
    }

    // MARK: Result

    private func resultSection(output: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            // Agent steps (collapsed summary)
            if !viewModel.agentSteps.isEmpty {
                agentStepsList(viewModel.agentSteps)
                Divider()
            }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Done").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Dismiss") { viewModel.reset() }.buttonStyle(BarSecondaryButtonStyle())
            }
            .padding(.horizontal, 14).frame(height: 36)

            if output != "Done." {
                Divider()
                ScrollView {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .frame(maxHeight: 90)
            }
        }
    }

    // MARK: Error

    private func errorSection(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).padding(.top, 1)
            Text(message)
                .font(.system(size: 12)).foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true).lineLimit(3)
            Spacer()
            Button("Dismiss") { viewModel.reset() }.buttonStyle(BarSecondaryButtonStyle())
        }
        .padding(.horizontal, 14).padding(.vertical, 14)
    }

    // MARK: Helpers

    private var copyButton: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(viewModel.command, forType: .string)
        } label: {
            Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(.tertiary)
        }
        .buttonStyle(.plain).help("Copy command")
    }

    private func effectColor(_ e: FileEffect) -> Color {
        switch e {
        case .created:  return .green
        case .modified: return .orange
        case .deleted:  return .red
        case .moved:    return .blue
        case .read:     return Color(nsColor: .secondaryLabelColor)
        }
    }
}

// MARK: - Button styles

struct BarPrimaryButtonStyle: ButtonStyle {
    var destructive = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 14).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(destructive ? Color.red : Color.accentColor))
            .foregroundStyle(.white)
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

struct BarSecondaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12))
            .padding(.horizontal, 12).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlColor)))
            .foregroundStyle(Color(nsColor: .labelColor))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}
