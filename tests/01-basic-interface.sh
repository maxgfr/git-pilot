# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "Basic interface"

run "$TEST_DIR" --version
assert_contains "version prints to stdout" "$OUT" "git-pilot v"

run "$TEST_DIR" --help
for cmd in status commit-context commit "<type>" branch-context conflicts merge-context take mark-resolved "rebase start" "rebase continue" "rebase abort" push; do
    assert_contains "help lists '$cmd'" "$OUT" "$cmd"
done

run "$TEST_DIR" commit-context
assert_eq "outside a repo exits 1" "$RC" "1"
assert_contains "outside a repo explains why" "$ERR" "Not inside a git repository"

repo=$(new_repo basic)
run "$repo" frobnicate
assert_eq "unknown command exits 1" "$RC" "1"

# Missing arguments are usage errors, never "unbound variable" crashes.
run "$repo"
assert_eq "no command exits 1" "$RC" "1"
assert_contains "no command prints the usage" "$ERR" "Usage: git-pilot.sh"
for args in "take" "take ours" "mark-resolved" "rebase" "commit -F" "commit -m" "branch-context --base"; do
    # shellcheck disable=SC2086  # the words of $args are separate arguments
    run "$repo" $args
    assert_eq "'$args' without its argument exits 1" "$RC" "1"
    assert_not_contains "'$args' without its argument fails cleanly" "$ERR" "unbound variable"
done

run "$repo/.git" status
assert_eq "inside .git exits 1" "$RC" "1"
assert_contains "inside .git explains why" "$ERR" "Not inside a work tree"

