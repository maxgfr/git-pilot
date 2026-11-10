# git-pilot

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Shell: Bash](https://img.shields.io/badge/Shell-Bash-green.svg)](script.sh)

Git autopilot for coding agents: AI-written commits, conflict resolution, and auto-rebase. Pure Bash.

git-pilot is an [agent skill](https://skills.sh) plus a small CLI. The agent you already use (Claude Code, Codex, Cursor, OpenCode, and others) writes the commit messages and resolves the conflicts. The `git-pilot` CLI does the Git plumbing and the safety checks. git-pilot never calls a model, needs no API key, and is tied to no provider.

## Features

- **AI commit messages**: your agent writes the message from the staged diff and follows the repository's conventions (Conventional Commits, emoji, language, title-only or bullet points).
- **Convention detection**: reports commitlint, semantic-release, commitizen and commit templates, plus the share of Conventional and emoji subjects and the types and scopes already in use.
- **Atomic commits**: the agent splits a messy working tree into coherent commits from a compact `status` overview.
- **Pull request descriptions**: commits, bodies, the PR template and the diff against the base branch, ready for the agent to write the title and body.
- **Staging guard**: flags staged secrets (`.env`, private keys, token-like strings) and large files; `commit` refuses them until you confirm.
- **Conflict resolution**: rich merge and rebase context so the agent resolves each hunk while preserving the intent of both sides.
- **Auto-rebase**: `pull --rebase` loop with stable exit codes for each conflict round.
- **Blanket strategies**: keep ours, theirs, or both for every hunk in a file.
- **Safety checks**: refuses to commit with conflict markers or unmerged files, supports dry runs, never force-pushes.
- **Smart diff truncation**: keeps the most complete small file diffs within a 16K-character budget.
- **Agent-agnostic**: works with any agent that supports skills, and from the terminal.

## Installation

### As an agent skill (recommended)

```bash
npx skills add maxgfr/git-pilot            # current project
npx skills add maxgfr/git-pilot -g         # all projects (user level)
npx skills add maxgfr/git-pilot -a codex   # a specific agent ('*' for all)
```

The skill bundles its helper script, so nothing else needs to be installed.

### As a CLI

```bash
brew install maxgfr/tap/git-pilot
```

or

```bash
curl -fsSL https://raw.githubusercontent.com/maxgfr/git-pilot/main/script.sh -o git-pilot
chmod +x git-pilot
sudo mv git-pilot /usr/local/bin/
```

Requires Bash and Git.

## Usage with an agent

Ask your agent in plain language:

```text
commit my staged changes
commit everything as a fix, with bullet points, in French
preview a commit message for this diff (dry run)
split my changes into logical commits
write the pull request description for this branch
resolve the merge conflicts
pull with rebase and fix the conflicts, then push
```

The agent shows you the message or the resolution before it commits, pushes, or applies anything, unless you have already told it to go ahead.

## CLI reference

```
git-pilot <command> [options]
```

| Command | Description |
|---|---|
| `status` | Staged, unstaged and untracked files with line counts and sizes |
| `commit-context [-a]` | Print the branch, staged files, warnings, conventions, recent commit subjects, and the staged diff. `-a` stages all changes first |
| `commit -F <file\|-> \| -m <msg> [--dry-run] [--push] [--allow-flagged]` | Commit the staged changes with the given message and print the new SHA |
| `branch-context [--base <ref>]` | Print the branch's commits, PR template, conventions, and diff against its base (default: `origin/HEAD`, then `main` or `master`) |
| `conflicts` | List the files with unresolved conflicts |
| `merge-context` | Print the merge or rebase context: both sides' commits and diff stats |
| `take <ours\|theirs\|both> <file>...` | Resolve every hunk in the files with one strategy, then stage them. Binary conflicts take the chosen side's whole file (`ours` or `theirs` only) |
| `mark-resolved <file>...` | Stage the files after checking that no conflict markers remain |
| `rebase start\|continue\|abort` | `git pull --rebase`, continue after resolving conflicts, or abort |
| `push` | `git push` |
| `--version`, `--help` | |

Commands work from any directory of the repository. Printed paths are relative to the repository root; paths you pass are relative to the current directory, as with Git.

stdout carries data and stderr carries diagnostics, so the output is easy to pipe:

```bash
git-pilot commit-context | your-favorite-llm "write a commit message" > msg.txt
git-pilot commit -F msg.txt
```

| Exit code | Meaning |
|---|---|
| `0` | Success |
| `1` | Error (not a repository, nothing staged, bad usage...) |
| `2` | Conflict markers or unmerged files present |
| `3` | Rebase stopped on conflicts: resolve them, then run `rebase continue` |
| `4` | Push rejected: run `rebase start`, then `push` |
| `5` | Staged files flagged as secrets or large files: unstage them or pass `--allow-flagged` |

During a rebase, "ours" is the upstream and "theirs" is your commit being replayed.

| Environment variable | Default | Description |
|---|---|---|
| `GIT_PILOT_DIFF_BUDGET` | `16000` | Max diff characters printed by `commit-context` and `branch-context` |
| `GIT_PILOT_MAX_FILE_SIZE` | `5242880` | Staged file size (bytes) flagged as large |

Both must be non-negative integers; any other value (`16k`, `5MB`) is an error.

## Migrating from 1.x

Version 2 removes the built-in AI providers (`claude-code`, `codex`, `anthropic`, `openai`, `gemini`, `mistral`), along with `setup`, `config`, API keys, and the provider and formatting flags. The AI work now happens in the agent that runs the skill.

| 1.x | 2.x |
|---|---|
| `git-pilot` / `git-pilot -a -c -e -l fr` | Ask your agent: "commit everything, conventional, with emoji, in French" |
| `git-pilot resolve` | "resolve the conflicts" (the agent uses `conflicts`, `merge-context`, `mark-resolved`) |
| `git-pilot rebase` | "pull with rebase and fix the conflicts" (`rebase start` / `continue`) |
| `git-pilot setup` / `config` | Not needed. You can delete `~/.config/git-pilot/` |

## License

[MIT](LICENSE)

---

Inspired by [claude-auto-commit](https://github.com/0xkaz/claude-auto-commit).
