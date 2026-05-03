import Foundation

struct ExecutionResult {
    let command: String
    let output: String
    let error: String
    let exitCode: Int32
    var succeeded: Bool { exitCode == 0 }
    var displayOutput: String {
        let combined = [output, error].filter { !$0.isEmpty }.joined(separator: "\n")
        return combined.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum ExecutionError: LocalizedError {
    case shellNotFound
    case timeout
    case cancelled

    var errorDescription: String? {
        switch self {
        case .shellNotFound: return "Shell not found"
        case .timeout: return "Command timed out after 30 seconds"
        case .cancelled: return "Command was cancelled"
        }
    }
}

class CommandExecutor {
    static let shared = CommandExecutor()
    private var runningProcess: Process?
    private init() {}

    func execute(command: String, workingDirectory: String?) async throws -> ExecutionResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()

                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.currentDirectoryURL = workingDirectory.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory())

                // Inherit environment + common tool paths
                var env = ProcessInfo.processInfo.environment
                let paths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                let existingPath = env["PATH"] ?? ""
                env["PATH"] = (paths + [existingPath]).joined(separator: ":")
                process.environment = env

                self.runningProcess = process

                do {
                    try process.run()
                } catch {
                    continuation.resume(throwing: error)
                    return
                }

                // Timeout after 30s
                let timeoutItem = DispatchWorkItem {
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: timeoutItem)

                process.waitUntilExit()
                timeoutItem.cancel()
                self.runningProcess = nil

                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData, encoding: .utf8) ?? ""
                let error = String(data: errData, encoding: .utf8) ?? ""

                continuation.resume(returning: ExecutionResult(
                    command: command,
                    output: output,
                    error: error,
                    exitCode: process.terminationStatus
                ))
            }
        }
    }

    func cancel() {
        runningProcess?.terminate()
        runningProcess = nil
    }

    // Lightweight probe execution: 10s timeout, no cancel handle, output capped at 4 KB.
    func executeProbe(command: String, workingDirectory: String?) async throws -> ExecutionResult {
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                let outPipe = Pipe()
                let errPipe = Pipe()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                process.standardOutput = outPipe
                process.standardError = errPipe
                process.currentDirectoryURL = workingDirectory.map { URL(fileURLWithPath: $0) } ?? URL(fileURLWithPath: NSHomeDirectory())
                var env = ProcessInfo.processInfo.environment
                let paths = ["/usr/local/bin", "/opt/homebrew/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
                env["PATH"] = (paths + [env["PATH"] ?? ""]).joined(separator: ":")
                process.environment = env
                let timeoutItem = DispatchWorkItem { process.terminate() }
                do { try process.run() } catch { continuation.resume(throwing: error); return }
                DispatchQueue.global().asyncAfter(deadline: .now() + 10, execute: timeoutItem)
                process.waitUntilExit()
                timeoutItem.cancel()
                let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: outData.prefix(4096), encoding: .utf8) ?? ""
                let error  = String(data: errData.prefix(512),  encoding: .utf8) ?? ""
                continuation.resume(returning: ExecutionResult(command: command, output: output, error: error, exitCode: process.terminationStatus))
            }
        }
    }
}
