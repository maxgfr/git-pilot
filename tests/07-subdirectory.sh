# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "Running from a subdirectory"

s=$(conflicted_repo subdir "pkg/conflict.txt")
printf '%s\n' "<<<<<<< HEAD" "x" "=======" "y" ">>>>>>> other" > "$s/root.txt"
git -C "$s" add root.txt
run "$s/pkg" conflicts
assert_eq "conflicts lists each file once, from the repository root" "$OUT" $'pkg/conflict.txt\nroot.txt'
run "$s/pkg" take ours conflict.txt
assert_eq "take accepts a path relative to the current directory" "$RC" "0"
run "$s/pkg" commit -m "merge" --dry-run
assert_eq "commit sees conflict markers outside the current directory (exit 2)" "$RC" "2"
git -C "$s" rm -q --cached root.txt
rm "$s/root.txt"
printf '{}\n' > "$s/.releaserc"
printf '%s\n' "new" > "$s/pkg/new.txt"
git -C "$s" add pkg/new.txt
run "$s/pkg" commit-context
assert_contains "conventions are detected from a subdirectory" "$OUT" "semantic-release (.releaserc)"
run "$s/pkg" status
assert_contains "status lists untracked files outside the current directory" "$OUT" "3 .releaserc"

# Printed paths are relative to the root: they are accepted back from anywhere.
s=$(conflicted_repo subdir-root-paths "pkg/conflict.txt")
run "$s/pkg" take ours pkg/conflict.txt
assert_eq "take accepts a root-relative path from a subdirectory" "$RC" "0"
assert_eq "take resolved the root-relative path" "$(cat "$s/pkg/conflict.txt")" $'line 1\nours\nline 3'
s=$(conflicted_repo subdir-root-mark "pkg/conflict.txt")
printf '%s\n' "line 1" "ours and theirs" "line 3" > "$s/pkg/conflict.txt"
run "$s/pkg" mark-resolved pkg/conflict.txt
assert_eq "mark-resolved accepts a root-relative path from a subdirectory" "$RC" "0"
run "$s/pkg" conflicts
assert_eq "the root-relative path was staged" "$OUT" ""

# The same name in the current directory does not hide the file in conflict.
s=$(conflicted_repo subdir-shadow "a.txt")
mkdir -p "$s/sub"
printf '%s\n' "unrelated" > "$s/sub/a.txt"
printf '%s\n' "line 1" "ours and theirs" "line 3" > "$s/a.txt"
run "$s/sub" mark-resolved a.txt
assert_eq "mark-resolved prefers the file in conflict over a namesake" "$(git -C "$s" diff --name-only --diff-filter=U)" ""
assert_eq "mark-resolved leaves the namesake unstaged" "$(git -C "$s" ls-files sub/a.txt)" ""

# diff.relative must not hide conflict markers outside the current directory.
s=$(new_repo subdir-relative)
mkdir -p "$s/sub"
printf '%s\n' "x" > "$s/sub/x.txt"
printf '%s\n' "<<<<<<< HEAD" "a" "=======" "b" ">>>>>>> other" > "$s/root.txt"
git -C "$s" add -A
git -C "$s" config diff.relative true
run "$s/sub" conflicts
assert_eq "conflicts ignores diff.relative" "$OUT" "root.txt"
run "$s/sub" commit -m "feat: x" --dry-run
assert_eq "commit sees markers outside the directory despite diff.relative (exit 2)" "$RC" "2"
git -C "$s" rm -q --cached root.txt
rm "$s/root.txt"
printf 'TOKEN=x\n' > "$s/.env"
git -C "$s" add .env sub/x.txt
git -C "$s" reset -q sub/x.txt
run "$s/sub" commit-context
assert_contains "the staging guard ignores diff.relative" "$OUT" "secret-file: .env"
run "$s/sub" commit -m "chore: env" --dry-run
assert_eq "commit refuses a secret outside the directory despite diff.relative (exit 5)" "$RC" "5"

