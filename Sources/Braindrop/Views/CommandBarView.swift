import SwiftUI
import AppKit

// MARK: - State

enum BarState: Equatable {
    case idle
    case generating
    case extracting
    case probing(Int, String)
    case planPreview(AgentPlan)
    case executingPlan(Int, Int, String)
    case preview
    case executing
    case installing(String)      // auto-installing a brew package
    case result(String)
    case contentResult(String)   // LLM text answer (no shell command)
    case error(String)

    static func == (lhs: BarState, rhs: BarState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.generating, .generating),
             (.extracting, .extracting), (.preview, .preview),
             (.executing, .executing): return true
        case (.probing(let a, let b), .probing(let c, let d)): return a == c && b == d
        case (.planPreview(let a), .planPreview(let b)):       return a.summary == b.summary
        case (.executingPlan(let a,let b,let c), .executingPlan(let d,let e,let f)): return a==d && b==e && c==f
        case (.installing(let a), .installing(let b)):         return a == b
        case (.result(let a), .result(let b)):               return a == b
        case (.contentResult(let a), .contentResult(let b)): return a == b
        case (.error(let a), .error(let b)):                 return a == b
        default: return false
        }
    }
}

// MARK: - ViewModel

@MainActor
class CommandBarViewModel: ObservableObject {

    @Published var query               = ""
    @Published var barState: BarState  = .idle
    @Published var command             = ""
    @Published var streamingCommand    = ""
    @Published var prediction          = PreviewResult()
    @Published var agentSteps: [AgentStep]   = []
    @Published var pendingPlan: AgentPlan?   = nil
    @Published var planStepResults: [StepResult] = []
    @Published var files: [FileContext]      = []
    @Published var workingDir: String?       = nil
    @Published var historyIndex              = -1
    @Published var idealHeight: CGFloat      = BraindropPanel.barRowHeight
    @Published var detectedOutputFile: String? = nil

    var onClose:        (() -> Void)?
    var onOpenSettings: (() -> Void)?

    private let agent     = AgentRunner.shared
    private let executor  = CommandExecutor.shared
    private let previewer = CommandPreview.shared
    private let history   = CommandHistory.shared
    private let settings  = AppSettings.shared
    private let llm       = LLMService.shared

    func onAppear(files: [FileContext], workingDir: String?) {
        query              = ""
        command            = ""
        streamingCommand   = ""
        prediction         = PreviewResult()
        agentSteps         = []
        pendingPlan        = nil
        planStepResults    = []
        detectedOutputFile = nil
        historyIndex       = -1
        barState           = .idle
        self.files         = files
        self.workingDir    = workingDir
        updateHeight()
    }

    func reset() {
        barState           = .idle
        query              = ""
        command            = ""
        streamingCommand   = ""
        prediction         = PreviewResult()
        agentSteps         = []
        pendingPlan        = nil
        planStepResults    = []
        detectedOutputFile = nil
        updateHeight()
    }

    // MARK: - Generate

    func generate() {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        agentSteps         = []
        streamingCommand   = ""
        detectedOutputFile = nil
        pendingPlan        = nil
        planStepResults    = []

        let fs = files; let wd = workingDir
        let kind = agent.classifyTask(query: q, files: fs)

        switch kind {

        // ── Content query: extract → LLM text answer (no shell command) ──────
        case .contentQuery:
            barState = .extracting
            updateHeight()
            Task {
                do {
                    let answer = try await agent.answerContentQuery(query: q, files: fs, cwd: wd)
                    barState = .contentResult(answer)
                    updateHeight()
                } catch {
                    barState = .error(error.localizedDescription)
                    updateHeight()
                }
            }

        // ── Simple: stream tokens live, show preview ─────────────────────
        case .simple:
            barState = .generating
            updateHeight()
            Task {
                do {
                    let cmd = try await llm.generateStreaming(
                        query: q, files: fs, cwd: wd,
                        onToken: { [weak self] token in
                            Task { @MainActor [weak self] in self?.streamingCommand += token }
                        }
                    )
                    // If model generated an install-echo, auto-install and regenerate
                    if let brewCmd = ToolAvailability.parseInstallEcho(cmd) {
                        await autoInstall(brewCmd: brewCmd, query: q, files: fs, cwd: wd)
                        return
                    }
                    command    = cmd
                    prediction = previewer.analyze(command: cmd, context: fs)
                    barState   = .preview
                    updateHeight()
                    if shouldAutoRun(prediction.category) { await run() }
                } catch {
                    barState = .error(error.localizedDescription)
                    updateHeight()
                }
            }

        // ── Discovery: probe loop ─────────────────────────────────────────
        case .discovery:
            barState = .generating
            updateHeight()
            Task {
                do {
                    let result = try await agent.run(
                        query: q, files: fs, cwd: wd,
                        onProgress: { [weak self] progress in
                            Task { @MainActor [weak self] in
                                guard let self else { return }
                                switch progress {
                                case .probing(let step, let cmd):
                                    self.barState = .probing(step, cmd); self.updateHeight()
                                case .finalizing:
                                    self.barState = .generating; self.updateHeight()
                                }
                            }
                        }
                    )
                    if let brewCmd = ToolAvailability.parseInstallEcho(result.command) {
                        await autoInstall(brewCmd: brewCmd, query: q, files: fs, cwd: wd)
                        return
                    }
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
    }

    // MARK: - Auto-install missing tool then regenerate

    private func autoInstall(brewCmd: String, query: String, files: [FileContext], cwd: String?) async {
        // Extract package name for display (e.g. "brew install --cask libreoffice" → "libreoffice")
        let pkg = brewCmd
            .replacingOccurrences(of: "brew install --cask ", with: "")
            .replacingOccurrences(of: "brew install ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        barState = .installing(pkg)
        updateHeight()

        do {
            let r = try await executor.execute(command: brewCmd, workingDirectory: nil)
            if r.succeeded {
                ToolAvailability.shared.markPackageInstalled(brewCmd)
                // Regenerate now that tool is available
                streamingCommand = ""
                barState = .generating
                updateHeight()
                let cmd = try await llm.generateStreaming(
                    query: query, files: files, cwd: cwd, onToken: { [weak self] token in
                        Task { @MainActor [weak self] in self?.streamingCommand += token }
                    }
                )
                command    = cmd
                prediction = previewer.analyze(command: cmd, context: files)
                barState   = .preview
                updateHeight()
                if shouldAutoRun(prediction.category) { await run() }
            } else {
                let msg = r.displayOutput.isEmpty ? "brew install \(pkg) failed." : r.displayOutput
                barState = .error(msg)
                updateHeight()
            }
        } catch {
            barState = .error(error.localizedDescription)
            updateHeight()
        }
    }

    /// Retry-after-install: install missing tool then re-run the same command.
    private func autoInstallAndRetry(brewCmd: String, retryCommand: String) async {
        let pkg = brewCmd
            .replacingOccurrences(of: "brew install --cask ", with: "")
            .replacingOccurrences(of: "brew install ", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        barState = .installing(pkg)
        updateHeight()

        do {
            let r = try await executor.execute(command: brewCmd, workingDirectory: nil)
            if r.succeeded {
                ToolAvailability.shared.markPackageInstalled(brewCmd)
                command = retryCommand
                await run()
            } else {
                barState = .error(r.displayOutput.isEmpty ? "Failed to install \(pkg)." : r.displayOutput)
                updateHeight()
            }
        } catch {
            barState = .error(error.localizedDescription)
            updateHeight()
        }
    }

    // MARK: - Execute shell command

    func run() async {
        barState = .executing
        updateHeight()
        history.add(query: query, command: command, files: files.map(\.path))
        do {
            let r = try await executor.execute(command: command, workingDirectory: workingDir)
            if r.succeeded {
                detectedOutputFile = findOutputFile(in: command, cwd: workingDir)
                let out = r.displayOutput.isEmpty ? "Done." : r.displayOutput
                barState = .result(out)
                updateHeight()
            } else {
                let errText = [r.error, r.output].filter { !$0.isEmpty }.joined(separator: "\n")
                // Auto-install if a known tool is missing
                if let missing = ToolAvailability.missingTool(from: errText),
                   let brewCmd = ToolAvailability.shared.installCommand(for: missing) {
                    let savedCmd = command
                    await autoInstallAndRetry(brewCmd: brewCmd, retryCommand: savedCmd)
                } else {
                    barState = .error(errText.isEmpty ? "Command failed (exit \(r.exitCode))" : errText)
                    updateHeight()
                }
            }
        } catch {
            barState = .error(error.localizedDescription)
            updateHeight()
        }
    }

    // MARK: - Plan execution

    func executePlan() async {
        guard let plan = pendingPlan else { return }
        barState = .executingPlan(0, plan.steps.count, "")
        updateHeight()
        history.add(query: query, command: plan.summary, files: files.map(\.path))
        do {
            let results = try await PlanExecutor.shared.executePlan(
                plan, cwd: workingDir,
                onStep: { [weak self] current, total, cmd in
                    Task { @MainActor [weak self] in
                        self?.barState = .executingPlan(current, total, cmd)
                        self?.updateHeight()
                    }
                }
            )
            planStepResults = results
            if let lastCmd = results.last?.step.command {
                detectedOutputFile = findOutputFile(in: lastCmd, cwd: workingDir)
            }
            let succeeded = results.allSatisfy { $0.succeeded }
            let summary = results.map { r in
                "[\(r.succeeded ? "✓" : "✗")] \(r.step.description)"
                + (r.output.isEmpty ? "" : "\n    \(r.output.prefix(100))")
            }.joined(separator: "\n")
            barState = succeeded
                ? .result(summary.isEmpty ? "Done." : summary)
                : .error(results.first(where: { !$0.succeeded })?.output ?? "A step failed")
        } catch {
            barState = .error(error.localizedDescription)
        }
        updateHeight()
    }

    func rejectPlan() {
        pendingPlan = nil; planStepResults = []; barState = .idle; updateHeight()
    }

    func reject() {
        barState = .idle; command = ""; prediction = PreviewResult()
        agentSteps = []; updateHeight()
    }

    func cancelExecution() {
        executor.cancel(); barState = .idle; updateHeight()
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

        case .extracting:
            return row + 1 + 44

        case .probing:
            return row + 1 + 44

        case .planPreview(let plan):
            return row + 1 + 32 + CGFloat(plan.steps.count) * 52 + 1 + 52

        case .executingPlan:
            return row + 1 + 52

        case .installing:
            return row + 1 + 60

        case .preview:
            let stepRows = CGFloat(agentSteps.count) * 30
            let stepDiv: CGFloat = agentSteps.isEmpty ? 0 : (1 + stepRows + 1)
            let effectRows = CGFloat(max(1, prediction.effects.count))
            let warnRows   = CGFloat(prediction.warnings.count)
            return row + 1 + stepDiv + 44 + 1 + effectRows * 28 + warnRows * 22 + 1 + 52

        case .executing:
            return row + 1 + 44

        case .result(let out):
            let stepH: CGFloat = agentSteps.isEmpty ? 0 : (1 + CGFloat(agentSteps.count) * 30 + 1)
            let lines = CGFloat(out.components(separatedBy: "\n").prefix(6).count)
            let revealH: CGFloat = detectedOutputFile != nil ? 36 : 0
            return row + 1 + stepH + max(40, lines * 18 + 16) + 1 + 36 + revealH

        case .contentResult(let text):
            let approxLines = max(3, min(8, CGFloat(text.count) / 60))
            return row + 1 + max(60, approxLines * 18 + 24) + 1 + 36

        case .error:
            return row + 1 + 52
        }
    }

    // MARK: - Output file detection

    private func findOutputFile(in command: String, cwd: String?) -> String? {
        let pattern = #""([^"]+\.[a-zA-Z0-9]{2,6})""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(command.startIndex..., in: command)
        let paths: [String] = regex.matches(in: command, range: range).compactMap { m in
            guard let r = Range(m.range(at: 1), in: command) else { return nil }
            return String(command[r])
        }
        for path in paths.reversed() {
            let full = path.hasPrefix("/") ? path : ((cwd.map { $0 + "/" } ?? "") + path)
            if FileManager.default.fileExists(atPath: full) { return full }
        }
        return nil
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
                if isExpanded { Divider(); expandedSection }
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
            // Left: dot + context label — also acts as drag handle
            HStack(spacing: 5) {
                Circle().fill(dotColor).frame(width: 8, height: 8)
                if !viewModel.files.isEmpty {
                    fileCountLabel
                } else if let cwd = viewModel.workingDir {
                    Text(URL(fileURLWithPath: cwd).lastPathComponent)
                        .font(.system(size: 12)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .frame(width: 90, alignment: .leading)
            .padding(.leading, 14)
            // Drag handle overlay on the left zone
            .background(WindowDragHandle())

            // Center: text field / live streaming preview
            ZStack {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 0.5)
                    )
                HStack(spacing: 6) {
                    if isSpinning { ProgressView().scaleEffect(0.55).progressViewStyle(.circular) }
                    if viewModel.barState == .generating && !viewModel.streamingCommand.isEmpty {
                        Text(viewModel.streamingCommand)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        TextField("Ask anything about your files…", text: $viewModel.query)
                            .textFieldStyle(.plain).font(.system(size: 13))
                            .focused($focused)
                            .onSubmit { viewModel.generate() }
                            .onKeyPress(.upArrow)   { viewModel.historyUp();   return .handled }
                            .onKeyPress(.downArrow) { viewModel.historyDown(); return .handled }
                            .disabled(isInputDisabled)
                    }
                }
                .padding(.horizontal, 8)
            }
            .frame(height: 26).padding(.horizontal, 10)

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

    private var isSpinning: Bool {
        switch viewModel.barState {
        case .generating, .extracting, .probing, .executing, .executingPlan, .installing: return true
        default: return false
        }
    }
    private var isInputDisabled: Bool {
        switch viewModel.barState {
        case .generating, .extracting, .probing, .executing, .executingPlan, .installing: return true
        default: return false
        }
    }

    @ViewBuilder
    private var fileCountLabel: some View {
        let files = viewModel.files
        let byKind = Dictionary(grouping: files) { $0.fileKind ?? $0.ext.uppercased() }
        if byKind.keys.count == 1, let kind = byKind.keys.first {
            Text("\(files.count) \(kind)").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("\(files.count) files").font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    private var dotColor: Color {
        switch viewModel.barState {
        case .idle:
            if !viewModel.files.isEmpty { return .red }
            if viewModel.workingDir != nil { return .blue }
            return Color(nsColor: .tertiaryLabelColor)
        case .generating:    return .orange
        case .extracting:    return .purple
        case .installing:    return .orange
        case .probing:       return .orange
        case .planPreview:   return .purple
        case .executingPlan: return .orange
        case .preview:       return .blue
        case .executing:     return .orange
        case .result:        return .green
        case .contentResult: return .green
        case .error:         return .red
        }
    }

    private var modelButton: some View {
        Menu {
            // Show short name of active model
            let shortName = AppSettings.shared.ollamaModel.components(separatedBy: "/").last ?? AppSettings.shared.ollamaModel
            Text(shortName).font(.system(size: 11)).foregroundStyle(.secondary)
            Divider()
            ForEach([
                "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit",
                "mlx-community/Qwen2.5-Coder-3B-Instruct-4bit",
                "mlx-community/Qwen2.5-Coder-7B-Instruct-4bit",
                "mlx-community/Qwen2.5-0.5B-Instruct-4bit",
                "mlx-community/Llama-3.2-3B-Instruct-4bit"
            ], id: \.self) { m in
                Button(m.components(separatedBy: "/").last ?? m) { AppSettings.shared.ollamaModel = m }
            }
            Divider()
            Button("Settings…") { viewModel.onOpenSettings?() }
        } label: {
            // Show just an icon — tooltip reveals the full model name
            Image(systemName: "sparkles")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help(AppSettings.shared.ollamaModel.components(separatedBy: "/").last ?? AppSettings.shared.ollamaModel)
    }

    // MARK: Expanded section

    @ViewBuilder
    private var expandedSection: some View {
        switch viewModel.barState {
        case .installing(let pkg):                installingSection(package: pkg)
        case .extracting:                         extractingSection
        case .probing(let s, let c):              probingSection(step: s, command: c)
        case .planPreview(let p):                 planPreviewSection(plan: p)
        case .executingPlan(let c, let t, let m): executingPlanSection(current: c, total: t, command: m)
        case .preview:                            previewSection
        case .executing:                          executingSection
        case .result(let o):                      resultSection(output: o)
        case .contentResult(let a):               contentResultSection(answer: a)
        case .error(let e):                       errorSection(message: e)
        default:                                  EmptyView()
        }
    }

    // MARK: Installing

    private func installingSection(package: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6)
            VStack(alignment: .leading, spacing: 3) {
                Text("Installing \(package)…")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                Text("brew install \(package)")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                Text("Will retry your command automatically")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).frame(height: 60)
    }

    // MARK: Extracting

    private var extractingSection: some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Analysing file contents…")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text("Extracting text with PDFKit / textutil")
                    .font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            Spacer()
        }
        .padding(.horizontal, 14).frame(height: 44)
    }

    // MARK: Probing

    private func probingSection(step: Int, command: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6)
            VStack(alignment: .leading, spacing: 2) {
                Text("Step \(step) · gathering info")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                Text(command)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
        }
        .padding(.horizontal, 14).frame(height: 44)
    }

    // MARK: Plan preview

    private func planPreviewSection(plan: AgentPlan) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "list.bullet.clipboard").font(.system(size: 11)).foregroundStyle(.purple)
                Text(plan.summary).font(.system(size: 12, weight: .medium)).lineLimit(1)
                Spacer()
                Text("\(plan.steps.count) steps").font(.system(size: 11)).foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 14).frame(height: 32)

            ForEach(plan.steps) { step in
                HStack(spacing: 8) {
                    Text("\(step.id)")
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.purple.opacity(0.7)))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.description)
                            .font(.system(size: 11, weight: .medium)).lineLimit(1)
                        Text(step.command)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 52)
            }

            Divider()
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel") { viewModel.rejectPlan() }
                    .buttonStyle(BarSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Execute Plan") { Task { await viewModel.executePlan() } }
                    .buttonStyle(BarPrimaryButtonStyle()).keyboardShortcut(.defaultAction)
            }
            .padding(.horizontal, 14).frame(height: 52)
        }
    }

    // MARK: Executing plan

    private func executingPlanSection(current: Int, total: Int, command: String) -> some View {
        HStack(spacing: 10) {
            ProgressView().scaleEffect(0.6)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text("Step \(current) of \(total)")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                    if total > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Color(nsColor: .separatorColor)).frame(height: 3)
                                RoundedRectangle(cornerRadius: 2).fill(Color.orange)
                                    .frame(width: geo.size.width * CGFloat(current) / CGFloat(total), height: 3)
                            }
                        }
                        .frame(width: 60, height: 3)
                    }
                }
                if !command.isEmpty {
                    Text(command).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14).frame(height: 52)
    }

    // MARK: Preview

    private var previewSection: some View {
        VStack(spacing: 0) {
            if !viewModel.agentSteps.isEmpty {
                agentStepsList(viewModel.agentSteps); Divider()
            }
            HStack(spacing: 8) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                Text(viewModel.command)
                    .font(.system(size: 12, design: .monospaced)).lineLimit(2).textSelection(.enabled)
                Spacer()
                copyButton
            }
            .padding(.horizontal, 14).frame(height: 44)

            if !viewModel.prediction.effects.isEmpty || !viewModel.prediction.warnings.isEmpty {
                Divider(); effectsList
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
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.orange.opacity(0.8)))
                    VStack(alignment: .leading, spacing: 1) {
                        Text(step.command)
                            .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                        Text(step.output.prefix(80))
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer()
                }
                .padding(.horizontal, 14).frame(height: 30)
            }
        }
        .padding(.vertical, 4)
    }

    private var effectsList: some View {
        VStack(spacing: 0) {
            ForEach(viewModel.prediction.effects) { effect in
                HStack(spacing: 8) {
                    Image(systemName: effect.symbol).font(.system(size: 10))
                        .foregroundStyle(effectColor(effect)).frame(width: 14)
                    Text(effect.verb).font(.system(size: 11, weight: .medium))
                        .foregroundStyle(effectColor(effect)).frame(width: 44, alignment: .leading)
                    Text(effect.label).font(.system(size: 11, design: .monospaced))
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
                .buttonStyle(BarSecondaryButtonStyle()).keyboardShortcut(.cancelAction)
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

    // MARK: Result (shell command output)

    private func resultSection(output: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if !viewModel.agentSteps.isEmpty { agentStepsList(viewModel.agentSteps); Divider() }

            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                Text("Done").font(.system(size: 12, weight: .medium))
                Spacer()
                if let path = viewModel.detectedOutputFile {
                    Button {
                        NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
                    } label: {
                        Label("Reveal", systemImage: "folder").font(.system(size: 12))
                    }
                    .buttonStyle(BarSecondaryButtonStyle())
                }
                Button("Dismiss") { viewModel.reset() }.buttonStyle(BarSecondaryButtonStyle())
            }
            .padding(.horizontal, 14).frame(height: 36)

            if output != "Done." {
                Divider()
                ScrollView {
                    Text(output)
                        .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 14).padding(.vertical, 6)
                }
                .frame(maxHeight: 90)
            }
        }
    }

    // MARK: Content result (LLM text answer)

    private func contentResultSection(answer: String) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").foregroundStyle(.purple)
                Text("AI Answer").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Dismiss") { viewModel.reset() }.buttonStyle(BarSecondaryButtonStyle())
            }
            .padding(.horizontal, 14).frame(height: 36)

            Divider()
            ScrollView {
                Text(answer)
                    .font(.system(size: 12)).foregroundStyle(.primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14).padding(.vertical, 8)
            }
            .frame(maxHeight: 120)
        }
    }

    // MARK: Error

    private func errorSection(message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red).padding(.top, 1)
            Text(message)
                .font(.system(size: 12)).fixedSize(horizontal: false, vertical: true).lineLimit(4)
                .textSelection(.enabled)
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

// MARK: - Window drag handle

/// Transparent NSView that lets the user drag the panel by clicking anywhere
/// in the bar row that isn't a text field or button.
struct WindowDragHandle: NSViewRepresentable {
    func makeNSView(context: Context) -> DragHandleView { DragHandleView() }
    func updateNSView(_ nsView: DragHandleView, context: Context) {}

    class DragHandleView: NSView {
        override func mouseDown(with event: NSEvent) {
            // Initiate window drag — works even on non-activating panels
            window?.performDrag(with: event)
        }
        // Forward mouseUp/mouseDragged so AppKit drag bookkeeping completes
        override func mouseUp(with event: NSEvent)      { super.mouseUp(with: event) }
        override func mouseDragged(with event: NSEvent) { super.mouseDragged(with: event) }
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
