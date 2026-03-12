#!/bin/bash
# Install CI notification hooks on all self-hosted GitHub Actions runners.
# Copies hook scripts to each runner's hooks/ dir and adds env vars to .env.
# Runners must be restarted to pick up .env changes.
#
# Usage: ./scripts/install-runner-hooks.sh [--dry-run]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

RUNNER_DIRS=(
    "$HOME/.local/share/actions-runner-workspaces"
    "$HOME/.local/share/actions-runner"
    "$HOME/.local/share/actions-runner-code-cadence"
)

log() { echo "[install-runner-hooks] $*"; }

for dir in "${RUNNER_DIRS[@]}"; do
    [[ -f "$dir/.runner" ]] || continue

    name="$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1],'rb').read().decode('utf-8-sig')); print(d['agentName'])" "$dir/.runner" 2>/dev/null || echo "${dir##*/}")"
    hooks_dir="$dir/hooks"

    log "Runner: $name ($dir)"

    if [[ "$DRY_RUN" == true ]]; then
        log "  [dry-run] would create $hooks_dir/"
        log "  [dry-run] would copy notify-start.sh, notify-complete.sh"
        log "  [dry-run] would add ACTIONS_RUNNER_HOOK_JOB_STARTED to .env"
        log "  [dry-run] would add ACTIONS_RUNNER_HOOK_JOB_COMPLETED to .env"
        continue
    fi

    mkdir -p "$hooks_dir"
    cp "$SCRIPT_DIR/runner-notify-start.sh" "$hooks_dir/notify-start.sh"
    cp "$SCRIPT_DIR/runner-notify-complete.sh" "$hooks_dir/notify-complete.sh"
    chmod +x "$hooks_dir/notify-start.sh" "$hooks_dir/notify-complete.sh"
    log "  Copied hooks to $hooks_dir/"

    env_file="$dir/.env"
    touch "$env_file"

    add_env() {
        local key="$1" val="$2"
        if grep -q "^${key}=" "$env_file" 2>/dev/null; then
            log "  $key already set in .env (skipping)"
        else
            echo "${key}=${val}" >> "$env_file"
            log "  Added $key to .env"
        fi
    }

    add_env "ACTIONS_RUNNER_HOOK_JOB_STARTED" "$hooks_dir/notify-start.sh"
    add_env "ACTIONS_RUNNER_HOOK_JOB_COMPLETED" "$hooks_dir/notify-complete.sh"
done

log ""
log "Done. Restart runners to pick up changes:"
for dir in "${RUNNER_DIRS[@]}"; do
    [[ -f "$dir/.runner" ]] || continue
    name="$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1],'rb').read().decode('utf-8-sig')); print(d['agentName'])" "$dir/.runner" 2>/dev/null || echo "${dir##*/}")"
    log "  $name: cd $dir && ./run.sh"
done
