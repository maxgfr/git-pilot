# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "Skill packaging"

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

