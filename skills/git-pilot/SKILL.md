---
name: git-pilot
description: Git autopilot for commits, pull requests, merge conflicts and rebases. Use when the user asks to commit their changes with a generated message, split changes into atomic commits, write a pull request title and description, resolve merge or rebase conflicts, or pull with rebase and fix the conflicts. Bundles a deterministic helper script; you write the messages and resolutions yourself.
---

# git-pilot

You do the thinking (commit messages, conflict resolutions); the bundled
script does the Git plumbing and safety checks.

The script is `scripts/git-pilot.sh`, relative to this SKILL.md. Run it with
`bash <this-skill-dir>/scripts/git-pilot.sh <command>` from inside the user's
repository. If `git-pilot` is on `PATH` (Homebrew install), it is the same
tool. stdout is data for you; stderr is diagnostics.

Exit codes: `0` ok, `1` error, `2` conflict markers or unmerged files present,
`3` rebase stopped on conflicts, `4` push rejected, `5` staged files flagged as
secrets or large files.

## Rules

- Never commit, push, or apply a resolution the user has not confirmed, unless
  they already said to go ahead (e.g. "commit it", "yes", "don't ask").
- "Dry run" / "preview" means: show the message, do not commit (`--dry-run`).
- Never use `--no-verify`, `--force`, `--force-with-lease`, or rewrite pushed
  history. If a hook fails, show the error and fix the cause.
- Only stage everything (`-a`) when the user asks for it or nothing is staged
  and they asked to commit "all" their changes.
- Push only when the user asks.
- Never commit files flagged as secrets or large files without telling the
  user what was flagged and getting an explicit go-ahead.

## Commit

1. `scripts/git-pilot.sh commit-context` (add `-a` to stage all changes first).
   - Exit `1`: nothing is staged. Tell the user, or offer `-a`.
   - Exit `2`: conflicts remain. Go to **Resolve conflicts** first.
   - Output: branch, staged files, `Warnings` (flagged files, if any),
     `Conventions` (tooling, Conventional Commits and emoji usage, types and
     scopes used), recent commit subjects, and the staged diff (large diffs are
     truncated; read the files if you need more).
   - If `Warnings` is present, stop and show it to the user: suggest
     unstaging (`git restore --staged <file>`) and adding the file to
     `.gitignore`, or proceed with `commit --allow-flagged` only if they
     confirm the file is safe.
2. Write the message:
   - Title: one line, at most 72 characters, imperative mood, no trailing period.
   - Use Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`,
     `chore:`, `test:`, `perf:`, `ci:`, `build:`, `style:`, `revert:`) when
     the `Conventions` section shows them (tooling such as commitlint or
     semantic-release, or most recent subjects), or when the user asks. Reuse
     an existing scope when one fits. Honor a type the user imposes (e.g.
     "commit as fix"). Use `!` or a `BREAKING CHANGE:` footer for breaking
     changes. If a commit template is listed, follow it.
   - Default to a title only. Add a body (blank line, then 2–5 one-line `-`
     bullets on what changed and why) when the user asks for details or the
     change is too large for one line.
   - Add a leading emoji only when the user asks or the history uses them.
   - Write in the language the user asks for; otherwise match the history
     (English when unsure).
   - Describe the change, not the tooling: never add AI attribution, trailers or
     links unless the repo explicitly requires them.
3. Show the message and ask for confirmation (see Rules).
4. Commit by passing the message on stdin:

   ```bash
   printf '%s\n' "$message" | bash scripts/git-pilot.sh commit -F -
   ```

   `--dry-run` prints without committing; `--push` pushes afterwards. On
   success stdout is the new commit SHA. Exit `5` means flagged files are
   staged (see step 1).

## Split into atomic commits

When the user asks to commit "in logical commits" or the changes clearly mix
unrelated work:

1. `scripts/git-pilot.sh status` lists staged, unstaged and untracked files
   with line counts and sizes. Read the diffs (`git diff`, `git diff --cached`)
   to understand each change.
2. Propose a plan to the user: an ordered list of commits, each with its files
   (or hunks) and a draft message. Keep each commit coherent and, when
   possible, buildable on its own; put refactors before the features that rely
   on them.
3. If something was already staged that does not belong to the first commit,
   unstage it first (`git restore --staged <file>`).
4. For each commit: stage only its files (`git add -- <file>...`). For part of
   a file, write the hunks to a patch and apply it to the index
   (`git apply --cached <patch>`); never use interactive `git add -p`. Then
   run **Commit** steps 1–4 (one confirmation for the whole plan is enough if
   the user approved it).
5. Finish with `scripts/git-pilot.sh status` and confirm nothing was left out
   unintentionally.

## Pull request description

1. `scripts/git-pilot.sh branch-context` (add `--base <ref>` when the target
   branch is not `origin/HEAD`, `main` or `master`). Output: branch, base,
   commits with bodies, the repository's pull request template if any,
   `Conventions`, diff stat and diff.
2. Write:
   - A title: if the repository squash-merges with Conventional Commits or
     semantic-release, make it a valid Conventional Commit subject (it becomes
     the release note); otherwise a short imperative summary.
   - A body that follows the template when there is one. Otherwise: a short
     summary of what and why, the notable changes as bullets, breaking changes
     and migration notes if any, and how it was tested (only what was really
     run). Reference issues mentioned in commits (`Closes #123`).
   - No AI attribution, generated-by lines, or session links.
3. Show it to the user. Create the pull request only if they ask, with their
   hosting CLI (e.g. `gh pr create --title … --body-file …`), after pushing
   the branch.

## Resolve conflicts

1. `scripts/git-pilot.sh conflicts` lists the files; empty output means none.
2. `scripts/git-pilot.sh merge-context` explains the situation: merge or
   rebase, both sides' commits and diff stats. Note which side is "ours": in a
   merge it is the current branch; **during a rebase it is the upstream**, and
   "theirs" is the local commit being replayed.
3. For each file, read it and resolve every hunk between `<<<<<<<`,
   `|||||||` (base, if present), `=======` and `>>>>>>>`:
   - Understand why each side changed the code, from the commit context.
   - Keep the intent of both sides when possible; when both changed the same
     thing, combine them logically. Keep the code compiling and consistent
     (imports, signatures, call sites, lockfiles regenerated not hand-merged).
   - Edit the file with your normal editing tools and remove all markers.
4. Show the user a short summary of each resolution, then stage it:
   `scripts/git-pilot.sh mark-resolved <file>...` (exit `2` means markers
   remain).
5. If the user wants one blanket strategy instead, use
   `scripts/git-pilot.sh take <ours|theirs|both> <file>...`. A conflicted
   file without markers (binary file, or deleted on one side) gets that
   side's whole version; `both`, or a side that deleted the file, exits `1`:
   decide with the user, then `git rm` or `mark-resolved`.
6. Finish: for a merge, commit (see **Commit**, the message can be the
   default `Merge branch '…'`); for a rebase, continue below.

## Rebase (pull --rebase)

1. `scripts/git-pilot.sh rebase start`.
   - Exit `0`: up to date, done.
   - Exit `3`: stopped on conflicts. Resolve them (see above), then run
     `scripts/git-pilot.sh rebase continue`. Repeat while it exits `3`.
     Stop after 10 rounds and ask the user.
   - Exit `1`: report git's error (dirty tree, no upstream…). If git says the
     resolved commit is now empty, ask the user before `git rebase --skip`.
2. If the user gives up or a resolution is not safe,
   `scripts/git-pilot.sh rebase abort` restores the previous state.
3. To push after a rejected push (exit `4`): `rebase start`, resolve, then
   `scripts/git-pilot.sh push`.
