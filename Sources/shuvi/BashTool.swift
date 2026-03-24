import Foundation
import ShuviAI
import ShuviAgent

/// Global reference to the currently running Process, so SIGINT handler can terminate it.
final class ProcessHolder: @unchecked Sendable {
    static let shared = ProcessHolder()
    private let lock = NSLock()
    private var _process: Process?

    var process: Process? {
        get { lock.withLock { _process } }
        set { lock.withLock { _process = newValue } }
    }

    func terminate() {
        lock.withLock { _process?.terminate() }
    }
}

struct BashTool: AgentToolProtocol {
    let name = "bash"
    let label = "Bash"
    let description = "Execute a bash command on the user's macOS system. Returns stdout, stderr, and exit code."
    let parameters = ToolSchema(
        type: "object",
        properties: [
            "command": .object([
                "type": .string("string"),
                "description": .string("The bash command to execute"),
            ]),
            "description": .object([
                "type": .string("string"),
                "description": .string("Brief description of what this command does"),
            ]),
        ],
        required: ["command"]
    )

    private let maxOutputLength = 10000

    func execute(
        toolCallId: String,
        params: JSONValue,
        onUpdate: AgentToolUpdateCallback?
    ) async throws -> AgentToolResult {
        guard let command = params["command"]?.stringValue else {
            return .error("Missing 'command' parameter")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
        process.currentDirectoryURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        ProcessHolder.shared.process = process

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            ProcessHolder.shared.process = nil
            return .error("Failed to execute command: \(error.localizedDescription)")
        }

        ProcessHolder.shared.process = nil

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        var stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        var stderr = String(data: stderrData, encoding: .utf8) ?? ""
        let exitCode = process.terminationStatus

        if stdout.count > maxOutputLength {
            stdout = String(stdout.prefix(maxOutputLength)) + "\n... (truncated)"
        }
        if stderr.count > maxOutputLength {
            stderr = String(stderr.prefix(maxOutputLength)) + "\n... (truncated)"
        }

        var result = "Exit code: \(exitCode)"
        if !stdout.isEmpty { result += "\nstdout:\n\(stdout)" }
        if !stderr.isEmpty { result += "\nstderr:\n\(stderr)" }

        return AgentToolResult(
            content: [.text(TextContent(text: result))],
            details: .object([
                "exitCode": .int(Int64(exitCode)),
                "stdout": .string(stdout),
                "stderr": .string(stderr),
            ])
        )
    }
}
