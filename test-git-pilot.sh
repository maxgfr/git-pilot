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
git config --global user.name "Pilot Tester"
git config --global user.email "pilot@example.invalid"
git config --global init.defaultBranch main
git config --global pull.rebase true

pass() { PASS=$((PASS + 1)); printf 'PASS %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }

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
    OUT=$(cd "$dir" && "$GIT_PILOT" "$@" 2>"$TEST_DIR/stderr")
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

# Repo with a merge in progress that conflicts on conflict.txt.
conflicted_repo() {
    local dir
    dir=$(new_repo "$1")
    printf '%s\n' "line 1" "base" "line 3" > "$dir/conflict.txt"
    chmod +x "$dir/conflict.txt"
    git -C "$dir" add conflict.txt
    git -C "$dir" commit -q -m "feat: add file"
    git -C "$dir" checkout -q -b other
    printf '%s\n' "line 1" "theirs" "line 3" > "$dir/conflict.txt"
    git -C "$dir" commit -q -am "feat: theirs change"
    git -C "$dir" checkout -q main
    printf '%s\n' "line 1" "ours" "line 3" > "$dir/conflict.txt"
    git -C "$dir" commit -q -am "feat: ours change"
    git -C "$dir" merge -q other >/dev/null 2>&1 || true
    printf '%s\n' "$dir"
}

# --- Basic interface ---------------------------------------------------------

run "$TEST_DIR" --version
assert_contains "version prints to stdout" "$OUT" "git-pilot v"

run "$TEST_DIR" --help
for cmd in commit-context commit conflicts merge-context take mark-resolved "rebase start" "rebase continue" "rebase abort" push; do
    assert_contains "help lists '$cmd'" "$OUT" "$cmd"
done

run "$TEST_DIR" commit-context
assert_eq "outside a repo exits 1" "$RC" "1"
assert_contains "outside a repo explains why" "$ERR" "Not inside a git repository"

repo=$(new_repo basic)
run "$repo" frobnicate
assert_eq "unknown command exits 1" "$RC" "1"

# --- commit-context ----------------------------------------------------------

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

# --- commit ------------------------------------------------------------------

head_before=$(git -C "$repo" rev-parse HEAD)
run_stdin "$repo" "feat: add hello file" commit -F - --dry-run
assert_eq "dry run succeeds" "$RC" "0"
assert_eq "dry run prints the message" "$OUT" "feat: add hello file"
assert_eq "dry run leaves HEAD unchanged" "$(git -C "$repo" rev-parse HEAD)" "$head_before"

run "$repo" commit -m "   "
assert_eq "empty message exits 1" "$RC" "1"

run "$repo" commit
assert_eq "missing message exits 1" "$RC" "1"

message=$'feat: add hello file\n\n- Add a greeting fixture'
run_stdin "$repo" "$message" commit -F -
assert_eq "commit succeeds" "$RC" "0"
assert_eq "commit prints the new HEAD" "$OUT" "$(git -C "$repo" rev-parse HEAD)"
assert_eq "commit keeps the exact message" "$(git -C "$repo" log -1 --format=%B | sed -e :a -e '/^\n*$/{$d;N;ba' -e '}')" "$message"

printf '%s\n' "file message" > "$TEST_DIR/msg.txt"
printf '%s\n' "more" >> "$repo/hello.txt"
git -C "$repo" add hello.txt
run "$repo" commit -F "$TEST_DIR/msg.txt"
assert_eq "commit -F <file> uses the file" "$(git -C "$repo" log -1 --format=%s)" "file message"

# --- conflicts, merge-context, take, mark-resolved ---------------------------

c=$(conflicted_repo merge)
run "$c" conflicts
assert_eq "conflicts lists the conflicted file" "$OUT" "conflict.txt"

run "$c" commit-context
assert_eq "commit-context refuses with conflicts (exit 2)" "$RC" "2"
run "$c" commit -m "merge"
assert_eq "commit refuses with conflicts (exit 2)" "$RC" "2"

run "$c" merge-context
assert_contains "merge-context lists conflicted files" "$OUT" "conflict.txt"
assert_contains "merge-context detects the merge" "$OUT" "Merge in progress"
assert_contains "merge-context shows incoming commits" "$OUT" "feat: theirs change"
assert_contains "merge-context shows our commits" "$OUT" "feat: ours change"

run "$c" mark-resolved conflict.txt
assert_eq "mark-resolved refuses remaining markers (exit 2)" "$RC" "2"

run "$c" take ours conflict.txt
assert_eq "take ours succeeds" "$RC" "0"
assert_eq "take ours keeps our side" "$(cat "$c/conflict.txt")" $'line 1\nours\nline 3'
if [ -x "$c/conflict.txt" ]; then pass "take keeps the file mode"; else fail "take keeps the file mode"; fi
run "$c" conflicts
assert_eq "take stages the file" "$OUT" ""

c=$(conflicted_repo theirs)
run "$c" take theirs conflict.txt
assert_eq "take theirs keeps their side" "$(cat "$c/conflict.txt")" $'line 1\ntheirs\nline 3'

c=$(conflicted_repo both)
run "$c" take both conflict.txt
assert_eq "take both keeps both sides" "$(cat "$c/conflict.txt")" $'line 1\nours\ntheirs\nline 3'

run "$c" take sideways conflict.txt
assert_eq "take rejects unknown strategies" "$RC" "1"

c=$(conflicted_repo manual)
printf '%s\n' "line 1" "ours and theirs" "line 3" > "$c/conflict.txt"
run "$c" mark-resolved conflict.txt
assert_eq "mark-resolved stages a clean file" "$RC" "0"
run_stdin "$c" "Merge branch 'other'" commit -F -
assert_eq "merge commit succeeds after resolution" "$RC" "0"
assert_eq "merge commit has two parents" "$(git -C "$c" rev-list --parents -1 HEAD | wc -w | xargs)" "3"

# --- rebase start / continue / abort -----------------------------------------

remote="$TEST_DIR/remote.git"
git init -q --bare "$remote"
seed=$(new_repo seed)
printf '%s\n' "a" "b" "c" > "$seed/shared.txt"
git -C "$seed" add shared.txt
git -C "$seed" commit -q -m "feat: shared file"
git -C "$seed" remote add origin "$remote"
git -C "$seed" push -q -u origin main 2>/dev/null

local_clone="$TEST_DIR/local"
git clone -q "$remote" "$local_clone" 2>/dev/null

run "$local_clone" rebase start
assert_eq "rebase start without upstream changes succeeds" "$RC" "0"

printf '%s\n' "a" "upstream" "c" > "$seed/shared.txt"
git -C "$seed" commit -q -am "feat: upstream edit"
git -C "$seed" push -q 2>/dev/null

printf '%s\n' "a" "local" "c" > "$local_clone/shared.txt"
git -C "$local_clone" commit -q -am "feat: local edit"

run "$local_clone" push
assert_eq "rejected push exits 4" "$RC" "4"

run "$local_clone" rebase start
assert_eq "rebase start stops on conflicts (exit 3)" "$RC" "3"
assert_contains "rebase start names the conflicted file" "$ERR" "shared.txt"

run "$local_clone" merge-context
assert_contains "merge-context detects the rebase" "$OUT" "Rebase in progress"

run "$local_clone" rebase continue
assert_eq "rebase continue refuses unresolved conflicts (exit 3)" "$RC" "3"

run "$local_clone" rebase abort
assert_eq "rebase abort succeeds" "$RC" "0"
assert_eq "rebase abort restores the local commit" "$(git -C "$local_clone" log -1 --format=%s)" "feat: local edit"

run "$local_clone" rebase start
assert_eq "rebase start stops again (exit 3)" "$RC" "3"
printf '%s\n' "a" "upstream and local" "c" > "$local_clone/shared.txt"
run "$local_clone" mark-resolved shared.txt
run "$local_clone" rebase continue
assert_eq "rebase continue completes" "$RC" "0"
assert_eq "history is linear on top of upstream" "$(git -C "$local_clone" log --format=%s -2 | tr '\n' '|')" "feat: local edit|feat: upstream edit|"
assert_eq "rebased content is the resolution" "$(sed -n 2p "$local_clone/shared.txt")" "upstream and local"

run "$local_clone" push
assert_eq "push succeeds after rebase" "$RC" "0"

run "$local_clone" rebase continue
assert_eq "rebase continue without a rebase exits 1" "$RC" "1"

# --- Skill packaging ---------------------------------------------------------

skill_md="$SKILL_DIR/SKILL.md"
if [ -f "$skill_md" ]; then pass "SKILL.md exists"; else fail "SKILL.md exists"; fi
frontmatter=$(awk 'NR == 1 && $0 == "---" { inside = 1; next } inside && $0 == "---" { exit } inside { print }' "$skill_md")
assert_contains "SKILL.md name matches its directory" "$frontmatter" "name: $(basename "$SKILL_DIR")"
if printf '%s\n' "$frontmatter" | grep -Eq '^description: .{40,}'; then pass "SKILL.md has a description"; else fail "SKILL.md has a description"; fi

if cmp -s "$GIT_PILOT" "$SKILL_DIR/scripts/git-pilot.sh"; then
    pass "bundled skill script matches script.sh"
else
    fail "bundled skill script matches script.sh (run: cp script.sh skills/git-pilot/scripts/git-pilot.sh)"
fi
if [ -x "$SKILL_DIR/scripts/git-pilot.sh" ]; then pass "bundled skill script is executable"; else fail "bundled skill script is executable"; fi

run "$TEST_DIR" --help
while IFS= read -r cmd; do
    assert_contains "SKILL.md command '$cmd' exists in --help" "$OUT" "$cmd"
done < <(grep -oE 'git-pilot\.sh [a-z-]+' "$skill_md" | awk '{print $2}' | sort -u)

if grep -nE 'claude -p|codex exec|api\.(openai|anthropic|mistral)|generativelanguage' "$GIT_PILOT" "$skill_md" >/dev/null; then
    fail "no model calls in the CLI or the skill"
else
    pass "no model calls in the CLI or the skill"
fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
exit "$FAIL"
