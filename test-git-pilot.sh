#!/usr/bin/env bash
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_PILOT="$SCRIPT_DIR/script.sh"
TEST_DIR=$(mktemp -d /tmp/git-pilot-tests.XXXXXX)
PASS=0
FAIL=0

trap 'rm -rf "$TEST_DIR"' EXIT

assert_contains() {
    local name="$1" value="$2" expected="$3"
    if [[ "$value" == *"$expected"* ]]; then
        PASS=$((PASS + 1))
        printf 'PASS %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s (missing: %s)\n' "$name" "$expected"
    fi
}

assert_not_contains() {
    local name="$1" value="$2" unexpected="$3"
    if [[ "$value" != *"$unexpected"* ]]; then
        PASS=$((PASS + 1))
        printf 'PASS %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL %s (unexpected: %s)\n' "$name" "$unexpected"
    fi
}

mkdir -p "$TEST_DIR/bin" "$TEST_DIR/repo" "$TEST_DIR/config"
cat > "$TEST_DIR/bin/codex" <<'MOCK_CODEX'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$CODEX_ARGS_FILE"
cat > "$CODEX_STDIN_FILE"
printf '%s\n' "fix: generate a safe Codex commit message"
MOCK_CODEX
chmod +x "$TEST_DIR/bin/codex"

git -C "$TEST_DIR/repo" init -q -b main
git -C "$TEST_DIR/repo" config user.name "Pilot Tester"
git -C "$TEST_DIR/repo" config user.email "pilot@example.invalid"
git -C "$TEST_DIR/repo" commit -q --allow-empty -m "chore: initialize fixture"
printf '%s\n' "changed" > "$TEST_DIR/repo/change.txt"
git -C "$TEST_DIR/repo" add change.txt
before_status=$(git -C "$TEST_DIR/repo" status --porcelain)

output=$(cd "$TEST_DIR/repo" && \
    CODEX_ARGS_FILE="$TEST_DIR/codex-model-args" \
    CODEX_STDIN_FILE="$TEST_DIR/codex-model-stdin" \
    GIT_PILOT_CONFIG_DIR="$TEST_DIR/config" \
    PATH="$TEST_DIR/bin:$PATH" \
    "$GIT_PILOT" --provider codex --model codex-test-model --dry-run --yes 2>&1)
result_code=$?
codex_args=$(cat "$TEST_DIR/codex-model-args")
codex_stdin=$(cat "$TEST_DIR/codex-model-stdin")
after_status=$(git -C "$TEST_DIR/repo" status --porcelain)

assert_contains "codex command succeeds" "$result_code" "0"
assert_contains "codex output is used" "$output" "fix: generate a safe Codex commit message"
assert_contains "codex uses non-interactive exec" "$codex_args" "exec"
assert_contains "codex session is ephemeral" "$codex_args" "--ephemeral"
assert_contains "codex sandbox is read-only" "$codex_args" "read-only"
assert_contains "codex model override is forwarded" "$codex_args" "codex-test-model"
assert_not_contains "legacy -q option is absent" "$codex_args" "-q"
assert_not_contains "staged diff is absent from process arguments" "$codex_args" "changed"
assert_contains "staged diff is sent through stdin" "$codex_stdin" "changed"
assert_contains "dry run leaves staged state unchanged" "$after_status" "$before_status"

printf '%s\n' 'provider=codex' 'model=stale-config-model' > "$TEST_DIR/config/config"
output=$(cd "$TEST_DIR/repo" && \
    CODEX_ARGS_FILE="$TEST_DIR/codex-default-args" \
    CODEX_STDIN_FILE="$TEST_DIR/codex-default-stdin" \
    GIT_PILOT_CONFIG_DIR="$TEST_DIR/config" \
    PATH="$TEST_DIR/bin:$PATH" \
    "$GIT_PILOT" --provider codex --dry-run --yes 2>&1)
result_code=$?
codex_default_args=$(cat "$TEST_DIR/codex-default-args")

assert_contains "codex uses configured default model" "$result_code" "0"
assert_not_contains "codex does not force a model" "$codex_default_args" "--model"
assert_not_contains "codex does not force gpt-5-mini" "$codex_default_args" "gpt-5-mini"
assert_not_contains "codex ignores a saved model without --model" "$codex_default_args" "stale-config-model"

config_output=$(GIT_PILOT_CONFIG_DIR="$TEST_DIR/config" "$GIT_PILOT" config 2>&1)
assert_contains "codex config displays CLI provider default" "$config_output" "<provider default>"
assert_not_contains "codex config hides ignored saved model" "$config_output" "stale-config-model"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit "$FAIL"
