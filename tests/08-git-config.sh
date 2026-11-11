# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "Output independent of the user's Git configuration"

u=$(conflicted_repo unicode "café.txt")
git -C "$u" config color.ui always
run "$u" conflicts
assert_eq "conflicts prints non-ASCII paths unescaped" "$OUT" "café.txt"
run "$u" merge-context
assert_not_contains "merge-context prints no color codes" "$OUT" $'\033'
run "$u" take ours "café.txt"
printf '%s\n' "new" > "$u/naïve.txt"
git -C "$u" add -A
run "$u" commit-context
assert_contains "commit-context prints non-ASCII paths unescaped" "$OUT" $'A\tnaïve.txt'
assert_not_contains "commit-context prints no color codes" "$OUT" $'\033'
run "$u" status
assert_contains "status prints non-ASCII paths unescaped" "$OUT" "A +1 -0 naïve.txt"

