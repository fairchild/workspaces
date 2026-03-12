#!/bin/bash
# SwiftBar/xbar plugin: shows self-hosted GitHub Actions runner status in the menu bar.
# Install: run scripts/install-runner-ci-menubar.sh
# Refresh: every 5 seconds (from filename)

set -euo pipefail

RUNNER_DIRS=(
    "$HOME/.local/share/actions-runner-workspaces"
    "$HOME/.local/share/actions-runner"
    "$HOME/.local/share/actions-runner-code-cadence"
)
LOG="$HOME/.local/share/runner-activity.log"

resolve_real_script() {
    local source="$1"
    if [[ ! -L "$source" ]]; then
        printf '%s\n' "$source"
        return
    fi

    local target=""
    target="$(readlink "$source" 2>/dev/null || true)"
    if [[ -z "$target" ]]; then
        printf '%s\n' "$source"
        return
    fi

    if [[ "$target" == /* ]]; then
        printf '%s\n' "$target"
        return
    fi

    printf '%s\n' "$(cd "$(dirname "$source")" && cd "$(dirname "$target")" && pwd)/$(basename "$target")"
}

resolve_status_script() {
    local plugin_dir=""
    plugin_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

    local installed_sidecar="$plugin_dir/.runner-ci-menubar/runner-status.sh"
    if [[ -x "$installed_sidecar" ]]; then
        printf '%s\n' "$installed_sidecar"
        return
    fi

    local real_script=""
    real_script="$(resolve_real_script "$0")"
    local repo_sidecar=""
    repo_sidecar="$(cd "$(dirname "$real_script")" && pwd)/runner-status.sh"
    if [[ -x "$repo_sidecar" ]]; then
        printf '%s\n' "$repo_sidecar"
        return
    fi

    return 1
}

total=0
running=0
offline=0
job_details=()

for dir in "${RUNNER_DIRS[@]}"; do
    [[ -f "$dir/.runner" ]] || continue
    total=$((total + 1))

    name="$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1],'rb').read().decode('utf-8-sig')); print(d['agentName'])" "$dir/.runner" 2>/dev/null || echo "${dir##*/}")"
    repo="$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1],'rb').read().decode('utf-8-sig')); print(d['gitHubUrl'].split('/')[-1])" "$dir/.runner" 2>/dev/null || echo "?")"

    listener="$(pgrep -f "$dir/.*Runner.Listener" 2>/dev/null || true)"
    if [[ -z "$listener" ]]; then
        offline=$((offline + 1))
        job_details+=("$name ($repo)|color=red" "-- offline|color=#888888")
        continue
    fi

    worker="$(pgrep -f "$dir/.*Runner.Worker" 2>/dev/null || true)"
    if [[ -n "$worker" ]]; then
        running=$((running + 1))
        job_name="$(grep "Running job:" "$dir/_diag"/Runner_*.log 2>/dev/null | tail -1 | sed 's/.*Running job: //' || echo "?")"
        job_details+=("$name ($repo)|color=orange" "-- $job_name|color=orange")
    else
        job_details+=("$name ($repo)|color=green" "-- idle|color=#888888")
    fi
done

# Menu bar title line
if [[ $running -gt 0 ]]; then
    echo "CI:$running | color=orange sfimage=hammer.fill"
elif [[ $offline -gt 0 ]]; then
    echo "CI | color=red sfimage=exclamationmark.triangle"
else
    echo "CI | color=#888888 sfimage=checkmark.circle"
fi

echo "---"

# Runner details
for line in "${job_details[@]}"; do
    echo "$line"
done

echo "---"

# Recent activity from log
if [[ -f "$LOG" ]]; then
    echo "Recent Activity"
    tail -8 "$LOG" | while IFS= read -r line; do
        echo "-- $line | font=Menlo size=11"
    done
else
    echo "No activity log yet | color=#888888"
    echo "-- Install runner hooks to enable | color=#888888"
fi

echo "---"
echo "Refresh | refresh=true"
STATUS_SCRIPT="$(resolve_status_script || true)"
if [[ -n "$STATUS_SCRIPT" ]]; then
    echo "Open runner-status.sh | bash='$STATUS_SCRIPT' terminal=true"
else
    echo "runner-status.sh not installed | color=#888888"
fi
