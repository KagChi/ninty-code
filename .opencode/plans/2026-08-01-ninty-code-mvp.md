# ninty-code — Implementation Plan (All-Swift)

Date: 2026-08-01
Status: Active

## Locked Decisions

| Decision | Choice |
|---|---|
| Product | Open-source AI coding assistant, desktop-only |
| Platform | macOS 26+ Tahoe, ARM64 only |
| Stack | 100% Swift — SwiftUI UI, Swift agent core (local SPM package `Packages/NintyCore`) |
| UI | SwiftUI + Liquid Glass |
| Providers | Single `OpenAICompatibleProvider` + presets (OpenAI, Anthropic compat, Google compat, Ollama, LM Studio, custom) |
| Agents | `build` (full access), `plan` (read-only + bash prompts), custom via config |
| v1 scope | File tools + bash + permissions, MCP, disk sessions, custom agents/config |
| License | MIT |
| CI/CD | GitHub Actions; tags `v*` + manual dispatch; signing gated on secrets, prepared now |
| Identity | ninty-code, bundle ID `ai.ninty.code`, config `ninty.json`, dirs `~/.config/ninty`, `~/.local/share/ninty` |

## Architecture

Single Xcode project + local SPM package:

```
ninty-code/
├── NintyCode.xcodeproj
├── Packages/
│   └── NintyCore/                  # SPM package — ALL agent logic, zero UI deps
│       ├── Package.swift
│       ├── Sources/NintyCore/
│       │   ├── Providers/          # ModelProvider protocol, SSE parser, OpenAICompatibleProvider, presets
│       │   ├── Agent/              # AgentSession actor, loop, agent definitions, prompts
│       │   ├── Tools/              # AgentTool protocol, built-ins, registry
│       │   ├── Permissions/        # rule engine (allow/deny/ask)
│       │   ├── Sessions/           # JSONL storage, SessionStore
│       │   ├── Config/             # global + project config, auth.json
│       │   ├── MCP/                # MCPManager actor (swift-sdk stdio)
│       │   └── Resources/models.json
│       └── Tests/NintyCoreTests/
│           └── Fixtures/           # recorded SSE streams
├── NintyCode/                      # app target — SwiftUI only
│   ├── App/
│   ├── State/                      # @Observable stores bridging core → UI
│   ├── Views/                      # Chat, Sidebar, Composer, Permissions, Settings
│   └── Resources/
├── .github/workflows/              # ci.yml, release.yml
├── .opencode/plans/
├── ExportOptions.plist
├── AGENTS.md
├── LICENSE
└── README.md
```

Rules:
- `NintyCore` never imports SwiftUI/AppKit/UIKit (Foundation + Network only).
- App target contains zero agent logic; talks to core via async streams only.
- SPM deps: `modelcontextprotocol/swift-sdk` (MCP), `swift-markdown` (rendering, app target), Splash or equivalent (highlighting, app target).

## Phase A — Repository Foundation

- Root: `LICENSE` (MIT), `README.md`, `AGENTS.md`, `.gitignore`.
- Xcode: deployment target 26.0, `ARCHS=arm64`, `EXCLUDED_ARCHS=x86_64`, bundle `ai.ninty.code`, Swift 6 language mode, strict concurrency, sandbox OFF (arbitrary file access + shell exec), hardened runtime ON.

## Phase B — NintyCore Foundation Types

- `JSONValue` (Codable, Sendable enum) — dynamic tool args/payloads.
- `JSONSchema` (Codable, Sendable) — type/properties/required/enum/items/description.
- `Message` — role + parts (text / toolCall / toolResult).
- `ChatRequest` — model, system, messages, tools.
- `StreamEvent` — textDelta, toolCallStart/Delta/End, usage, finish.
- `ModelProvider` protocol — `models()`, `stream(_:) -> AsyncThrowingStream<StreamEvent, Error>`.
- `SSEParser` — line-based, handles multi-line data, comments, CRLF, `[DONE]`, chunk splits.
- `ProviderHTTP` — request builder, non-2xx → typed errors, exponential backoff (1s/2s/4s, max 3) on 429/5xx/network, never retry other 4xx.

## Phase C — Provider (single implementation)

### OpenAICompatibleProvider

- `POST {baseURL}/chat/completions`, `stream: true`, `stream_options.include_usage` (tolerated absent).
- Delta parser: `content` → textDelta; `tool_calls[i]` start/fragment accumulation by index; `finish_reason`; `usage` chunk.
- Configurable: `baseURL`, optional API key, extra headers.
- Model listing: `GET {baseURL}/models`, fallback to static catalog when unsupported.

### Presets (models.json)

| id | baseURL | key env |
|---|---|---|
| openai | `https://api.openai.com/v1` | `OPENAI_API_KEY` |
| anthropic | `https://api.anthropic.com/v1/` (+ `anthropic-version: 2023-06-01` header) | `ANTHROPIC_API_KEY` |
| google | `https://generativelanguage.googleapis.com/v1beta/openai/` | `GOOGLE_API_KEY` |
| ollama | `http://localhost:11434/v1` | — |
| lmstudio | `http://localhost:1234/v1` | — |
| custom | user-supplied | — |

Known caveat: compat endpoints are subsets — tool calling + streaming work; vendor-specific extras (thinking blocks, prompt caching) unsupported until a dedicated provider is added later.

### Tests

One fixture suite: simple text, tool call, parallel tool calls, usage chunk, chunk-split SSE, missing usage, `/models` fallback, per-preset config resolution.

## Phase D — Config

- Global `~/.config/ninty/ninty.json` + project `ninty.json` (walk up from project root, nearest wins), deep merge, project overrides.
- Schema: `model` ("provider/model"), `providers` (apiKey, baseURL, headers), `mcp` (command, args, env), `agents` (prompt, tools rules, model override).
- Key chain: `auth.json` (chmod 600) → env var → config file.
- `AGENTS.md` at project root → `projectInstructions`.

## Phase E — Tools

Protocol `AgentTool` (name, description, parameters: JSONSchema, execute(args, ctx)); `ToolContext` (projectRoot, sessionID); `ToolResult` (output, isError).

| Tool | Spec |
|---|---|
| `read` | path, offset?, limit?. Numbered lines, 2000-line cap, 2000-char/line truncation. |
| `write` | path, content. Creates parents, overwrites. |
| `edit` | path, oldString, newString, replaceAll?. Fail on absent; fail on ambiguous unless replaceAll. |
| `bash` | command, timeout? (default 120s, max 600s). `/bin/zsh -c`, combined output, 50KB cap, exit code. |
| `glob` | pattern, path?. mtime desc, cap 100. |
| `grep` | pattern, include?, path?. NSRegularExpression, cap 100, file:line context. |
| `list` | path?. Dirs suffixed `/`, cap 200. |
| `todowrite` | todos array. Session state, echoed. |

Path safety: resolve against projectRoot, reject `..` escapes (absolute paths allowed but permission-checked).

ToolRegistry: built-ins + MCP-bridged (`server:tool`); `definitions(for: agent)` filters denied tools before sending to provider.

## Phase F — Permissions + Agents

- Rules: per-agent `[toolPattern: allow|deny|ask]`; wildcards `*`, `mcp:*`; evaluation deny > ask > allow, first match.
- Session allowlist: `always` replies auto-allow subsequent same-tool calls.
- `ask` suspends tool execution via continuation until UI reply (`once`/`always`/`reject`).
- **build**: `["*": allow]`; concise coding-agent system prompt.
- **plan**: write/edit/todowrite deny; bash + `mcp:*` ask; reads allow; read-only analyst prompt.
- **custom**: config-defined prompt + rules (default inherit build) + optional model override.

## Phase G — Agent Loop + Sessions

`AgentSession` actor: `send(text)`, `replyPermission(id, reply)`, `abort()`; single `AsyncStream<SessionEvent>` out.

Turn flow: append+persist user msg → build request (system = agent prompt + AGENTS.md + env block; tools filtered by agent) → stream → forward events, accumulate tool args → per tool call: permission check (deny → error result; ask → emit + suspend) → execute → persist result → loop until no tool calls → `.done(usage)`.

Compaction: > 90% context → summarization turn, history replaced with summary + last 4 messages.

Storage: `~/.local/share/ninty/project/<path-hash>/sessions/<uuid>.jsonl`, append-only (meta/message/toolResult/usage), corrupt-line tolerant. Title = first user msg, 60 chars.

## Phase H — MCP

`MCPManager` actor via `modelcontextprotocol/swift-sdk` stdio. Lazy start on first session. Tools bridged as `server:tool`, default permission `ask`. Crash → tools unavailable, logged, core alive. Restart API for settings UI.

## Phase I — App State Bridge

- `AppState` (@Observable): projects, activeProject, sessions, config, models; project picker (NSOpenPanel + security-scoped bookmark).
- `ChatStore` (@Observable, per session): messages, streaming, pendingPermission, agent, model, todos; owns AgentSession, consumes event stream.

## Phase J — App UI

- Shell: `NavigationSplitView`, min 900×600, unified toolbar.
- Sidebar: project section, sessions list (context menu delete/rename), new-session button, glass containers.
- ChatView: ScrollViewReader + LazyVStack, auto-scroll w/ user override; markdown via swift-markdown custom walker; code blocks highlighted + copy; tool cards (status header + collapsible body; bash terminal style; edit red/green diff; todos checklist).
- Permission: inline card + sheet fallback — tool name, command/diff preview, Allow once / Always allow / Deny.
- Composer: growing TextEditor, ⌘↵/↵ send, abort while streaming, agent picker (build/plan/custom), model picker grouped by provider, `@` file-mention fuzzy autocomplete, glass container.
- Settings scene: Providers (SecureField keys, baseURL override, test connection via GET /models), MCP (server editor), General (default model).
- Liquid Glass pass: `.glassEffect()` composer/tool cards, `GlassEffectContainer` sidebar, `NSGlassEffectView` bridge where needed; verify dark/light/increased-contrast.

## Phase K — CI/CD

- `ci.yml`: push/PR → macos-26 → `swift test --package-path Packages/NintyCore` + unsigned xcodebuild Debug. SPM cache. No secrets.
- `release.yml`: tags `v*` + dispatch → tests gate → archive/export (ExportOptions.plist) → signing gate `if: vars.APPLE_SIGNING_ENABLED == 'true'` (keychain import, codesign, notarytool, staple) → create-dmg → changelog → softprops/action-gh-release (tag = full, dispatch = draft prerelease). Secrets: `APPLE_CERTIFICATE`, `APPLE_CERTIFICATE_PASSWORD`, `APPLE_TEAM_ID`, `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`; var `APPLE_SIGNING_ENABLED`.

## Phase L — Verification + v0.1.0

- Unit checklist: SSE parser, provider fixtures, config precedence, edit uniqueness, bash timeout/cap, glob/grep caps, permission matrix + allowlist, session roundtrip + corruption, compaction, MCP discover/call/crash.
- Manual QA: key → chat → tool card → edit diff → plan denials/prompts → once vs always → MCP → custom agent → resume → Ollama.
- Tag `v0.1.0` → verify DMG on clean machine.

## Out of Scope (v1)

CLI/TUI, Windows/Linux/iOS, LSP, checkpoints/undo, plugins, models.dev live catalog, usage/cost tracking, multi-window.
