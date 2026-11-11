#!/bin/bash

# ==============================================================================
#  git-pilot
#  Deterministic Git helpers for the git-pilot agent skill.
#  The agent running the skill writes commit messages and resolves conflicts;
#  this script never calls a model. stdout is data, stderr is diagnostics.
# ==============================================================================

set -euo pipefail

# Text tools work on bytes. Under a UTF-8 locale, the macOS awk, sed, tr and
# grep abort on bytes that are not valid UTF-8 (a Latin-1 file in a diff),
# which would silently truncate what the checks see. Git keeps the user's locale.
awk() { LC_ALL=C command awk "$@"; }
grep() { LC_ALL=C command grep "$@"; }
sed() { LC_ALL=C command sed "$@"; }
tr() { LC_ALL=C command tr "$@"; }
cut() { LC_ALL=C command cut "$@"; }
sort() { LC_ALL=C command sort "$@"; }
comm() { LC_ALL=C command comm "$@"; }

VERSION="2.1.0"

# Exit codes
EXIT_ERROR=1
EXIT_CONFLICTS=2
EXIT_REBASE_STOPPED=3
EXIT_PUSH_REJECTED=4
EXIT_FLAGGED=5

# --- Colors (stderr only) ---
if [ -t 2 ] && [ -z "${NO_COLOR:-}" ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    BLUE=''
    YELLOW=''
    NC=''
fi

log_info() {
    printf "${BLUE}[INFO]${NC} %s\n" "$1" >&2
}

log_success() {
    printf "${GREEN}[OK]${NC} %s\n" "$1" >&2
}

log_warn() {
    printf "${YELLOW}[WARN]${NC} %s\n" "$1" >&2
}

log_error() {
    printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
}

die() {
    log_error "$1"
    exit "${2:-$EXIT_ERROR}"
}

print_usage() {
    cat <<'EOF'
git-pilot — deterministic Git helpers for the git-pilot agent skill

Usage: git-pilot.sh <command> [options]

Commit:
  status                              Staged, unstaged and untracked files with line counts and sizes
  commit-context [-a]                 Print staged files, warnings, conventions, recent subjects
                                      and the staged diff (-a stages all changes first)
  commit (-F <file|-> | -m <msg>) [--dry-run] [--push] [--allow-flagged]
                                      Commit the staged changes with the given message

Pull request:
  branch-context [--base <ref>]       Print the branch's commits, diff stat and diff against its base
                                      (default: origin/HEAD, then main or master)

Conflicts:
  conflicts                           List files with unresolved conflicts
  merge-context                       Print merge, rebase, cherry-pick or revert context for conflict resolution
  take <ours|theirs|both> <file>...   Resolve every conflict in the files with one strategy and stage them
  mark-resolved <file>...             Stage files after checking no conflict markers remain

Sync:
  rebase start                        git pull --rebase
  rebase continue                     Continue the rebase after conflicts are resolved
  rebase abort                        Abort the rebase in progress
  push                                Push the current branch (sets its upstream on the first push)

Other:
  -v, --version                       Show version
  -h, --help                          Show this help

Exit codes:
  0 success, 1 error, 2 conflict markers or unmerged files present,
  3 rebase stopped on conflicts, 4 push rejected because the remote is ahead (run 'rebase start' first),
  5 staged files flagged as secrets or large files (see 'commit-context')

Environment:
  GIT_PILOT_DIFF_BUDGET               Max diff characters printed (default 16000)
  GIT_PILOT_MAX_FILE_SIZE             Staged file size flagged as large, in bytes (default 5242880)
  Both must be non-negative integers; any other value is an error.
  NO_COLOR                            Set to disable colors in diagnostics
EOF
}

# ==============================================================================
#  Git helpers
# ==============================================================================

check_git_repo() {
    command -v git >/dev/null 2>&1 || die "git is not installed."
    # rev-parse succeeds inside .git and in bare repositories too: it prints "false".
    local inside
    inside=$(git rev-parse --is-inside-work-tree 2>/dev/null) || die "Not inside a git repository."
    [ "$inside" = true ] || die "Not inside a work tree (bare repository or .git directory)."
}

git_dir() {
    git rev-parse --git-dir 2>/dev/null || echo ".git"
}

# Top of the working tree. Paths are printed relative to it and repository
# files are looked up from it, so commands behave the same from any directory.
repo_root() {
    git rev-parse --show-toplevel
}

# Name of the checked-out branch, or "detached HEAD".
current_branch() {
    local branch
    branch=$(git branch --show-current 2>/dev/null || true)
    printf '%s\n' "${branch:-detached HEAD}"
}

# git for output that is printed or parsed: no colors, unquoted non-ASCII paths
# and diffs of the whole repository (diff.relative would limit them to the
# current directory), whatever the user's configuration says.
git_plain() {
    git -c color.ui=never -c color.diff=never -c core.quotePath=false \
        -c diff.relative=false -c log.showSignature=false "$@"
}

# git with a path the user named: a pathspec such as "*.txt" or ":/" is the
# literal file name, never a pattern that would reach other files.
git_path() {
    GIT_LITERAL_PATHSPECS=1 git_plain "$@"
}

# awk function: the path of a "+++ b/<path>" diff header, without the prefix.
# Git quotes a path containing a double quote, a backslash or a control
# character ("+++ \"b/a\\\"b\""): it is kept quoted, as "git diff --name-only"
# prints it, so that both lists name the file the same way.
AWK_HEADER_PATH='function header_path(line,   p) {
    p = substr(line, 5); sub(/\t$/, "", p)
    if (substr(p, 1, 1) == "\"") { sub(/^"b\//, "\"", p); return p }
    return substr(p, 3)
}'

rebase_in_progress() {
    local dir
    dir=$(git_dir)
    [ -d "$dir/rebase-merge" ] || [ -d "$dir/rebase-apply" ]
}

unmerged_files() {
    git_plain diff --name-only --diff-filter=U 2>/dev/null || true
}

# Sorted, unique "path<TAB>marker line" pairs, from the index and the working
# tree, for conflict marker lines that commit (or tree) $1 does not have.
marker_lines_against() {
    {
        git_plain diff --cached -U0 --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$1" -- 2>/dev/null || true
        git_plain diff -U0 --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ "$1" -- 2>/dev/null || true
    } | awk "$AWK_HEADER_PATH"'
             /^diff --git / { in_hunk = 0; next }
             /^@@ / { in_hunk = 1; next }
             !in_hunk && /^\+\+\+ / { file = header_path($0); next }
             in_hunk && /^\+(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)( |$)/ { print file "\t" substr($0, 2) }' | sort -u
}

# Files where an unfinished resolution left conflict markers: marker lines that
# are new compared with HEAD and with the other side of the operation in
# progress. Marker lines that a side already had (merge fixtures, documentation
# about conflicts) are content, not leftovers, and never block a commit.
leftover_marker_files() {
    # Compared line by line, not file by file: when each side added its own
    # fixture line to the same file, neither line is a leftover.
    local refs=() ref lines i
    if git rev-parse --verify --quiet 'HEAD^{commit}' >/dev/null; then
        refs+=(HEAD)
    else
        refs+=("$(git hash-object -t tree /dev/null)")
    fi
    for ref in MERGE_HEAD CHERRY_PICK_HEAD REBASE_HEAD 'REVERT_HEAD^'; do
        if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null 2>&1; then
            refs+=("$ref")
        fi
    done

    # Every step must succeed: a scan that fails half way would report fewer
    # files than there are, and let conflict markers be committed.
    local other
    lines=$(marker_lines_against "${refs[0]}") || return 1
    for ((i = 1; i < ${#refs[@]}; i++)); do
        [ -n "$lines" ] || break
        other=$(marker_lines_against "${refs[$i]}") || return 1
        lines=$(comm -12 <(printf '%s\n' "$lines") <(printf '%s\n' "$other")) || return 1
    done
    [ -z "$lines" ] || printf '%s\n' "$lines" | cut -f1 | awk '!seen[$0]++'
}

# Unmerged files plus files where a resolution left conflict markers. Exits
# with an error rather than return an incomplete list.
conflicted_files() {
    local unmerged leftover
    unmerged=$(unmerged_files)
    leftover=$(leftover_marker_files) || die "Could not scan the changes for conflict markers."
    printf '%s\n%s\n' "$unmerged" "$leftover" | awk 'NF && !seen[$0]++'
}

is_unmerged() {
    [ -n "$(git_path ls-files -u -- "$1" 2>/dev/null)" ]
}

# True when the index holds stage $2 of unmerged file $1 (2 is ours, 3 is theirs).
# "git ls-files -u" prints "<mode> <blob> <stage><TAB><path>".
has_stage() {
    git_path ls-files -u -- "$1" 2>/dev/null | awk -v stage="$2" '$3 == stage { found = 1 } END { exit !found }'
}

# True when neither side of the unmerged file $1 deleted it.
has_both_sides() {
    has_stage "$1" 2 && has_stage "$1" 3
}

# The file is read from stdin so that awk never parses its name as an
# assignment. Markers are matched as Git writes them, with LF or CRLF endings.
file_has_markers() {
    awk '/^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)( |\r?$)/ { found = 1; exit } END { exit !found }' < "$1"
}

# Exit with EXIT_CONFLICTS when conflicts remain, listing them on stderr.
require_no_conflicts() {
    local files
    files=$(conflicted_files)
    [ -z "$files" ] && return 0

    log_error "Unresolved conflicts in $(printf '%s\n' "$files" | wc -l | xargs) file(s):"
    printf '%s\n' "$files" | sed 's/^/  /' >&2
    log_warn "Resolve them (edit + 'mark-resolved', or 'take <ours|theirs|both>') before committing."
    exit "$EXIT_CONFLICTS"
}

# Print the setting held by environment variable $1 (default $2), which must be
# a non-negative integer. A bad value is an error rather than a silent default:
# it would otherwise switch off the check it configures.
int_setting() {
    local name="$1" value
    value="${!name:-$2}"
    case "$value" in
        ''|*[!0-9]*) die "$name must be a non-negative integer, got: $value" ;;
    esac
    [ "${#value}" -le 15 ] || die "$name is too large: $value"
    printf '%s\n' "$((10#$value))"
}

# Read once in main, before any command runs.
DIFF_BUDGET=16000       # Max chars of diff printed for the agent (~4K tokens)
MAX_FILE_SIZE=5242880   # Staged file size flagged as large, in bytes

load_settings() {
    DIFF_BUDGET=$(int_setting GIT_PILOT_DIFF_BUDGET "$DIFF_BUDGET") || exit "$EXIT_ERROR"
    MAX_FILE_SIZE=$(int_setting GIT_PILOT_MAX_FILE_SIZE "$MAX_FILE_SIZE") || exit "$EXIT_ERROR"
}

# Usage: truncate_diff <diff> <stat shown when the diff is truncated>
# A diff over the budget is cut per file: the smallest file diffs are kept whole
# (most information per character) and printed in their original order.
truncate_diff() {
    local diff="$1"
    local stat="$2"
    local budget="$DIFF_BUDGET"
    local length=${#diff}

    # Fits in budget — send as-is
    if [ "$length" -le "$budget" ]; then
        printf '%s\n' "$diff"
        return
    fi

    # A stat with one line per file can outgrow the budget on its own: keep its summary line.
    if [ "${#stat}" -gt $((budget / 2)) ]; then
        stat="${stat##*$'\n'}"
    fi
    local header="File diffs (most relevant):"$'\n'
    if [ -n "$stat" ]; then
        header="Changes overview:"$'\n'"${stat}"$'\n\n'"${header}"
    fi
    # Room left for file diffs once the header and the closing notice (~80 chars) are counted.
    local available=$((budget - ${#header} - 80))
    [ "$available" -gt 0 ] || available=0

    # Pass 1, linear in the diff: the size of each file diff (each starts with
    # "diff --git") as "index size", smallest first, then the indexes that fit.
    # awk counts bytes or characters depending on the implementation; bytes only
    # overestimate, so the budget holds either way.
    local selection skipped keep
    selection=$(printf '%s\n' "$diff" |
        awk '/^diff --git / { if (n) print n, size; n++; size = 0 }
             { if (!n) n = 1; size += length($0) + 1 }
             END { if (n) print n, size }' |
        sort -k2,2n -k1,1n |
        awk -v available="$available" '
             { if (used + $2 <= available) { used += $2; keep = keep " " $1 } else skipped++ }
             END { print skipped + 0 " " keep }')
    skipped=${selection%% *}
    keep=${selection#* }

    printf '%s' "$header"
    if [ -n "${keep// /}" ]; then
        # Pass 2: print the kept file diffs, numbered exactly as in pass 1.
        printf '%s\n' "$diff" |
            awk -v keep="$keep " '/^diff --git / { n++ } { if (!n) n = 1 } index(keep, " " n " ")'
        printf '\n%s\n' "[... ${skipped} large file(s) omitted — ${length} chars total]"
    else
        # Not even the smallest file diff fits: show the start of the diff.
        printf '%s\n' "${diff:0:$available}"
        printf '\n%s\n' "[... ${skipped} large file(s) omitted, diff cut to fit — ${length} chars total]"
    fi
}

gather_merge_context() {
    local budget=8000
    local ctx=""

    # Resolve actual git dir (supports worktrees where .git is a file)
    local dir
    dir=$(git_dir)

    ctx+="Current branch: $(current_branch)"$'\n'

    # Detect merge vs rebase and gather incoming branch info
    if [ -f "$dir/MERGE_HEAD" ]; then
        local merge_head
        merge_head=$(head -1 "$dir/MERGE_HEAD")
        local merge_msg=""
        [ -f "$dir/MERGE_MSG" ] && merge_msg=$(head -1 "$dir/MERGE_MSG")
        ctx+="Merge in progress: $merge_msg"$'\n'
        ctx+="Merge head: $merge_head"$'\n'
        ctx+="Ours = HEAD (current branch), theirs = the branch being merged in."$'\n'

        # Commits from incoming branch (what's being merged in)
        local incoming_log
        incoming_log=$(git_plain log --oneline -10 "$merge_head" --not HEAD 2>/dev/null || true)
        if [ -n "$incoming_log" ]; then
            ctx+=$'\n'"Incoming commits (theirs):"$'\n'"$incoming_log"$'\n'
        fi

        # Commits from current branch (ours)
        local our_log
        our_log=$(git_plain log --oneline -10 HEAD --not "$merge_head" 2>/dev/null || true)
        if [ -n "$our_log" ]; then
            ctx+=$'\n'"Current branch commits (ours):"$'\n'"$our_log"$'\n'
        fi

        # Diff stats from both sides to understand scope of changes
        local merge_base
        merge_base=$(git merge-base HEAD "$merge_head" 2>/dev/null || true)
        if [ -n "$merge_base" ]; then
            local ours_stat
            ours_stat=$(git_plain diff --stat "$merge_base" HEAD 2>/dev/null || true)
            if [ -n "$ours_stat" ]; then
                ctx+=$'\n'"Changes on current branch (ours):"$'\n'"$ours_stat"$'\n'
            fi
            local theirs_stat
            theirs_stat=$(git_plain diff --stat "$merge_base" "$merge_head" 2>/dev/null || true)
            if [ -n "$theirs_stat" ]; then
                ctx+=$'\n'"Changes on incoming branch (theirs):"$'\n'"$theirs_stat"$'\n'
            fi
        fi

    elif rebase_in_progress; then
        ctx+="Rebase in progress."$'\n'
        ctx+="Ours = the upstream commits being rebased onto, theirs = the local commit being replayed."$'\n'
        local rebase_dir=""
        [ -d "$dir/rebase-merge" ] && rebase_dir="$dir/rebase-merge"
        [ -d "$dir/rebase-apply" ] && rebase_dir="$dir/rebase-apply"

        if [ -n "$rebase_dir" ]; then
            [ -f "$rebase_dir/head-name" ] && ctx+="Rebasing: $(cat "$rebase_dir/head-name")"$'\n'
            [ -f "$rebase_dir/onto" ] && ctx+="Onto: $(git_plain log --oneline -1 "$(cat "$rebase_dir/onto")" 2>/dev/null || true)"$'\n'
            if [ -f "$rebase_dir/message" ]; then
                ctx+="Current patch: $(head -3 "$rebase_dir/message")"$'\n'
            fi
        fi

    # After the rebase check: a rebase replays commits with the same machinery
    # and can leave a CHERRY_PICK_HEAD of its own.
    elif [ -f "$dir/CHERRY_PICK_HEAD" ]; then
        ctx+="Cherry-pick in progress: $(git_plain log --oneline -1 CHERRY_PICK_HEAD 2>/dev/null || true)"$'\n'
        ctx+="Ours = HEAD (current branch), theirs = the commit being picked."$'\n'
        ctx+="Once resolved and staged, finish with: git -c core.editor=true cherry-pick --continue"$'\n'
        ctx+=$'\n'"Changes of the picked commit (theirs):"$'\n'"$(git_plain show --stat --format= CHERRY_PICK_HEAD 2>/dev/null || true)"$'\n'

    elif [ -f "$dir/REVERT_HEAD" ]; then
        ctx+="Revert in progress: $(git_plain log --oneline -1 REVERT_HEAD 2>/dev/null || true)"$'\n'
        ctx+="Ours = HEAD (current branch), theirs = the state before the reverted commit."$'\n'
        ctx+="Once resolved and staged, finish with: git -c core.editor=true revert --continue"$'\n'
        ctx+=$'\n'"Changes of the reverted commit (being undone):"$'\n'"$(git_plain show --stat --format= REVERT_HEAD 2>/dev/null || true)"$'\n'

    else
        # No active merge/rebase — just provide recent history for context
        local recent_log
        recent_log=$(git_plain log --oneline -10 2>/dev/null || true)
        if [ -n "$recent_log" ]; then
            ctx+=$'\n'"Recent commits:"$'\n'"$recent_log"$'\n'
        fi
    fi

    # Truncate to budget
    if [ "${#ctx}" -gt "$budget" ]; then
        ctx="${ctx:0:$budget}"$'\n'"[... context truncated]"
    fi

    printf '%s\n' "$ctx"
}

# Rewrite a file in place, keeping its mode. The file is read from stdin:
# as an operand, awk would treat a name like "key=value.txt" as an assignment.
rewrite_with_awk() {
    local file="$1" program="$2" side="${3:-}"
    local tmp
    tmp=$(mktemp)
    if ! awk -v side="$side" "$program" < "$file" > "$tmp"; then
        rm -f "$tmp"
        die "Could not rewrite: $file"
    fi
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

# Resolve every conflict hunk of file $1, keeping side $2 (ours, theirs or both).
# A hunk is "<<<<<<< ours ||||||| base ======= theirs >>>>>>>". Each marker is
# matched exactly as Git writes it, and only where it can occur: a line such as
# "==========" (a heading underline) or "=======" inside their side is content.
resolve_keep() {
    rewrite_with_awk "$1" '
    BEGIN { keep_ours = (side != "theirs"); keep_theirs = (side != "ours") }
    state == 0 && /^<<<<<<<( |\r?$)/ { state = 1; next }
    state == 1 && /^\|\|\|\|\|\|\|( |\r?$)/ { state = 2; next }
    (state == 1 || state == 2) && /^=======\r?$/ { state = 3; next }
    state == 3 && /^>>>>>>>( |\r?$)/ { state = 0; next }
    state == 0 || (state == 1 && keep_ours) || (state == 3 && keep_theirs) { print }
    ' "$2"
}

resolve_keep_ours() { resolve_keep "$1" ours; }
resolve_keep_theirs() { resolve_keep "$1" theirs; }
resolve_keep_both() { resolve_keep "$1" both; }

# Resolve and stage an unmerged file that has no conflict markers (binary file,
# or deleted on one side) by taking one side's whole version. When that side
# deleted the file, taking it means deleting the file.
take_whole_side() {
    local strategy="$1" file="$2" stage=2
    [ "$strategy" = ours ] || stage=3

    if has_stage "$file" "$stage"; then
        git_path checkout "--$strategy" -- "$file" || die "Could not check out the '$strategy' version of: $file"
        git_path add -- "$file" || die "Could not stage: $file"
    else
        git_path rm -q -- "$file" >&2 || die "Could not remove: $file"
        log_info "Deleted, as on the '$strategy' side: $file"
    fi
}

# True when Git knows path $1: it exists, or the index has it.
path_known() {
    [ -e "$1" ] || [ -L "$1" ] || [ -n "$(git_path ls-files -- "$1" 2>/dev/null)" ]
}

# Paths are printed relative to the repository root but typed relative to the
# current directory. Accept both, and the quoted form Git prints for unusual
# names ("a\"b.txt"). When both readings name a file, the one in conflict wins.
resolve_path() {
    local path="$1" root
    case "$path" in
        \"*\")
            path=${path#\"}
            path=${path%\"}
            path=${path//\\\"/\"}
            path=$(printf '%b' "$path")
            ;;
    esac
    case "$path" in
        /*) printf '%s\n' "$path"; return 0 ;;
    esac
    root=$(repo_root)
    if path_known "$path"; then
        if [ "$root/$path" -ef "$path" ] || ! path_known "$root/$path" ||
            is_unmerged "$path" || ! is_unmerged "$root/$path"; then
            printf '%s\n' "$path"
            return 0
        fi
    fi
    if path_known "$root/$path"; then
        printf '%s\n' "$root/$path"
        return 0
    fi
    printf '%s\n' "$path"
}

# ==============================================================================
#  Staging guard and conventions
# ==============================================================================

# Print one line per staged file that looks like a secret or is too large.
staged_findings() {
    local max_size="$MAX_FILE_SIZE"
    local paths=() blobs=() sizes=() meta file size i

    # Staged paths and their blob ids from one "git diff --raw" (records are
    # ":modes <old blob> <new blob> <status>" NUL path NUL), then every size from
    # one "git cat-file": two processes in all instead of two per file.
    while IFS= read -r -d '' meta && IFS= read -r -d '' file; do
        meta=${meta% *}
        blobs+=("${meta##* }")
        paths+=("$file")
    done < <(git_plain diff --cached --raw -z --no-abbrev --no-renames --diff-filter=ACM)

    if [ "${#paths[@]}" -gt 0 ]; then
        while IFS= read -r size; do
            sizes+=("$size")
        done < <(printf '%s\n' "${blobs[@]}" | git cat-file --batch-check='%(objectsize)' 2>/dev/null)

        for i in "${!paths[@]}"; do
            file=${paths[$i]}
            case "${file##*/}" in
                .env.example|.env.sample|.env.template|.env.dist) ;;
                .env|.env.*|*.pem|*.key|*.p12|*.pfx|*.keystore|*.jks|id_rsa|id_dsa|id_ecdsa|id_ed25519|.netrc|.pgpass|.htpasswd)
                    printf '%s\n' "secret-file: $file" ;;
            esac
            # Not a number: an object git does not have, such as a submodule commit.
            size=${sizes[$i]:-0}
            case "$size" in *[!0-9]*) size=0 ;; esac
            if [ "$size" -gt "$max_size" ]; then
                printf '%s\n' "large-file: $file ($size bytes)"
            fi
        done
    fi

    # Token-like strings in added lines: "path<TAB>line", match with grep -E, report unique paths.
    # A heuristic for well-known formats, not a secret scanner. Short prefixes
    # must start a word: "sk-" also ends ordinary ones (mask-, risk-, task-).
    local token_patterns=(
        '(^|[^A-Za-z0-9])AKIA[0-9A-Z]{16}'                                  # AWS access key id
        '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----'                             # PEM private key
        'gh[pousr]_[A-Za-z0-9]{36}'                                         # GitHub token
        'github_pat_[A-Za-z0-9_]{22}'                                       # GitHub fine-grained token
        'glpat-[A-Za-z0-9_-]{20}'                                           # GitLab personal access token
        'xox[abprs]-[A-Za-z0-9-]{10}'                                       # Slack token
        'hooks\.slack\.com/services/T[A-Za-z0-9_]+/B[A-Za-z0-9_]+/[A-Za-z0-9_]{20}'  # Slack webhook
        '(^|[^A-Za-z0-9_-])sk-[A-Za-z0-9_-]{32}'                            # OpenAI, Anthropic and similar
        '(^|[^A-Za-z0-9_])[sr]k_live_[A-Za-z0-9]{24}'                       # Stripe live key
        'AIza[0-9A-Za-z_-]{35}'                                             # Google API key
        '(^|[^A-Za-z0-9_])npm_[A-Za-z0-9]{36}'                              # npm token
        'pypi-AgEIcHlwaS5vcmc[A-Za-z0-9_-]{50}'                             # PyPI token
        '(^|[^A-Za-z0-9_])hf_[A-Za-z0-9]{34}'                               # Hugging Face token
        '(^|[^A-Za-z0-9_])SG\.[A-Za-z0-9_-]{22}\.[A-Za-z0-9_-]{43}'         # SendGrid key
        '(^|[^A-Za-z0-9_])do[pors]_v1_[a-f0-9]{64}'                         # DigitalOcean token
    )
    local token_pattern
    token_pattern=$(IFS='|'; printf '%s' "${token_patterns[*]}")
    # File headers only count outside hunks (an added "++ x" line reads "+++ x"),
    # and the prefixes are forced so that diff.noprefix cannot shift the path.
    git_plain diff --cached -U0 --no-color --no-ext-diff --src-prefix=a/ --dst-prefix=b/ --diff-filter=ACMR 2>/dev/null |
        awk "$AWK_HEADER_PATH"'
             /^diff --git / { in_hunk = 0; next }
             /^@@ / { in_hunk = 1; next }
             !in_hunk && /^\+\+\+ / { file = header_path($0); next }
             in_hunk && /^\+/ { print file "\t" substr($0, 2) }' |
        { grep -E -e "$token_pattern" || true; } |
        cut -f1 | awk '!seen[$0]++ { print "secret-content: " $0 }'
}

# Print a "Conventions:" section describing the repository's commit style.
detect_conventions() {
    local tooling=() f root
    root=$(repo_root)
    for f in commitlint.config.js commitlint.config.cjs commitlint.config.mjs commitlint.config.ts \
             .commitlintrc .commitlintrc.json .commitlintrc.yml .commitlintrc.yaml .commitlintrc.js; do
        [ -f "$root/$f" ] && tooling+=("commitlint ($f)")
    done
    for f in .releaserc .releaserc.json .releaserc.yml .releaserc.yaml .releaserc.js release.config.js release.config.cjs; do
        [ -f "$root/$f" ] && tooling+=("semantic-release ($f)")
    done
    [ -f "$root/.czrc" ] && tooling+=("commitizen (.czrc)")
    [ -f "$root/.husky/commit-msg" ] && tooling+=("commit-msg hook (.husky/commit-msg)")
    if [ -f "$root/package.json" ]; then
        grep -q '"commitlint"' "$root/package.json" && tooling+=("commitlint (package.json)")
        grep -q '"release"[[:space:]]*:' "$root/package.json" && tooling+=("semantic-release (package.json)")
        grep -q '"commitizen"' "$root/package.json" && tooling+=("commitizen (package.json)")
    fi

    local subjects total conventional emoji types scopes
    subjects=$(git_plain log --no-merges --format='%s' -50 2>/dev/null || true)
    total=$(printf '%s' "$subjects" | grep -c '' || true)

    printf '%s\n' "Conventions:"
    if [ "${#tooling[@]}" -gt 0 ]; then
        printf '  Tooling: %s\n' "$(printf '%s, ' "${tooling[@]}" | sed 's/, $//')"
    else
        printf '  Tooling: none detected\n'
    fi

    local template
    template=$(git config --get commit.template 2>/dev/null || true)
    if [ -n "$template" ]; then
        printf '  Commit template: %s\n' "$template"
    fi

    if [ "$total" -gt 0 ]; then
        conventional=$(printf '%s\n' "$subjects" | grep -cE '^[a-z]+(\([^)]*\))?!?: ' || true)
        # Emoji by their UTF-8 lead bytes (U+1Fxxx, and the arrow, technical, symbol
        # and dingbat blocks), or a :shortcode:. Any non-ASCII byte would also
        # match accented and CJK letters.
        local emoji_lead=$'^(\xf0\x9f|\xe2[\x86\x87\x8c-\x8f\x96-\x9e\xac-\xaf]|:[a-z0-9_+-]+:)'
        emoji=$(printf '%s\n' "$subjects" | LC_ALL=C grep -cE "$emoji_lead" || true)
        printf '  Conventional Commits: %s/%s recent subjects\n' "$conventional" "$total"
        printf '  Leading emoji: %s/%s recent subjects\n' "$emoji" "$total"
        types=$(printf '%s\n' "$subjects" | sed -nE 's/^([a-z]+)(\([^)]*\))?!?: .*/\1/p' | sort | uniq -c | sort -rn | head -6 | awk '{ printf "%s%s (%s)", sep, $2, $1; sep = ", " }')
        [ -n "$types" ] && printf '  Types used: %s\n' "$types"
        scopes=$(printf '%s\n' "$subjects" | sed -nE 's/^[a-z]+\(([^)]+)\)!?: .*/\1/p' | sort | uniq -c | sort -rn | head -6 | awk '{ printf "%s%s (%s)", sep, $2, $1; sep = ", " }')
        [ -n "$scopes" ] && printf '  Scopes used: %s\n' "$scopes"
    fi
    return 0
}

# Resolve the default base ref for branch-context.
default_base() {
    local ref
    ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
    if [ -n "$ref" ]; then
        printf '%s\n' "$ref"
        return 0
    fi
    for ref in origin/main origin/master main master; do
        if git rev-parse --verify --quiet "$ref^{commit}" >/dev/null; then
            printf '%s\n' "$ref"
            return 0
        fi
    done
    return 1
}

# ==============================================================================
#  Commands
# ==============================================================================

cmd_commit_context() {
    local auto_stage=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -a|--auto-stage) auto_stage=true; shift ;;
            *) die "Unknown option for commit-context: $1" ;;
        esac
    done

    require_no_conflicts

    if [ "$auto_stage" = true ]; then
        git add -A || die "git add failed."
        log_info "Staged all changes."
    fi

    local diff
    diff=$(git_plain diff --cached --no-color --no-ext-diff)
    # A merge resolved entirely to our side stages nothing, yet still needs its commit.
    local merging=false
    [ ! -f "$(git_dir)/MERGE_HEAD" ] || merging=true
    if [ -z "$diff" ] && [ "$merging" = false ]; then
        die "No staged changes found. Stage your changes first with 'git add' (or pass -a)."
    fi

    printf 'Branch: %s\n' "$(current_branch)"
    printf '\n%s\n' "Staged files:"
    git_plain diff --cached --name-status

    local findings
    findings=$(staged_findings)
    if [ -n "$findings" ]; then
        printf '\n%s\n' "Warnings (confirm with the user before committing):"
        printf '%s\n' "$findings" | sed 's/^/  /'
        log_warn "Some staged files look like secrets or large files; 'commit' refuses them without --allow-flagged."
    fi

    printf '\n'
    detect_conventions
    local recent
    recent=$(git_plain log --format='%s' -10 2>/dev/null || true)
    if [ -n "$recent" ]; then
        printf '\n%s\n%s\n' "Recent commit subjects (match their style):" "$recent"
    fi
    printf '\n%s\n' "Diff:"
    if [ -z "$diff" ]; then
        printf '%s\n' "(none: the merge in progress resolves to the current branch's content)"
        return 0
    fi
    # The stat is only shown with a truncated diff: skip the extra git call otherwise.
    local stat=""
    [ "${#diff}" -le "$DIFF_BUDGET" ] || stat=$(git_plain diff --cached --stat)
    truncate_diff "$diff" "$stat"
}

# Print "status<TAB>+added<TAB>-deleted<TAB>path" lines for a diff (extra args go to git diff).
diff_summary() {
    # git reports an unmerged file twice in the working tree diff ("U", then "M"
    # with the line counts): fold the counts into the "U" line.
    paste <(git_plain diff --name-status "$@" | cut -f1) <(git_plain diff --numstat "$@") |
        awk -F'\t' '
            NF {
                if (($4 in row) && status[row[$4]] == "U") { added[row[$4]] = $2; deleted[row[$4]] = $3; next }
                n++; row[$4] = n; status[n] = $1; added[n] = $2; deleted[n] = $3; path[n] = $4
            }
            END { for (i = 1; i <= n; i++) printf "  %s +%s -%s %s\n", status[i], added[i], deleted[i], path[i] }'
}

# Usage: file_sizes <root> <absolute path>...
# Print "  <bytes> <path relative to root>" for readable regular files, with one wc.
file_sizes() {
    local root="$1" size path
    shift
    { wc -c "$@" 2>/dev/null || true; } | while read -r size path; do
        [ "$path" = total ] || printf '  %s %s\n' "$size" "${path#"$root"/}"
    done
}

# Print "  <bytes> <path>" for each untracked file, reading sizes in batches of
# 200 files instead of starting a process per file.
untracked_summary() {
    local root file batch=()
    root=$(repo_root)
    while IFS= read -r -d '' file; do
        if [ -f "$root/$file" ] && [ -r "$root/$file" ]; then
            batch+=("$root/$file")
            if [ "${#batch[@]}" -ge 200 ]; then
                file_sizes "$root" "${batch[@]}"
                batch=()
            fi
        else
            # No size to read: nested repository, dangling link, unreadable file.
            [ "${#batch[@]}" -eq 0 ] || file_sizes "$root" "${batch[@]}"
            batch=()
            printf '  - %s\n' "$file"
        fi
    done < <(git ls-files --others --exclude-standard --full-name -z -- ':/')
    [ "${#batch[@]}" -eq 0 ] || file_sizes "$root" "${batch[@]}"
}

cmd_status() {
    [ $# -eq 0 ] || die "status takes no arguments."

    local upstream counts
    printf 'Branch: %s\n' "$(current_branch)"
    upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || true)
    if [ -n "$upstream" ]; then
        counts=$(git rev-list --left-right --count "HEAD...$upstream" 2>/dev/null || printf '0\t0')
        printf 'Upstream: %s (ahead %s, behind %s)\n' "$upstream" "$(printf '%s' "$counts" | cut -f1)" "$(printf '%s' "$counts" | cut -f2)"
    fi

    printf '\n%s\n' "Staged (status +added -deleted path):"
    diff_summary --cached

    printf '\n%s\n' "Unstaged (status +added -deleted path):"
    diff_summary

    printf '\n%s\n' "Untracked (bytes path):"
    untracked_summary

    local conflicts
    conflicts=$(conflicted_files)
    if [ -n "$conflicts" ]; then
        printf '\n%s\n' "Conflicted:"
        printf '%s\n' "$conflicts" | sed 's/^/  /'
    fi
}

cmd_branch_context() {
    local base=""
    while [ $# -gt 0 ]; do
        case "$1" in
            -b|--base)
                [ -n "${2:-}" ] || die "Option $1 requires a ref."
                base="$2"; shift 2 ;;
            *) die "Unknown option for branch-context: $1" ;;
        esac
    done

    if [ -z "$base" ]; then
        base=$(default_base) || die "Could not find a base branch. Pass --base <ref>."
    fi
    git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "Unknown base ref: $base"

    local merge_base
    merge_base=$(git merge-base "$base" HEAD 2>/dev/null) || die "No common history between $base and HEAD."

    local commits
    commits=$(git_plain log --no-merges --reverse --format='- %h %s' "$merge_base..HEAD")
    [ -n "$commits" ] || die "No commits on this branch since $base."

    if ! git_plain diff --quiet || ! git_plain diff --cached --quiet; then
        log_warn "Uncommitted changes are not part of the branch context."
    fi
    if ! git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' >/dev/null 2>&1; then
        log_warn "The branch has no upstream yet; push it before opening a pull request."
    fi

    printf 'Branch: %s\n' "$(current_branch)"
    printf 'Base: %s (merge base %s)\n' "$base" "$(git rev-parse --short "$merge_base")"

    printf '\n%s\n%s\n' "Commits (oldest first):" "$commits"

    # awk caps the output itself and reads git's output to the end: piping into
    # head would kill the pipeline (SIGPIPE under pipefail) on long bodies.
    local bodies
    bodies=$(git_plain log --no-merges --reverse --format='@@git-pilot@@%h %s%n%b' "$merge_base..HEAD" |
        awk 'function emit(line) { if (count++ < 80) print line }
             /^@@git-pilot@@/ { header = substr($0, 14); printed = 0; next }
             NF { if (!printed) { emit(header); printed = 1 } emit("  " $0) }
             END { if (count > 80) print "[... " count - 80 " more lines of commit bodies omitted]" }')
    if [ -n "$bodies" ]; then
        printf '\n%s\n%s\n' "Commit bodies:" "$bodies"
    fi

    local template="" f root
    root=$(repo_root)
    for f in .github/pull_request_template.md .github/PULL_REQUEST_TEMPLATE.md PULL_REQUEST_TEMPLATE.md \
             docs/pull_request_template.md .gitlab/merge_request_templates/Default.md; do
        if [ -f "$root/$f" ]; then
            template="$f"
            break
        fi
    done
    if [ -n "$template" ]; then
        printf '\n%s\n' "Pull request template ($template):"
        cat "$root/$template"
    fi

    printf '\n'
    detect_conventions

    local stat diff
    stat=$(git_plain diff --stat "$merge_base" HEAD)
    diff=$(git_plain diff --no-color --no-ext-diff "$merge_base" HEAD)
    printf '\n%s\n%s\n' "Diff stat:" "$stat"
    printf '\n%s\n' "Diff:"
    truncate_diff "$diff" ""
}

# Remote that branch $1, which has no upstream, is pushed to: the branch's own
# pushRemote or remote, then remote.pushDefault, "origin", or the only remote,
# in the order Git itself uses. Fails when there is no obvious choice.
default_push_remote() {
    local branch="$1" remote="" key
    for key in "branch.$branch.pushRemote" remote.pushDefault "branch.$branch.remote"; do
        remote=$(git config --get "$key" 2>/dev/null || true)
        [ -z "$remote" ] || break
    done
    if [ -z "$remote" ]; then
        if git config --get remote.origin.url >/dev/null 2>&1; then
            remote=origin
        else
            remote=$(git remote 2>/dev/null || true)
            case "$remote" in
                ''|*$'\n'*) return 1 ;;
            esac
        fi
    fi
    printf '%s\n' "$remote"
}

cmd_push() {
    [ $# -eq 0 ] || die "push takes no arguments: it pushes the current branch to its upstream."

    local args=() branch remote=""
    branch=$(git branch --show-current 2>/dev/null || true)
    [ -n "$branch" ] || die "Cannot push a detached HEAD: check out a branch first."

    # A branch that was never pushed gets its upstream on the way. A branch with
    # a configured upstream is pushed as Git would push it, even when the remote
    # branch is gone: its configuration says where it belongs.
    if [ -z "$(git config --get "branch.$branch.merge" 2>/dev/null || true)" ]; then
        remote=$(default_push_remote "$branch") ||
            die "The branch has no upstream and there is no single remote to choose. Run 'git push -u <remote> $branch' once."
        args=(-u "$remote" "$branch")
        log_info "No upstream yet: pushing to $remote and tracking $remote/$branch."
    fi

    log_info "Pushing..."
    if git push ${args[@]+"${args[@]}"} >&2; then
        log_success "Pushed!"
        return 0
    fi

    # Ask the remote again without sending anything: only a branch that is
    # behind its remote is worth a rebase. Anything else (authentication,
    # network, a hook or a protected branch refusing the push) is a plain error.
    # --no-verify: the pre-push hook already ran (and maybe failed) above.
    local verdict
    verdict=$(git push --dry-run --porcelain --no-verify ${args[@]+"${args[@]}"} 2>/dev/null || true)
    if printf '%s\n' "$verdict" | grep -Eq '^!.*\[rejected\] \((fetch first|non-fast-forward)\)'; then
        # A first push to a branch that already exists remotely set no upstream,
        # and 'rebase start' needs one: track the remote branch now.
        if [ -n "$remote" ]; then
            if git fetch -q "$remote" "$branch" >&2 &&
                git branch -q --set-upstream-to="$remote/$branch" "$branch" >&2; then
                log_info "Now tracking $remote/$branch."
            else
                die "Push rejected: $remote/$branch has commits you do not have, and it could not be tracked. Run 'git branch --set-upstream-to=$remote/$branch', then 'rebase start'."
            fi
        fi
        log_error "Push rejected: the remote has commits you do not have. Run 'rebase start', then 'push' again."
        exit "$EXIT_PUSH_REJECTED"
    fi
    die "git push failed for another reason than new commits on the remote (see git's message above)."
}

cmd_commit() {
    local message_file="" message="" have_message=false dry_run=false push=false allow_flagged=false
    while [ $# -gt 0 ]; do
        case "$1" in
            -F|--file)
                [ -n "${2:-}" ] || die "Option $1 requires a file path (or - for stdin)."
                message_file="$2"; have_message=true; shift 2 ;;
            -m|--message)
                [ $# -ge 2 ] || die "Option $1 requires a message."
                message="$2"; have_message=true; shift 2 ;;
            -d|--dry-run) dry_run=true; shift ;;
            -P|--push) push=true; shift ;;
            --allow-flagged) allow_flagged=true; shift ;;
            *) die "Unknown option for commit: $1" ;;
        esac
    done
    [ "$have_message" = true ] || die "commit needs a message: -F <file>, -F - (stdin) or -m <message>."

    if [ -n "$message_file" ]; then
        if [ "$message_file" = "-" ]; then
            message=$(cat)
        else
            [ -f "$message_file" ] || die "Message file not found: $message_file"
            message=$(cat "$message_file")
        fi
    fi
    [ -n "$(printf '%s' "$message" | tr -d '[:space:]')" ] || die "Commit message is empty."

    require_no_conflicts
    if git_plain diff --cached --quiet && [ ! -f "$(git_dir)/MERGE_HEAD" ]; then
        die "No staged changes found. Stage your changes first with 'git add'."
    fi

    local findings
    findings=$(staged_findings)
    if [ -n "$findings" ] && [ "$allow_flagged" != true ]; then
        log_error "Refusing to commit flagged files:"
        printf '%s\n' "$findings" | sed 's/^/  /' >&2
        log_warn "Unstage them, or pass --allow-flagged once the user has confirmed they are safe."
        exit "$EXIT_FLAGGED"
    fi

    if [ "$dry_run" = true ]; then
        printf '%s\n' "$message"
        log_info "Dry run — no commit created."
        return 0
    fi

    printf '%s\n' "$message" | git commit -F - >&2 || die "git commit failed."
    git rev-parse HEAD
    log_success "Committed!"

    if [ "$push" = true ]; then
        cmd_push
    fi
}

cmd_conflicts() {
    [ $# -eq 0 ] || die "conflicts takes no arguments."
    conflicted_files
}

cmd_merge_context() {
    [ $# -eq 0 ] || die "merge-context takes no arguments."
    local files
    files=$(conflicted_files)
    if [ -n "$files" ]; then
        printf '%s\n%s\n\n' "Conflicted files:" "$files"
    else
        printf '%s\n\n' "Conflicted files: none"
    fi
    gather_merge_context
}

cmd_take() {
    local strategy="${1:-}"
    case "$strategy" in
        ours|theirs|both) shift ;;
        *) die "Usage: take <ours|theirs|both> <file>..." ;;
    esac
    [ $# -gt 0 ] || die "Usage: take <ours|theirs|both> <file>..."

    # Check every file before changing any: a file that is not in conflict
    # would otherwise be staged as it is and reported as resolved.
    # A refusal therefore leaves every file as it was.
    local args=("$@") files=() whole=() arg file i leftover="" name
    for arg in "$@"; do
        file=$(resolve_path "$arg")
        [ ! -d "$file" ] || die "take resolves files, not directories: $arg"
        if ! is_unmerged "$file"; then
            [ -f "$file" ] || die "File not found: $arg"
            # Already staged but with markers left in it: only markers that a
            # resolution left behind count, not a committed file that documents them.
            [ -n "$leftover" ] || leftover=$(leftover_marker_files) ||
                die "Could not scan the changes for conflict markers."
            name=$(git_path ls-files --full-name -- "$file" 2>/dev/null || true)
            if [ -z "$name" ] || ! printf '%s\n' "$leftover" | grep -Fxq -- "$name"; then
                die "Not in conflict, nothing to resolve: $arg"
            fi
            whole+=(false)
        elif ! has_both_sides "$file" || [ ! -f "$file" ] || ! file_has_markers "$file"; then
            # Deleted on one side, binary, or otherwise without markers to edit:
            # one side's version is taken as a whole. Markers in the file are
            # then content (a fixture), not something to resolve.
            [ "$strategy" != both ] ||
                die "Cannot keep both sides of $arg: it has no conflict hunks (binary file, or deleted on one side). Resolve it manually."
            whole+=(true)
        else
            whole+=(false)
        fi
        files+=("$file")
    done

    for i in "${!files[@]}"; do
        file=${files[$i]}
        if [ "${whole[$i]}" = true ]; then
            take_whole_side "$strategy" "$file"
        else
            "resolve_keep_$strategy" "$file"
            git_path add -- "$file" || die "Could not stage: ${args[$i]}"
        fi
        log_success "Resolved ($strategy): ${args[$i]}"
    done
}

cmd_mark_resolved() {
    [ $# -gt 0 ] || die "Usage: mark-resolved <file>..."
    local args=("$@") files=() arg file i failed=false
    for arg in "$@"; do
        file=$(resolve_path "$arg")
        # A directory would be staged whole, without its files being checked.
        [ ! -d "$file" ] || die "mark-resolved takes files, not directories: $arg"
        if [ -f "$file" ]; then
            if file_has_markers "$file"; then
                log_error "Conflict markers remain in: $arg"
                failed=true
            elif is_unmerged "$file" && grep -Eq '^=======[[:space:]]*$' < "$file"; then
                # Not refused: such a line is also a Markdown or reStructuredText heading underline.
                log_warn "A '=======' line remains in $arg: check that it is not a leftover conflict separator."
            fi
        fi
        files+=("$file")
    done
    [ "$failed" = false ] || exit "$EXIT_CONFLICTS"

    for i in "${!files[@]}"; do
        git_path add -A -- "${files[$i]}" || die "Could not stage: ${args[$i]}"
        log_success "Staged: ${args[$i]}"
    done
}

# After a failed rebase step: 3 when stopped on conflicts, 1 otherwise.
rebase_failure() {
    if rebase_in_progress && [ -n "$(unmerged_files)" ]; then
        log_warn "Rebase stopped on conflicts:"
        unmerged_files | sed 's/^/  /' >&2
        log_info "Resolve them, then run 'rebase continue' (or 'rebase abort')."
        exit "$EXIT_REBASE_STOPPED"
    fi
    die "$1"
}

cmd_rebase() {
    local sub="${1:-}"
    [ $# -le 1 ] || die "Usage: rebase <start|continue|abort>"
    case "$sub" in
        start)
            rebase_in_progress && die "A rebase is already in progress. Use 'rebase continue' or 'rebase abort'."
            log_info "Pulling with rebase..."
            if git pull --rebase >&2; then
                log_success "Rebase completed — no conflicts."
                return 0
            fi
            rebase_failure "git pull --rebase failed."
            ;;
        continue)
            rebase_in_progress || die "No rebase in progress."
            local remaining
            remaining=$(conflicted_files)
            if [ -n "$remaining" ]; then
                log_error "Unresolved conflicts remain:"
                printf '%s\n' "$remaining" | sed 's/^/  /' >&2
                exit "$EXIT_REBASE_STOPPED"
            fi
            if GIT_EDITOR=true git rebase --continue >&2 && ! rebase_in_progress; then
                log_success "Rebase completed."
                return 0
            fi
            rebase_failure "git rebase --continue failed."
            ;;
        abort)
            rebase_in_progress || die "No rebase in progress."
            git rebase --abort >&2 || die "git rebase --abort failed."
            log_success "Rebase aborted."
            ;;
        *)
            die "Usage: rebase <start|continue|abort>"
            ;;
    esac
}

# ==============================================================================
#  Main
# ==============================================================================

main() {
    local command="${1:-}"
    [ $# -gt 0 ] && shift

    case "$command" in
        -v|--version) printf 'git-pilot v%s\n' "$VERSION"; return 0 ;;
        -h|--help|help) print_usage; return 0 ;;
        "") print_usage >&2; exit "$EXIT_ERROR" ;;
    esac

    check_git_repo
    load_settings

    case "$command" in
        status)         cmd_status "$@" ;;
        commit-context) cmd_commit_context "$@" ;;
        branch-context) cmd_branch_context "$@" ;;
        commit)         cmd_commit "$@" ;;
        conflicts)      cmd_conflicts "$@" ;;
        merge-context)  cmd_merge_context "$@" ;;
        take)           cmd_take "$@" ;;
        mark-resolved)  cmd_mark_resolved "$@" ;;
        rebase)         cmd_rebase "$@" ;;
        push)           cmd_push "$@" ;;
        *)
            log_error "Unknown command: $command"
            print_usage >&2
            exit "$EXIT_ERROR"
            ;;
    esac
}

main "$@"
