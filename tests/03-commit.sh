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

