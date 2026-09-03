# Repository guide

## Working agreement

- Keep `script.sh` compatible with Bash on macOS and Ubuntu.
- Treat stdout as generated data and stderr as user-facing diagnostics.
- Preserve confirmation and dry-run boundaries around Git mutations.
- Run CLI AI providers non-interactively. Codex uses an ephemeral, read-only sandbox and returns only its final response.
- Keep API credentials out of logs and preserve mode `600` for saved configuration.

## Verification

- Run `bash -n script.sh test-git-pilot.sh` after shell changes.
- Run `shellcheck script.sh test-git-pilot.sh` before committing.
- Run `bash test-git-pilot.sh`; provider changes require tests through the public CLI with external executables mocked at the process boundary.
- Exercise commit, conflict-resolution, and rebase paths when changing shared prompt or Git logic.

## Release

- Use Conventional Commit subjects. semantic-release publishes from `main`.
- Leave version changes to `.version-hook.sh` and the release workflow.
