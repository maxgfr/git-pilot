#!/usr/bin/env bash
# Tests for the git-pilot CLI, run through its public interface against real
# temporary repositories. No model is involved: the CLI never calls one.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GIT_PILOT="$SCRIPT_DIR/script.sh"
SKILL_DIR="$SCRIPT_DIR/skills/git-pilot"
TEST_DIR=$(mktemp -d "${TMPDIR:-/tmp}/git-pilot-tests.XXXXXX")
PASS=0
FAIL=0

trap 'rm -rf "$TEST_DIR"' EXIT

# Isolate from the developer's global Git configuration (signing, hooks...).
export GIT_CONFIG_GLOBAL="$TEST_DIR/gitconfig"
export GIT_CONFIG_NOSYSTEM=1
# The same results whether gitleaks is installed or not; its own test turns it on.
export GIT_PILOT_GITLEAKS=0
git config --global user.name "Pilot Tester"
git config --global user.email "pilot@example.invalid"
git config --global init.defaultBranch main
git config --global pull.rebase true

SECTION="setup"
FAILURES=()

# Start a group of tests: its name heads the output and tags every failure.
section() { SECTION="$1"; printf '\n== %s\n' "$1"; }
pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); FAILURES+=("[$SECTION] $1"); printf 'FAIL [%s] %s\n' "$SECTION" "$1"; }

assert_eq() {
    local name="$1" actual="$2" expected="$3"
    if [ "$actual" = "$expected" ]; then pass "$name"; else fail "$name (expected: $expected, got: $actual)"; fi
}

assert_contains() {
    local name="$1" value="$2" expected="$3"
    if [[ "$value" == *"$expected"* ]]; then pass "$name"; else fail "$name (missing: $expected)"; fi
}

assert_not_contains() {
    local name="$1" value="$2" unexpected="$3"
    if [[ "$value" != *"$unexpected"* ]]; then pass "$name"; else fail "$name (unexpected: $unexpected)"; fi
}

# run <dir> <args...>: sets OUT (stdout), ERR (stderr), RC.
run() {
    local dir="$1"
    shift
    OUT=$(cd "$dir" && "$GIT_PILOT" "$@" 2>"$TEST_DIR/stderr" </dev/null)
    RC=$?
    ERR=$(cat "$TEST_DIR/stderr")
}

# run_env <dir> <NAME=value> <args...>: run with one extra environment variable.
run_env() {
    local dir="$1" assignment="$2"
    shift 2
    OUT=$(cd "$dir" && env "$assignment" "$GIT_PILOT" "$@" 2>"$TEST_DIR/stderr" </dev/null)
    RC=$?
    ERR=$(cat "$TEST_DIR/stderr")
}

# run_stdin <dir> <stdin> <args...>
run_stdin() {
    local dir="$1" input="$2"
    shift 2
    OUT=$(cd "$dir" && printf '%s\n' "$input" | "$GIT_PILOT" "$@" 2>"$TEST_DIR/stderr")
    RC=$?
    ERR=$(cat "$TEST_DIR/stderr")
}

new_repo() {
    local dir="$TEST_DIR/$1"
    git init -q "$dir"
    git -C "$dir" commit -q --allow-empty -m "chore: initialize fixture"
    printf '%s\n' "$dir"
}

# Repo with a merge in progress that conflicts on a file (default: conflict.txt).
conflicted_repo() {
    local dir file="${2:-conflict.txt}"
    dir=$(new_repo "$1")
    mkdir -p "$(dirname "$dir/$file")"
    printf '%s\n' "line 1" "base" "line 3" > "$dir/$file"
    chmod +x "$dir/$file"
    git -C "$dir" add -- "$file"
    git -C "$dir" commit -q -m "feat: add file"
    git -C "$dir" checkout -q -b other
    printf '%s\n' "line 1" "theirs" "line 3" > "$dir/$file"
    git -C "$dir" commit -q -am "feat: theirs change"
    git -C "$dir" checkout -q main
    printf '%s\n' "line 1" "ours" "line 3" > "$dir/$file"
    git -C "$dir" commit -q -am "feat: ours change"
    git -C "$dir" merge -q other >/dev/null 2>&1 || true
    printf '%s\n' "$dir"
}

# Repo with a merge in progress that conflicts on blob.bin, a binary file:
# git leaves our version in the working tree and writes no conflict markers.
binary_conflicted_repo() {
    local dir
    dir=$(new_repo "$1")
    printf 'base\0\1\2' > "$dir/blob.bin"
    git -C "$dir" add blob.bin
    git -C "$dir" commit -q -m "feat: add blob"
    git -C "$dir" checkout -q -b other
    printf 'theirs\0\1\2' > "$dir/blob.bin"
    git -C "$dir" commit -q -am "feat: theirs blob"
    git -C "$dir" checkout -q main
    printf 'ours\0\1\2' > "$dir/blob.bin"
    git -C "$dir" commit -q -am "feat: ours blob"
    git -C "$dir" merge -q other >/dev/null 2>&1 || true
    printf '%s\n' "$dir"
}

# Repo with a merge in progress where "other" deleted gone.txt and main edited it.
deleted_side_repo() {
    local dir
    dir=$(new_repo "$1")
    printf '%s\n' "base" > "$dir/gone.txt"
    git -C "$dir" add gone.txt
    git -C "$dir" commit -q -m "feat: add file"
    git -C "$dir" checkout -q -b other
    git -C "$dir" rm -q gone.txt
    git -C "$dir" commit -q -m "feat: remove file"
    git -C "$dir" checkout -q main
    printf '%s\n' "ours" > "$dir/gone.txt"
    git -C "$dir" commit -q -am "feat: edit file"
    git -C "$dir" merge -q other >/dev/null 2>&1 || true
    printf '%s\n' "$dir"
}

# Each file is one section. They run in order in this shell: later ones reuse
# repositories set up by earlier ones ($repo, $guard, $remote...).
# shellcheck source=tests/01-basic-interface.sh
source "$SCRIPT_DIR/tests/01-basic-interface.sh"
# shellcheck source=tests/02-commit-context.sh
source "$SCRIPT_DIR/tests/02-commit-context.sh"
# shellcheck source=tests/03-commit.sh
source "$SCRIPT_DIR/tests/03-commit.sh"
# shellcheck source=tests/04-conflicts.sh
source "$SCRIPT_DIR/tests/04-conflicts.sh"
# shellcheck source=tests/05-cherry-pick-revert.sh
source "$SCRIPT_DIR/tests/05-cherry-pick-revert.sh"
# shellcheck source=tests/06-marker-content.sh
source "$SCRIPT_DIR/tests/06-marker-content.sh"
# shellcheck source=tests/07-subdirectory.sh
source "$SCRIPT_DIR/tests/07-subdirectory.sh"
# shellcheck source=tests/08-git-config.sh
source "$SCRIPT_DIR/tests/08-git-config.sh"
# shellcheck source=tests/09-rebase-push.sh
source "$SCRIPT_DIR/tests/09-rebase-push.sh"
# shellcheck source=tests/10-status.sh
source "$SCRIPT_DIR/tests/10-status.sh"
# shellcheck source=tests/11-staging-guard.sh
source "$SCRIPT_DIR/tests/11-staging-guard.sh"
# shellcheck source=tests/12-conventions.sh
source "$SCRIPT_DIR/tests/12-conventions.sh"
# shellcheck source=tests/13-branch-context.sh
source "$SCRIPT_DIR/tests/13-branch-context.sh"
# shellcheck source=tests/14-release-hook.sh
source "$SCRIPT_DIR/tests/14-release-hook.sh"
# shellcheck source=tests/15-skill-packaging.sh
source "$SCRIPT_DIR/tests/15-skill-packaging.sh"

if [ "$FAIL" -gt 0 ]; then
    printf '\nFailures:\n'
    printf '  %s\n' "${FAILURES[@]}"
fi
printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
# Not "exit $FAIL": an exit status wraps at 256, so 256 failures would read as success.
[ "$FAIL" -eq 0 ]
