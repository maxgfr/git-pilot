# shellcheck shell=bash
# Sourced by test-git-pilot.sh, which defines the helpers and the shared state.

section "conflicts, merge-context, take, mark-resolved"

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

# Lines that only look like markers are content: a heading underline in a hunk
# must not split it. CRLF files keep working.
ul=$(new_repo underline)
printf '%s\n' "Title" "==========" "body" > "$ul/README.md"
git -C "$ul" add README.md
git -C "$ul" commit -q -m "docs: add readme"
git -C "$ul" checkout -q -b other
printf '%s\n' "Theirs title" "==========" "theirs body" > "$ul/README.md"
git -C "$ul" commit -q -am "docs: their readme"
git -C "$ul" checkout -q main
printf '%s\n' "Ours title" "==========" "ours body" > "$ul/README.md"
git -C "$ul" commit -q -am "docs: our readme"
git -C "$ul" merge -q other >/dev/null 2>&1 || true
cp "$ul/README.md" "$TEST_DIR/underline-conflict.md"
run "$ul" take ours README.md
assert_eq "take ours keeps a whole side with a heading underline" "$(cat "$ul/README.md")" $'Ours title\n==========\nours body'
cp "$TEST_DIR/underline-conflict.md" "$ul/README.md"
git -C "$ul" checkout -q -m README.md
run "$ul" take theirs README.md
assert_eq "take theirs keeps a whole side with a heading underline" "$(cat "$ul/README.md")" $'Theirs title\n==========\ntheirs body'

# take only rewrites what Git calls conflicts; anything else is refused untouched.
c=$(conflicted_repo unterminated)
printf '%s\n' "line 1" "<<<<<<< HEAD" "ours" "=======" "theirs" "line 3" > "$c/conflict.txt"
cp "$c/conflict.txt" "$TEST_DIR/unterminated.txt"
run "$c" take theirs conflict.txt
assert_eq "take refuses an unterminated hunk" "$RC" "1"
assert_eq "a refused hunk leaves the file as it was" "$(cat "$c/conflict.txt")" "$(cat "$TEST_DIR/unterminated.txt")"

sep=$(new_repo separator-in-ours)
printf '%s\n' "a" "b" "c" > "$sep/s.txt"
git -C "$sep" add s.txt
git -C "$sep" commit -q -m "feat: add s"
git -C "$sep" checkout -q -b other
printf '%s\n' "a" "theirs" "c" > "$sep/s.txt"
git -C "$sep" commit -q -am "feat: their s"
git -C "$sep" checkout -q main
printf '%s\n' "a" "ours 1" "=======" "ours 2" "c" > "$sep/s.txt"
git -C "$sep" commit -q -am "feat: our s"
git -C "$sep" merge -q other >/dev/null 2>&1 || true
run "$sep" take ours s.txt
assert_eq "take refuses a hunk with a separator line in its content" "$RC" "1"
assert_contains "the refusal says to resolve by hand" "$ERR" "resolve it by hand"

doc=$(new_repo documented-in-conflict)
printf '%s\n' "Example:" "<<<<<<< HEAD" "mine" "=======" "yours" ">>>>>>> branch" "" "Value: base" > "$doc/guide.md"
git -C "$doc" add guide.md
git -C "$doc" commit -q -m "docs: add guide"
git -C "$doc" checkout -q -b other
sed -i.bak 's/Value: base/Value: theirs/' "$doc/guide.md" && rm "$doc/guide.md.bak"
git -C "$doc" commit -q -am "docs: their value"
git -C "$doc" checkout -q main
sed -i.bak 's/Value: base/Value: ours/' "$doc/guide.md" && rm "$doc/guide.md.bak"
git -C "$doc" commit -q -am "docs: our value"
git -C "$doc" merge -q other >/dev/null 2>&1 || true
run "$doc" take theirs guide.md
assert_eq "take refuses a conflicted file that also documents markers" "$RC" "1"
assert_contains "the refusal counts the marker blocks" "$ERR" "2 marker blocks but 1 conflicts"

# A conflicted symbolic link that points to a directory is taken as a whole.
ln_repo=$(new_repo symlink-dir)
mkdir -p "$ln_repo/a" "$ln_repo/b"
printf '%s\n' "x" > "$ln_repo/a/x.txt"
printf '%s\n' "y" > "$ln_repo/b/y.txt"
ln -s a "$ln_repo/current"
git -C "$ln_repo" add -A
git -C "$ln_repo" commit -q -m "feat: add link"
git -C "$ln_repo" checkout -q -b other
rm "$ln_repo/current"; ln -s b "$ln_repo/current"
git -C "$ln_repo" commit -q -am "feat: point at b"
git -C "$ln_repo" checkout -q main
mkdir -p "$ln_repo/c"; printf '%s\n' "z" > "$ln_repo/c/z.txt"
rm "$ln_repo/current"; ln -s c "$ln_repo/current"
git -C "$ln_repo" add -A
git -C "$ln_repo" commit -q -m "feat: point at c"
git -C "$ln_repo" merge -q other >/dev/null 2>&1 || true
run "$ln_repo" take theirs current
assert_eq "take resolves a symbolic link to a directory" "$RC" "0"
assert_eq "the link takes their target" "$(readlink "$ln_repo/current")" "b"

crlf=$(new_repo crlf)
printf 'one\r\nbase\r\nthree\r\n' > "$crlf/win.txt"
git -C "$crlf" add win.txt
git -C "$crlf" commit -q -m "feat: add windows file"
git -C "$crlf" checkout -q -b other
printf 'one\r\ntheirs\r\nthree\r\n' > "$crlf/win.txt"
git -C "$crlf" commit -q -am "feat: their line"
git -C "$crlf" checkout -q main
printf 'one\r\nours\r\nthree\r\n' > "$crlf/win.txt"
git -C "$crlf" commit -q -am "feat: our line"
git -C "$crlf" merge -q other >/dev/null 2>&1 || true
run "$crlf" take theirs win.txt
assert_eq "take resolves a CRLF file" "$(od -An -c "$crlf/win.txt" | tr -d ' \n')" 'one\r\ntheirs\r\nthree\r\n'

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

# Taking the side that deleted a file deletes it; the other side keeps it.
c=$(deleted_side_repo deleted-theirs)
run "$c" take theirs gone.txt
assert_eq "take of the side that deleted the file succeeds" "$RC" "0"
assert_contains "take says that it deleted the file" "$ERR" "Deleted"
if [ ! -e "$c/gone.txt" ]; then pass "take deletes the file from the working tree"; else fail "take deletes the file from the working tree"; fi
assert_eq "take deletes the file from the index" "$(git -C "$c" ls-files gone.txt)" ""
run "$c" commit -m "Merge branch 'other'"
assert_eq "the merge can be committed after the deletion" "$RC" "0"

c=$(deleted_side_repo deleted-ours)
run "$c" take ours gone.txt
assert_eq "take keeps the surviving side of a deleted file" "$(git -C "$c" rev-parse :gone.txt)" "$(git -C "$c" rev-parse HEAD:gone.txt)"

c=$(deleted_side_repo deleted-both)
run "$c" take both gone.txt
assert_eq "take both refuses a file deleted on one side" "$RC" "1"
assert_eq "refused take both leaves the deleted file unmerged" "$(git -C "$c" diff --name-only --diff-filter=U)" "gone.txt"

# A file that is not in conflict is refused, and nothing is staged.
c=$(new_repo plain)
printf '%s\n' "one" > "$c/plain.txt"
git -C "$c" add plain.txt
git -C "$c" commit -q -m "feat: add plain file"
printf '%s\n' "two" >> "$c/plain.txt"
run "$c" take ours plain.txt
assert_eq "take refuses a file that is not in conflict" "$RC" "1"
assert_contains "take says the file is not in conflict" "$ERR" "Not in conflict"
assert_eq "a refused take stages nothing" "$(git -C "$c" diff --cached --name-only)" ""

# A committed file that documents conflict markers is not a conflict either.
c=$(new_repo documented)
printf '%s\n' "Example:" "<<<<<<< HEAD" "mine" "=======" "yours" ">>>>>>> branch" > "$c/doc.md"
git -C "$c" add doc.md
git -C "$c" commit -q -m "docs: explain conflicts"
run "$c" take theirs doc.md
assert_eq "take refuses a committed file that documents markers" "$RC" "1"
assert_eq "the documented markers are left untouched" "$(git -C "$c" status --porcelain)" ""

# Directories and pathspec patterns are refused or taken literally.
c=$(conflicted_repo take-directory)
printf '%s\n' "untracked" > "$c/stray.txt"
run "$c" take ours .
assert_eq "take refuses a directory" "$RC" "1"
assert_eq "a refused directory stages nothing" "$(git -C "$c" ls-files stray.txt)" ""
run "$c" mark-resolved ':/'
assert_eq "mark-resolved takes ':/' as a file name, not the whole tree" "$RC" "1"
run "$c" mark-resolved '*.txt'
assert_eq "mark-resolved takes '*.txt' as a file name, not a pattern" "$RC" "1"
assert_eq "a refused pattern stages nothing" "$(git -C "$c" diff --name-only --diff-filter=U)" "conflict.txt"

# A lone separator is only reported: it is also a heading underline.
c=$(conflicted_repo separator)
printf '%s\n' "Title" "=======" "ours and theirs" > "$c/conflict.txt"
run "$c" mark-resolved conflict.txt
assert_eq "mark-resolved accepts a lone separator line" "$RC" "0"
assert_contains "mark-resolved warns about a lone separator line" "$ERR" "'=======' line remains"

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

# Each side adding its own fixture line to the same file is not a conflict.
fl=$(new_repo fixture-lines)
printf '%s\n' "top" "middle 1" "middle 2" "middle 3" "bottom" > "$fl/fixtures.txt"
git -C "$fl" add fixtures.txt
git -C "$fl" commit -q -m "test: add fixtures"
git -C "$fl" checkout -q -b other
printf '%s\n' "top" "middle 1" "middle 2" "middle 3" "bottom" "<<<<<<< theirs fixture" > "$fl/fixtures.txt"
git -C "$fl" commit -q -am "test: their fixture"
git -C "$fl" checkout -q main
printf '%s\n' "<<<<<<< our fixture" "top" "middle 1" "middle 2" "middle 3" "bottom" > "$fl/fixtures.txt"
git -C "$fl" commit -q -am "test: our fixture"
git -C "$fl" merge -q --no-commit other >/dev/null 2>&1 || true
run "$fl" conflicts
assert_eq "fixture lines added by each side are not conflicts" "$OUT" ""
run "$fl" commit -m "Merge branch 'other'"
assert_eq "a clean merge of fixture lines can be committed" "$RC" "0"

# A file deleted on one side keeps its marker-shaped content when the other side is taken.
dm=$(new_repo delete-fixture)
printf '%s\n' "<<<<<<< HEAD" "A" "=======" "B" ">>>>>>> x" "more" > "$dm/fixture.txt"
git -C "$dm" add fixture.txt
git -C "$dm" commit -q -m "test: add fixture"
git -C "$dm" checkout -q -b other
git -C "$dm" rm -q fixture.txt
git -C "$dm" commit -q -m "test: remove fixture"
git -C "$dm" checkout -q main
printf '%s\n' "ours" >> "$dm/fixture.txt"
git -C "$dm" commit -q -am "test: extend fixture"
git -C "$dm" merge -q other >/dev/null 2>&1 || true
run "$dm" take ours fixture.txt
assert_eq "take ours keeps a deleted-on-their-side fixture intact" "$(git -C "$dm" rev-parse :fixture.txt)" "$(git -C "$dm" rev-parse HEAD:fixture.txt)"

# take both on a mix of files refuses before changing any of them.
mix=$(binary_conflicted_repo mixed)
git -C "$mix" merge --abort
printf '%s\n' "base" > "$mix/text.txt"
git -C "$mix" add text.txt
git -C "$mix" commit -q -m "feat: add text"
git -C "$mix" checkout -q other
printf '%s\n' "theirs" > "$mix/text.txt"
git -C "$mix" add text.txt
git -C "$mix" commit -q -m "feat: their text"
git -C "$mix" checkout -q main
printf '%s\n' "ours" > "$mix/text.txt"
git -C "$mix" commit -q -am "feat: our text"
git -C "$mix" merge -q other >/dev/null 2>&1 || true
run "$mix" take both text.txt blob.bin
assert_eq "take both refuses a mix with a binary conflict" "$RC" "1"
assert_eq "a refused take both changes no file" "$(git -C "$mix" diff --name-only --diff-filter=U | tr '\n' ' ')" "blob.bin text.txt "

# Names that Git prints quoted are listed once, and accepted back as printed.
qt=$(conflicted_repo quoted 'q"uote.txt')
run "$qt" conflicts
assert_eq "conflicts lists a quoted name once, as Git prints it" "$OUT" '"q\"uote.txt"'
run "$qt" take ours '"q\"uote.txt"'
assert_eq "take accepts a name in Git's quoted form" "$RC" "0"
assert_eq "take resolved the quoted name" "$(cat "$qt/q\"uote.txt")" $'line 1\nours\nline 3'

# Content that is not UTF-8 (a Latin-1 file) must not break the checks under a
# UTF-8 locale, where some awk, sed and grep builds abort on invalid bytes.
l1=$(new_repo latin1)
printf 'caf\351\n' > "$l1/latin1.txt"
git -C "$l1" add latin1.txt
run_env "$l1" LC_ALL=en_US.UTF-8 conflicts
assert_eq "conflicts handles Latin-1 content" "$RC" "0"
run_env "$l1" LC_ALL=en_US.UTF-8 commit-context
assert_eq "commit-context handles Latin-1 content" "$RC" "0"
run_env "$l1" LC_ALL=en_US.UTF-8 commit -m "feat: add latin1 file"
assert_eq "commit handles Latin-1 content" "$RC" "0"
printf 'caf\351 au lait\n' > "$l1/latin1.txt"
printf '%s\n' "<<<<<<< HEAD" "a" "=======" "b" ">>>>>>> other" > "$l1/left.txt"
git -C "$l1" add -A
run_env "$l1" LC_ALL=en_US.UTF-8 commit -m "feat: more"
assert_eq "markers next to Latin-1 content still block the commit (exit 2)" "$RC" "2"
assert_contains "the blocked commit names the file with markers" "$ERR" "left.txt"

