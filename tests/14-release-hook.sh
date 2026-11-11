# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "Release hook"

hook="$TEST_DIR/hook"
mkdir -p "$hook/skills/git-pilot/scripts"
cp "$GIT_PILOT" "$hook/script.sh"
hook_out=$(cd "$hook" && bash "$SCRIPT_DIR/.version-hook.sh" 9.8.7 2>&1)
assert_eq "the version hook succeeds" "$?" "0"
assert_contains "the version hook reports what it did" "$hook_out" "version 9.8.7"
assert_eq "the version hook sets the version" "$(bash "$hook/script.sh" --version)" "git-pilot v9.8.7"
if cmp -s "$hook/script.sh" "$hook/skills/git-pilot/scripts/git-pilot.sh"; then pass "the version hook syncs the bundled script"; else fail "the version hook syncs the bundled script"; fi
(cd "$hook" && bash "$SCRIPT_DIR/.version-hook.sh" '1.0.0/;e' >/dev/null 2>&1)
assert_eq "the version hook refuses an invalid version" "$?" "1"
assert_eq "a refused version leaves script.sh alone" "$(bash "$hook/script.sh" --version)" "git-pilot v9.8.7"
printf '%s\n' "echo no version here" > "$hook/script.sh"
(cd "$hook" && bash "$SCRIPT_DIR/.version-hook.sh" 9.9.9 >/dev/null 2>&1)
assert_eq "the version hook fails when there is no VERSION line" "$?" "1"

