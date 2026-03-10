#!/bin/bash

# ==============================================================================
#  git-pilot
#  AI-powered git automation: smart commits, conflict resolution, and auto-rebase
#  Supports Claude Code, Codex (CLI), Anthropic, OpenAI, Gemini, Mistral (API)
# ==============================================================================

set -e

# --- Configuration & Defaults ---
VERSION="1.6.2"
CONFIG_DIR="${GIT_PILOT_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/git-pilot}"
CONFIG_FILE="$CONFIG_DIR/config"
MAX_TOKENS=1024

# --- Runtime state (overridable by CLI flags) ---
PROVIDER=""
MODEL=""
API_KEY=""
DRY_RUN=false
AUTO_STAGE=false
AUTO_PUSH=false
CONVENTIONAL=false
EMOJI=false
LANGUAGE=""
SKIP_CONFIRM=false
ACTION="commit"  # commit | setup | config | resolve | rebase

# --- Colors ---
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    BLUE='\033[0;34m'
    YELLOW='\033[1;33m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED=''
    GREEN=''
    BLUE=''
    YELLOW=''
    CYAN=''
    BOLD=''
    NC=''
fi

# --- Helper Functions ---

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

# Spinner for long-running operations
SPINNER_PID=""

start_spinner() {
    local msg="$1"
    if [ ! -t 1 ]; then return; fi
    (
        local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
        local i=0
        while true; do
            printf "\r${CYAN}%s${NC} %s" "${frames[$i]}" "$msg" >&2
            i=$(( (i + 1) % ${#frames[@]} ))
            sleep 0.1
        done
    ) &
    SPINNER_PID=$!
    disown "$SPINNER_PID" 2>/dev/null
}

stop_spinner() {
    if [ -n "$SPINNER_PID" ]; then
        kill "$SPINNER_PID" 2>/dev/null
        wait "$SPINNER_PID" 2>/dev/null || true
        SPINNER_PID=""
        printf "\r\033[K" >&2  # clear line
    fi
}

trap 'stop_spinner' EXIT

print_banner() {
    echo -e "${CYAN}"
    echo "   ██████╗ ██╗████████╗      ██████╗ ██╗██╗      ██████╗ ████████╗"
    echo "  ██╔════╝ ██║╚══██╔══╝      ██╔══██╗██║██║     ██╔═══██╗╚══██╔══╝"
    echo "  ██║  ███╗██║   ██║   █████╗██████╔╝██║██║     ██║   ██║   ██║   "
    echo "  ██║   ██║██║   ██║   ╚════╝██╔═══╝ ██║██║     ██║   ██║   ██║   "
    echo "  ╚██████╔╝██║   ██║         ██║     ██║███████╗╚██████╔╝   ██║   "
    echo "   ╚═════╝ ╚═╝   ╚═╝         ╚═╝     ╚═╝╚══════╝ ╚═════╝    ╚═╝   "
    echo -e "${NC}"
    echo -e "              AI-powered git automation v${VERSION}"
    echo ""
}

print_usage() {
    echo "Usage: git-pilot [command] [options]"
    echo ""
    echo "Commands:"
    echo "  commit              Generate AI commit message and commit (default)"
    echo "  resolve             Resolve merge conflicts with AI"
    echo "  rebase              Pull --rebase with AI conflict resolution"
    echo "  setup               Run interactive configuration wizard"
    echo "  config              Show current configuration"
    echo ""
    echo "Options:"
    echo "  -p, --provider <name>    Provider: claude-code, codex, anthropic, openai, gemini, mistral"
    echo "  -m, --model <name>       Model name (e.g. haiku, gpt-5-mini, claude-haiku-4-5)"
    echo "      --api-key <key>      API key (for API providers: anthropic, openai, gemini, mistral)"
    echo "  -d, --dry-run            Preview commit message without committing"
    echo "  -a, --auto-stage         Stage all changes before commit"
    echo "  -P, --auto-push          Push after commit"
    echo "  -c, --conventional       Use Conventional Commits format"
    echo "  -e, --emoji              Add emoji to commit message"
    echo "  -l, --lang <code>        Language for commit message (e.g. en, fr, es)"
    echo "  -y, --yes                Skip confirmation prompts"
    echo "  -v, --version            Show version"
    echo "  -h, --help               Show this help message"
    echo ""
    echo "Examples:"
    echo "  git-pilot                          # Commit with AI message"
    echo "  git-pilot -a -c                    # Auto-stage + conventional commits"
    echo "  git-pilot -d                       # Dry run (preview only)"
    echo "  git-pilot resolve                  # Resolve merge conflicts"
    echo "  git-pilot rebase                   # Pull --rebase with AI"
    echo "  git-pilot setup                    # Configure provider & preferences"
    echo "  git-pilot config                   # Show current config"
    echo "  git-pilot -a -P                    # Auto-stage + push after commit"
    echo "  git-pilot -p anthropic             # Use Anthropic API (claude-haiku-4-5)"
    echo "  git-pilot -p openai -m gpt-5-mini  # Use specific API provider/model"
    echo "  git-pilot -p codex                 # Use OpenAI Codex CLI"
}

ask_yes_no() {
    local prompt="$1"
    if [ "$SKIP_CONFIRM" = true ]; then
        return 0
    fi
    printf "\n%b%s [y/N]: %b" "$BOLD" "$prompt" "$NC" >&2
    read -r answer
    [[ "$answer" == "y" || "$answer" == "Y" ]]
}

prompt_input() {
    local prompt_text="$1"
    local default_val="$2"
    local user_val

    if [ -n "$default_val" ]; then
        printf "%b%s [%s]: %b" "$BOLD" "$prompt_text" "$default_val" "$NC" >&2
    else
        printf "%b%s: %b" "$BOLD" "$prompt_text" "$NC" >&2
    fi

    read -r user_val
    if [ -z "$user_val" ]; then
        echo "$default_val"
    else
        echo "$user_val"
    fi
}

prompt_secret() {
    local prompt_text="$1"
    local user_val
    printf "%b%s: %b" "$BOLD" "$prompt_text" "$NC" >&2
    read -rs user_val
    echo "" >&2
    echo "$user_val"
}

prompt_select() {
    local prompt_text="$1"
    shift
    local options=("$@")

    echo "" >&2
    printf "%b%s%b\n" "$BOLD" "$prompt_text" "$NC" >&2
    for i in "${!options[@]}"; do
        printf "  %b%d)%b %s\n" "$CYAN" "$((i + 1))" "$NC" "${options[$i]}" >&2
    done
    printf "%bChoice [1]: %b" "$BOLD" "$NC" >&2
    read -r choice

    if [ -z "$choice" ]; then
        choice=1
    fi

    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#options[@]}" ]; then
        echo "${options[$((choice - 1))]}"
    else
        echo "${options[0]}"
    fi
}

detect_pkg_manager() {
    if command -v brew >/dev/null 2>&1; then echo "brew"; return; fi
    if command -v apt-get >/dev/null 2>&1; then echo "apt"; return; fi
    if command -v dnf >/dev/null 2>&1; then echo "dnf"; return; fi
    if command -v yum >/dev/null 2>&1; then echo "yum"; return; fi
}

install_package() {
    local manager="$1"
    local pkg="$2"
    log_info "Installing $pkg via $manager..."

    case "$manager" in
        brew) brew install "$pkg" ;;
        apt) sudo apt-get update && sudo apt-get install -y "$pkg" ;;
        dnf) sudo dnf install -y "$pkg" ;;
        yum) sudo yum install -y "$pkg" ;;
        *) return 1 ;;
    esac
}

require_command() {
    local cmd="$1"
    local pkg="${2:-$1}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_warn "Missing dependency: $cmd"
        local manager
        manager=$(detect_pkg_manager)
        if [ -n "$manager" ]; then
            if ask_yes_no "Install '$pkg' using $manager?"; then
                install_package "$manager" "$pkg" || true
            fi
        else
            log_error "No package manager found. Install '$pkg' manually."
        fi

        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "Command '$cmd' still not found. Exiting."
            exit 1
        fi
    fi
}

# ==============================================================================
#  Config Management
# ==============================================================================

load_config() {
    if [ -f "$CONFIG_FILE" ]; then
        # shellcheck source=/dev/null
        while IFS='=' read -r key value; do
            # Skip comments and empty lines
            [[ "$key" =~ ^#.*$ || -z "$key" ]] && continue
            # Trim whitespace
            key=$(echo "$key" | xargs)
            value=$(echo "$value" | xargs)
            case "$key" in
                provider)      [ -z "$PROVIDER" ] && PROVIDER="$value" ;;
                api_key)       [ -z "$API_KEY" ] && API_KEY="$value" ;;
                model)         [ -z "$MODEL" ] && MODEL="$value" ;;
                max_tokens)    MAX_TOKENS="$value" ;;
                auto_stage)    [ "$AUTO_STAGE" = false ] && AUTO_STAGE="$value" ;;
                auto_push)     [ "$AUTO_PUSH" = false ] && AUTO_PUSH="$value" ;;
                language)      [ -z "$LANGUAGE" ] && LANGUAGE="$value" ;;
                conventional)  [ "$CONVENTIONAL" = false ] && CONVENTIONAL="$value" ;;
                emoji)         [ "$EMOJI" = false ] && EMOJI="$value" ;;
            esac
        done < "$CONFIG_FILE"
    fi

    # Env var fallbacks for API key (only for API-based providers)
    if [ -z "$API_KEY" ]; then
        case "$PROVIDER" in
            anthropic)  API_KEY="${ANTHROPIC_API_KEY:-}" ;;
            openai)     API_KEY="${OPENAI_API_KEY:-}" ;;
            gemini)     API_KEY="${GEMINI_API_KEY:-${GOOGLE_API_KEY:-}}" ;;
            mistral)    API_KEY="${MISTRAL_API_KEY:-}" ;;
        esac
    fi
}

save_config() {
    mkdir -p "$CONFIG_DIR"
    cat > "$CONFIG_FILE" << EOF
# git-pilot configuration
provider=$PROVIDER
api_key=$API_KEY
model=$MODEL
max_tokens=$MAX_TOKENS
auto_stage=$AUTO_STAGE
auto_push=$AUTO_PUSH
language=$LANGUAGE
conventional=$CONVENTIONAL
emoji=$EMOJI
EOF
    chmod 600 "$CONFIG_FILE"
    log_success "Configuration saved to $CONFIG_FILE"
}

get_default_model() {
    local p="$1"
    case "$p" in
        claude-code) echo "haiku" ;;
        codex)       echo "gpt-5-mini" ;;
        anthropic)   echo "claude-haiku-4-5" ;;
        openai)      echo "gpt-5-mini" ;;
        gemini)      echo "gemini-2.5-flash-lite" ;;
        mistral)     echo "mistral-small-latest" ;;
        *)           echo "" ;;
    esac
}

# Check if provider is CLI-based (no API key needed)
is_cli_provider() {
    local p="$1"
    case "$p" in
        claude-code|codex) return 0 ;;
        *) return 1 ;;
    esac
}

# ==============================================================================
#  Setup Wizard
# ==============================================================================

run_setup() {
    print_banner
    log_info "Configuration Wizard"
    echo ""

    # Provider
    PROVIDER=$(prompt_select "Choose your AI provider:" "claude-code" "codex" "anthropic" "openai" "gemini" "mistral")
    log_info "Provider: $PROVIDER"

    if is_cli_provider "$PROVIDER"; then
        # CLI-based provider — check CLI is installed
        local cli_cmd
        case "$PROVIDER" in
            claude-code) cli_cmd="claude" ;;
            codex)       cli_cmd="codex" ;;
        esac
        if command -v "$cli_cmd" >/dev/null 2>&1; then
            log_success "$cli_cmd CLI found!"
        else
            log_warn "$cli_cmd CLI not found. Install it before using git-pilot."
        fi
        API_KEY=""
        MODEL=""
    else
        # API-based provider — need key + model
        API_KEY=$(prompt_secret "Enter your API key")
        if [ -z "$API_KEY" ]; then
            log_error "API key is required for $PROVIDER."
            exit 1
        fi

        local default_model
        default_model=$(get_default_model "$PROVIDER")
        MODEL=$(prompt_input "Model" "$default_model")
    fi

    # Preferences
    echo ""
    log_info "Preferences"

    if ask_yes_no "Auto-stage all changes before commit?"; then
        AUTO_STAGE=true
    else
        AUTO_STAGE=false
    fi

    if ask_yes_no "Auto-push after commit?"; then
        AUTO_PUSH=true
    else
        AUTO_PUSH=false
    fi

    if ask_yes_no "Use Conventional Commits format?"; then
        CONVENTIONAL=true
    else
        CONVENTIONAL=false
    fi

    if ask_yes_no "Add emoji to commit messages?"; then
        EMOJI=true
    else
        EMOJI=false
    fi

    LANGUAGE=$(prompt_input "Commit message language" "en")

    # Test connection
    echo ""
    log_info "Testing connection..."
    local test_response
    test_response=$(call_ai_api "Say 'OK' if you can read this." 2>&1) || true
    if [ -n "$test_response" ] && [ "$test_response" != "null" ]; then
        log_success "Connection successful!"
    else
        log_warn "Could not verify connection. Configuration saved anyway."
    fi

    save_config
    echo ""
    log_success "Setup complete! Run 'git-pilot' in any git repo to start."
}

show_config() {
    load_config

    # Apply defaults for display
    local p="${PROVIDER:-claude-code}"
    local m="${MODEL:-$(get_default_model "$p")}"
    local l="${LANGUAGE:-en}"

    echo ""
    echo -e "${BOLD}git-pilot configuration${NC}"
    echo -e "${CYAN}─────────────────────────────────────${NC}"
    printf "  %-16s %s\n" "Provider:" "$p"
    printf "  %-16s %s\n" "Model:" "${m:-<provider default>}"
    if is_cli_provider "$p"; then
        printf "  %-16s %s\n" "API key:" "(not needed — CLI provider)"
    elif [ -n "$API_KEY" ]; then
        printf "  %-16s %s\n" "API key:" "${API_KEY:0:8}...${API_KEY: -4}"
    else
        printf "  %-16s %s\n" "API key:" "(not set)"
    fi
    printf "  %-16s %s\n" "Max tokens:" "$MAX_TOKENS"
    printf "  %-16s %s\n" "Language:" "$l"
    printf "  %-16s %s\n" "Auto-stage:" "$AUTO_STAGE"
    printf "  %-16s %s\n" "Auto-push:" "$AUTO_PUSH"
    printf "  %-16s %s\n" "Conventional:" "$CONVENTIONAL"
    printf "  %-16s %s\n" "Emoji:" "$EMOJI"
    echo -e "${CYAN}─────────────────────────────────────${NC}"
    printf "  %-16s %s\n" "Config file:" "$CONFIG_FILE"
    if [ -f "$CONFIG_FILE" ]; then
        printf "  %-16s %s\n" "Status:" "exists"
    else
        printf "  %-16s %s\n" "Status:" "not created yet (run 'git-pilot setup')"
    fi
    echo ""
}

# ==============================================================================
#  AI Providers (CLI + API)
# ==============================================================================

call_ai_api() {
    local prompt="$1"
    local response

    local spinner_msg="Thinking"
    [ -n "$MODEL" ] && spinner_msg="Thinking ($PROVIDER/$MODEL)"
    start_spinner "$spinner_msg..."

    case "$PROVIDER" in
        claude-code) response=$(call_claude_code "$prompt") || { stop_spinner; exit 1; } ;;
        codex)       response=$(call_codex_cli "$prompt")   || { stop_spinner; exit 1; } ;;
        anthropic)   response=$(call_anthropic "$prompt")   || { stop_spinner; exit 1; } ;;
        openai)      response=$(call_openai "$prompt" "$MODEL") || { stop_spinner; exit 1; } ;;
        gemini)      response=$(call_gemini "$prompt")      || { stop_spinner; exit 1; } ;;
        mistral)     response=$(call_mistral "$prompt")     || { stop_spinner; exit 1; } ;;
        *)
            stop_spinner
            log_error "Unknown provider: $PROVIDER"
            exit 1
            ;;
    esac

    stop_spinner

    if [ -z "$response" ]; then
        log_error "AI provider '$PROVIDER' returned empty response."
        exit 1
    fi

    echo "$response"
}

# --- CLI-based providers ---

call_claude_code() {
    local prompt="$1"
    local result
    local model_flag=""

    if [ -n "$MODEL" ]; then
        model_flag="--model $MODEL"
    fi

    # Unset CLAUDECODE to allow running inside Claude Code sessions
    # shellcheck disable=SC2086
    result=$(unset CLAUDECODE; claude -p "$prompt" $model_flag 2>/dev/null) || {
        log_error "Claude Code CLI failed. Is 'claude' installed and authenticated?"
        exit 1
    }

    if [ -z "$result" ]; then
        log_error "Claude Code returned empty response."
        exit 1
    fi

    echo "$result"
}

call_codex_cli() {
    local prompt="$1"
    local result
    local model_flag=""

    if [ -n "$MODEL" ]; then
        model_flag="--model $MODEL"
    fi

    # shellcheck disable=SC2086
    result=$(codex -q "$prompt" $model_flag 2>/dev/null) || {
        log_error "Codex CLI failed. Is 'codex' installed and authenticated?"
        exit 1
    }

    if [ -z "$result" ]; then
        log_error "Codex returned empty response."
        exit 1
    fi

    echo "$result"
}

# --- API-based providers ---

call_anthropic() {
    local prompt="$1"
    local body
    body=$(jq -n \
        --arg model "$MODEL" \
        --argjson max_tokens "$MAX_TOKENS" \
        --arg prompt "$prompt" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            messages: [{ role: "user", content: $prompt }]
        }')

    local result
    result=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -H "x-api-key: $API_KEY" \
        -H "anthropic-version: 2023-06-01" \
        -d "$body" \
        "https://api.anthropic.com/v1/messages")

    local http_code
    http_code=$(echo "$result" | tail -n1)
    local response_body
    response_body=$(echo "$result" | sed '$d')

    if [ "$http_code" -ne 200 ]; then
        local error_msg
        error_msg=$(echo "$response_body" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null)
        log_error "Anthropic API error ($http_code): $error_msg"
        exit 1
    fi

    echo "$response_body" | jq -r '.content[0].text'
}

call_openai() {
    local prompt="$1"
    local model="$2"
    local body
    body=$(jq -n \
        --arg model "$model" \
        --argjson max_tokens "$MAX_TOKENS" \
        --arg prompt "$prompt" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            messages: [{ role: "user", content: $prompt }]
        }')

    local result
    result=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$body" \
        "https://api.openai.com/v1/chat/completions")

    local http_code
    http_code=$(echo "$result" | tail -n1)
    local response_body
    response_body=$(echo "$result" | sed '$d')

    if [ "$http_code" -ne 200 ]; then
        local error_msg
        error_msg=$(echo "$response_body" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null)
        log_error "OpenAI API error ($http_code): $error_msg"
        exit 1
    fi

    echo "$response_body" | jq -r '.choices[0].message.content'
}

call_gemini() {
    local prompt="$1"
    local body
    body=$(jq -n \
        --arg prompt "$prompt" \
        '{
            contents: [{ parts: [{ text: $prompt }] }]
        }')

    local result
    result=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -d "$body" \
        "https://generativelanguage.googleapis.com/v1beta/models/${MODEL}:generateContent?key=${API_KEY}")

    local http_code
    http_code=$(echo "$result" | tail -n1)
    local response_body
    response_body=$(echo "$result" | sed '$d')

    if [ "$http_code" -ne 200 ]; then
        local error_msg
        error_msg=$(echo "$response_body" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null)
        log_error "Gemini API error ($http_code): $error_msg"
        exit 1
    fi

    echo "$response_body" | jq -r '.candidates[0].content.parts[0].text'
}

call_mistral() {
    local prompt="$1"
    local body
    body=$(jq -n \
        --arg model "$MODEL" \
        --argjson max_tokens "$MAX_TOKENS" \
        --arg prompt "$prompt" \
        '{
            model: $model,
            max_tokens: $max_tokens,
            messages: [{ role: "user", content: $prompt }]
        }')

    local result
    result=$(curl -s -w "\n%{http_code}" \
        -H "Content-Type: application/json" \
        -H "Authorization: Bearer $API_KEY" \
        -d "$body" \
        "https://api.mistral.ai/v1/chat/completions")

    local http_code
    http_code=$(echo "$result" | tail -n1)
    local response_body
    response_body=$(echo "$result" | sed '$d')

    if [ "$http_code" -ne 200 ]; then
        local error_msg
        error_msg=$(echo "$response_body" | jq -r '.error.message // .error // "Unknown error"' 2>/dev/null)
        log_error "Mistral API error ($http_code): $error_msg"
        exit 1
    fi

    echo "$response_body" | jq -r '.choices[0].message.content'
}

# ==============================================================================
#  Git Operations
# ==============================================================================

check_git_repo() {
    if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        log_error "Not inside a git repository."
        exit 1
    fi
}

get_staged_diff() {
    if [ "$AUTO_STAGE" = true ]; then
        git add -A
        log_info "Staged all changes."
    fi

    local diff
    diff=$(git diff --cached)

    if [ -z "$diff" ]; then
        log_error "No staged changes found. Stage your changes with 'git add' or use --auto-stage."
        exit 1
    fi

    echo "$diff"
}

get_diff_budget() {
    # Max chars budget for diff context sent to the AI
    # 16K chars ≈ ~4K tokens — costs < $0.01 even on the priciest provider
    echo 16000
}

truncate_diff() {
    local diff="$1"
    local budget
    budget=$(get_diff_budget)
    local length=${#diff}

    # Fits in budget — send as-is
    if [ "$length" -le "$budget" ]; then
        echo "$diff"
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
    trap 'rm -rf "$tmpdir"' RETURN

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
            result="${result}${chunk}"
            used=$((used + chunk_len))
        else
            skipped=$((skipped + 1))
        fi
    done < <(find "$tmpdir" -type f -exec wc -c {} + | grep -v total | sort -n | awk '{print $2}')

    # If we got nothing (single huge file), fall back to raw truncation
    if [ -z "$result" ]; then
        result="${diff:0:$available}"
        skipped=1
    fi

    if [ "$skipped" -gt 0 ]; then
        footer=$'\n\n'"[... ${skipped} large file(s) omitted — ${length} chars total]"
    fi

    echo "${header}${result}${footer}"
}

build_commit_prompt() {
    local diff="$1"
    local prompt="You are a git commit message generator. Based on the following diff, write a commit message with a title and a description."

    if [ "$CONVENTIONAL" = true ]; then
        prompt="$prompt Use Conventional Commits format (e.g. feat:, fix:, docs:, refactor:, chore:)."
    fi

    if [ "$EMOJI" = true ]; then
        prompt="$prompt Include a relevant emoji at the start of the title."
    fi

    if [ -n "$LANGUAGE" ] && [ "$LANGUAGE" != "en" ]; then
        prompt="$prompt Write the commit message in $LANGUAGE."
    fi

    prompt="$prompt

Rules:
- Output ONLY the commit message, nothing else
- Line 1: short summary title, max 72 characters, imperative mood
- Line 2: blank
- Lines 3+: description explaining WHAT changed and WHY (2-5 bullet points starting with -)
- Keep each bullet concise (one line)
- Do not wrap the message in quotes or backticks

Diff:
$diff"

    echo "$prompt"
}

generate_commit_message() {
    local diff
    diff=$(get_staged_diff)

    local truncated_diff
    truncated_diff=$(truncate_diff "$diff")

    local prompt
    prompt=$(build_commit_prompt "$truncated_diff")

    local provider_label="$PROVIDER"
    [ -n "$MODEL" ] && provider_label="$PROVIDER ($MODEL)"
    log_info "Generating commit message with $provider_label..."
    local message
    message=$(call_ai_api "$prompt") || return 1

    # Clean up: remove surrounding quotes/backticks if present
    message=$(echo "$message" | sed 's/^[`"'"'"']*//;s/[`"'"'"']*$//')

    echo "$message"
}

do_commit() {
    check_git_repo

    local message
    message=$(generate_commit_message) || exit 1

    if [ -z "$message" ]; then
        log_error "Failed to generate commit message."
        exit 1
    fi

    echo ""
    echo -e "${BOLD}Proposed commit message:${NC}"
    echo -e "${GREEN}─────────────────────────────────────${NC}"
    echo "$message"
    echo -e "${GREEN}─────────────────────────────────────${NC}"
    echo ""

    if [ "$DRY_RUN" = true ]; then
        log_info "Dry run — no commit created."
        return 0
    fi

    if ask_yes_no "Commit with this message?"; then
        git commit -m "$message"
        log_success "Committed!"

        if [ "$AUTO_PUSH" = true ]; then
            log_info "Pushing..."
            git push
            log_success "Pushed!"
        fi
    else
        log_info "Commit cancelled."
    fi
}

resolve_conflicts() {
    check_git_repo

    local conflict_files
    conflict_files=$(git diff --name-only --diff-filter=U)

    if [ -z "$conflict_files" ]; then
        log_info "No merge conflicts found."
        return 0
    fi

    local count
    count=$(echo "$conflict_files" | wc -l | xargs)
    log_info "Found $count file(s) with conflicts."

    echo "$conflict_files" | while IFS= read -r file; do
        log_info "Resolving: $file"

        local content
        content=$(cat "$file")
        local prompt="You are resolving a git merge conflict. Below is the file content with conflict markers (<<<<<<<, =======, >>>>>>>).

Resolve the conflict by choosing the best combination of both sides. Output ONLY the resolved file content, nothing else. No explanations, no markdown fences.

File: $file
Content:
$content"

        local resolved
        resolved=$(call_ai_api "$prompt") || { log_error "Failed to resolve: $file"; continue; }

        if [ -n "$resolved" ] && [ "$resolved" != "null" ]; then
            echo ""
            echo -e "${BOLD}Resolved $file:${NC}"
            echo -e "${GREEN}─────────────────────────────────────${NC}"
            echo "$resolved" | head -20
            if [ "$(echo "$resolved" | wc -l)" -gt 20 ]; then
                echo "  ... ($(echo "$resolved" | wc -l) lines total)"
            fi
            echo -e "${GREEN}─────────────────────────────────────${NC}"

            if ask_yes_no "Apply this resolution to $file?"; then
                echo "$resolved" > "$file"
                git add "$file"
                log_success "Resolved and staged: $file"
            else
                log_warn "Skipped: $file"
            fi
        else
            log_error "Failed to resolve: $file"
        fi
    done

    # Check if any conflicts remain
    local remaining
    remaining=$(git diff --name-only --diff-filter=U)
    if [ -z "$remaining" ]; then
        log_success "All conflicts resolved!"
    else
        log_warn "Some conflicts remain: $remaining"
    fi
}

do_pull_rebase() {
    check_git_repo

    log_info "Pulling with rebase..."

    if git pull --rebase 2>/dev/null; then
        log_success "Rebase completed successfully — no conflicts."
        return 0
    fi

    log_warn "Conflicts detected during rebase. Resolving with AI..."

    local max_iterations=10
    local iteration=0

    while [ $iteration -lt $max_iterations ]; do
        iteration=$((iteration + 1))

        local conflict_files
        conflict_files=$(git diff --name-only --diff-filter=U)

        if [ -z "$conflict_files" ]; then
            break
        fi

        log_info "Rebase iteration $iteration — resolving conflicts..."
        resolve_conflicts

        # Check if all resolved
        local remaining
        remaining=$(git diff --name-only --diff-filter=U)
        if [ -n "$remaining" ]; then
            log_error "Unresolved conflicts remain. Aborting rebase."
            git rebase --abort
            exit 1
        fi

        if ! git rebase --continue 2>/dev/null; then
            # More conflicts in next commit
            continue
        else
            break
        fi
    done

    if [ $iteration -ge $max_iterations ]; then
        log_error "Too many rebase iterations. Aborting."
        git rebase --abort
        exit 1
    fi

    log_success "Rebase completed with AI conflict resolution!"
}

# ==============================================================================
#  Argument Parsing
# ==============================================================================

# Check for command as first argument
if [ $# -gt 0 ]; then
    case "$1" in
        setup|config|commit|resolve|rebase)
            ACTION="$1"
            shift
            ;;
    esac
fi

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -p|--provider)
            PROVIDER="$2"
            shift; shift
            ;;
        -m|--model)
            MODEL="$2"
            shift; shift
            ;;
        --api-key)
            API_KEY="$2"
            shift; shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -a|--auto-stage)
            AUTO_STAGE=true
            shift
            ;;
        --auto-push|-P)
            AUTO_PUSH=true
            shift
            ;;
        -c|--conventional)
            CONVENTIONAL=true
            shift
            ;;
        -e|--emoji)
            EMOJI=true
            shift
            ;;
        -l|--lang)
            LANGUAGE="$2"
            shift; shift
            ;;
        --resolve)
            ACTION="resolve"
            shift
            ;;
        --rebase)
            ACTION="rebase"
            shift
            ;;
        --setup)
            ACTION="setup"
            shift
            ;;
        -y|--yes)
            SKIP_CONFIRM=true
            shift
            ;;
        -v|--version)
            echo "git-pilot v$VERSION"
            exit 0
            ;;
        -h|--help)
            print_banner
            print_usage
            exit 0
            ;;
        *)
            log_error "Unknown argument: $1"
            print_usage
            exit 1
            ;;
    esac
done

# ==============================================================================
#  Main Flow
# ==============================================================================

# Setup and config don't need git repo or full API config
if [ "$ACTION" = "setup" ]; then
    run_setup
    exit 0
fi

if [ "$ACTION" = "config" ]; then
    show_config
    exit 0
fi

# Load config
load_config

# Default provider
if [ -z "$PROVIDER" ]; then
    PROVIDER="claude-code"
fi

# Default model per provider
if [ -z "$MODEL" ]; then
    MODEL=$(get_default_model "$PROVIDER")
fi

# Default language
if [ -z "$LANGUAGE" ]; then
    LANGUAGE="en"
fi

# Check dependencies
require_command git

if is_cli_provider "$PROVIDER"; then
    # CLI-based: check the CLI tool is installed
    case "$PROVIDER" in
        claude-code) require_command claude "claude-code" ;;
        codex)       require_command codex "codex" ;;
    esac
else
    # API-based: need curl + jq + API key
    require_command curl
    require_command jq
    if [ -z "$API_KEY" ]; then
        log_error "No API key configured for $PROVIDER. Run 'git-pilot setup' or set --api-key / environment variable."
        log_info "Environment variables: ANTHROPIC_API_KEY, OPENAI_API_KEY, GEMINI_API_KEY, MISTRAL_API_KEY"
        exit 1
    fi
fi

# Route action
case "$ACTION" in
    commit)   do_commit ;;
    resolve)  resolve_conflicts ;;
    rebase)   do_pull_rebase ;;
    *)
        log_error "Unknown action: $ACTION"
        exit 1
        ;;
esac
