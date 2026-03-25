import Foundation
import ShuviAI
import ShuviAgent
import ShuviAgentOpenAIProvider

// MARK: - Global Agent Reference (for SIGINT handler)

/// Holds a reference to the running agent so the C signal handler can abort it.
final class AgentHolder: @unchecked Sendable {
    static let shared = AgentHolder()
    private let lock = NSLock()
    private var _agent: Agent?

    var agent: Agent? {
        get { lock.withLock { _agent } }
        set { lock.withLock { _agent = newValue } }
    }
}

// MARK: - Configuration

struct ShuviConfig: Codable {
    var apiKey: String?
    var baseUrl: String?
    var model: String?
    var thinkingLevel: String?
}

extension ShuviConfig {
    static let defaultBaseUrl = "https://api.openai.com/v1"
    static let defaultModel: String = "gpt-5.4-mini"
    static let defaultThinkingLevel = "medium"

    static let configDir: URL = {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shuvi")
    }()

    static let configFile: URL = {
        configDir.appendingPathComponent("config.json")
    }()

    /// Load config from disk, or create interactively if missing.
    static func loadOrCreate() -> ShuviConfig {
        let fm = FileManager.default

        // Create directory if needed
        if !fm.fileExists(atPath: configDir.path) {
            try? fm.createDirectory(at: configDir, withIntermediateDirectories: true)
        }

        var config: ShuviConfig
        if let data = try? Data(contentsOf: configFile),
           let decoded = try? JSONDecoder().decode(ShuviConfig.self, from: data) {
            config = decoded
        } else {
            // Create default config
            config = ShuviConfig()
            print("\(I18n.firstRunCreatingConfig) \(configFile.path)")
        }

        // Check apiKey
        if config.apiKey == nil || config.apiKey!.isEmpty {
            print(I18n.enterApiKey, terminator: "")
            fflush(stdout)
            guard let key = readLine(), !key.isEmpty else {
                print(I18n.apiKeyEmpty)
                exit(1)
            }
            config.apiKey = key
            config.save()
            print("\(I18n.configSavedTo) \(configFile.path)")
        }

        return config
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(self) {
            try? data.write(to: Self.configFile)
        }
    }

    var resolvedBaseUrl: String { baseUrl ?? Self.defaultBaseUrl }
    var resolvedModel: String { model ?? Self.defaultModel }
    var resolvedThinkingLevel: ThinkingLevel {
        ThinkingLevel(rawValue: thinkingLevel ?? Self.defaultThinkingLevel) ?? .medium
    }
}

// MARK: - History

enum History {
    static let filePath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appendingPathComponent(".shuvi_history.json")

    static func save(_ messages: [Message]) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(messages) else { return }
        try? data.write(to: filePath)
    }

    static func load() -> [Message]? {
        guard let data = try? Data(contentsOf: filePath),
              let messages = try? JSONDecoder().decode([Message].self, from: data) else {
            return nil
        }
        return messages
    }
}

// MARK: - Registered Tools

/// All tools available to the agent. Shared between agent mode and direct invocation.
let registeredTools: [any AgentToolProtocol] = [BashTool(), ReadTool()]

// MARK: - Main

@main
struct Shuvi {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())

        // Parse flags
        if args.contains("--help") || args.contains("-h") {
            printHelp()
            exit(0)
        }

        // Direct tool invocation: shuvi tool:<name> <args...> or shuvi <name> <args...>
        if let first = args.first {
            let toolName: String?
            if first.hasPrefix("tool:") {
                toolName = String(first.dropFirst(5))
            } else if registeredTools.contains(where: { $0.name == first }) {
                toolName = first
            } else {
                toolName = nil
            }
            if let toolName = toolName {
                args.removeFirst()
                await directToolCall(toolName, args: args)
                return
            }
        }

        let continueMode = args.first == "--continue" || args.first == "-c"
        if continueMode {
            args.removeFirst()
        }

        let userPrompt = args.joined(separator: " ")

        if !continueMode && userPrompt.isEmpty {
            print(I18n.usageShort)
            exit(0)
        }

        // Early check: --continue requires history file to exist
        if continueMode && History.load() == nil {
            print("\u{001B}[31m\(I18n.noHistoryFound) \(History.filePath.path)\u{001B}[0m")
            exit(1)
        }

        // Load config
        let config = ShuviConfig.loadOrCreate()
        let apiKey = config.apiKey!

        // Register provider
        // Strip /v1 suffix for OpenAIProvider (it adds its own path)
        var baseUrl = config.resolvedBaseUrl
        if baseUrl.hasSuffix("/v1") {
            baseUrl = String(baseUrl.dropLast(3))
        }
        let provider = OpenAIProvider(apiKey: apiKey, baseUrl: baseUrl)
        AIProviderRegistry.shared.register(provider)

        // Build model
        let model = Model(
            id: config.resolvedModel,
            name: config.resolvedModel,
            api: KnownApi.openaiCompletions,
            provider: KnownProvider.openai,
            baseUrl: baseUrl,
            contextWindow: 200_000,
            maxTokens: 8192
        )

        let cwd = FileManager.default.currentDirectoryPath
        let systemPrompt = """
        You are a macOS command-line assistant. CWD: \(cwd)
        Act immediately with tools — do not describe commands in text. The system confirms bash execution automatically.
        Always include the "description" parameter in bash calls. Use plain text output, no Markdown.
        """

        // Terminal renderer for streaming + collapse
        let renderer = TerminalRenderer()

        // Create agent
        let agent = Agent(options: AgentOptions(
            initialModel: model,
            systemPrompt: systemPrompt,
            thinkingLevel: config.resolvedThinkingLevel,
            tools: registeredTools,
            toolExecution: .sequential,
            beforeToolCall: { context in
                // Read tool is safe (read-only), auto-allow without user confirmation
                if context.toolCall.name == "read" {
                    renderer.flushToolLine()
                    return .allow
                }

                renderer.onToolConfirm(command: "")

                guard let response = readLine()?.trimmingCharacters(in: .whitespaces) else {
                    return .blocked("No response from user")
                }

                let lower = response.lowercased()
                if lower == "y" || lower == "yes" {
                    return .allow
                } else if lower == "n" || lower == "no" {
                    return .blocked("user rejected this command")
                } else {
                    return .blocked("user reject: \(response)")
                }
            }
        ))

        // Install SIGINT handler
        AgentHolder.shared.agent = agent
        signal(SIGINT) { _ in
            ProcessHolder.shared.terminate()
            if let agent = AgentHolder.shared.agent {
                Task { await agent.abort() }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
                exit(130)
            }
        }

        // Subscribe to events for streaming output
        let _ = await agent.subscribe { event in
            switch event {
            case .messageUpdate(_, let ame):
                switch ame {
                case .textDelta(_, let delta, _):
                    renderer.onTextDelta(delta)
                case .textEnd(_, let content, _):
                    renderer.onTextEnd(content)
                case .thinkingDelta(_, let delta, _):
                    renderer.onThinkingDelta(delta)
                case .thinkingEnd(_, let content, _):
                    renderer.onThinkingEnd(content)
                case .toolcallDelta(_, let delta, _):
                    renderer.onToolCallDelta(delta)
                case .toolcallEnd(_, let toolCall, _):
                    renderer.onToolCallEnd(toolCall)
                case .error(_, let msg):
                    let errText = msg.errorMessage ?? "Unknown error"
                    renderer.onError(errText)
                default:
                    break
                }
            case .messageEnd(let message):
                if case .assistant(let am) = message {
                    renderer.addUsage(am.usage)
                    if am.stopReason == .error, let errMsg = am.errorMessage {
                        renderer.onError(errMsg)
                    }
                }
            case .toolExecutionEnd(_, let name, let result, let isError):
                renderer.onToolResult(name: name, result: result, isError: isError)
            case .agentEnd:
                renderer.onAgentEnd()
            default:
                break
            }
        }

        // Load previous history in continue mode (existence already checked above)
        if continueMode, let previousMessages = History.load() {
            await agent.replaceMessages(previousMessages)
            renderer.onInfo("Loaded \(previousMessages.count) messages from history")
        }

        // Run first turn (skip if --continue with no prompt, go straight to input loop)
        if !userPrompt.isEmpty {
            do {
                try await agent.prompt(userPrompt)
                await agent.waitForIdle()
            } catch {
                print("\n\u{001B}[31mError: \(error)\u{001B}[0m")
            }
            History.save(await agent.messages)
        }

        // Multi-turn conversation loop
        while true {
            print("\n\u{001B}[36m\(I18n.continuePrompt)\u{001B}[0m", terminator: " ")
            fflush(stdout)

            guard let input = readLine()?.trimmingCharacters(in: .whitespaces),
                  !input.isEmpty else {
                continue
            }

            do {
                try await agent.prompt(input)
                await agent.waitForIdle()
            } catch {
                print("\n\u{001B}[31mError: \(error)\u{001B}[0m")
            }

            History.save(await agent.messages)
        }
    }

    // MARK: - Help

    private static func printHelp() {
        let def = I18n.defaultLabel
        var text = """
        \(I18n.helpTitle)

        \(I18n.helpUsage)
          shuvi <prompt>                 \(I18n.helpLaunchAgent)
          shuvi --continue <prompt>      \(I18n.helpContinueWithPrompt)
          shuvi --continue               \(I18n.helpContinueNoPrompt)
          shuvi tool:<name> <args...>    \(I18n.helpDirectTool)
          shuvi --help                   \(I18n.helpShowHelp)

        \(I18n.helpOptions)
          -c, --continue    \(I18n.helpContinueFlag)
          -h, --help        \(I18n.helpHelpFlag)

        \(I18n.helpConfigFile) ~/.shuvi/config.json
          apiKey           \(I18n.helpApiKey)
          baseUrl          \(I18n.helpBaseUrl) (\(def): \(ShuviConfig.defaultBaseUrl))
          model            \(I18n.helpModel) (\(def): \(ShuviConfig.defaultModel))
          thinkingLevel    \(I18n.helpThinkingLevel) (\(def): \(ShuviConfig.defaultThinkingLevel))

        \(I18n.helpConfirmPrompt)
          y/yes            \(I18n.helpConfirmAllow)
          n/no             \(I18n.helpConfirmReject)
          \(I18n.isChinese ? "其他文本" : "other text")          \(I18n.helpConfirmFeedback)
          Ctrl+C           \(I18n.helpConfirmAbort)

        \(I18n.helpAvailableTools)
        """

        for tool in registeredTools {
            let desc = tool.description
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            text += "\n\n  tool:\(tool.name)    \(desc)"

            if let props = tool.parameters.properties {
                let required = Set(tool.parameters.required ?? [])
                let sorted = props.keys.sorted { a, b in
                    let aReq = required.contains(a)
                    let bReq = required.contains(b)
                    if aReq != bReq { return aReq }
                    return a < b
                }
                var usageParts: [String] = []
                for key in sorted {
                    let paramDesc = props[key]?["description"]?.stringValue ?? ""
                    let paramType = props[key]?["type"]?.stringValue ?? "string"
                    let isRequired = required.contains(key)
                    if isRequired {
                        usageParts.append("<\(key)>")
                    } else {
                        usageParts.append("[--\(key) <\(paramType)>]")
                    }
                    let reqLabel = isRequired ? " (\(I18n.helpRequired))" : ""
                    text += "\n    \(isRequired ? "" : "  ")\(key)    \(paramDesc)\(reqLabel)"
                }
                text += "\n    \(I18n.helpToolUsage) shuvi tool:\(tool.name) \(usageParts.joined(separator: " "))"
            }
        }

        print(text)
    }

    // MARK: - Direct Tool Invocation

    /// Generic direct tool call: `shuvi tool:<name> <positional-args...> [--param value ...]`
    ///
    /// Positional args are mapped to required parameters in schema order.
    /// Named args (`--key value`) are mapped to optional parameters.
    private static func directToolCall(_ toolName: String, args: [String]) async {
        guard let tool = registeredTools.first(where: { $0.name == toolName }) else {
            print("\u{001B}[31m\(I18n.unknownTool(toolName))\u{001B}[0m")
            print(I18n.availableTools(registeredTools.map(\.name).joined(separator: ", ")))
            exit(1)
        }

        // Parse args into params JSONValue
        let params = parseToolArgs(args, schema: tool.parameters)

        do {
            let result = try await tool.execute(
                toolCallId: "direct",
                params: .object(params),
                onUpdate: nil
            )
            for block in result.content {
                if case .text(let tc) = block {
                    print(tc.text)
                }
            }
        } catch {
            print("\u{001B}[31mError: \(error.localizedDescription)\u{001B}[0m")
            exit(1)
        }
    }

    /// Parse CLI args into tool params based on schema.
    /// Positional args fill required params in order; `--key value` fills by name.
    private static func parseToolArgs(_ args: [String], schema: ToolSchema) -> [String: JSONValue] {
        let requiredKeys = schema.required ?? []
        let props = schema.properties ?? [:]

        var result: [String: JSONValue] = [:]
        var positionalIndex = 0
        var i = 0

        while i < args.count {
            let arg = args[i]

            if arg.hasPrefix("--"), i + 1 < args.count {
                // Named parameter
                let key = String(arg.dropFirst(2))
                let value = args[i + 1]
                result[key] = coerceValue(value, key: key, props: props)
                i += 2
            } else {
                // Positional → map to next required param
                if positionalIndex < requiredKeys.count {
                    let key = requiredKeys[positionalIndex]
                    result[key] = coerceValue(arg, key: key, props: props)
                    positionalIndex += 1
                }
                i += 1
            }
        }

        return result
    }

    /// Coerce a string CLI value to the appropriate JSONValue based on schema type.
    private static func coerceValue(_ value: String, key: String, props: [String: JSONValue]) -> JSONValue {
        let paramType = props[key]?["type"]?.stringValue ?? "string"
        switch paramType {
        case "number", "integer":
            if let intVal = Int64(value) { return .int(intVal) }
            if let dblVal = Double(value) { return .double(dblVal) }
            return .string(value)
        case "boolean":
            return .bool(value == "true" || value == "1")
        default:
            return .string(value)
        }
    }
}
