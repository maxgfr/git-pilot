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

# A diff filter that fails must not blind the checks.
bf=$(new_repo broken-filters)
printf '%s\n' "*.dat diff=dat" > "$bf/.gitattributes"
printf '%s\n' "one" > "$bf/b.dat"
git -C "$bf" add -A
git -C "$bf" commit -q -m "chore: add data"
git -C "$bf" config diff.dat.textconv "$TEST_DIR/no-such-textconv"
git -C "$bf" config diff.orderFile "$TEST_DIR/no-such-order-file"
printf '%s\n' "two" > "$bf/b.dat"
printf '%s\n' "<<<<<<< HEAD" "a" "=======" "b" ">>>>>>> other" > "$bf/z.txt"
printf 'aws_key = "AKIA%s"\n' "ABCDEFGHIJKLMNOP" > "$bf/k.txt"
git -C "$bf" add -A
run "$bf" conflicts
assert_eq "conflicts sees markers despite a broken textconv and orderFile" "$OUT" "z.txt"
run "$bf" commit -m "feat: broken" --dry-run
assert_eq "commit refuses markers despite a broken textconv (exit 2)" "$RC" "2"
git -C "$bf" rm -q --cached z.txt
run "$bf" commit -m "feat: broken" --dry-run
assert_eq "commit refuses a key despite a broken textconv (exit 5)" "$RC" "5"
run "$bf" commit-context
assert_eq "commit-context survives a broken textconv" "$RC" "0"
assert_contains "commit-context still flags the key" "$OUT" "secret-content: k.txt"

# A diff that git cannot produce at all (a missing object) stops the checks.
co=$(new_repo corrupt)
printf '%s\n' "<<<<<<< HEAD" "a" "=======" "b" ">>>>>>> other" > "$co/z.txt"
printf '%s\n' "unique content for the corrupt object test" > "$co/gone.txt"
git -C "$co" add -A
blob=$(git -C "$co" rev-parse :gone.txt)
# Without the working copy either, git cannot rebuild the blob from the file.
rm -f "$co/.git/objects/${blob:0:2}/${blob:2}" "$co/gone.txt"
run "$co" commit -m "feat: corrupt" --dry-run
assert_eq "commit fails when the staged diff cannot be read" "$RC" "1"
run "$co" conflicts
assert_eq "conflicts fails when the diff cannot be read" "$RC" "1"
assert_contains "the failure is explained" "$ERR" "Could not scan the changes for conflict markers"

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

