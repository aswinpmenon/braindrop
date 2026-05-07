import Foundation
import AppKit

/// Manages the lifecycle of the `mlx_lm.server` process as an in-process child.
/// The server is started on app launch and terminated when the app quits.
@MainActor
class MLXServerManager: ObservableObject {
    static let shared = MLXServerManager()

    enum ServerState {
        case idle
        case starting
        case running
        case failed(String)
    }

    @Published private(set) var state: ServerState = .idle

    private var process: Process?
    private var startupTask: Task<Void, Never>?

    // MLX server config
    private let model   = "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"
    private let port    = 8080
    private let host    = "127.0.0.1"

    // Candidate Python paths that may have mlx_lm installed
    private let pythonCandidates = [
        "/opt/homebrew/bin/python3.11",
        "/opt/homebrew/bin/python3.12",
        "/opt/homebrew/bin/python3",
        "/usr/local/bin/python3.11",
        "/usr/local/bin/python3",
        "/usr/bin/python3",
    ]

    private init() {}

    // MARK: - Public API

    /// Start the server in the background. Safe to call multiple times.
    func start() {
        guard case .idle = state else { return }
        state = .starting
        startupTask = Task.detached(priority: .utility) { [weak self] in
            await self?.doStart()
        }
    }

    /// Terminate the server. Called on app quit.
    func stop() {
        startupTask?.cancel()
        if let p = process, p.isRunning {
            p.terminate()
            // Give it a moment to clean up
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
                if p.isRunning { p.interrupt() }
            }
        }
        process = nil
        state = .idle
    }

    // MARK: - Private

    private func doStart() async {
        // Kill any stale server from a previous session
        killStale()

        guard let python = findPython() else {
            await MainActor.run {
                self.state = .failed("mlx_lm not found. Run: pip3 install mlx-lm")
            }
            return
        }

        let p = Process()
        p.executableURL = URL(fileURLWithPath: python)
        p.arguments = [
            "-m", "mlx_lm.server",
            "--model", model,
            "--port", "\(port)",
            "--host", host,
        ]

        // Merge Homebrew paths so mlx_lm can find its dependencies
        var env = ProcessInfo.processInfo.environment
        let brewBin = "/opt/homebrew/bin:/usr/local/bin"
        env["PATH"] = "\(brewBin):\(env["PATH"] ?? "/usr/bin:/bin")"
        p.environment = env

        // Discard stdout/stderr so no Terminal window appears
        p.standardOutput = Pipe()
        p.standardError  = Pipe()

        p.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if case .running = self.state {
                    self.state = .failed("MLX server exited (code \(proc.terminationStatus))")
                }
            }
        }

        do {
            try p.run()
        } catch {
            await MainActor.run {
                self.state = .failed("Failed to launch: \(error.localizedDescription)")
            }
            return
        }

        await MainActor.run { self.process = p }

        // Poll until the server responds on the health endpoint
        let ready = await waitForServer()
        await MainActor.run {
            self.state = ready ? .running : .failed("Server did not start in time")
        }
    }

    /// Poll /v1/models until the server is ready (up to 120 s).
    private func waitForServer() async -> Bool {
        let url = URL(string: "http://\(host):\(port)/v1/models")!
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if Task.isCancelled { return false }
            do {
                let (_, resp) = try await URLSession.shared.data(from: url)
                if (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
            } catch {}
            try? await Task.sleep(nanoseconds: 2_000_000_000) // 2 s
        }
        return false
    }

    /// Kill any pre-existing mlx_lm.server process (e.g., leftover from a crash).
    private func killStale() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "mlx_lm.server"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Find the first Python binary that has mlx_lm installed.
    private func findPython() -> String? {
        for candidate in pythonCandidates {
            guard FileManager.default.fileExists(atPath: candidate) else { continue }
            let check = Process()
            check.executableURL = URL(fileURLWithPath: candidate)
            check.arguments = ["-c", "import mlx_lm"]
            check.standardOutput = Pipe(); check.standardError = Pipe()
            try? check.run(); check.waitUntilExit()
            if check.terminationStatus == 0 { return candidate }
        }
        return nil
    }
}
