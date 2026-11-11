# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "status"

st=$(new_repo status)
printf '%s\n' "one" "two" > "$st/tracked.txt"
git -C "$st" add tracked.txt
git -C "$st" commit -q -m "feat: tracked file"
printf '%s\n' "three" >> "$st/tracked.txt"
printf '%s\n' "staged" > "$st/staged.txt"
git -C "$st" add staged.txt
printf '%s\n' "new" > "$st/untracked.txt"
run "$st" status
assert_eq "status succeeds" "$RC" "0"
assert_contains "status shows staged files with counts" "$OUT" "A +1 -0 staged.txt"
assert_contains "status shows unstaged files with counts" "$OUT" "M +1 -0 tracked.txt"
assert_contains "status shows untracked files with sizes" "$OUT" "4 untracked.txt"

# An unmerged file appears once per section, with its line counts.
uc=$(conflicted_repo status-unmerged)
run "$uc" status
assert_contains "status shows an unmerged file with its line counts" "$OUT" "U +4 -0 conflict.txt"
assert_not_contains "status does not repeat an unmerged file as modified" "$OUT" "M +4 -0 conflict.txt"

# Names Git quotes are quoted the same way here, one entry per line.
printf '%s\n' "tab" > "$st/tab"$'\t'"name.txt"
printf '%s\n' "newline" > "$st/new"$'\n'"line.txt"
run "$st" status
assert_contains "status quotes an untracked name with a tab" "$OUT" '  4 "tab\tname.txt"'
assert_contains "status quotes an untracked name with a newline" "$OUT" '  8 "new\nline.txt"'
printf '%s\n' "ctrl" > "$st/c"$'\001'"d.txt"
printf '%s\n' "nel" > "$st/n"$'\302\205'"l.txt"
run "$st" status
assert_contains "status quotes other control bytes in octal, like Git" "$OUT" '  5 "c\001d.txt"'
assert_contains "status leaves U+0085 unquoted, like Git" "$OUT" "  4 n"$'\302\205'"l.txt"
git_names=$(git -C "$st" -c core.quotePath=false ls-files --others --exclude-standard | grep -E '^"c|^n')
assert_contains "Git itself quotes the control byte the same way" "$git_names" '"c\001d.txt"'
assert_contains "Git itself leaves U+0085 unquoted" "$git_names" "n"$'\302\205'"l.txt"
rm "$st/c"$'\001'"d.txt" "$st/n"$'\302\205'"l.txt"
qs=$(new_repo quoted-secret)
printf 'x\n' > "$qs/a\"b.pem"
git -C "$qs" add -A
run "$qs" commit-context
assert_contains "a flagged name is quoted like Git does" "$OUT" 'secret-file: "a\"b.pem"'
rm "$st/tab"$'\t'"name.txt" "$st/new"$'\n'"line.txt"

git -C "$st" checkout -q --detach
run "$st" status
assert_contains "status names a detached HEAD" "$OUT" "Branch: detached HEAD"
run "$st" commit-context
assert_contains "commit-context names a detached HEAD" "$OUT" "Branch: detached HEAD"
git -C "$st" checkout -q main

# Untracked entries that are not readable regular files are listed without a size.
printf '%s\n' "hello" > "$st/my notes.txt"
git init -q "$st/vendored"
git -C "$st/vendored" commit -q --allow-empty -m "chore: nested repository"
ln -s missing-target "$st/dangling"
run "$st" status
assert_eq "status succeeds with special untracked entries" "$RC" "0"
assert_contains "status keeps spaces in untracked paths" "$OUT" "  6 my notes.txt"
assert_contains "status lists a nested repository without a size" "$OUT" "  - vendored/"
assert_contains "status lists a dangling link without a size" "$OUT" "  - dangling"
assert_contains "status still sizes regular files around them" "$OUT" "  4 untracked.txt"

