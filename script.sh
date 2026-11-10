#!/bin/bash

# ==============================================================================
#  git-pilot
#  Deterministic Git helpers for the git-pilot agent skill.
#  The agent running the skill writes commit messages and resolves conflicts;
#  this script never calls a model. stdout is data, stderr is diagnostics.
# ==============================================================================

set -eo pipefail

VERSION="1.12.11"

# Exit codes
EXIT_ERROR=1
EXIT_CONFLICTS=2
EXIT_REBASE_STOPPED=3
EXIT_PUSH_REJECTED=4

# --- Colors (stderr only) ---
if [ -t 2 ]; then
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
  commit-context [-a]                 Print staged files, recent subjects and the staged diff
                                      (-a stages all changes first)
  commit (-F <file|-> | -m <msg>) [--dry-run] [--push]
                                      Commit the staged changes with the given message

Conflicts:
  conflicts                           List files with unresolved conflicts
  merge-context                       Print merge/rebase context for conflict resolution
  take <ours|theirs|both> <file>...   Resolve every conflict in the files with one strategy and stage them
  mark-resolved <file>...             Stage files after checking no conflict markers remain

Sync:
  rebase start                        git pull --rebase
  rebase continue                     Continue the rebase after conflicts are resolved
  rebase abort                        Abort the rebase in progress
  push                                git push

Other:
  -v, --version                       Show version
  -h, --help                          Show this help

Exit codes:
  0 success, 1 error, 2 conflict markers or unmerged files present,
  3 rebase stopped on conflicts, 4 push rejected (run 'rebase start' first)
EOF
}

# ==============================================================================
#  Git helpers
# ==============================================================================

check_git_repo() {
    command -v git >/dev/null 2>&1 || die "git is not installed."
    git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "Not inside a git repository."
}

git_dir() {
    git rev-parse --git-dir 2>/dev/null || echo ".git"
}

rebase_in_progress() {
    local dir
    dir=$(git_dir)
    [ -d "$dir/rebase-merge" ] || [ -d "$dir/rebase-apply" ]
}

unmerged_files() {
    git diff --name-only --diff-filter=U 2>/dev/null || true
}

# Unmerged files plus tracked files that still contain conflict markers.
conflicted_files() {
    {
        unmerged_files
        git grep -Il -E '^<<<<<<<( |$)' 2>/dev/null || true
    } | awk 'NF && !seen[$0]++'
}

file_has_markers() {
    grep -Eq '^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)( |$)' "$1"
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

get_diff_budget() {
    # Max chars of diff printed for the agent (~4K tokens)
    echo "${GIT_PILOT_DIFF_BUDGET:-16000}"
}

truncate_diff() {
    local diff="$1"
    local budget
    budget=$(get_diff_budget)
    local length=${#diff}

    # Fits in budget — send as-is
    if [ "$length" -le "$budget" ]; then
        printf '%s\n' "$diff"
        return
    fi

    # Smart truncation: stat overview + fit as many complete file diffs as possible
    local stat
    stat=$(git diff --cached --stat)
    local header="Changes overview:"$'\n'"${stat}"$'\n\n'"File diffs (most relevant):"$'\n'
    local footer=$'\n\n'"[... ${length} chars total, truncated to fit budget]"
    local available=$((budget - ${#header} - ${#footer}))

    # Split diff by file (each starts with "diff --git"), collect into temp files
    local tmpdir
    tmpdir=$(mktemp -d)

    local idx=0
    local current_file=""

    while IFS= read -r line; do
        if [[ "$line" == "diff --git"* ]]; then
            if [ -n "$current_file" ]; then
                printf '%s' "$current_file" > "$tmpdir/$idx"
                idx=$((idx + 1))
            fi
            current_file="$line"$'\n'
        else
            current_file="${current_file}${line}"$'\n'
        fi
    done <<< "$diff"
    if [ -n "$current_file" ]; then
        printf '%s' "$current_file" > "$tmpdir/$idx"
    fi

    # Sort file chunks by size (smallest first = most info per char)
    local result=""
    local used=0
    local skipped=0

    while IFS= read -r chunk_file; do
        local chunk
        chunk=$(cat "$chunk_file")
        local chunk_len=${#chunk}
        if [ $((used + chunk_len)) -le "$available" ]; then
            result="${result}${chunk}"$'\n'
            used=$((used + chunk_len + 1))
        else
            skipped=$((skipped + 1))
        fi
    done < <(find "$tmpdir" -type f -exec wc -c {} + | grep -v ' total$' | sort -n | awk '{print $2}')

    rm -rf "$tmpdir"

    # If we got nothing (single huge file), fall back to raw truncation
    if [ -z "$result" ]; then
        result="${diff:0:$available}"
        skipped=1
    fi

    if [ "$skipped" -gt 0 ]; then
        footer=$'\n\n'"[... ${skipped} large file(s) omitted — ${length} chars total]"
    fi

    printf '%s\n' "${header}${result}${footer}"
}

gather_merge_context() {
    local budget=8000
    local ctx=""

    # Resolve actual git dir (supports worktrees where .git is a file)
    local git_dir
    git_dir=$(git_dir)

    # Current branch
    local current_branch
    current_branch=$(git branch --show-current 2>/dev/null || echo "unknown")
    ctx+="Current branch: ${current_branch:-detached HEAD}"$'\n'

    # Detect merge vs rebase and gather incoming branch info
    if [ -f "$git_dir/MERGE_HEAD" ]; then
        local merge_head
        merge_head=$(head -1 "$git_dir/MERGE_HEAD")
        local merge_msg=""
        [ -f "$git_dir/MERGE_MSG" ] && merge_msg=$(head -1 "$git_dir/MERGE_MSG")
        ctx+="Merge in progress: $merge_msg"$'\n'
        ctx+="Merge head: $merge_head"$'\n'
        ctx+="Ours = HEAD (current branch), theirs = the branch being merged in."$'\n'

        # Commits from incoming branch (what's being merged in)
        local incoming_log
        incoming_log=$(git log --oneline -10 "$merge_head" --not HEAD 2>/dev/null || true)
        if [ -n "$incoming_log" ]; then
            ctx+=$'\n'"Incoming commits (theirs):"$'\n'"$incoming_log"$'\n'
        fi

        # Commits from current branch (ours)
        local our_log
        our_log=$(git log --oneline -10 HEAD --not "$merge_head" 2>/dev/null || true)
        if [ -n "$our_log" ]; then
            ctx+=$'\n'"Current branch commits (ours):"$'\n'"$our_log"$'\n'
        fi

        # Diff stats from both sides to understand scope of changes
        local merge_base
        merge_base=$(git merge-base HEAD "$merge_head" 2>/dev/null || true)
        if [ -n "$merge_base" ]; then
            local ours_stat
            ours_stat=$(git diff --stat "$merge_base" HEAD 2>/dev/null || true)
            if [ -n "$ours_stat" ]; then
                ctx+=$'\n'"Changes on current branch (ours):"$'\n'"$ours_stat"$'\n'
            fi
            local theirs_stat
            theirs_stat=$(git diff --stat "$merge_base" "$merge_head" 2>/dev/null || true)
            if [ -n "$theirs_stat" ]; then
                ctx+=$'\n'"Changes on incoming branch (theirs):"$'\n'"$theirs_stat"$'\n'
            fi
        fi

    elif rebase_in_progress; then
        ctx+="Rebase in progress."$'\n'
        ctx+="Ours = the upstream commits being rebased onto, theirs = the local commit being replayed."$'\n'
        local rebase_dir=""
        [ -d "$git_dir/rebase-merge" ] && rebase_dir="$git_dir/rebase-merge"
        [ -d "$git_dir/rebase-apply" ] && rebase_dir="$git_dir/rebase-apply"

        if [ -n "$rebase_dir" ]; then
            [ -f "$rebase_dir/head-name" ] && ctx+="Rebasing: $(cat "$rebase_dir/head-name")"$'\n'
            [ -f "$rebase_dir/onto" ] && ctx+="Onto: $(git log --oneline -1 "$(cat "$rebase_dir/onto")" 2>/dev/null || true)"$'\n'
            if [ -f "$rebase_dir/message" ]; then
                ctx+="Current patch: $(head -3 "$rebase_dir/message")"$'\n'
            fi
        fi
    else
        # No active merge/rebase — just provide recent history for context
        local recent_log
        recent_log=$(git log --oneline -10 2>/dev/null || true)
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

# Rewrite a file in place, keeping its mode.
rewrite_with_awk() {
    local file="$1" program="$2"
    local tmp
    tmp=$(mktemp)
    awk "$program" "$file" > "$tmp"
    cat "$tmp" > "$file"
    rm -f "$tmp"
}

resolve_keep_both() {
    rewrite_with_awk "$1" '
    /^<<<<<<</ { in_conflict=1; next }
    in_conflict && /^\|\|\|\|\|\|\|/ { skip_base=1; next }
    in_conflict && /^=======/ { skip_base=0; next }
    in_conflict && /^>>>>>>>/ { in_conflict=0; skip_base=0; next }
    !skip_base { print }
    '
}

resolve_keep_ours() {
    rewrite_with_awk "$1" '
    /^<<<<<<</ { in_conflict=1; keep=1; next }
    in_conflict && /^\|\|\|\|\|\|\|/ { keep=0; next }
    in_conflict && /^=======/ { keep=0; next }
    in_conflict && /^>>>>>>>/ { in_conflict=0; keep=0; next }
    !in_conflict || keep { print }
    '
}

resolve_keep_theirs() {
    rewrite_with_awk "$1" '
    /^<<<<<<</ { in_conflict=1; keep=0; next }
    in_conflict && /^\|\|\|\|\|\|\|/ { next }
    in_conflict && /^=======/ { keep=1; next }
    in_conflict && /^>>>>>>>/ { in_conflict=0; keep=0; next }
    !in_conflict || keep { print }
    '
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
        git add -A
        log_info "Staged all changes."
    fi

    local diff
    diff=$(git diff --cached)
    [ -n "$diff" ] || die "No staged changes found. Stage your changes first with 'git add' (or pass -a)."

    printf '%s\n' "Branch: $(git branch --show-current 2>/dev/null || true)"
    printf '\n%s\n' "Staged files:"
    git diff --cached --name-status
    local recent
    recent=$(git log --format='%s' -10 2>/dev/null || true)
    if [ -n "$recent" ]; then
        printf '\n%s\n%s\n' "Recent commit subjects (match their style):" "$recent"
    fi
    printf '\n%s\n' "Diff:"
    truncate_diff "$diff"
}

cmd_push() {
    log_info "Pushing..."
    if git push >&2; then
        log_success "Pushed!"
        return 0
    fi
    log_error "Push failed or was rejected. If the remote has new commits, run 'rebase start', then 'push' again."
    exit "$EXIT_PUSH_REJECTED"
}

cmd_commit() {
    local message_file="" message="" have_message=false dry_run=false push=false
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
    if git diff --cached --quiet && [ ! -f "$(git_dir)/MERGE_HEAD" ]; then
        die "No staged changes found. Stage your changes first with 'git add'."
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
    conflicted_files
}

cmd_merge_context() {
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

    local file
    for file in "$@"; do
        [ -f "$file" ] || die "File not found: $file"
        "resolve_keep_$strategy" "$file"
        git add -- "$file"
        log_success "Resolved ($strategy): $file"
    done
}

cmd_mark_resolved() {
    [ $# -gt 0 ] || die "Usage: mark-resolved <file>..."
    local file failed=false
    for file in "$@"; do
        if [ -f "$file" ] && file_has_markers "$file"; then
            log_error "Conflict markers remain in: $file"
            failed=true
        fi
    done
    [ "$failed" = false ] || exit "$EXIT_CONFLICTS"

    for file in "$@"; do
        git add -A -- "$file"
        log_success "Staged: $file"
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
            git rebase --abort >&2
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

    case "$command" in
        commit-context) cmd_commit_context "$@" ;;
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
