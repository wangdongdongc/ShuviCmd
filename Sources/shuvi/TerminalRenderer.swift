import Foundation
import ShuviAI
import ShuviAgent

/// Manages output display with a quiet-accumulate + collapse-on-end approach.
/// During streaming, shows a brief waiting indicator.
/// When a block ends, replaces it with a single-line summary.
final class TerminalRenderer: @unchecked Sendable {
    private let lock = NSLock()

    /// Whether we are currently inside a streaming block
    private var inBlock: Bool = false
    /// The label shown for the current block (e.g. "text", "thinking", "tool")
    private var blockLabel: String = ""
    /// Accumulated usage across all turns
    private var totalInput: Int = 0
    private var totalOutput: Int = 0
    private var totalCacheRead: Int = 0
    private var totalCacheWrite: Int = 0
    private var totalCost: Double = 0

    /// Max characters shown in collapsed summary
    private let maxSummaryLength = 80

    // MARK: - Text

    func onTextDelta(_ delta: String) {
        lock.withLock {
            if !inBlock {
                _startBlock(label: "text", color: "2")
            }
        }
    }

    func onTextEnd(_ fullText: String) {
        lock.withLock {
            guard inBlock else { return }
            let trimmed = fullText.trimmingCharacters(in: .whitespacesAndNewlines)
            _endBlock("\u{001B}[2m[text]\u{001B}[0m \(trimmed)")
        }
    }

    // MARK: - Thinking

    func onThinkingDelta(_ delta: String) {
        lock.withLock {
            if !inBlock {
                _startBlock(label: "thinking", color: "35")
            }
        }
    }

    func onThinkingEnd(_ fullText: String) {
        lock.withLock {
            guard inBlock else { return }
            let summary = _oneLine(fullText)
            _endBlock("\u{001B}[35m[thinking]\u{001B}[0m \(summary)")
        }
    }

    // MARK: - Tool call

    func onToolCallDelta(_ delta: String) {
        lock.withLock {
            if !inBlock {
                _startBlock(label: "tool", color: "36")
            }
        }
    }

    func onToolCallEnd(_ toolCall: ToolCall) {
        lock.withLock {
            guard inBlock else { return }

            // Build a display summary from tool arguments
            let summary: String
            let desc: String?
            switch toolCall.name {
            case "bash":
                summary = toolCall.arguments["command"]?.stringValue ?? toolCall.name
                desc = toolCall.arguments["description"]?.stringValue
            case "read":
                summary = toolCall.arguments["path"]?.stringValue ?? toolCall.name
                desc = nil
            default:
                // Generic: show first required string argument or tool name
                summary = toolCall.arguments.objectValue?
                    .first(where: { $0.value.stringValue != nil })?.value.stringValue ?? toolCall.name
                desc = nil
            }

            _clearCurrentLine()
            var line = "\u{001B}[36m[\(toolCall.name)]\u{001B}[0m \(summary)"
            if let desc = desc {
                line += " \u{001B}[2m(\(desc))\u{001B}[0m"
            }
            _rawWrite(line)
            inBlock = false
            blockLabel = ""
            needsToolLineNewline = true
        }
    }

    /// Whether the tool line still needs a trailing newline.
    /// For bash: newline comes after user confirm input. For auto-allow tools: we add it here.
    private var needsToolLineNewline = false

    /// Call this to finalize the tool line with a newline if it hasn't been done yet.
    func flushToolLine() {
        lock.withLock {
            if needsToolLineNewline {
                _rawWrite("\n")
                needsToolLineNewline = false
            }
        }
    }

    // MARK: - Tool execution

    func onToolConfirm(command: String) {
        lock.withLock {
            // Append confirm prompt on the same line as [tool]
            _rawWrite("  (y/n): ")
            needsToolLineNewline = false  // readLine will provide the newline
        }
    }

    /// Called after user responds to confirm prompt, to finalize the tool line.
    func onToolConfirmResult(_ response: String) {
        lock.withLock {
            // User's input is already echoed by readLine, just add newline
            // Nothing extra needed — readLine already printed the response + newline
        }
    }

    func onToolResult(name: String, result: AgentToolResult, isError: Bool) {
        // Intentionally not displayed
    }

    // MARK: - Errors & lifecycle

    func onInfo(_ message: String) {
        lock.withLock {
            _rawWrite("\u{001B}[2m[info]\u{001B}[0m \(message)\n")
        }
    }

    func onError(_ message: String) {
        lock.withLock {
            if inBlock {
                _clearCurrentLine()
                inBlock = false
            }
            _rawWrite("\u{001B}[31m[error]\u{001B}[0m \(message)\n")
        }
    }

    func addUsage(_ usage: Usage) {
        lock.withLock {
            totalInput += usage.input
            totalOutput += usage.output
            totalCacheRead += usage.cacheRead
            totalCacheWrite += usage.cacheWrite
            totalCost += usage.cost.total
        }
    }

    func onAgentEnd() {
        lock.withLock {
            var parts = [
                "in: \(totalInput)",
                "out: \(totalOutput)",
            ]
            if totalCacheRead > 0 { parts.append("cache_read: \(totalCacheRead)") }
            if totalCacheWrite > 0 { parts.append("cache_write: \(totalCacheWrite)") }
            parts.append("total: \(totalInput + totalOutput) tokens")
            if totalCost > 0 { parts.append("cost: $\(String(format: "%.4f", totalCost))") }
            _rawWrite("\u{001B}[2m[usage] \(parts.joined(separator: " | "))\u{001B}[0m\n")
        }
    }

    // MARK: - Private

    /// Show a waiting indicator for a new block
    private func _startBlock(label: String, color: String) {
        inBlock = true
        blockLabel = label
        _rawWrite("\u{001B}[\(color)m[\(label)]\u{001B}[0m\u{001B}[2m ...\u{001B}[0m")
    }

    /// Replace the waiting indicator with the final collapsed line
    private func _endBlock(_ line: String) {
        _clearCurrentLine()
        _rawWrite(line + "\n")
        inBlock = false
        blockLabel = ""
    }

    /// Erase the current line and move cursor to column 0
    private func _clearCurrentLine() {
        _rawWrite("\u{001B}[2K\r")
    }

    /// Collapse text into a single line, truncated
    private func _oneLine(_ text: String) -> String {
        let cleaned = text
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespaces)
        if cleaned.count > maxSummaryLength {
            return String(cleaned.prefix(maxSummaryLength)) + "..."
        }
        return cleaned
    }

    /// Write directly to stdout fd, bypassing Swift print buffering.
    private func _rawWrite(_ str: String) {
        let data = Array(str.utf8)
        data.withUnsafeBufferPointer { buf in
            var written = 0
            while written < buf.count {
                let n = Darwin.write(STDOUT_FILENO, buf.baseAddress! + written, buf.count - written)
                if n <= 0 { break }
                written += n
            }
        }
    }
}
