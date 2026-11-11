# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "Conflict markers that are content, not leftovers"

# A committed fixture full of markers must not block unrelated commits.
fx=$(new_repo fixtures)
printf '%s\n' "<<<<<<< HEAD" "ours" "=======" "theirs" ">>>>>>> other" > "$fx/fixture.txt"
git -C "$fx" add fixture.txt
git -C "$fx" commit -q -m "test: add a conflict fixture"
printf '%s\n' "code" > "$fx/code.txt"
git -C "$fx" add code.txt
run "$fx" conflicts
assert_eq "a committed fixture is not a conflict" "$OUT" ""
run "$fx" commit -m "feat: add code"
assert_eq "commit works next to a committed fixture" "$RC" "0"

printf '%s\n' "half resolved" ">>>>>>> other" > "$fx/half.txt"
git -C "$fx" add half.txt
run "$fx" commit -m "feat: half" --dry-run
assert_eq "commit refuses a leftover closing marker (exit 2)" "$RC" "2"
git -C "$fx" rm -q --cached half.txt
rm "$fx/half.txt"

printf '%s\n' "<<<<<<< HEAD" "left over" >> "$fx/fixture.txt"
run "$fx" conflicts
assert_eq "a new marker line in the fixture is a conflict" "$OUT" "fixture.txt"
git -C "$fx" add fixture.txt
run "$fx" commit -m "test: extend the fixture"
assert_eq "commit refuses a newly added marker line (exit 2)" "$RC" "2"
git -C "$fx" reset -q --hard

# Nor must a fixture that the merged branch brings in.
git -C "$fx" checkout -q -b other
printf '%s\n' "<<<<<<< HEAD" "a" "=======" "b" ">>>>>>> x" > "$fx/incoming-fixture.txt"
printf '%s\n' "theirs" > "$fx/code.txt"
git -C "$fx" add -A
git -C "$fx" commit -q -m "test: add another fixture"
git -C "$fx" checkout -q main
printf '%s\n' "ours" > "$fx/code.txt"
git -C "$fx" commit -q -am "feat: change code"
git -C "$fx" merge -q other >/dev/null 2>&1 || true
run "$fx" conflicts
assert_eq "only the real conflict of the merge is listed" "$OUT" "code.txt"
run "$fx" take ours code.txt
run "$fx" commit -m "Merge branch 'other'"
assert_eq "a merge that brings in a fixture can be committed" "$RC" "0"

