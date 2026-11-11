# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "branch-context"

bc=$(new_repo branch)
git -C "$bc" checkout -q -b feature
printf '%s\n' "feature" > "$bc/feature.txt"
git -C "$bc" add feature.txt
git -C "$bc" commit -q -m "feat: add feature file" -m "Explain why the feature exists."
mkdir -p "$bc/.github"
printf '%s\n' "## Summary" "## Testing" > "$bc/.github/pull_request_template.md"
git -C "$bc" add .github
git -C "$bc" commit -q -m "docs: add pull request template"
run "$bc" branch-context
assert_eq "branch-context succeeds" "$RC" "0"
assert_contains "branch-context detects the base" "$OUT" "Base: main"
assert_contains "branch-context lists commits" "$OUT" "feat: add feature file"
assert_contains "branch-context includes commit bodies" "$OUT" "Explain why the feature exists."
assert_contains "branch-context includes the PR template" "$OUT" "Pull request template (.github/pull_request_template.md)"
assert_contains "branch-context prints the diff" "$OUT" "+feature"
assert_contains "branch-context warns without upstream" "$ERR" "no upstream"

# Commit bodies larger than a pipe buffer used to kill the command (SIGPIPE, exit 141).
long=$(new_repo long-bodies)
git -C "$long" checkout -q -b feature
body=$(awk 'BEGIN { for (i = 0; i < 150; i++) print "body line " i " padded so that every commit carries about ten kilobytes" }')
for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    git -C "$long" commit -q --allow-empty -m "feat: change $i" -m "$body"
done
run "$long" branch-context
assert_eq "branch-context survives long commit bodies" "$RC" "0"
assert_contains "branch-context says when commit bodies are cut" "$OUT" "more lines of commit bodies omitted"
assert_eq "branch-context caps commit bodies at 80 lines" "$(printf '%s\n' "$OUT" | grep -c '^  body line ')" "79"

mkdir -p "$bc/nested"
run "$bc/nested" branch-context
assert_contains "branch-context finds the PR template from a subdirectory" "$OUT" "Pull request template (.github/pull_request_template.md)"
run "$bc" branch-context --base feature
assert_eq "branch-context with no commits exits 1" "$RC" "1"
run "$bc" branch-context --base nope
assert_eq "branch-context with an unknown base exits 1" "$RC" "1"

