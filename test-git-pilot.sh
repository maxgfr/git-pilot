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

run "$repo/.git" status
assert_eq "inside .git exits 1" "$RC" "1"
assert_contains "inside .git explains why" "$ERR" "Not inside a work tree"

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

# A merge resolved to our side stages nothing, but its commit is still due.
run "$c" commit-context
assert_eq "commit-context accepts a merge with nothing staged" "$RC" "0"
assert_contains "commit-context explains the empty merge diff" "$OUT" "merge in progress resolves to the current branch"
run "$c" commit -m "Merge branch 'other'"
assert_eq "commit concludes a merge with nothing staged" "$RC" "0"
run "$c" commit-context
assert_eq "commit-context still refuses nothing staged outside a merge" "$RC" "1"

c=$(conflicted_repo theirs)
run "$c" take theirs conflict.txt
assert_eq "take theirs keeps their side" "$(cat "$c/conflict.txt")" $'line 1\ntheirs\nline 3'

c=$(conflicted_repo both)
run "$c" take both conflict.txt
assert_eq "take both keeps both sides" "$(cat "$c/conflict.txt")" $'line 1\nours\ntheirs\nline 3'

run "$c" take sideways conflict.txt
assert_eq "take rejects unknown strategies" "$RC" "1"

# mark-resolved only vouches for files it has checked.
c=$(conflicted_repo directory)
run "$c" mark-resolved .
assert_eq "mark-resolved refuses a directory" "$RC" "1"
assert_eq "a refused directory leaves the conflict unstaged" "$(git -C "$c" diff --name-only --diff-filter=U)" "conflict.txt"
run "$c" mark-resolved missing.txt
assert_eq "mark-resolved on an unknown path exits 1" "$RC" "1"

# Conflicts without markers: binary files, and files deleted on one side.
c=$(binary_conflicted_repo binary-theirs)
run "$c" take theirs blob.bin
assert_eq "take theirs on a binary conflict succeeds" "$RC" "0"
assert_eq "take theirs stages their binary version" "$(git -C "$c" rev-parse :blob.bin)" "$(git -C "$c" rev-parse other:blob.bin)"
assert_eq "take theirs writes their binary version" "$(git -C "$c" hash-object blob.bin)" "$(git -C "$c" rev-parse other:blob.bin)"

c=$(binary_conflicted_repo binary-ours)
run "$c" take ours blob.bin
assert_eq "take ours keeps our binary version intact" "$(git -C "$c" rev-parse :blob.bin)" "$(git -C "$c" rev-parse HEAD:blob.bin)"

c=$(binary_conflicted_repo binary-both)
run "$c" take both blob.bin
assert_eq "take both refuses a conflict without markers" "$RC" "1"
assert_eq "refused take both leaves the file unmerged" "$(git -C "$c" diff --name-only --diff-filter=U)" "blob.bin"

c=$(new_repo deleted-side)
printf '%s\n' "base" > "$c/gone.txt"
git -C "$c" add gone.txt
git -C "$c" commit -q -m "feat: add file"
git -C "$c" checkout -q -b other
git -C "$c" rm -q gone.txt
git -C "$c" commit -q -m "feat: remove file"
git -C "$c" checkout -q main
printf '%s\n' "ours" > "$c/gone.txt"
git -C "$c" commit -q -am "feat: edit file"
git -C "$c" merge -q other >/dev/null 2>&1 || true
run "$c" take theirs gone.txt
assert_eq "take refuses a side that deleted the file" "$RC" "1"
assert_contains "take explains the deleted side" "$ERR" "deleted"
assert_eq "refused take leaves the file unmerged" "$(git -C "$c" diff --name-only --diff-filter=U)" "gone.txt"
run "$c" take ours gone.txt
assert_eq "take keeps the surviving side of a deleted file" "$(git -C "$c" rev-parse :gone.txt)" "$(git -C "$c" rev-parse HEAD:gone.txt)"

# File names that awk would read as an assignment, or grep as an option.
c=$(conflicted_repo assignment "key=value.txt")
run "$c" take ours "key=value.txt"
assert_eq "take keeps the content of a file named like an assignment" "$(cat "$c/key=value.txt")" $'line 1\nours\nline 3'

c=$(conflicted_repo dashname "-x.txt")
run "$c" mark-resolved "-x.txt"
assert_eq "mark-resolved checks a file named like an option (exit 2)" "$RC" "2"

c=$(conflicted_repo manual)
printf '%s\n' "line 1" "ours and theirs" "line 3" > "$c/conflict.txt"
run "$c" mark-resolved conflict.txt
assert_eq "mark-resolved stages a clean file" "$RC" "0"
run_stdin "$c" "Merge branch 'other'" commit -F -
assert_eq "merge commit succeeds after resolution" "$RC" "0"
assert_eq "merge commit has two parents" "$(git -C "$c" rev-list --parents -1 HEAD | wc -w | xargs)" "3"

# --- Running from a subdirectory ---------------------------------------------

s=$(conflicted_repo subdir "pkg/conflict.txt")
printf '%s\n' "<<<<<<< HEAD" "x" "=======" "y" ">>>>>>> other" > "$s/root.txt"
git -C "$s" add root.txt
run "$s/pkg" conflicts
assert_eq "conflicts lists each file once, from the repository root" "$OUT" $'pkg/conflict.txt\nroot.txt'
run "$s/pkg" take ours conflict.txt
assert_eq "take accepts a path relative to the current directory" "$RC" "0"
run "$s/pkg" commit -m "merge" --dry-run
assert_eq "commit sees conflict markers outside the current directory (exit 2)" "$RC" "2"
git -C "$s" rm -q --cached root.txt
rm "$s/root.txt"
printf '{}\n' > "$s/.releaserc"
printf '%s\n' "new" > "$s/pkg/new.txt"
git -C "$s" add pkg/new.txt
run "$s/pkg" commit-context
assert_contains "conventions are detected from a subdirectory" "$OUT" "semantic-release (.releaserc)"
run "$s/pkg" status
assert_contains "status lists untracked files outside the current directory" "$OUT" "3 .releaserc"

# --- Output independent of the user's Git configuration ----------------------

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

# Arguments that would be ignored are refused instead.
printf '%s\n' "a" "second local edit" "c" > "$local_clone/shared.txt"
git -C "$local_clone" commit -q -am "feat: second local edit"
run "$local_clone" push --force
assert_eq "push refuses extra arguments" "$RC" "1"
assert_eq "a refused push sends nothing" "$(git -C "$local_clone" rev-list --count '@{upstream}..HEAD')" "1"
run "$local_clone" rebase start --autostash
assert_eq "rebase refuses extra arguments" "$RC" "1"
run "$local_clone" conflicts shared.txt
assert_eq "conflicts refuses arguments" "$RC" "1"
run "$local_clone" merge-context shared.txt
assert_eq "merge-context refuses arguments" "$RC" "1"

# --- status ------------------------------------------------------------------

st=$(new_repo status)
printf '%s\n' "one" "two" > "$st/tracked.txt"
git -C "$st" add tracked.txt
git -C "$st" commit -q -m "feat: tracked file"
printf '%s\n' "three" >> "$st/tracked.txt"
printf '%s\n' "staged" > "$st/staged.txt"
git -C "$st" add staged.txt
printf '%s\n' "new" > "$st/untracked.txt"
run "$st" status
assert_eq "status succeeds" "$RC" "0"
assert_contains "status shows staged files with counts" "$OUT" "A +1 -0 staged.txt"
assert_contains "status shows unstaged files with counts" "$OUT" "M +1 -0 tracked.txt"
assert_contains "status shows untracked files with sizes" "$OUT" "4 untracked.txt"

# --- staging guard -----------------------------------------------------------

guard=$(new_repo guard)
printf 'TOKEN=%s\n' "x" > "$guard/.env"
git -C "$guard" add .env
run "$guard" commit-context
assert_eq "commit-context still succeeds with flagged files" "$RC" "0"
assert_contains "commit-context flags secret files" "$OUT" "secret-file: .env"
run "$guard" commit -m "chore: add env"
assert_eq "commit refuses flagged files (exit 5)" "$RC" "5"
assert_eq "refused commit leaves HEAD unchanged" "$(git -C "$guard" log --format=%s -1)" "chore: initialize fixture"
run "$guard" commit -m "chore: add env" --allow-flagged
assert_eq "commit --allow-flagged proceeds" "$RC" "0"

printf 'aws_key = "AKIA%s"\n' "ABCDEFGHIJKLMNOP" > "$guard/config.py"
git -C "$guard" add config.py
run "$guard" commit-context
assert_contains "commit-context flags token-like content" "$OUT" "secret-content: config.py"
git -C "$guard" reset -q config.py

printf '%s\n' "API_KEY=" > "$guard/.env.example"
git -C "$guard" add .env.example
run "$guard" commit-context
assert_not_contains "example env files are not flagged" "$OUT" "Warnings"
git -C "$guard" reset -q .env.example

head -c 2048 /dev/zero > "$guard/blob.bin"
git -C "$guard" add blob.bin
run_env "$guard" GIT_PILOT_MAX_FILE_SIZE=1024 commit-context
assert_contains "commit-context flags large files" "$OUT" "large-file: blob.bin (2048 bytes)"

# An invalid size limit used to disable the large-file check silently.
run_env "$guard" GIT_PILOT_MAX_FILE_SIZE=1k commit -m "chore: add blob" --dry-run
assert_eq "an invalid size limit exits 1" "$RC" "1"
assert_contains "an invalid size limit is named" "$ERR" "GIT_PILOT_MAX_FILE_SIZE must be"

# Token patterns need a boundary: "sk-" also ends ordinary words (mask-, risk-, task-).
git -C "$guard" reset -q blob.bin
printf '%s\n' ".mask-image-linear-gradient-to-bottom-from-black-to-transparent { }" > "$guard/style.css"
printf '%s\n' "see risk-management-and-compliance-framework-overview-2024" >> "$guard/style.css"
git -C "$guard" add style.css
run "$guard" commit-context
assert_not_contains "kebab-case words are not flagged as API keys" "$OUT" "secret-content"
git -C "$guard" reset -q style.css

printf 'api_key = "sk-%s"\n' "abcdefghijklmnopqrstuvwxyz0123456789" > "$guard/keys.txt"
git -C "$guard" add keys.txt
run "$guard" commit-context
assert_contains "API keys are still flagged" "$OUT" "secret-content: keys.txt"
git -C "$guard" reset -q keys.txt

# An added line that starts with "++ " looks like a "+++ " file header in the diff.
printf '%s\n' "++ counter" > "$guard/notes.txt"
printf 'token = "AKIA%s"\n' "ABCDEFGHIJKLMNOP" >> "$guard/notes.txt"
git -C "$guard" add notes.txt
run "$guard" commit-context
assert_contains "flagged content is attributed to the right file" "$OUT" "secret-content: notes.txt"
git -C "$guard" config diff.noprefix true
run "$guard" commit-context
assert_contains "flagged paths survive diff.noprefix" "$OUT" "secret-content: notes.txt"

git -C "$guard" mv .env .env.production
run "$guard" commit-context
assert_contains "a renamed secret file is flagged under its new name" "$OUT" "secret-file: .env.production"

# --- conventions -------------------------------------------------------------

conv=$(new_repo conventions)
printf '{}\n' > "$conv/.releaserc"
git -C "$conv" add .releaserc
git -C "$conv" commit -q -m "feat(cli): add releaserc"
git -C "$conv" commit -q --allow-empty -m "fix(cli): handle empty input"
git -C "$conv" commit -q --allow-empty -m "Update readme"
printf '%s\n' "x" > "$conv/x.txt"
git -C "$conv" add x.txt
run "$conv" commit-context
assert_contains "conventions detect semantic-release" "$OUT" "semantic-release (.releaserc)"
assert_contains "conventions count conventional subjects" "$OUT" "Conventional Commits: 3/4 recent subjects"
assert_contains "conventions list scopes" "$OUT" "Scopes used: cli (2)"
assert_contains "conventions count emoji subjects" "$OUT" "Leading emoji: 0/4"

# Accented and CJK first letters are text, not emoji.
emo=$(new_repo emoji)
for subject in "Éviter la casse" "修复 bug" "Über fix" "✨ add sparkle" "🐛 fix bug" ":bug: fix other bug" "♻️ recycle code"; do
    git -C "$emo" commit -q --allow-empty -m "$subject"
done
printf '%s\n' "x" > "$emo/x.txt"
git -C "$emo" add x.txt
run "$emo" commit-context
assert_contains "conventions count only real leading emoji" "$OUT" "Leading emoji: 4/8 recent subjects"

# --- branch-context ----------------------------------------------------------

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
