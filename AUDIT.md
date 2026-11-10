# Code audit: git-pilot 2.0.0

Audited on 2026-11-10, from commit `f59638d` (`chore(release): 2.0.0`). Scope: `script.sh` (the CLI, 803 lines, duplicated byte for byte in `skills/git-pilot/scripts/git-pilot.sh`), `skills/git-pilot/SKILL.md`, `test-git-pilot.sh`, the release hook and the two workflows.

## Summary

1. The codebase is small and in good shape: one Bash script with a clear stdout/stderr split, documented exit codes, no dependencies beyond Git, and a baseline that was fully green (`bash -n`, `shellcheck`, 107/107 tests).
2. The bugs were all at edges the tests did not exercise: unusual file names, binary conflicts, running from a subdirectory, the user's Git configuration, invalid settings and large inputs.
3. Thirteen bugs are fixed, each with a regression test. Two could lose file content in `take`, and four weakened a safety check (conflict markers, large files). The suite went from 107 to 175 assertions; 49 of the new ones fail against the 2.0.0 script.
4. Three performance cliffs are removed. The worst made `commit-context` take 440 s on a 20,000-line staged file; it now takes about 1 s.
5. Nothing critical is left open. What remains is two design questions (how wide the conflict-marker scan should be, what exit code 4 means) and CI/release hardening, which was left untouched as deployment configuration.

Every commit below passed `bash -n`, `shellcheck script.sh test-git-pilot.sh` and `bash test-git-pilot.sh` on macOS (`/bin/bash` 3.2.57). The Ubuntu job ran in CI on the audit branch before anything reached `main`.

## Bugs fixed

All fixes are in `script.sh` (mirrored in the bundled skill script); all tests are in `test-git-pilot.sh`.

| Commit | Function | Issue | Fix | Tests added |
|---|---|---|---|---|
| `6e31c35` | `rewrite_with_awk`, `file_has_markers` | A file named like `key=value.txt` was parsed by awk as a variable assignment: `take` emptied the file, staged it and reported success. A file named like `-x.txt` was parsed by grep as options, so `mark-resolved` skipped the marker check and staged it. | Both tools read the file from stdin. | `take keeps the content of a file named like an assignment`, `mark-resolved checks a file named like an option (exit 2)` |
| `c48d340` | `cmd_take` | On a binary conflict Git writes no markers and leaves our version in place. `take theirs` therefore staged **our** side, and awk truncated the file at its first NUL byte. | An unmerged file without markers gets the chosen side's whole version (`git checkout --ours/--theirs`). `both`, or a side that deleted the file, exits 1 with an explanation. | 10 assertions: binary `theirs`/`ours`/`both`, delete/modify conflict |
| `7bbf12b` | `conflicted_files`, `detect_conventions`, `cmd_status`, `cmd_branch_context` | From a subdirectory, `git grep` only scanned the current directory: `commit` missed conflict markers elsewhere (exit 0 instead of 2), and a conflicted file was listed twice under two different paths. Commit tooling, the PR template and untracked files outside the current directory were not found. | Lookups are anchored at the top of the working tree. | 6 assertions: "Running from a subdirectory" section, PR template from a subdirectory |
| `5d89d6c` | new `git_plain` helper, used by every listing | Non-ASCII paths were printed as `"caf\303\251.txt"`, which cannot be passed back to `take` or `mark-resolved`. With `color.ui=always`, ANSI codes ended up in the context sent to the agent and large diffs could no longer be split per file. | One helper forces `color.ui=never` and `core.quotePath=false` for output that is printed or parsed; context diffs also pass `--no-ext-diff`. | 5 assertions under "Output independent of the user's Git configuration" |
| `fb30cd5` | `cmd_branch_context` | Commit bodies were cut with `… \| awk \| head -80`. Past one pipe buffer of bodies, `head` exited early, awk got SIGPIPE and `pipefail` turned it into exit 141 with no output. | awk applies the 80-line cap itself and reads its input to the end. | `branch-context survives long commit bodies` + 2 |
| `653fbd5` | new `int_setting` / `load_settings`, `truncate_diff`, `staged_findings` | `GIT_PILOT_MAX_FILE_SIZE=1k` made the size test fail inside an `if`, silently disabling the large-file guard. `GIT_PILOT_DIFF_BUDGET=16k` crashed mid-output with a Bash arithmetic error. A budget smaller than the truncation notice crashed on a negative substring length. | Both settings are validated once before any command runs (exit 1 with the variable named); the space left for the diff is clamped at 0. | 8 assertions (invalid budget, tiny budget, invalid size limit) |
| `730a742` | `cmd_mark_resolved`, `cmd_commit_context`, `cmd_rebase` | `mark-resolved .` staged a whole directory without checking any file for markers. An unknown path exited 128, which is not a documented code; so did a failing `git add -A` or `git rebase --abort`. | Directories are refused; those Git failures now exit 1. | `mark-resolved refuses a directory` + 2 |
| `efa1e43` | `check_git_repo` | Inside `.git` or a bare repository, `git rev-parse --is-inside-work-tree` exits 0 and prints `false`, so the check passed. Commands printed raw Git errors and `status` exited 0. | The printed value is compared to `true`. | `inside .git exits 1` + 1 |
| `9961ea9` | `cmd_push`, `cmd_rebase`, `cmd_conflicts`, `cmd_merge_context` | Extra arguments were ignored without a word: `push --force` or `push origin other-branch` ran a plain `git push` of the current branch. | Unexpected arguments exit 1, as `status` already did. | 5 assertions under "Arguments that would be ignored are refused" |
| `dabf03f` | `detect_conventions` | Any non-ASCII first byte counted as a leading emoji, so `Éviter…`, `Über…` or `修复…` were reported as emoji subjects (6/7 instead of 3/7 in the reproduction). The skill tells the agent to add emoji when the history uses them. | The check matches the UTF-8 lead bytes of the emoji blocks, or a `:shortcode:`. | `conventions count only real leading emoji` |
| `cd86522` | `staged_findings` | `sk-[A-Za-z0-9_-]{32}` had no left boundary, so ordinary words ending in "sk" (`mask-image-linear-gradient-…`, `risk-management-…`) were reported as secret content and blocked `commit` with exit 5. An added line starting with `++ ` was taken for a file header, and `diff.noprefix` cut two characters off the reported path. | `AKIA` and `sk-` must start a word; the parser tracks hunks and forces the `a/` `b/` prefixes. | 4 assertions (kebab-case, real key, attribution, `diff.noprefix`) |
| `bc17e7d` | `cmd_commit_context` | When every conflict of a merge is resolved to our side, the index equals `HEAD`. `commit` accepts that state, but `commit-context` exited 1 with "No staged changes", so the documented flow (context, then commit) dead-ended. Found while writing the subdirectory tests. | With a merge in progress, an empty diff is reported instead of refused. | 4 assertions under "A merge resolved to our side" |
| `f1e81df` | `cmd_commit_context`, new `current_branch` helper | `commit-context` printed an empty `Branch:` line on a detached HEAD, unlike `status` and `branch-context`. | One helper names the branch in all four places. | `commit-context names a detached HEAD` + 1 |

## Optimizations

Measured on macOS (Apple silicon, `/bin/bash` 3.2.57, Git 2.56) with synthetic repositories. Process creation is slow on this machine, which is what the "before" numbers mostly measure; timings varied by up to 2x between runs, so the "after" column gives the range observed.

| Commit | What | Before | After |
|---|---|---|---|
| `605783d` | `truncate_diff`: the diff was split per file by a Bash loop appending each line to a growing string (quadratic), then written to temporary files. Replaced by two linear awk passes and a `sort`, with no temporary files. | `commit-context` with one staged file of 5,000 lines: **38.1 s**. 20,000 lines: **440.1 s**. 60,000 lines: stopped unfinished after more than two minutes. | 0.4–0.9 s, 1.1–1.6 s, 2.3–6.9 s |
| `a4a4e3e` | `staged_findings`: `basename` and `git cat-file -s` ran once per staged file. Replaced by one `git diff --cached --raw` and one `git cat-file --batch-check`. | `commit --dry-run` with 500 staged files: **9.2 s**. 2,000 files: **29.3 s**. | 0.2–0.4 s, 0.6–1.4 s |
| `7451eb4` | `cmd_status`: `wc` and `xargs` ran once per untracked file. Replaced by one `wc` per 200 files. | `status` with 500 untracked files: **4.3 s**. 2,000 files: **14.1 s**. | 0.2–0.5 s, 0.4–0.5 s |
| `605783d` | `cmd_commit_context` ran `git diff --cached --stat` on every call, although the stat is only printed with a truncated diff. | One extra `git diff` per call. | Skipped when the diff fits (estimated, not measured separately). |

## Behaviour changes to be aware of

None of these changes the happy path, but each is visible to a user or an agent:

- `take ours|theirs` on a binary or delete/modify conflict now takes that side's whole file; `take both` on such a file exits 1 (it used to report success and stage the wrong content).
- Paths are always printed relative to the repository root, unescaped, and commands cover the whole repository from any directory. Arguments are still relative to the current directory, as with Git. `README.md` and `SKILL.md` say so.
- Invalid `GIT_PILOT_DIFF_BUDGET` / `GIT_PILOT_MAX_FILE_SIZE` values exit 1 instead of crashing or being ignored.
- `mark-resolved <directory>`, and extra arguments to `push`, `rebase`, `conflicts` and `merge-context`, exit 1.
- Commands run inside `.git` or a bare repository exit 1.
- `commit-context` exits 0 during a merge that stages nothing.
- Token detection is stricter: a key glued to a preceding letter, digit, `_` or `-` (for example `xsk-…`) is no longer flagged.
- Truncated diffs list the kept files in diff order instead of smallest first; the notice now always reads `[... N large file(s) omitted — L chars total]`; a stat longer than half the budget is reduced to its summary line.
- `branch-context` adds `[... N more lines of commit bodies omitted]` when it cuts the bodies.
- `status` prints `-` instead of an empty size for untracked entries that are not readable regular files (nested repository, dangling link).

## Issues found but not fixed

### Critical

None.

### Important

1. **The conflict-marker scan covers every tracked file.** `conflicted_files` greps the whole tree for lines starting with `<<<<<<< `. A repository that legitimately contains such lines (merge fixtures, documentation about conflicts) can never `commit` or `rebase continue` through git-pilot, and there is no override. *Recommendation:* for `commit`, check only the added lines of the staged diff; for `conflicts` and `rebase continue`, restrict the scan to files changed in the index or working tree. Not changed because the wide scan looks deliberate (see open question 1).
2. **Exit code 4 means "any push failure".** `cmd_push` returns 4 when the remote rejects the push, but also when the branch has no upstream, authentication fails or the network is down. The help and `SKILL.md` then tell the agent to run `rebase start`, which cannot help in those cases. *Recommendation:* detect the missing upstream before pushing and exit 1 with a hint (or push with `-u`, see open question 2); keep 4 for a rejected push.
3. **Releases are not gated on tests.** `.github/workflows/release.yml` runs on every push to `main`, independently of `check-program.yml`, so a commit that fails the tests is still released. *Recommendation:* trigger the release with `workflow_run` on a successful "Check Program", or move both into one workflow with `needs:`. Not touched (deployment configuration).
4. **Unpinned third-party action.** `ludeeus/action-shellcheck@master` runs whatever is on that branch. The other actions are pinned to a major tag only. *Recommendation:* pin to a release tag or a commit SHA. Not touched (deployment configuration).

### Minor

5. `.version-hook.sh` has no `set -e`: if `sed` fails, the script still copies the unmodified file and reports success. Add `set -euo pipefail`.
6. `merge-context` only recognises merges and rebases. During a conflicted `cherry-pick` or `revert` it prints the recent history, without saying which side is which.
7. `take` on a file that is not in conflict stages it as it is and reports "Resolved". A warning, or a refusal, would be safer.
8. Marker detection deliberately ignores a lone `=======` line (it is also a Markdown and reStructuredText underline), so a half-removed conflict can pass `mark-resolved`.
9. The secret scan is a list of seven token patterns over added lines. It will miss most other providers and anything high-entropy. Consider running `gitleaks` or a similar tool when it is installed, and keeping the built-in list as the fallback.
10. Paths containing a tab, a newline or a double quote are still printed C-quoted by Git, and a newline breaks the line-based lists. Not handled.
11. `status` shows an unmerged file twice under "Unstaged" (a `U` line and an `M` line). This mirrors `git diff --name-status`.
12. Colours on stderr ignore `NO_COLOR`.
13. The script runs with `set -eo pipefail` but not `-u`. Enabling it needs care on Bash 3.2, where expanding an empty array is an error.
14. The cost of the whole-tree `git grep` in `conflicted_files` on very large repositories was not measured.
15. The test suite is one sequential 600-line script that takes about 30 s locally; splitting it per command would make failures easier to locate.

## Open questions

1. **Scope of the conflict-marker scan** (issue 1): should `commit` only look at what is being committed? I recommend yes; it removes the false positives and makes the check proportional to the change instead of the repository.
2. **Push without an upstream** (issue 2): should `push` set the upstream itself (`git push -u origin HEAD`), or stay a plain `git push` and fail with a clear message? The first is friendlier for the "commit and push a new branch" flow; the second keeps the command predictable.
3. **Paths from a subdirectory:** output is now root-relative while arguments stay relative to the current directory, exactly like `git diff` versus `git add`. If you would rather have the tool accept root-relative arguments too, or always behave as if run from the root, say so; it is a small change either way.
4. **Delete/modify conflicts in `take`:** it now stops when the chosen side deleted the file. Should it run `git rm` instead? I kept the conservative behaviour because it deletes a file.
5. **Gating the release on CI** (issue 3) and pinning the actions (issue 4): both are changes to deployment configuration, so they need your go-ahead.
