import Foundation

/// Lightweight i18n: detect system language once, provide localized strings.
enum I18n {
    /// Whether the user's system language is Chinese.
    static let isChinese: Bool = {
        // LANG/LC_ALL env takes priority (explicit user override)
        let envLang = ProcessInfo.processInfo.environment["LANG"]
            ?? ProcessInfo.processInfo.environment["LC_ALL"]
            ?? ""
        if !envLang.isEmpty {
            return envLang.hasPrefix("zh")
        }

        // Fallback to macOS system locale
        let preferred = Locale.preferredLanguages.first ?? ""
        return preferred.hasPrefix("zh")
    }()

    // MARK: - Config

    static let firstRunCreatingConfig = isChinese
        ? "首次使用，正在创建配置文件:"
        : "First run, creating config file:"

    static let enterApiKey = isChinese
        ? "请输入 API Key: "
        : "Enter API Key: "

    static let apiKeyEmpty = isChinese
        ? "API Key 不能为空，退出。"
        : "API Key cannot be empty, exiting."

    static let configSavedTo = isChinese
        ? "配置已保存到"
        : "Config saved to"

    // MARK: - Usage

    static let usageShort = isChinese
        ? "用法: shuvi <prompt>  (shuvi --help 查看更多)"
        : "Usage: shuvi <prompt>  (shuvi --help for more)"

    static let helpTitle = isChinese
        ? "shuvi - 一次性命令行智能体"
        : "shuvi - One-shot command-line agent"

    static let helpUsage = isChinese ? "用法:" : "Usage:"

    static let helpLaunchAgent = isChinese
        ? "启动智能体执行任务"
        : "Launch agent with a prompt"

    static let helpContinueWithPrompt = isChinese
        ? "加载上次对话历史并继续"
        : "Load previous session and continue"

    static let helpContinueNoPrompt = isChinese
        ? "从上次中断处继续"
        : "Resume from last interruption"

    static let helpDirectTool = isChinese
        ? "直接调用工具（见下方）"
        : "Invoke a tool directly (see below)"

    static let helpShowHelp = isChinese
        ? "显示帮助信息"
        : "Show this help message"

    static let helpOptions = isChinese ? "选项:" : "Options:"

    static let helpContinueFlag = isChinese
        ? "加载当前目录下的 .shuvi_history.json 继续对话"
        : "Load .shuvi_history.json from current directory to continue"

    static let helpHelpFlag = isChinese
        ? "显示此帮助信息"
        : "Show this help message"

    static let helpConfigFile = isChinese ? "配置文件:" : "Config file:"

    static let helpRequired = isChinese ? "必填" : "required"

    static let helpApiKey = isChinese
        ? "API Key (\(helpRequired))"
        : "API Key (\(helpRequired))"

    static let helpBaseUrl = isChinese
        ? "API 地址"
        : "API base URL"

    static let helpModel = isChinese
        ? "模型名称"
        : "Model name"

    static let helpThinkingLevel = isChinese
        ? "推理等级 off/minimal/low/medium/high"
        : "Thinking level: off/minimal/low/medium/high"

    static let helpConfirmPrompt = isChinese ? "确认提示:" : "Confirmation prompt:"

    static let helpConfirmAllow = isChinese
        ? "允许执行命令"
        : "Allow execution"

    static let helpConfirmReject = isChinese
        ? "拒绝执行"
        : "Reject execution"

    static let helpConfirmFeedback = isChinese
        ? "拒绝并将反馈传给 AI"
        : "Reject with feedback to AI"

    static let helpConfirmAbort = isChinese
        ? "中断智能体"
        : "Abort the agent"

    static let helpAvailableTools = isChinese
        ? "可用工具 (通过 shuvi tool:<name> 直接调用):"
        : "Available tools (invoke via shuvi tool:<name>):"

    static let helpToolUsage = isChinese ? "用法:" : "Usage:"

    // MARK: - Continue Mode

    static let noHistoryFound = isChinese
        ? "未找到历史记录:"
        : "No history found at"

    static let continuePrompt = isChinese
        ? ">"
        : ">"

    // MARK: - Direct Tool

    static func unknownTool(_ name: String) -> String {
        isChinese ? "未知工具: \(name)" : "Unknown tool: \(name)"
    }

    static func availableTools(_ names: String) -> String {
        isChinese ? "可用工具: \(names)" : "Available tools: \(names)"
    }

    // MARK: - Default

    static let defaultLabel = isChinese ? "默认" : "default"
}
