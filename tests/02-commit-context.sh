# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "commit-context"

run "$repo" commit-context
assert_eq "no staged changes exits 1" "$RC" "1"
assert_contains "no staged changes explains why" "$ERR" "No staged changes"

printf '%s\n' "hello" > "$repo/hello.txt"
run "$repo" commit-context -a
assert_eq "commit-context -a succeeds" "$RC" "0"
assert_contains "commit-context -a stages files" "$(git -C "$repo" diff --cached --name-only)" "hello.txt"
assert_contains "commit-context lists staged files" "$OUT" "hello.txt"
assert_contains "commit-context shows recent subjects" "$OUT" "chore: initialize fixture"
assert_contains "commit-context prints the diff" "$OUT" "+hello"
assert_not_contains "commit-context keeps diagnostics off stdout" "$OUT" "[INFO]"

big=$(new_repo big)
awk 'BEGIN { for (i = 0; i < 4000; i++) print "large line number " i }' > "$big/large.txt"
printf '%s\n' "small change" > "$big/small.txt"
git -C "$big" add -A
run "$big" commit-context
assert_contains "large diff is truncated" "$OUT" "large file(s) omitted"
assert_contains "small files survive truncation" "$OUT" "+small change"
if [ "${#OUT}" -lt 18000 ]; then pass "truncated output stays near budget"; else fail "truncated output stays near budget (${#OUT} chars)"; fi


# Kept file diffs come in diff order, and a stat too long for the budget shrinks to its summary.
printf '%s\n' "a" "b" "c" "d" "e" "f" "g" "h" > "$big/a-medium.txt"
git -C "$big" add -A
run "$big" commit-context
assert_contains "truncation keeps every file diff that fits" "$OUT" "+++ b/a-medium.txt"
assert_contains "kept file diffs stay in diff order" "${OUT%%+++ b/small.txt*}" "+++ b/a-medium.txt"
assert_contains "truncation counts the omitted files" "$OUT" "[... 1 large file(s) omitted"
run_env "$big" GIT_PILOT_DIFF_BUDGET=300 commit-context
assert_contains "an oversized stat keeps its summary line" "$OUT" "3 files changed"
assert_not_contains "an oversized stat drops its per-file lines" "$OUT" "large.txt |"

run_env "$big" GIT_PILOT_DIFF_BUDGET=16k commit-context
assert_eq "an invalid diff budget exits 1" "$RC" "1"
assert_contains "an invalid diff budget is named" "$ERR" "GIT_PILOT_DIFF_BUDGET must be"
assert_eq "an invalid diff budget prints no partial context" "$OUT" ""

# A budget smaller than the truncation notice used to crash on a negative length.
run_env "$big" GIT_PILOT_DIFF_BUDGET=50 commit-context
assert_eq "a tiny diff budget still succeeds" "$RC" "0"
assert_contains "a tiny diff budget still reports the omission" "$OUT" "omitted"
assert_not_contains "a tiny diff budget prints no diff lines" "$OUT" "+large line number"

