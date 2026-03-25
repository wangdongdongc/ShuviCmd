# Shuvi

A macOS command-line AI agent. It connects to OpenAI-compatible APIs and executes bash commands on your behalf, with user confirmation before each execution.

## Features

- Natural language to bash command execution with confirmation prompts
- Streaming terminal output with color-coded blocks (text, thinking, tool calls, errors)
- Session history persistence and continuation via `--continue`
- Configurable model, API endpoint, and thinking level

## Requirements

- macOS 13+

## Installation

```bash
brew tap wangdongdongc/tap
brew install shuvi
```

## Usage

```bash
shuvi "list all files in current directory"
shuvi -c "keep going"     # Continue previous session
shuvi -h                  # Show help
```

On first run, Shuvi will create `~/.shuvi/config.json` and prompt you for an API key.

## Configuration

`~/.shuvi/config.json`:

```json
{
  "apiKey": "your-api-key",
  "baseUrl": "https://api.openai.com/v1",
  "model": "gpt-5.4-mini",
  "thinkingLevel": "medium"
}
```

| Field | Default | Description |
|-------|---------|-------------|
| `apiKey` | — | OpenAI-compatible API key (required) |
| `baseUrl` | `https://api.openai.com/v1` | API base URL |
| `model` | `gpt-5.4-mini` | Model ID |
| `thinkingLevel` | `medium` | Thinking level: off, minimal, low, medium, high, xhigh |

## License

MIT
