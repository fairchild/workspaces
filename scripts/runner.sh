#!/bin/bash
set -euo pipefail

# macOS GitHub Actions Runner Management Script
# Handles setup, start, stop, and status for on-demand self-hosted runners

RUNNER_DIR="${RUNNER_DIR:-${HOME}/.local/share/actions-runner-workspaces}"
RUNNER_VERSION="${RUNNER_VERSION:-2.332.0}"
GITHUB_ORG="${GITHUB_ORG:-fairchild}"
GITHUB_REPO="${GITHUB_REPO:-workspaces}"
RUNNER_NAME="${RUNNER_NAME:-$(hostname -s)-workspaces}"
RUNNER_LABELS="${RUNNER_LABELS:-self-hosted-macos,macos,$(uname -m)}"
RUNNER_REGISTRATION_TOKEN="${RUNNER_REGISTRATION_TOKEN:-}"

# Config file for GitHub App credentials
CONFIG_DIR="${CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/github-runner}"
CONFIG_FILE="${CONFIG_FILE:-${CONFIG_DIR}/config}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info() { echo -e "${GREEN}[INFO]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

check_dependencies() {
    local missing=()
    for cmd in curl; do
        if ! command -v "$cmd" &>/dev/null; then
            missing+=("$cmd")
        fi
    done

    if [ -z "${RUNNER_REGISTRATION_TOKEN}" ]; then
        for cmd in jq openssl; do
            if ! command -v "$cmd" &>/dev/null; then
                missing+=("$cmd")
            fi
        done
    fi

    if [ ${#missing[@]} -ne 0 ]; then
        log_error "Missing dependencies: ${missing[*]}"
        log_info "Install with: brew install ${missing[*]}"
        exit 1
    fi
}

load_config() {
    if [ ! -f "$CONFIG_FILE" ]; then
        log_error "Config file not found: $CONFIG_FILE"
        log_info "Create it with:"
        log_info "  mkdir -p $CONFIG_DIR"
        log_info "  cat > $CONFIG_FILE << 'EOF'"
        log_info "GITHUB_APP_ID=your_app_id"
        log_info "GITHUB_APP_INSTALLATION_ID=your_installation_id"
        log_info "GITHUB_APP_PRIVATE_KEY_PATH=/path/to/private-key.pem"
        log_info "EOF"
        exit 1
    fi
    source "$CONFIG_FILE"

    if [ -z "${GITHUB_APP_ID:-}" ] || [ -z "${GITHUB_APP_INSTALLATION_ID:-}" ] || [ -z "${GITHUB_APP_PRIVATE_KEY_PATH:-}" ]; then
        log_error "Missing required config variables"
        exit 1
    fi

    if [ ! -f "$GITHUB_APP_PRIVATE_KEY_PATH" ]; then
        log_error "Private key file not found: $GITHUB_APP_PRIVATE_KEY_PATH"
        exit 1
    fi
}

generate_jwt() {
    local now header payload signature
    now=$(date +%s)

    header=$(echo -n '{"alg":"RS256","typ":"JWT"}' | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')
    payload=$(echo -n "{\"iat\":$((now - 60)),\"exp\":$((now + 600)),\"iss\":\"$GITHUB_APP_ID\"}" | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')
    signature=$(echo -n "${header}.${payload}" | openssl dgst -sha256 -sign "$GITHUB_APP_PRIVATE_KEY_PATH" | openssl base64 -e | tr -d '\n=' | tr '+/' '-_')

    echo "${header}.${payload}.${signature}"
}

get_registration_token() {
    if [ -n "${RUNNER_REGISTRATION_TOKEN}" ]; then
        log_info "Using runner registration token from environment"
        echo "$RUNNER_REGISTRATION_TOKEN"
        return
    fi

    load_config

    log_info "Generating GitHub App JWT..."
    local jwt installation_token registration_token
    jwt=$(generate_jwt)

    log_info "Getting installation access token..."
    installation_token=$(curl -s -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $jwt" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/app/installations/${GITHUB_APP_INSTALLATION_ID}/access_tokens" | jq -r '.token')

    if [ "$installation_token" = "null" ] || [ -z "$installation_token" ]; then
        log_error "Failed to get installation access token"
        exit 1
    fi

    log_info "Getting runner registration token..."
    registration_token=$(curl -s -X POST \
        -H "Accept: application/vnd.github+json" \
        -H "Authorization: Bearer $installation_token" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "https://api.github.com/repos/${GITHUB_ORG}/${GITHUB_REPO}/actions/runners/registration-token" | jq -r '.token')

    if [ "$registration_token" = "null" ] || [ -z "$registration_token" ]; then
        log_error "Failed to get registration token"
        exit 1
    fi

    echo "$registration_token"
}

download_runner() {
    local arch runner_url
    arch=$(uname -m)

    case "$arch" in
        x86_64) arch="x64" ;;
        arm64) arch="arm64" ;;
        *) log_error "Unsupported architecture: $arch"; exit 1 ;;
    esac

    runner_url="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-osx-${arch}-${RUNNER_VERSION}.tar.gz"

    log_info "Downloading runner v${RUNNER_VERSION} for ${arch}..."
    mkdir -p "$RUNNER_DIR"
    curl -sL "$runner_url" | tar xz -C "$RUNNER_DIR"
}

cmd_setup() {
    check_dependencies

    if [ -f "${RUNNER_DIR}/.runner" ]; then
        log_warn "Runner already configured. Use 'stop' then 'setup --force' to reconfigure."
        exit 0
    fi

    if [ ! -f "${RUNNER_DIR}/config.sh" ]; then
        download_runner
    fi

    local token
    token=$(get_registration_token)

    log_info "Configuring runner..."
    cd "$RUNNER_DIR"
    ./config.sh \
        --url "https://github.com/${GITHUB_ORG}/${GITHUB_REPO}" \
        --token "$token" \
        --name "$RUNNER_NAME" \
        --labels "$RUNNER_LABELS" \
        --unattended \
        --replace

    log_info "Runner configured successfully!"
    log_info "Use './scripts/runner.sh start' to start the runner"
}

cmd_start() {
    if [ ! -f "${RUNNER_DIR}/.runner" ]; then
        log_error "Runner not configured. Run 'setup' first."
        exit 1
    fi

    if pgrep -f "${RUNNER_DIR}/bin/Runner.Listener" &>/dev/null; then
        log_warn "Runner is already running"
        exit 0
    fi

    log_info "Starting runner..."
    cd "$RUNNER_DIR"
    nohup ./run.sh > "${RUNNER_DIR}/runner.log" 2>&1 &

    sleep 2
    if pgrep -f "${RUNNER_DIR}/bin/Runner.Listener" &>/dev/null; then
        log_info "Runner started successfully (PID: $(pgrep -f "${RUNNER_DIR}/bin/Runner.Listener"))"
        log_info "Logs: ${RUNNER_DIR}/runner.log"
    else
        log_error "Failed to start runner. Check logs: ${RUNNER_DIR}/runner.log"
        exit 1
    fi
}

cmd_stop() {
    if ! pgrep -f "${RUNNER_DIR}/bin/Runner.Listener" &>/dev/null; then
        log_warn "Runner is not running"
        exit 0
    fi

    log_info "Stopping runner..."
    pkill -f "${RUNNER_DIR}/bin/Runner.Listener" || true
    pkill -f "${RUNNER_DIR}/bin/Runner.Worker" || true

    sleep 1
    if pgrep -f "${RUNNER_DIR}/bin/Runner.Listener" &>/dev/null; then
        log_warn "Runner still running, force killing..."
        pkill -9 -f "${RUNNER_DIR}/bin/Runner.Listener" || true
        pkill -9 -f "${RUNNER_DIR}/bin/Runner.Worker" || true
    fi

    log_info "Runner stopped"
}

cmd_status() {
    echo "Runner Directory: $RUNNER_DIR"
    echo "Runner Name: $RUNNER_NAME"
    echo "Labels: $RUNNER_LABELS"
    echo ""

    if [ -f "${RUNNER_DIR}/.runner" ]; then
        echo -e "Configuration: ${GREEN}Configured${NC}"
    else
        echo -e "Configuration: ${YELLOW}Not configured${NC}"
    fi

    if pgrep -f "${RUNNER_DIR}/bin/Runner.Listener" &>/dev/null; then
        local pid
        pid=$(pgrep -f "${RUNNER_DIR}/bin/Runner.Listener")
        echo -e "Status: ${GREEN}Running${NC} (PID: $pid)"
    else
        echo -e "Status: ${YELLOW}Stopped${NC}"
    fi
}

cmd_logs() {
    if [ -f "${RUNNER_DIR}/runner.log" ]; then
        tail -f "${RUNNER_DIR}/runner.log"
    else
        log_error "No log file found"
        exit 1
    fi
}

run_service_command() {
    local subcommand="$1"

    if [ ! -f "${RUNNER_DIR}/.runner" ]; then
        log_error "Runner not configured. Run 'setup' first."
        exit 1
    fi

    if [ ! -f "${RUNNER_DIR}/svc.sh" ]; then
        log_error "Runner service helper not found at ${RUNNER_DIR}/svc.sh"
        exit 1
    fi

    cd "$RUNNER_DIR"
    ./svc.sh "$subcommand"
}

cmd_service_install() {
    run_service_command install
}

cmd_service_start() {
    run_service_command start
}

cmd_service_stop() {
    run_service_command stop
}

cmd_service_status() {
    run_service_command status
}

cmd_help() {
    cat << EOF
GitHub Actions Runner Management Script (workspaces)

Usage: $0 <command>

Commands:
  setup            Configure the runner (downloads if needed, fetches token via GitHub App or RUNNER_REGISTRATION_TOKEN)
  start            Start the runner in background
  stop             Stop the running runner
  status           Show runner status
  logs             Tail the runner logs
  service-install  Install the runner as a user launchd service
  service-start    Start the launchd service
  service-stop     Stop the launchd service
  service-status   Show launchd service status
  help             Show this help message

Configuration:
  Uses shared config at ${CONFIG_FILE}
  Override with env vars such as RUNNER_DIR, RUNNER_NAME, RUNNER_LABELS,
  RUNNER_VERSION, GITHUB_ORG, GITHUB_REPO, and RUNNER_REGISTRATION_TOKEN.

Examples:
  $0 setup     # One-time setup
  $0 start     # Start runner
  $0 stop      # Stop when done
  $0 status    # Check if running
EOF
}

case "${1:-help}" in
    setup)            cmd_setup ;;
    start)            cmd_start ;;
    stop)             cmd_stop ;;
    status)           cmd_status ;;
    logs)             cmd_logs ;;
    service-install)  cmd_service_install ;;
    service-start)    cmd_service_start ;;
    service-stop)     cmd_service_stop ;;
    service-status)   cmd_service_status ;;
    help)             cmd_help ;;
    *)      log_error "Unknown command: $1"; cmd_help; exit 1 ;;
esac
