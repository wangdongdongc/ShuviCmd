# ShuviCmd

A macOS command-line AI agent written in Swift 6.0. It connects to OpenAI-compatible APIs and executes bash commands on your behalf, with user confirmation before each execution.

## Features

- Natural language to bash command execution with confirmation prompts
- Streaming terminal output with color-coded blocks (text, thinking, tool calls, errors)
- Session history persistence and continuation via `--continue`
- Configurable model, API endpoint, and thinking level via `~/.shuvi/config.json`
- Graceful shutdown with SIGINT handling

## Requirements

- macOS 13+
- Swift 6.0+

## Installation

```bash
git clone <repo-url>
cd ShuviCmd
swift build
```

## Usage

```bash
swift run shuvi "your prompt here"    # Run with a prompt
swift run shuvi --continue            # Continue previous session
swift run shuvi --help                # Show help
```

## Configuration

Create `~/.shuvi/config.json`:

```json
{
  "apiKey": "your-api-key",
  "baseUrl": "https://api.openai.com/v1",
  "model": "gpt-5.4-mini",
  "thinkingLevel": "default"
}
```

## Dependencies

- [ShuviAgentCore](https://github.com/wangdongdongc/ShuviAgentCore) — AI agent framework providing core agent, AI abstraction, and OpenAI provider
- [ShuviMarkitdown](https://github.com/wangdongdongc/ShuviMarkitdown) — Document parsing utilities

## License

MIT
