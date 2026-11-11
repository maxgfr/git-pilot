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
assert_contains "the refusal names the cause" "$ERR" "marker-shaped lines of its own"

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
git -C "$ln_repo" reset -q --hard HEAD
git -C "$ln_repo" merge -q other >/dev/null 2>&1 || true
run "$ln_repo" mark-resolved current
assert_eq "mark-resolved stages a symbolic link to a directory" "$RC" "0"
assert_eq "the link is no longer in conflict" "$(git -C "$ln_repo" diff --name-only --diff-filter=U)" ""

# Ordinary conflicts must still resolve, whatever produced them.
many=$(new_repo many-hunks)
awk 'BEGIN { for (i = 0; i < 400; i++) print "line " i }' > "$many/m.txt"
git -C "$many" add m.txt
git -C "$many" commit -q -m "feat: add m"
git -C "$many" checkout -q -b other
awk 'BEGIN { for (i = 0; i < 400; i++) print (i % 3 == 0 ? "theirs " i : "line " i) }' > "$many/m.txt"
git -C "$many" commit -q -am "feat: their m"
git -C "$many" checkout -q main
awk 'BEGIN { for (i = 0; i < 400; i++) print (i % 3 == 0 ? "ours " i : "line " i) }' > "$many/m.txt"
git -C "$many" commit -q -am "feat: our m"
git -C "$many" merge -q other >/dev/null 2>&1 || true
run "$many" take theirs m.txt
assert_eq "take resolves a file with more than 127 conflicts" "$RC" "0"
assert_eq "every hunk took their side" "$(grep -c '^theirs ' "$many/m.txt")" "134"

c=$(conflicted_repo diff3-style)
git -C "$c" checkout -q --conflict=diff3 -- conflict.txt
run "$c" take ours conflict.txt
assert_eq "take resolves a conflict rewritten in diff3 style" "$(cat "$c/conflict.txt")" $'line 1\nours\nline 3'

c=$(conflicted_repo ignore-space)
git -C "$c" merge --abort
git -C "$c" merge -q -Xignore-space-change other >/dev/null 2>&1 || true
run "$c" take theirs conflict.txt
assert_eq "take resolves a conflict from a merge with -X options" "$RC" "0"

two=$(new_repo half-resolved)
printf '%s\n' "a" "1" "b" "c" "d" "e" "2" "f" > "$two/t.txt"
git -C "$two" add t.txt
git -C "$two" commit -q -m "feat: add t"
git -C "$two" checkout -q -b other
printf '%s\n' "a" "theirs 1" "b" "c" "d" "e" "theirs 2" "f" > "$two/t.txt"
git -C "$two" commit -q -am "feat: their t"
git -C "$two" checkout -q main
printf '%s\n' "a" "ours 1" "b" "c" "d" "e" "ours 2" "f" > "$two/t.txt"
git -C "$two" commit -q -am "feat: our t"
git -C "$two" merge -q other >/dev/null 2>&1 || true
awk 'done == 0 && /^<<<<<<< / { skip = 1; next } skip && /^>>>>>>> / { skip = 0; done = 1; print "hand 1"; next } !skip { print }' "$two/t.txt" > "$TEST_DIR/t.txt"
cat "$TEST_DIR/t.txt" > "$two/t.txt"
run "$two" take theirs t.txt
assert_eq "take resolves the hunks left after one was resolved by hand" "$(cat "$two/t.txt")" $'a\nhand 1\nb\nc\nd\ne\ntheirs 2\nf'

# A ">>>>>>>" line that belongs to a side would close the hunk early.
gt=$(new_repo closing-in-content)
printf '%s\n' "a" "base" "z" > "$gt/g.txt"
git -C "$gt" add g.txt
git -C "$gt" commit -q -m "feat: add g"
git -C "$gt" checkout -q -b other
printf '%s\n' "a" "theirs 1" ">>>>>>> example" "theirs 2" "z" > "$gt/g.txt"
git -C "$gt" commit -q -am "feat: their g"
git -C "$gt" checkout -q main
printf '%s\n' "a" "ours" "z" > "$gt/g.txt"
git -C "$gt" commit -q -am "feat: our g"
git -C "$gt" merge -q other >/dev/null 2>&1 || true
cp "$gt/g.txt" "$TEST_DIR/g.txt"
run "$gt" take theirs g.txt
assert_eq "take refuses a side that contains a closing marker line" "$RC" "1"
assert_eq "that refusal leaves the file as it was" "$(cat "$gt/g.txt")" "$(cat "$TEST_DIR/g.txt")"

# An already-staged leftover in a file that also documents markers is refused.
ds=$(new_repo staged-documented)
printf '%s\n' "Example:" "<<<<<<< HEAD" "A" "=======" "B" ">>>>>>> branch" "end" > "$ds/doc.md"
git -C "$ds" add doc.md
git -C "$ds" commit -q -m "docs: add example"
printf '%s\n' "<<<<<<< HEAD" "mine" "=======" "yours" ">>>>>>> other" >> "$ds/doc.md"
git -C "$ds" add doc.md
cp "$ds/doc.md" "$TEST_DIR/doc.md"
run "$ds" take ours doc.md
assert_eq "take refuses a leftover next to documented markers" "$RC" "1"
assert_eq "the documented example is left as it was" "$(cat "$ds/doc.md")" "$(cat "$TEST_DIR/doc.md")"

# A file without a final newline keeps it that way.
nonl=$(new_repo no-final-newline)
printf 'one\nbase\nlast' > "$nonl/n.txt"
git -C "$nonl" add n.txt
git -C "$nonl" commit -q -m "feat: add n"
git -C "$nonl" checkout -q -b other
printf 'one\ntheirs\nlast' > "$nonl/n.txt"
git -C "$nonl" commit -q -am "feat: their n"
git -C "$nonl" checkout -q main
printf 'one\nours\nlast' > "$nonl/n.txt"
git -C "$nonl" commit -q -am "feat: our n"
git -C "$nonl" merge -q other >/dev/null 2>&1 || true
run "$nonl" take theirs n.txt
assert_eq "take keeps a missing final newline missing" "$(od -An -c "$nonl/n.txt" | tr -d ' \n')" 'one\ntheirs\nlast'

# Longer markers from the conflict-marker-size attribute are read as markers.
ms=$(new_repo marker-size)
printf '%s\n' "*.txt conflict-marker-size=10" > "$ms/.gitattributes"
printf '%s\n' "a" "base" "c" "d" "e" "f" "only theirs changes this" > "$ms/s.txt"
git -C "$ms" add -A
git -C "$ms" commit -q -m "feat: add s"
git -C "$ms" checkout -q -b other
printf '%s\n' "a" "theirs" "c" "d" "e" "f" "changed by theirs" > "$ms/s.txt"
git -C "$ms" commit -q -am "feat: their s"
git -C "$ms" checkout -q main
printf '%s\n' "a" "ours" "c" "d" "e" "f" "only theirs changes this" > "$ms/s.txt"
git -C "$ms" commit -q -am "feat: our s"
git -C "$ms" merge -q other >/dev/null 2>&1 || true
cp "$ms/s.txt" "$TEST_DIR/s.txt"
run "$ms" mark-resolved s.txt
assert_eq "mark-resolved refuses 10-character markers (exit 2)" "$RC" "2"
run "$ms" take ours s.txt
assert_eq "take with 10-character markers keeps their clean change" "$(cat "$ms/s.txt")" $'a\nours\nc\nd\ne\nf\nchanged by theirs'

# NUL bytes in a file with markers: awk would cut lines, so take refuses.
nb=$(conflicted_repo nul-in-conflict)
printf 'line 1\n<<<<<<< HEAD\nours\000x\n=======\ntheirs\n>>>>>>> other\nline 3\n' > "$nb/conflict.txt"
run "$nb" take ours conflict.txt
assert_eq "take refuses a file with NUL bytes" "$RC" "1"
assert_contains "the NUL refusal is explained" "$ERR" "NUL bytes"

# NUL bytes in an already-staged leftover are refused too. Past the first 8000
# bytes, so that Git still diffs the file as text and sees the markers.
c=$(conflicted_repo nul-staged)
{ awk 'BEGIN { for (i = 0; i < 300; i++) print "padding line " i " so that the NUL comes late" }'
  printf 'line 1\n<<<<<<< HEAD\nours\000x\n=======\ntheirs\n>>>>>>> other\nline 3\n'; } > "$c/conflict.txt"
git -C "$c" add conflict.txt
run "$c" take ours conflict.txt
assert_eq "take refuses an already-staged file with NUL bytes" "$RC" "1"
assert_contains "the staged NUL refusal is explained" "$ERR" "NUL bytes"

# A staged leftover whose name Git quotes is still found in the leftover list.
c=$(conflicted_repo quoted-staged 'a"b.md')
printf '%s\n' "line 1" "<<<<<<< HEAD" "ours" "=======" "theirs" ">>>>>>> other" "line 3" > "$c/a\"b.md"
git -C "$c" add -- 'a"b.md'
run "$c" take ours 'a"b.md'
assert_eq "take resolves a staged leftover with a quoted name" "$(cat "$c/a\"b.md")" $'line 1\nours\nline 3'

# A staged leftover with no other side to check against (after "git stash pop").
sp=$(new_repo stash-pop)
printf '%s\n' "a" > "$sp/p.txt"
git -C "$sp" add p.txt
git -C "$sp" commit -q -m "feat: add p"
printf '%s\n' "<<<<<<< Updated upstream" "x" "=======" "y" ">>>>>>> Stashed changes" > "$sp/p.txt"
git -C "$sp" add p.txt
run "$sp" take ours p.txt
assert_eq "take refuses a leftover it cannot check against the other side" "$RC" "1"
assert_contains "that refusal says why" "$ERR" "cannot be checked"

# An unreadable version of a conflicted file is a reason to refuse, not to go on.
ur=$(conflicted_repo unreadable-stage)
theirs_blob=$(git -C "$ur" ls-files -u -- conflict.txt | awk '$3 == 3 { print $2 }')
rm -f "$ur/.git/objects/${theirs_blob:0:2}/${theirs_blob:2}"
run "$ur" take ours conflict.txt
assert_eq "take refuses when a version of the file cannot be read" "$RC" "1"

# Large files: the marker check must read the whole file, whatever its size.
lg=$(new_repo large-conflict)
awk 'BEGIN { for (i = 1; i <= 40000; i++) print i " filler filler filler filler" }' > "$TEST_DIR/pad.txt"
{ echo "top"; cat "$TEST_DIR/pad.txt"; echo "end"; } > "$lg/f.txt"
git -C "$lg" add f.txt
git -C "$lg" commit -q -m "feat: add f"
git -C "$lg" checkout -q -b other
{ echo "top theirs"; cat "$TEST_DIR/pad.txt"; echo "end theirs"; } > "$lg/f.txt"
git -C "$lg" commit -q -am "feat: their f"
git -C "$lg" checkout -q main
{ echo "top ours"; cat "$TEST_DIR/pad.txt"; echo "end"; } > "$lg/f.txt"
git -C "$lg" commit -q -am "feat: our f"
git -C "$lg" merge -q other >/dev/null 2>&1 || true
run "$lg" take ours f.txt
assert_eq "take ours on a 1 MB file keeps our first line" "$(head -n 1 "$lg/f.txt")" "top ours"
assert_eq "take ours on a 1 MB file keeps their clean change" "$(tail -n 1 "$lg/f.txt")" "end theirs"

# Criss-cross merge: Git builds a virtual base with nested markers of its own.
cc=$(new_repo criss-cross)
printf '%s\n' "l1" "l2" "l3" > "$cc/f.txt"
git -C "$cc" add f.txt
git -C "$cc" commit -q -m "feat: base"
git -C "$cc" checkout -q -b A
printf '%s\n' "l1" "A" "l3" > "$cc/f.txt"
git -C "$cc" commit -q -am "feat: A"
git -C "$cc" checkout -q -b B main
printf '%s\n' "l1" "B" "l3" > "$cc/f.txt"
git -C "$cc" commit -q -am "feat: B"
git -C "$cc" checkout -q A
git -C "$cc" merge -q -s ours B -m "Merge B, keep A" >/dev/null 2>&1
git -C "$cc" checkout -q B
git -C "$cc" merge -q -s ours A~1 -m "Merge A, keep B" >/dev/null 2>&1
printf '%s\n' "l1" "B2" "l3" > "$cc/f.txt"
git -C "$cc" commit -q -am "feat: B2"
git -C "$cc" checkout -q A
printf '%s\n' "l1" "A2" "l3" > "$cc/f.txt"
git -C "$cc" commit -q -am "feat: A2"
git -C "$cc" merge -q B >/dev/null 2>&1 || true
run "$cc" take theirs f.txt
assert_eq "take resolves a criss-cross merge" "$(cat "$cc/f.txt")" $'l1\nB2\nl3'

# A hunk at the end of the file ends the way the kept side ends.
eof=$(new_repo hunk-at-eof)
printf 'one\nbase' > "$eof/e.txt"
git -C "$eof" add e.txt
git -C "$eof" commit -q -m "feat: add e"
git -C "$eof" checkout -q -b other
printf 'one\ntheirs' > "$eof/e.txt"
git -C "$eof" commit -q -am "feat: their e"
git -C "$eof" checkout -q main
printf 'one\nours\n' > "$eof/e.txt"
git -C "$eof" commit -q -am "feat: our e"
git -C "$eof" merge -q other >/dev/null 2>&1 || true
cp "$eof/e.txt" "$TEST_DIR/e.txt"
run "$eof" take theirs e.txt
assert_eq "a hunk at EOF takes their missing final newline" "$(od -An -c "$eof/e.txt" | tr -d ' \n')" 'one\ntheirs'
cp "$TEST_DIR/e.txt" "$eof/e.txt"
git -C "$eof" checkout -q -m e.txt
run "$eof" take ours e.txt
assert_eq "a hunk at EOF keeps our final newline" "$(od -An -c "$eof/e.txt" | tr -d ' \n')" 'one\nours\n'

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

