# ninty-code

The open source AI coding assistant for macOS. Native SwiftUI app with a built-in agent that reads your project, writes code, and runs commands — with any model you plug in.

## Features

- **Chat with your codebase** — agent reads, edits, and searches files, runs shell commands
- **Model-agnostic** — OpenAI, Anthropic, Google, or local models (Ollama, LM Studio, llama.cpp) via OpenAI-compatible endpoints
- **Agents** — `build` for full-access development, `plan` for read-only analysis (edit tools denied, everything else runs unasked — opencode parity); custom agents via config
- **Permissions** — approve every sensitive action: allow once, always allow, or deny
- **MCP** — connect Model Context Protocol servers for extra tools
- **Sessions** — persisted to disk, resume anytime
- **Native UI** — SwiftUI + Liquid Glass, macOS 26 Tahoe, Apple Silicon only

## Requirements

- macOS 26+ (Tahoe), Apple Silicon
- Xcode 26+ (building from source)

## Building

```sh
swift test --package-path Packages/NintyCore
xcodebuild -scheme NintyCode -destination 'platform=macOS,arch=arm64' build
```

CI artifacts and release DMGs are ad-hoc signed (until Developer ID signing is enabled). If macOS reports the app as "damaged", clear the quarantine flag once:

```sh
xattr -dr com.apple.quarantine /Applications/NintyCode.app
```

## Configuration

Global config: `~/.config/ninty/ninty.json` — project config: `ninty.json` in your project root.

```json
{
  "model": "anthropic/claude-sonnet-4",
  "providers": {
    "anthropic": { "apiKey": "..." },
    "ollama": { "baseURL": "http://localhost:11434/v1" }
  },
  "mcp": {
    "myserver": { "command": "npx", "args": ["-y", "some-mcp-server"] }
  }
}
```

API keys can also come from env vars (`OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `GOOGLE_API_KEY`) or the in-app settings.

## License

MIT
