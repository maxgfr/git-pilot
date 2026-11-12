# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "commit"

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

section "quick commit (<type>)"

quick_remote="$TEST_DIR/quick-remote.git"
git init -q --bare "$quick_remote"
quick=$(new_repo quick)
git -C "$quick" remote add origin "$quick_remote"

run "$quick" fix
assert_eq "a clean tree has nothing to commit (exit 1)" "$RC" "1"
assert_contains "a clean tree says so" "$ERR" "Nothing to commit"

printf '%s\n' "a" > "$quick/a.sh"
printf '%s\n' "b" > "$quick/b.md"
head_before=$(git -C "$quick" rev-parse HEAD)
run "$quick" fix --dry-run
assert_eq "quick dry run succeeds" "$RC" "0"
assert_eq "quick dry run prints the message" "$OUT" "fix: add a.sh and b.md"
assert_eq "quick dry run leaves HEAD unchanged" "$(git -C "$quick" rev-parse HEAD)" "$head_before"
assert_eq "quick dry run leaves the index unchanged" "$(git -C "$quick" diff --cached --name-only)" ""

run "$quick" fix
assert_eq "quick commit succeeds" "$RC" "0"
assert_eq "quick commit prints the new HEAD" "$OUT" "$(git -C "$quick" rev-parse HEAD)"
assert_eq "quick commit names the files" "$(git -C "$quick" log -1 --format=%s)" "fix: add a.sh and b.md"
assert_eq "quick commit pushes" "$(git -C "$quick_remote" rev-parse main)" "$(git -C "$quick" rev-parse HEAD)"
assert_eq "quick commit sets the upstream" "$(git -C "$quick" rev-parse --abbrev-ref '@{upstream}')" "origin/main"

for f in c d e f g; do printf '%s\n' "$f" > "$quick/$f.txt"; done
mkdir -p "$quick/sub"
printf '%s\n' "z" > "$quick/sub/c.txt"
run "$quick" chore --no-push
assert_eq "quick --no-push succeeds" "$RC" "0"
assert_eq "quick commit counts the files it does not name, namesakes included" "$(git -C "$quick" log -1 --format=%s)" "chore: add c.txt, d.txt and 3 more files"
assert_eq "quick --no-push does not push" "$(git -C "$quick" rev-list --count origin/main..HEAD)" "1"

git -C "$quick" mv a.sh renamed.sh
run "$quick" refactor --no-push
assert_eq "quick commit names a rename" "$(git -C "$quick" log -1 --format=%s)" "refactor: rename renamed.sh"

git -C "$quick" rm -q b.md
printf '%s\n' "more" >> "$quick/c.txt"
run "$quick" fix --no-push
assert_eq "quick commit names a removal" "$(git -C "$quick" log -1 --format=%s)" "fix: remove b.md"
assert_eq "quick commit leaves unstaged changes alone when some are staged" "$(git -C "$quick" diff --name-only)" "c.txt"

long_name="a-file-name-long-enough-to-push-the-subject-past-seventy-two-characters.txt"
git -C "$quick" add c.txt
printf '%s\n' "x" > "$quick/$long_name"
git -C "$quick" add "$long_name"
run "$quick" fix --dry-run
assert_eq "a subject over 72 characters falls back to the count" "$OUT" "fix: update 2 files"

run "$quick" fix --bogus
assert_eq "quick rejects unknown options (exit 1)" "$RC" "1"

run_env "$quick" GIT_PILOT_AI_CMD='cat >/dev/null; printf "\`\`\`\nfix(core): handle the edge case\n\nExplain why.\n\`\`\`\n"' fix --ai --dry-run
assert_eq "quick --ai uses the command's message" "$OUT" $'fix(core): handle the edge case\n\nExplain why.'
run_env "$quick" GIT_PILOT_AI_CMD='grep -q "type MUST be .fix." && echo "fix: saw the type"' fix --ai --dry-run
assert_eq "quick --ai gives the command the type" "$OUT" "fix: saw the type"
run_env "$quick" GIT_PILOT_AI_CMD='grep -q "^+more" && echo "fix: saw the diff"' fix --ai --dry-run
assert_eq "quick --ai gives the command the staged diff" "$OUT" "fix: saw the diff"
run_env "$quick" GIT_PILOT_AI_CMD='cat >/dev/null; echo "feat: wrong type"' fix --ai --dry-run
assert_eq "quick --ai falls back on the wrong type" "$OUT" "fix: update 2 files"
assert_contains "quick --ai says why it fell back" "$ERR" "did not answer with a 'fix: ...' subject"
run_env "$quick" GIT_PILOT_AI_CMD='false' fix --ai --dry-run
assert_eq "quick --ai falls back when the command fails" "$OUT" "fix: update 2 files"
assert_eq "a failing AI command does not fail the commit" "$RC" "0"

git -C "$quick" reset -q
rm -f "$quick/$long_name"
printf '%s\n' "token" > "$quick/.env"
run "$quick" fix
assert_eq "quick refuses flagged files (exit 5)" "$RC" "5"
rm -f "$quick/.env"
git -C "$quick" reset -q

git -C "$quick" checkout -q --detach
run "$quick" fix
assert_eq "quick refuses to push a detached HEAD (exit 1)" "$RC" "1"
assert_eq "the refused quick commit stages nothing" "$(git -C "$quick" status --porcelain -- c.txt)" " M c.txt"
git -C "$quick" checkout -q main

git -C "$quick" push -q 2>/dev/null
quick_other="$TEST_DIR/quick-other"
git clone -q "$quick_remote" "$quick_other" 2>/dev/null
printf '%s\n' "ahead" > "$quick_other/ahead.txt"
git -C "$quick_other" add ahead.txt
git -C "$quick_other" commit -q -m "feat: remote ahead"
git -C "$quick_other" push -q 2>/dev/null
run "$quick" fix
assert_eq "quick commit exits 4 when the remote is ahead" "$RC" "4"
assert_eq "quick commit still commits when the push is rejected" "$(git -C "$quick" log -1 --format=%s)" "fix: update c.txt"

printf '%s\n' "new" > "$quick/types.txt"
for type in feat docs style perf test build ci revert; do
    run "$quick" "$type" --dry-run
    assert_eq "quick commit accepts '$type'" "$OUT" "$type: add types.txt"
done
run "$quick" wip --dry-run
assert_eq "a type the history does not use is an unknown command (exit 1)" "$RC" "1"
assert_contains "an unknown type points to GIT_PILOT_TYPES" "$ERR" "GIT_PILOT_TYPES"
run_env "$quick" GIT_PILOT_TYPES="deps wip" wip --dry-run
assert_eq "quick commit accepts a type from GIT_PILOT_TYPES" "$OUT" "wip: add types.txt"
git -C "$quick" commit -q --allow-empty -m "security(auth): rotate keys"
run "$quick" security --dry-run
assert_eq "quick commit accepts a type the history uses" "$OUT" "security: add types.txt"

