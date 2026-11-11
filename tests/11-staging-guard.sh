# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "staging guard"

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

# Other well-known token formats. Each sample is assembled here from pieces, so
# that this file never contains anything shaped like a real token.
flagged_sample() {
    local name="$1" sample="$2"
    printf 'value = "%s"\n' "$sample" > "$guard/candidate.txt"
    git -C "$guard" add candidate.txt
    run "$guard" commit-context
    assert_contains "$name is flagged" "$OUT" "secret-content: candidate.txt"
    git -C "$guard" rm -q --cached candidate.txt
}
alnum="abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"
hex="0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
flagged_sample "a Stripe live key" "sk_""live_${alnum:0:24}"
flagged_sample "a GitLab token" "glpat""-${alnum:0:20}"
flagged_sample "an npm token" "npm""_${alnum:0:36}"
flagged_sample "a Hugging Face token" "hf""_${alnum:0:34}"
flagged_sample "a SendGrid key" "SG"".${alnum:0:22}.${alnum:0:43}"
flagged_sample "a PyPI token" "pypi""-AgEIcHlwaS5vcmc${alnum:0:50}"
flagged_sample "a DigitalOcean token" "dop""_v1_${hex}"
flagged_sample "a Slack webhook" "https://hooks.slack"".com/services/T${alnum:0:9}/B${alnum:0:9}/${alnum:0:24}"
rm "$guard/candidate.txt"

# gitleaks, when installed, flags formats that the built-in patterns do not know.
hex="8f3a9c2e7b1d4f6a0c5e9b3d7f2a6c1e"
printf 'shopify = "%s"\n' "shpat""_$hex" > "$guard/shop.txt"
git -C "$guard" add shop.txt
run_env "$guard" GIT_PILOT_GITLEAKS=0 commit-context
assert_not_contains "the built-in patterns do not know Shopify tokens" "$OUT" "secret-content: shop.txt"
if command -v gitleaks >/dev/null 2>&1; then
    run_env "$guard" GIT_PILOT_GITLEAKS=1 commit-context
    assert_contains "gitleaks flags a Shopify token" "$OUT" "secret-content: shop.txt"
    run_env "$guard" GIT_PILOT_GITLEAKS=1 commit -m "feat: shop" --dry-run
    assert_eq "commit refuses what gitleaks flags (exit 5)" "$RC" "5"
    assert_contains "commit names the file gitleaks flagged" "$ERR" "secret-content: shop.txt"
    printf 'aws_key = "AKIA%s"\n' "ABCDEFGHIJKLMNOP" > "$guard/both.txt"
    git -C "$guard" add both.txt
    run_env "$guard" GIT_PILOT_GITLEAKS=1 commit-context
    assert_eq "a file flagged by both checks is listed once" "$(printf '%s\n' "$OUT" | grep -c 'secret-content: both.txt')" "1"
    git -C "$guard" rm -q --cached both.txt
    # Paths come back from its JSON report decoded, and quoted the way Git does.
    printf 'shopify = "%s"\n' "shpat""_$hex" > "$guard/amp&er.txt"
    printf 'shopify = "%s"\n' "shpat""_$hex" > "$guard/ta"$'\t'"b.txt"
    git -C "$guard" add -A
    run_env "$guard" GIT_PILOT_GITLEAKS=1 commit-context
    assert_contains "gitleaks paths are decoded" "$OUT" "secret-content: amp&er.txt"
    assert_contains "gitleaks paths are quoted like Git does" "$OUT" 'secret-content: "ta\tb.txt"'
    git -C "$guard" rm -q --cached "amp&er.txt" "ta"$'\t'"b.txt"
    rm "$guard/amp&er.txt" "$guard/ta"$'\t'"b.txt"
else
    printf 'SKIP gitleaks is not installed: its integration was not tested\n'
fi

# A gitleaks that hangs is stopped, and one that fails is reported, once.
stub="$TEST_DIR/stub-bin"
mkdir -p "$stub"
printf '%s\n' '#!/bin/sh' "echo run >> \"$TEST_DIR/stub-runs\"" '[ "$2" = "--help" ] && exit 0' 'sleep 30' > "$stub/gitleaks"
chmod +x "$stub/gitleaks"
started=$(date +%s)
OUT=$(cd "$guard" && PATH="$stub:$PATH" GIT_PILOT_GITLEAKS=1 GIT_PILOT_GITLEAKS_TIMEOUT=2 "$GIT_PILOT" commit-context 2>"$TEST_DIR/stderr" </dev/null)
RC=$?
ERR=$(cat "$TEST_DIR/stderr")
elapsed=$(( $(date +%s) - started ))
assert_eq "a hanging gitleaks does not fail commit-context" "$RC" "0"
assert_contains "a hanging gitleaks is reported" "$ERR" "did not finish within 2s"
if [ "$elapsed" -lt 20 ]; then pass "a hanging gitleaks is stopped by the timeout"; else fail "a hanging gitleaks is stopped by the timeout (${elapsed}s)"; fi
printf '%s\n' '#!/bin/sh' "echo run >> \"$TEST_DIR/stub-fail-runs\"" '[ "$2" = "--help" ] && exit 0' 'exit 3' > "$stub/gitleaks"
(cd "$guard" && PATH="$stub:$PATH" GIT_PILOT_GITLEAKS=1 "$GIT_PILOT" commit -m "feat: shop" --dry-run >/dev/null 2>&1 </dev/null)
# One run to tell the version (--help), one scan: no second attempt.
assert_eq "a failing gitleaks scans once" "$(grep -c run "$TEST_DIR/stub-fail-runs")" "2"
git -C "$guard" rm -q --cached shop.txt

git -C "$guard" mv .env .env.production
run "$guard" commit-context
assert_contains "a renamed secret file is flagged under its new name" "$OUT" "secret-file: .env.production"

