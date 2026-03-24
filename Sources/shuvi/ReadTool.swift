import Foundation
import ShuviAI
import ShuviAgent
import ShuviMarkitdown

struct ReadTool: AgentToolProtocol {
    let name = "read"
    let label = "Read"
    let description = """
        Read file, directory, or web page contents. \
        For URLs (http/https), fetches the page and converts to Markdown. \
        For text files, returns content with line numbers (supports pagination via offset/limit). \
        For directories, returns a sorted list of entries. \
        Also supports PDF, DOCX, XLSX, HTML, Jupyter Notebook, and ZIP formats (auto-converted to Markdown).
        """
    let parameters = ToolSchema(
        type: "object",
        properties: [
            "path": .object([
                "type": .string("string"),
                "description": .string("The file path, directory path, or URL (http/https) to read"),
            ]),
            "offset": .object([
                "type": .string("number"),
                "description": .string("Starting line number (1-based) for paginated reading of large text files"),
            ]),
            "limit": .object([
                "type": .string("number"),
                "description": .string("Maximum number of lines to read, used together with offset"),
            ]),
        ],
        required: ["path"]
    )

    // MARK: - Constants

    private let maxLines = 2000
    private let maxBytes = 256 * 1024  // 256KB
    private let maxLineLength = 2000

    /// Rich file extensions handled by ShuviMarkitdown.
    private let richExtensions: Set<String> = [
        ".pdf", ".docx", ".xlsx", ".html", ".htm", ".ipynb", ".zip",
    ]

    /// Known binary extensions — reject immediately to avoid garbled output.
    private let knownBinaryExtensions: Set<String> = [
        ".ppt", ".odt", ".ods", ".odp", ".rtf",
        ".exe", ".dll", ".so", ".dylib",
        ".bin", ".dat", ".db", ".sqlite",
        ".class", ".pyc", ".o", ".obj", ".wasm",
        ".tar", ".gz", ".bz2", ".7z", ".rar",
        ".mp3", ".mp4", ".avi", ".mov", ".wav", ".flac", ".ogg", ".webm",
        ".jpg", ".jpeg", ".png", ".gif", ".bmp", ".webp", ".ico", ".tiff", ".heic",
        ".ttf", ".otf", ".woff", ".woff2",
        ".iso", ".dmg", ".pkg",
        ".protobuf", ".pb",
    ]

    // MARK: - Execute

    func execute(
        toolCallId: String,
        params: JSONValue,
        onUpdate: AgentToolUpdateCallback?
    ) async throws -> AgentToolResult {
        guard let path = params["path"]?.stringValue else {
            return .error("Missing 'path' parameter")
        }

        let offset = params["offset"]?.intValue.map(Int.init) ?? params["offset"]?.doubleValue.map(Int.init)
        let limit = params["limit"]?.intValue.map(Int.init) ?? params["limit"]?.doubleValue.map(Int.init)

        do {
            // URL
            if path.hasPrefix("http://") || path.hasPrefix("https://") {
                return try await readUrl(path)
            }

            // Resolve relative paths against cwd
            let absolutePath = resolvePath(path)
            let fm = FileManager.default

            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: absolutePath, isDirectory: &isDir) else {
                return .error("File not found: \(path)")
            }

            // Directory
            if isDir.boolValue {
                return readDirectory(absolutePath, displayPath: path, offset: offset, limit: limit)
            }

            // File
            let attrs = try fm.attributesOfItem(atPath: absolutePath)
            let fileSize = (attrs[.size] as? Int) ?? 0
            let ext = (absolutePath as NSString).pathExtension.lowercased()
            let dotExt = ext.isEmpty ? "" : ".\(ext)"

            // Rich file → MarkItDown
            if richExtensions.contains(dotExt) {
                return try await readRichFile(absolutePath, displayPath: path, fileSize: fileSize)
            }

            // Known binary → reject
            if knownBinaryExtensions.contains(dotExt) {
                return .error("Unsupported binary format (\(dotExt)): \(path). Supported: text files, PDF, DOCX, XLSX, HTML, IPYNB.")
            }

            // Binary detection (first 8KB)
            if isBinaryFile(absolutePath, fileSize: fileSize) {
                return .error("Unsupported binary format: \(path). Supported: text files, PDF, DOCX, XLSX, HTML, IPYNB.")
            }

            // Plain text
            return readTextFile(absolutePath, displayPath: path, fileSize: fileSize, offset: offset, limit: limit)

        } catch {
            return .error("Read failed: \(error.localizedDescription)")
        }
    }

    // MARK: - URL

    private func readUrl(_ urlString: String) async throws -> AgentToolResult {
        let mid = ShuviMarkitdown.MarkItDown()
        let result = try await mid.convert(urlString)
        var text = result.markdown

        // Truncate
        let truncated = truncateHead(text)
        text = truncated.text

        // Header
        let titlePart = result.title.map { " — \($0)" } ?? ""
        text = "URL: \(urlString)\(titlePart) — converted to Markdown\n\n\(text)"

        return makeResult(text)
    }

    // MARK: - Directory

    private func readDirectory(_ absolutePath: String, displayPath: String, offset: Int?, limit: Int?) -> AgentToolResult {
        let fm = FileManager.default
        guard let contents = try? fm.contentsOfDirectory(atPath: absolutePath) else {
            return .error("Failed to read directory: \(displayPath)")
        }

        // Sort, mark directories with /
        let entries = contents.sorted().map { name -> String in
            var isDir: ObjCBool = false
            let fullPath = (absolutePath as NSString).appendingPathComponent(name)
            fm.fileExists(atPath: fullPath, isDirectory: &isDir)
            return isDir.boolValue ? "\(name)/" : name
        }

        let effectiveLimit = limit ?? maxLines
        let effectiveOffset = offset ?? 1
        let start = max(0, effectiveOffset - 1)
        let sliced = Array(entries.dropFirst(start).prefix(effectiveLimit))
        let total = entries.count
        let shown = sliced.count
        let endIndex = start + shown
        let isTruncated = endIndex < total

        var text = "Directory: \(displayPath) (\(total) entries)\n"
        if offset != nil || limit != nil {
            text += "Showing: entries \(effectiveOffset)-\(effectiveOffset + shown - 1)\n"
        }
        text += "\n" + sliced.joined(separator: "\n")

        if isTruncated {
            text += "\n\n(Showing \(shown) of \(total) entries. Use offset=\(endIndex + 1) to continue.)"
        } else {
            text += "\n\n(\(total) entries)"
        }

        return makeResult(text)
    }

    // MARK: - Rich File (MarkItDown)

    private func readRichFile(_ absolutePath: String, displayPath: String, fileSize: Int) async throws -> AgentToolResult {
        let mid = ShuviMarkitdown.MarkItDown()
        let result = try await mid.convert(absolutePath)
        var text = result.markdown

        // Truncate
        let truncated = truncateHead(text)
        text = truncated.text

        // Header
        let ext = (absolutePath as NSString).pathExtension.uppercased()
        text = "File: \(displayPath) (\(ext), \(formatSize(fileSize))) — converted to Markdown\n\n\(text)"

        return makeResult(text)
    }

    // MARK: - Plain Text

    private func readTextFile(_ absolutePath: String, displayPath: String, fileSize: Int, offset: Int?, limit: Int?) -> AgentToolResult {
        guard let data = FileManager.default.contents(atPath: absolutePath),
              let content = String(data: data, encoding: .utf8) else {
            return .error("Failed to read file as UTF-8: \(displayPath)")
        }

        let allLines = content.components(separatedBy: "\n")
        let totalLines = allLines.count

        let effectiveLimit = limit ?? maxLines
        let effectiveOffset = offset ?? 1
        let start = max(0, effectiveOffset - 1)

        var raw: [String] = []
        var bytes = 0
        var truncatedByBytes = false
        var hasMoreLines = false

        let endBound = min(start + effectiveLimit, totalLines)

        for i in start..<totalLines {
            if raw.count >= effectiveLimit {
                hasMoreLines = true
                break
            }

            if i >= endBound {
                hasMoreLines = true
                break
            }

            var line = allLines[i]

            // Truncate long lines (minified JS/CSS)
            if line.count > maxLineLength {
                line = String(line.prefix(maxLineLength)) + "... (line truncated)"
            }

            let lineBytes = line.utf8.count + (raw.isEmpty ? 0 : 1)
            if bytes + lineBytes > maxBytes {
                truncatedByBytes = true
                hasMoreLines = true
                break
            }

            raw.append(line)
            bytes += lineBytes
        }

        // Check if there are more lines beyond what we read
        if !hasMoreLines && start + raw.count < totalLines {
            // Last line might be empty trailing newline
            if start + raw.count < totalLines - 1 || !allLines.last!.isEmpty {
                hasMoreLines = true
            }
        }

        let lastReadLine = effectiveOffset + raw.count - 1
        let nextOffset = lastReadLine + 1
        // Line numbers with padding
        let padWidth = String(totalLines).length
        let numbered = raw.enumerated().map { i, line in
            let lineNum = effectiveOffset + i
            return "\(String(lineNum).padLeft(padWidth))│\(line)"
        }

        var text = numbered.joined(separator: "\n")

        // Truncation hint
        if truncatedByBytes {
            text += "\n\n(Output capped at \(formatSize(maxBytes)). Showing lines \(effectiveOffset)-\(lastReadLine). Use offset=\(nextOffset) to continue.)"
        } else if hasMoreLines {
            text += "\n\n(Showing lines \(effectiveOffset)-\(lastReadLine) of \(totalLines). Use offset=\(nextOffset) to continue.)"
        } else {
            text += "\n\n(End of file - total \(totalLines) lines)"
        }

        // File header
        let header = "File: \(displayPath) (\(totalLines) lines, \(formatSize(fileSize)))"
        if offset != nil || limit != nil {
            text = "\(header)\nShowing: lines \(effectiveOffset)-\(lastReadLine)\n\n\(text)"
        } else {
            text = "\(header)\n\n\(text)"
        }

        return makeResult(text)
    }

    // MARK: - Binary Detection

    /// Check first 8KB for NULL bytes.
    private func isBinaryFile(_ path: String, fileSize: Int) -> Bool {
        guard fileSize > 0,
              let handle = FileHandle(forReadingAtPath: path) else { return false }
        defer { handle.closeFile() }

        let sampleSize = min(8192, fileSize)
        let data = handle.readData(ofLength: sampleSize)
        return data.contains(0)
    }

    // MARK: - Helpers

    private func resolvePath(_ path: String) -> String {
        if path.hasPrefix("/") || path.hasPrefix("~") {
            return (path as NSString).expandingTildeInPath
        }
        let cwd = FileManager.default.currentDirectoryPath
        return (cwd as NSString).appendingPathComponent(path)
    }

    private func formatSize(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes) B" }
        let kb = Double(bytes) / 1024
        if kb < 1024 { return String(format: "%.1f KB", kb) }
        let mb = kb / 1024
        return String(format: "%.1f MB", mb)
    }

    private struct TruncateResult {
        let text: String
        let truncated: Bool
    }

    private func truncateHead(_ text: String) -> TruncateResult {
        let lines = text.components(separatedBy: "\n")
        if lines.count <= maxLines && text.utf8.count <= maxBytes {
            return TruncateResult(text: text, truncated: false)
        }

        var result: [String] = []
        var bytes = 0
        for line in lines {
            if result.count >= maxLines { break }
            let lineBytes = line.utf8.count + (result.isEmpty ? 0 : 1)
            if bytes + lineBytes > maxBytes { break }
            result.append(line)
            bytes += lineBytes
        }

        let truncatedText = "[Output truncated: \(lines.count) lines / \(formatSize(text.utf8.count))]\n\n"
            + result.joined(separator: "\n")
        return TruncateResult(text: truncatedText, truncated: true)
    }

    private func makeResult(_ text: String) -> AgentToolResult {
        AgentToolResult(
            content: [.text(TextContent(text: text))],
            details: .object(["type": .string("read")])
        )
    }
}

// MARK: - String Helpers

private extension String {
    var length: Int { count }

    func padLeft(_ width: Int) -> String {
        if count >= width { return self }
        return String(repeating: " ", count: width - count) + self
    }
}
