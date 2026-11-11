# Repository guide

git-pilot ships two things that must stay in sync:

- `script.sh`: the `git-pilot` CLI, a set of deterministic Git helpers (installed by Homebrew and curl).
- `skills/git-pilot/`: the agent skill (`SKILL.md` + `scripts/git-pilot.sh`, a byte-identical copy of `script.sh`), installed with `npx skills add maxgfr/git-pilot`.

## Working agreement

- The CLI never calls a model. Commit messages and conflict resolutions are written by the agent running the skill; keep that guidance in `SKILL.md`.
- Keep `script.sh` compatible with Bash on macOS and Ubuntu.
- Treat stdout as generated data and stderr as user-facing diagnostics. Keep subcommands non-interactive and keep their exit codes stable (documented in `--help` and `SKILL.md`).
- Preserve confirmation and dry-run boundaries around Git mutations, in the CLI and in the skill instructions.
- After editing `script.sh`, copy it to `skills/git-pilot/scripts/git-pilot.sh`; the tests fail when the two differ.

## Verification

- Run `bash -n script.sh test-git-pilot.sh tests/*.sh .version-hook.sh` after shell changes.
- Run `shellcheck -x script.sh test-git-pilot.sh .version-hook.sh` before committing (`-x` follows the test files).
- Run `bash test-git-pilot.sh`; it drives the public CLI against temporary repositories and checks the skill packaging. Each section lives in `tests/NN-name.sh`; the files run in order in one shell and later ones reuse repositories set up by earlier ones, so add a new test to the section it belongs to.
- Exercise commit, conflict-resolution, and rebase paths when changing Git logic or `SKILL.md`.

## Release

- Use Conventional Commit subjects. semantic-release publishes from `main`, in the `release` job of `.github/workflows/check-program.yml`, once the tests and ShellCheck pass.
- Actions are pinned to a commit SHA with the version in a comment; update both together.
- Leave version changes to `.version-hook.sh` and the release workflow; the hook also syncs the bundled skill script.
