# fn

> A tiny, open, model-independent coding agent.

`fn` is an independent community fork of
[fx](https://github.com/vercel-labs/fx) by Vercel Labs. It adds direct support
for your own OpenAI, Anthropic, and compatible local models. This project is
not affiliated with or endorsed by Vercel.

## Features

- OpenAI Chat Completions and Responses APIs
- Anthropic Messages API
- ChatGPT Codex and Grok subscription sign-in inherited from fx
- Local models through oMLX, MLXTP, MLX Serve, MLX, Ollama, LM Studio,
  llama.cpp, and compatible servers
- Native Zig binary with built-in coding tools

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/shengyuanchu/fn/main/install.sh | sh
```

## Configure

Endpoints may be a bare host, a base URL, a `/v1` URL, or a full API route.
OpenAI endpoints default to Chat Completions; use a full Responses route to
select the Responses API.

For subscription access, run `fn login codex` or `fn login grok`.

### OpenAI Responses

```bash
export OPENAI_API_KEY="your-api-key"
export OPENAI_ENDPOINT="your-responses-endpoint"
export MODEL="your-model"

fn
```

### OpenAI Chat Completions

```bash
export OPENAI_API_KEY="your-api-key"
export OPENAI_ENDPOINT="your-chat-completions-endpoint"
export MODEL="your-model"

fn
```

### Anthropic Messages

```bash
export ANTHROPIC_API_KEY="your-api-key"
export ANTHROPIC_ENDPOINT="your-anthropic-messages-endpoint"
export MODEL="your-model"

fn
```

### Subscription providers

`fn login codex` and `fn login grok` select that provider and a model from its
authenticated catalog. Inside fn, open `/setup` and choose **Model provider**
to move between Gateway, Codex, and Grok. `/model` lists the active provider's
fetched models. Use `/logout codex` or `/logout grok` to remove that
subscription session without affecting other providers.

The OpenAI Codex route uses ChatGPT subscription access directly and never sends its OAuth token to Vercel AI Gateway. The session is stored privately at `~/.fx/chatgpt-auth.json` and refreshed when needed. On supported Codex models, `/fast` requests OpenAI's priority service tier and consumes ChatGPT credits at the higher Fast mode rate.

The Grok route uses subscription access directly at xAI and never sends its OAuth token to Vercel AI Gateway or OpenAI. Its session is stored privately at `~/.fx/grok-auth.json`, refreshed when needed, and used only with the authenticated xAI catalog and Responses API.

To use a Vercel AI Gateway API key instead, run `fn setup`.

### Local models

```bash
export OPENAI_ENDPOINT="your-local-chat-completions-endpoint"
export MODEL="your-model"

fn
```

## Usage

```bash
cd your-project
fn                                  # Interactive session
fn ask "hello"                      # One request
fn --resume                         # Resume a session
fn update                           # Update fn
fn --help                           # Show all options
```

`fn` starts in `auto` permission mode. Routine understood development actions
run directly; unresolved actions receive a narrow safety review. Use
`--prompt-permissions` to allow configured approval prompts for interactive
JSON or quiet requests, or `--yolo` to disable approvals.

The current directory becomes the primary workspace. Enter a prompt, or run `/help` to browse interactive commands.

The status line hides the workspace path and Git branch by default. Enable the `Status line workspace` option in `/settings`, run `/statusline workspace`, or set it in `~/.fx/settings.json`:

```json
{
  "statusLine": {
    "workspace": true
  }
}
```

List saved sessions with `fn sessions`. Resume the latest session for the current workspace, or select an exact session ID, through the same command group:

```bash
fn session resume last
fn session resume --id <id>
```

Each interactive session names its terminal tab. The title prefers the session name, falls back to the workspace name, and keeps the active model as secondary context. Renaming or resuming a session updates the tab, and exiting clears the fn-owned title. Noninteractive commands do not emit terminal-title controls.

Run `/trace` to create a private Markdown diagnostic with logs, session context, runtime state, permissions, and recent activity. On macOS, fn copies the `.md` file to the clipboard; on other platforms, it saves the file and prints its path. Review and redact the trace before sharing it.

Use `fn ask` for a single request:

```bash
fn ask "explain the changes in this repository"
```

Foreground terminal commands run with an explicit finite deadline. fn uses durable terminal sessions for services, watchers, GUI applications, and other long-lived work, and keeps captured foreground output available through an opaque bounded-read handle for the active session or `--no-save` process.

Inside a saved session, `/permissions remember <allow|deny> <tool-name> <arguments-json>` stores an exact confirmed rule without running the action. `/permissions` lists stable rule IDs, and `/permissions revoke <rule-id>` removes a stored rule even when its original workspace or file state has changed.

## Embed fn

fn builds as a native binary or WebAssembly. Applications embedding fn can provide network transport, session storage, configuration, permission handling, and terminal I/O. The SDK retains its upstream fx symbol and artifact names.

| Surface | Use |
| --- | --- |
| `fn acp` | Connect the native agent to editors and other Agent Client Protocol clients. |
| `createFxAgent()` | Embed the agent core in a JavaScript host with `fx-core.wasm`. |
| `createFxTerminal()` | Embed the interactive terminal with `fx-term.wasm`. |

The WebAssembly SDK is experimental. See the [WebAssembly SDK](sdk/README.md).

## Extend fn

Add reusable instructions with skills, connect external tools through MCP, or
delegate independent work to subagents. Inside fn,
`/mcp add <name> <command> [args...]` saves a local server and
`/mcp add --transport http <name> <url>` saves a remote Streamable HTTP server.
`fn status` and `fn doctor` report an invalid trusted MCP profile without
starting its servers.

## Build from source

Requires Zig 0.16.0 or newer.

```bash
git clone https://github.com/shengyuanchu/fn.git
cd fn
zig build -Doptimize=ReleaseSafe
./zig-out/bin/fn
```

Run tests with `zig build test`.

## Upstream

Changes from fx are brought in through reviewed sync pull requests. Each `fn`
release records its corresponding upstream fx version.

## Contributing

Issues and pull requests are welcome. Never post API keys, tokens, private
source code, or unredacted traces.

## License

Apache-2.0. See [LICENSE](LICENSE) and
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). Upstream fx notices are
retained as required by its license.
