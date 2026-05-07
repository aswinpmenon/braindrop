import Foundation
import Combine

/// Manages the lifecycle of the `mlx_lm.server` process as an in-process child.
/// The server is started on app launch and terminated when the app quits.
class MLXServerManager: ObservableObject {
    static let shared = MLXServerManager()

    enum ServerState {
        case idle
        case starting
        case running
        case failed(String)
    }

    /// Always mutated on the main thread so SwiftUI / Combine works correctly.
    @Published private(set) var state: ServerState = .idle

    private var process: Process?
    private var startupTask: Task<Void, Never>?

    // MLX server config
    private let model = "mlx-community/Qwen2.5-Coder-1.5B-Instruct-4bit"
    private let port  = 8080
    private let host  = "127.0.0.1"

    // Python candidates checked in order — first one with mlx_lm wins
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

    /// Start the server asynchronously. Safe to call multiple times.
    func start() {
        setState(.starting)
        startupTask = Task.detached(priority: .utility) { [weak self] in
            await self?.doStart()
        }
    }

    /// Terminate the server. Call from applicationWillTerminate.
    func stop() {
        startupTask?.cancel()
        process?.terminate()
        process = nil
        setState(.idle)
    }

    // MARK: - Private

    /// Runs entirely off the main thread — no main-thread blocking.
    private func doStart() async {
        killStale()   // blocking — fine off main thread

        guard let python = findPython() else {
            setState(.failed("mlx_lm not found — run: pip3.11 install mlx-lm"))
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

        var env = ProcessInfo.processInfo.environment
        let brewBin = "/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin"
        env["PATH"] = "\(brewBin):\(env["PATH"] ?? "/usr/bin:/bin")"
        p.environment = env

        // Fully detach from any controlling terminal:
        // closing stdin prevents the process from ever waiting on terminal input,
        // and redirecting stdout/stderr to /dev/null stops any output reaching
        // a parent terminal session.
        p.standardInput  = FileHandle.nullDevice
        p.standardOutput = FileHandle.nullDevice
        p.standardError  = FileHandle.nullDevice

        p.terminationHandler = { [weak self] proc in
            self?.setState(.failed("MLX server exited (code \(proc.terminationStatus))"))
        }

        do {
            try p.run()
        } catch {
            setState(.failed("Launch failed: \(error.localizedDescription)"))
            return
        }
        self.process = p

        let ready = await waitForServer()
        setState(ready ? .running : .failed("Server did not respond in time"))
    }

    /// Poll /v1/models with 2 s intervals until the server says 200 OK (up to 120 s).
    private func waitForServer() async -> Bool {
        let url = URL(string: "http://\(host):\(port)/v1/models")!
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest  = 3
        cfg.timeoutIntervalForResource = 3
        let session = URLSession(configuration: cfg)
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if Task.isCancelled { return false }
            if let (_, resp) = try? await session.data(from: url),
               (resp as? HTTPURLResponse)?.statusCode == 200 { return true }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        return false
    }

    /// Kill any pre-existing mlx_lm.server — blocking, must run off main thread.
    private func killStale() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        p.arguments = ["-f", "mlx_lm.server"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Find the first Python that has mlx_lm installed — blocking, off main thread.
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

    // MARK: - Thread-safe state update

    private func setState(_ newState: ServerState) {
        DispatchQueue.main.async { [weak self] in
            self?.state = newState
        }
    }
}
