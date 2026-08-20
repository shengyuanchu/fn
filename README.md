# fn

> A tiny, open, model-independent coding agent.

`fn` is an independent community fork of
[fx](https://github.com/vercel-labs/fx) by Vercel Labs. It adds direct support
for your own OpenAI, Anthropic, and compatible local models. This project is
not affiliated with or endorsed by Vercel.

## Features

- OpenAI Chat Completions and Responses APIs
- Anthropic Messages API
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

`fn` asks before sensitive actions. `--yolo` disables approvals.

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
