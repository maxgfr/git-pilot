# git-pilot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](script.sh)

AI-powered git automation: smart commits, conflict resolution, and auto-rebase. Pure Bash.

## Features

- **AI commit messages** — Generate meaningful commit messages (title + description) from your staged diff
- **Multi-provider** — Claude Code & Codex (CLI), Anthropic, OpenAI, Gemini & Mistral (API)
- **CLI-first** — Uses `claude` and `codex` CLIs directly — no API key needed for those
- **Budget-friendly defaults** — Uses cheap/mini models by default (`haiku`, `gpt-5-mini`, `gemini-2.5-flash-lite`, `mistral-small-latest`)
- **Smart diff truncation** — Prioritizes small file diffs to maximize info sent to the AI (16K chars budget)
- **Conflict resolution** — AI-powered merge conflict resolution
- **Auto-rebase** — `pull --rebase` with automatic conflict resolution
- **Conventional Commits** — Optional formatting with `--conventional`
- **Emoji support** — Add emoji to commit messages with `--emoji`
- **Multi-language** — Generate commit messages in any language
- **Dry run** — Preview commit messages without committing
- **Pure Bash** — Single script, no heavy runtime dependencies

## Installation

### Homebrew

```bash
brew install maxgfr/tap/git-pilot
```

### Manual

```bash
curl -fsSL https://raw.githubusercontent.com/maxgfr/git-pilot/main/script.sh -o git-pilot
chmod +x git-pilot
sudo mv git-pilot /usr/local/bin/
```

### Prerequisites

For CLI providers (no API key needed):
- **Claude Code**: Install [Claude Code](https://docs.anthropic.com/en/docs/claude-code) (`claude` CLI)
- **Codex**: Install [OpenAI Codex](https://github.com/openai/codex) (`codex` CLI)

For API providers:
- `curl` and `jq` (installed automatically if missing)
- An API key for the chosen provider

## Quick Start

```bash
# 1. Configure your provider
git-pilot setup

# 2. Stage your changes and generate a commit
git add .
git-pilot
```

With Claude Code (default), no API key is needed — just have `claude` installed.

## Usage

```
git-pilot [command] [options]
```

### Commands

| Command   | Description                                    |
|-----------|------------------------------------------------|
| `commit`  | Generate AI commit message and commit (default)|
| `resolve` | Resolve merge conflicts with AI                |
| `rebase`  | Pull --rebase with AI conflict resolution      |
| `setup`   | Run interactive configuration wizard           |
| `config`  | Show current configuration                     |

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--provider <name>` | `-p` | Provider: `claude-code`, `codex`, `anthropic`, `openai`, `gemini`, `mistral` |
| `--model <name>` | `-m` | Model name (e.g. `haiku`, `gpt-5-mini`, `claude-haiku-4-5`) |
| `--api-key <key>` | | API key (for API providers: anthropic, openai, gemini, mistral) |
| `--dry-run` | `-d` | Preview commit message without committing |
| `--auto-stage` | `-a` | Stage all changes before commit |
| `--auto-push` | `-P` | Push after commit |
| `--conventional` | `-c` | Use Conventional Commits format |
| `--emoji` | `-e` | Add emoji to commit message |
| `--lang <code>` | `-l` | Language for commit message (e.g. `en`, `fr`, `es`) |
| `--yes` | `-y` | Skip confirmation prompts |
| `--version` | `-v` | Show version |
| `--help` | `-h` | Show help |

## Examples

```bash
# Basic commit with Claude Code (default, uses haiku)
git add .
git-pilot

# Auto-stage + conventional commits + emoji
git-pilot -a -c -e

# Dry run (preview only)
git-pilot -d

# Use Codex CLI
git-pilot -p codex

# Use Anthropic API
git-pilot -p anthropic

# Use OpenAI API with a specific model
git-pilot -p openai -m gpt-5-mini

# Commit in French
git-pilot -l fr

# Resolve merge conflicts with AI
git-pilot resolve

# Pull --rebase with AI conflict resolution
git-pilot rebase

# Show current config
git-pilot config

# Non-interactive mode (auto-stage + skip confirm + push)
git-pilot -a -y -P
```

## Configuration

Configuration is stored at `~/.config/git-pilot/config` (XDG-compliant) with `chmod 600` to protect your API key.

```ini
# git-pilot configuration
provider=claude-code
api_key=
model=haiku
max_tokens=1024
auto_stage=false
auto_push=false
language=en
conventional=true
emoji=false
skip_confirm=false
```

You can view your active configuration at any time with `git-pilot config`.

### Environment Variables

API keys can be provided via environment variables (fallback for API providers):

| Provider  | Environment Variable |
|-----------|---------------------|
| Anthropic | `ANTHROPIC_API_KEY`  |
| OpenAI    | `OPENAI_API_KEY`     |
| Gemini    | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| Mistral   | `MISTRAL_API_KEY`    |

CLI providers (`claude-code`, `codex`) don't need API keys — they use their own authentication.

## Supported Providers

| Provider | Type | Default Model | Cost |
|----------|------|---------------|------|
| `claude-code` | CLI | `haiku` | Free (uses your Claude subscription) |
| `codex` | CLI | `gpt-5-mini` | Free (uses your OpenAI auth) |
| `anthropic` | API | `claude-haiku-4-5` | ~$1.00/M input tokens |
| `openai` | API | `gpt-5-mini` | ~$0.25/M input tokens |
| `gemini` | API | `gemini-2.5-flash-lite` | ~$0.075/M input tokens |
| `mistral` | API | `mistral-small-latest` | ~$0.06/M input tokens |

All default models are cheap/mini models — more than enough for generating commit messages.

## License

[MIT](LICENSE)

---

Inspired by [claude-auto-commit](https://github.com/0xkaz/claude-auto-commit).
