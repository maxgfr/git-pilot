# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "rebase start / continue / abort"

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

# A first push sets the upstream; exit 4 is kept for a remote that is ahead.
git -C "$local_clone" checkout -q -b topic
git -C "$local_clone" commit -q --allow-empty -m "feat: start topic"
run "$local_clone" push
assert_eq "push of a new branch succeeds" "$RC" "0"
assert_eq "push of a new branch sets its upstream" "$(git -C "$local_clone" rev-parse --abbrev-ref 'topic@{upstream}')" "origin/topic"
git -C "$local_clone" checkout -q main

run "$repo" push
assert_eq "push without any remote exits 1, not 4" "$RC" "1"
git -C "$local_clone" remote set-url --push origin "$TEST_DIR/no-such-remote.git"
git -C "$local_clone" commit -q --allow-empty -m "feat: unreachable"
run "$local_clone" push
assert_eq "push to an unreachable remote exits 1, not 4" "$RC" "1"
git -C "$local_clone" remote set-url --push origin "$remote"
git -C "$local_clone" reset -q --hard HEAD~1

# A branch whose remote branch was deleted goes back to its own remote, not origin.
fork="$TEST_DIR/fork.git"
git init -q --bare "$fork"
git -C "$local_clone" remote add fork "$fork"
git -C "$local_clone" checkout -q -b forked
git -C "$local_clone" commit -q --allow-empty -m "feat: forked work"
git -C "$local_clone" push -q -u fork forked 2>/dev/null
git -C "$local_clone" push -q fork --delete forked 2>/dev/null
git -C "$local_clone" fetch -q --prune fork
git -C "$local_clone" commit -q --allow-empty -m "feat: more forked work"
run "$local_clone" push
assert_eq "push of a branch whose remote branch is gone succeeds" "$RC" "0"
assert_eq "push keeps the branch's own remote" "$(git -C "$fork" rev-parse forked)" "$(git -C "$local_clone" rev-parse HEAD)"
assert_eq "push does not move the branch to origin" "$(git -C "$remote" rev-parse --verify --quiet refs/heads/forked || echo none)" "none"
assert_eq "push keeps the branch's upstream" "$(git -C "$local_clone" rev-parse --abbrev-ref 'forked@{upstream}')" "fork/forked"

# A first push to a branch that already exists remotely, and is ahead: exit 4,
# and the upstream is set so that 'rebase start' works right away.
git -C "$seed" fetch -q origin
git -C "$seed" checkout -q -b shared-topic origin/main
printf '%s\n' "upstream" > "$seed/upstream-topic.txt"
git -C "$seed" add upstream-topic.txt
git -C "$seed" commit -q -m "feat: upstream topic"
git -C "$seed" push -q origin shared-topic 2>/dev/null
git -C "$seed" checkout -q main
git -C "$local_clone" checkout -q -b shared-topic main
printf '%s\n' "local" > "$local_clone/local-topic.txt"
git -C "$local_clone" add local-topic.txt
git -C "$local_clone" commit -q -m "feat: local topic"
run "$local_clone" push
assert_eq "first push to a remote branch that is ahead exits 4" "$RC" "4"
assert_eq "a rejected first push still sets the upstream" "$(git -C "$local_clone" rev-parse --abbrev-ref 'shared-topic@{upstream}')" "origin/shared-topic"
run "$local_clone" rebase start
assert_eq "rebase start works after a rejected first push" "$RC" "0"
run "$local_clone" push
assert_eq "push succeeds after that rebase" "$RC" "0"

# A tag named like the new branch does not make the first push ambiguous.
git -C "$local_clone" checkout -q -b tagged main
git -C "$local_clone" tag tagged
git -C "$local_clone" commit -q --allow-empty -m "feat: tagged work"
run "$local_clone" push
assert_eq "first push of a branch named like a tag succeeds" "$RC" "0"
assert_eq "the branch, not the tag, was pushed" "$(git -C "$remote" rev-parse refs/heads/tagged)" "$(git -C "$local_clone" rev-parse HEAD)"
assert_eq "its upstream is set" "$(git -C "$local_clone" rev-parse --abbrev-ref 'tagged@{upstream}')" "origin/tagged"
git -C "$local_clone" checkout -q main

# In a single-branch clone, a rejected first push still sets up the rebase.
single="$TEST_DIR/single"
git clone -q --single-branch --branch main "$remote" "$single" 2>/dev/null
git -C "$single" checkout -q -b shared-topic
printf '%s\n' "single" > "$single/single-topic.txt"
git -C "$single" add single-topic.txt
git -C "$single" commit -q -m "feat: single topic"
run "$single" push
assert_eq "rejected first push in a single-branch clone exits 4" "$RC" "4"
run "$single" rebase start
assert_eq "rebase start works in that single-branch clone" "$RC" "0"
run "$single" push
assert_eq "push succeeds after that rebase" "$RC" "0"

# With push.default=matching, another branch being rejected is not exit 4.
git -C "$single" checkout -q main
git -C "$single" reset -q --hard HEAD~1 2>/dev/null || true
git -C "$single" commit -q --allow-empty -m "feat: diverged main"
git -C "$single" checkout -q shared-topic
git -C "$single" commit -q --allow-empty -m "feat: topic after rebase"
git -C "$single" config push.default matching
run "$single" push
assert_eq "a rejection of another branch exits 1, not 4" "$RC" "1"
assert_eq "the current branch was still pushed" "$(git -C "$remote" rev-parse refs/heads/shared-topic)" "$(git -C "$single" rev-parse HEAD)"

# A failing pre-push hook runs once, not twice.
git -C "$local_clone" commit -q --allow-empty -m "feat: hooked"
hooks="$TEST_DIR/hooks"
mkdir -p "$hooks"
printf '%s\n' '#!/bin/sh' "echo run >> \"$TEST_DIR/pre-push-runs\"" 'exit 1' > "$hooks/pre-push"
chmod +x "$hooks/pre-push"
git -C "$local_clone" config core.hooksPath "$hooks"
run "$local_clone" push
assert_eq "push refused by a hook exits 1, not 4" "$RC" "1"
assert_eq "the pre-push hook runs once" "$(wc -l < "$TEST_DIR/pre-push-runs" | xargs)" "1"
git -C "$local_clone" config --unset core.hooksPath
git -C "$local_clone" reset -q --hard HEAD~1
git -C "$local_clone" checkout -q main

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

