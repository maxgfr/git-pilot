# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "cherry-pick and revert conflicts"

cp=$(conflicted_repo cherry-pick)
git -C "$cp" merge --abort
git -C "$cp" cherry-pick other >/dev/null 2>&1 || true
run "$cp" conflicts
assert_eq "conflicts lists a cherry-pick conflict" "$OUT" "conflict.txt"
run "$cp" merge-context
assert_contains "merge-context detects the cherry-pick" "$OUT" "Cherry-pick in progress"
assert_contains "merge-context names the picked commit" "$OUT" "feat: theirs change"
assert_contains "merge-context says which side is which in a cherry-pick" "$OUT" "theirs = the commit being picked"
run "$cp" take theirs conflict.txt
run "$cp" commit -m "feat: theirs change"
assert_eq "a resolved cherry-pick can be committed" "$RC" "0"

rv=$(new_repo revert)
printf '%s\n' "one" > "$rv/file.txt"
git -C "$rv" add file.txt
git -C "$rv" commit -q -m "feat: add file"
printf '%s\n' "two" > "$rv/file.txt"
git -C "$rv" commit -q -am "feat: second version"
printf '%s\n' "three" > "$rv/file.txt"
git -C "$rv" commit -q -am "feat: third version"
git -C "$rv" revert --no-edit HEAD~1 >/dev/null 2>&1 || true
run "$rv" merge-context
assert_contains "merge-context detects the revert" "$OUT" "Revert in progress"
assert_contains "merge-context names the reverted commit" "$OUT" "feat: second version"

