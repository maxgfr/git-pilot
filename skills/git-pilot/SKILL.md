---
name: git-pilot
description: Git autopilot for commits, merge conflicts and rebases. Use when the user asks to commit their changes with a generated message, write a commit message from the staged diff, resolve merge or rebase conflicts, or pull with rebase and fix the conflicts. Bundles a deterministic helper script; you write the messages and resolutions yourself.
---

# git-pilot

You do the thinking (commit messages, conflict resolutions); the bundled
script does the Git plumbing and safety checks.

The script is `scripts/git-pilot.sh`, relative to this SKILL.md. Run it with
`bash <this-skill-dir>/scripts/git-pilot.sh <command>` from inside the user's
repository. If `git-pilot` is on `PATH` (Homebrew install), it is the same
tool. stdout is data for you; stderr is diagnostics.

Exit codes: `0` ok, `1` error, `2` conflict markers or unmerged files present,
`3` rebase stopped on conflicts, `4` push rejected.

## Rules

- Never commit, push, or apply a resolution the user has not confirmed, unless
  they already said to go ahead (e.g. "commit it", "yes", "don't ask").
- "Dry run" / "preview" means: show the message, do not commit (`--dry-run`).
- Never use `--no-verify`, `--force`, `--force-with-lease`, or rewrite pushed
  history. If a hook fails, show the error and fix the cause.
- Only stage everything (`-a`) when the user asks for it or nothing is staged
  and they asked to commit "all" their changes.
- Push only when the user asks.

## Commit

1. `scripts/git-pilot.sh commit-context` (add `-a` to stage all changes first).
   - Exit `1`: nothing is staged. Tell the user, or offer `-a`.
   - Exit `2`: conflicts remain. Go to **Resolve conflicts** first.
   - Output: branch, staged files, recent commit subjects, and the staged diff
     (large diffs are truncated; read the files if you need more).
2. Write the message:
   - Title: one line, at most 72 characters, imperative mood, no trailing period.
   - Use Conventional Commits (`feat:`, `fix:`, `docs:`, `refactor:`,
     `chore:`, `test:`, `perf:`, `ci:`, `build:`, `style:`, `revert:`) when
     the recent subjects or the repo's tooling (commitlint, semantic-release,
     contributing guide) use them, or when the user asks. Honor a type the user
     imposes (e.g. "commit as fix"). Use `!` or a `BREAKING CHANGE:` footer for
     breaking changes.
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
   success stdout is the new commit SHA.

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
   `scripts/git-pilot.sh take <ours|theirs|both> <file>...`.
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
