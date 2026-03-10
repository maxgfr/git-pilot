# git-pilot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](script.sh)

AI-powered git automation: smart commits, conflict resolution, and auto-rebase. Pure Bash.

Inspired by [claude-auto-commit](https://github.com/0xkaz/claude-auto-commit).

## Features

- **AI commit messages** — Generate meaningful commit messages from your staged diff
- **Multi-provider** — Supports Anthropic, OpenAI, Gemini, Mistral, and Codex
- **Conflict resolution** — AI-powered merge conflict resolution
- **Auto-rebase** — `pull --rebase` with automatic conflict resolution
- **Conventional Commits** — Optional formatting with `--conventional`
- **Emoji support** — Add emoji to commit messages with `--emoji`
- **Multi-language** — Generate commit messages in any language
- **Dry run** — Preview commit messages without committing
- **Pure Bash** — Single script, no runtime dependencies beyond `curl`, `jq`, and `git`

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

## Quick Start

```bash
# 1. Configure your provider and API key
git-pilot setup

# 2. Stage your changes and generate a commit
git add .
git-pilot
```

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
| `--provider <name>` | `-p` | Provider: `anthropic`, `openai`, `gemini`, `mistral`, `codex` |
| `--model <name>` | `-m` | Model name (e.g. `claude-sonnet-4-20250514`, `gpt-4o`) |
| `--api-key <key>` | | API key (overrides config) |
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
# Basic commit with AI message
git add .
git-pilot

# Auto-stage + conventional commits + emoji
git-pilot -a -c -e

# Dry run (preview only)
git-pilot -d

# Use a specific provider and model
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
provider=anthropic
api_key=sk-ant-xxxx
model=claude-sonnet-4-20250514
max_tokens=1024
auto_stage=false
auto_push=false
language=en
conventional=true
emoji=false
```

### Environment Variables

API keys can also be provided via environment variables (fallback when not in config):

| Provider  | Environment Variable |
|-----------|---------------------|
| Anthropic | `ANTHROPIC_API_KEY`  |
| OpenAI    | `OPENAI_API_KEY`     |
| Gemini    | `GEMINI_API_KEY` or `GOOGLE_API_KEY` |
| Mistral   | `MISTRAL_API_KEY`    |
| Codex     | `OPENAI_API_KEY`     |

## Supported Providers

| Provider  | Default Model              | Endpoint |
|-----------|---------------------------|----------|
| Anthropic | `claude-sonnet-4-20250514`     | `api.anthropic.com/v1/messages` |
| OpenAI    | `gpt-4o`                  | `api.openai.com/v1/chat/completions` |
| Gemini    | `gemini-2.0-flash`        | `generativelanguage.googleapis.com/v1beta/...` |
| Mistral   | `mistral-large-latest`    | `api.mistral.ai/v1/chat/completions` |
| Codex     | `gpt-4o`                  | `api.openai.com/v1/chat/completions` |

## License

[MIT](LICENSE)
