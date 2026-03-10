# git-pilot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](script.sh)

AI-powered git automation: smart commits, conflict resolution, and auto-rebase. Pure Bash.

Inspired by [claude-auto-commit](https://github.com/0xkaz/claude-auto-commit).

## Features

- **AI commit messages** — Generate meaningful commit messages from your staged diff
- **Multi-provider** — Claude Code & Codex (CLI), OpenAI, Gemini & Mistral (API)
- **CLI-first** — Uses `claude` and `codex` CLIs directly — no API key needed for those
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

| Command   | Description                                |
|-----------|--------------------------------------------|
| `commit`  | Generate AI commit message and commit (default) |
| `resolve` | Resolve merge conflicts with AI            |
| `rebase`  | Pull --rebase with AI conflict resolution  |
| `setup`   | Run interactive configuration wizard       |

### Options

| Flag | Short | Description |
|------|-------|-------------|
| `--provider <name>` | `-p` | Provider: `claude-code`, `codex`, `openai`, `gemini`, `mistral` |
| `--model <name>` | `-m` | Model name (for API providers, e.g. `gpt-4o`) |
| `--api-key <key>` | | API key (for API providers: openai, gemini, mistral) |
| `--dry-run` | `-d` | Preview commit message without committing |
| `--auto-stage` | `-a` | Stage all changes before commit |
| `--auto-push` | | Push after commit |
| `--conventional` | `-c` | Use Conventional Commits format |
| `--emoji` | `-e` | Add emoji to commit message |
| `--lang <code>` | `-l` | Language for commit message (e.g. `en`, `fr`, `es`) |
| `--yes` | `-y` | Skip confirmation prompts |
| `--version` | `-v` | Show version |
| `--help` | `-h` | Show help |

## Examples

```bash
# Basic commit with Claude Code (default)
git add .
git-pilot

# Auto-stage + conventional commits + emoji
git-pilot -a -c -e

# Dry run (preview only)
git-pilot -d

# Use Codex CLI
git-pilot -p codex

# Use an API provider
git-pilot -p openai -m gpt-4o

# Commit in French
git-pilot -l fr

# Resolve merge conflicts with AI
git-pilot resolve

# Pull --rebase with AI conflict resolution
git-pilot rebase

# Non-interactive mode
git-pilot -a -y --auto-push
```

## Configuration

Configuration is stored at `~/.config/git-pilot/config` (XDG-compliant) with `chmod 600` to protect your API key.

```ini
# git-pilot configuration
provider=claude-code
api_key=
model=
max_tokens=1024
auto_stage=false
auto_push=false
language=en
conventional=true
emoji=false
```

### Environment Variables

API keys can be provided via environment variables (fallback for API providers):

| Provider  | Environment Variable |
|-----------|---------------------|
| OpenAI    | `OPENAI_API_KEY`     |
| Gemini    | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| Mistral   | `MISTRAL_API_KEY`    |

CLI providers (`claude-code`, `codex`) don't need API keys — they use their own authentication.

## Supported Providers

| Provider | Type | Default Model | How it works |
|----------|------|---------------|--------------|
| `claude-code` | CLI | *(uses claude default)* | Calls `claude -p` directly |
| `codex` | CLI | *(uses codex default)* | Calls `codex -q` directly |
| `openai` | API | `gpt-4o` | `api.openai.com/v1/chat/completions` |
| `gemini` | API | `gemini-2.0-flash` | `generativelanguage.googleapis.com/v1beta/...` |
| `mistral` | API | `mistral-large-latest` | `api.mistral.ai/v1/chat/completions` |

## License

[MIT](LICENSE)
