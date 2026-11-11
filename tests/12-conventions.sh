# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "conventions"

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

