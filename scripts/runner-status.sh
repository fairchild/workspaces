#!/bin/bash
# Show GitHub Actions self-hosted runner activity on this machine.
# Usage: ./scripts/runner-status.sh          # snapshot
#        ./scripts/runner-status.sh --watch  # live tail

set -euo pipefail

RUNNER_DIRS=(
    "$HOME/.local/share/actions-runner-workspaces"
    "$HOME/.local/share/actions-runner"
    "$HOME/.local/share/actions-runner-code-cadence"
)

bold="\033[1m"
dim="\033[2m"
green="\033[32m"
yellow="\033[33m"
red="\033[31m"
reset="\033[0m"

print_status() {
    printf "\n${bold}=== Self-Hosted Runner Status ===${reset}\n\n"

    for dir in "${RUNNER_DIRS[@]}"; do
        [[ -f "$dir/.runner" ]] || continue

        local name repo
        name="$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1],'rb').read().decode('utf-8-sig')); print(d['agentName'])" "$dir/.runner" 2>/dev/null || echo "${dir##*/}")"
        repo="$(python3 -c "import json,sys; d=json.loads(open(sys.argv[1],'rb').read().decode('utf-8-sig')); print(d['gitHubUrl'].split('/')[-1])" "$dir/.runner" 2>/dev/null || echo "?")"

        # Check if the runner listener is alive
        local listener_pid
        listener_pid="$(pgrep -f "$dir/bin/Runner.Listener" 2>/dev/null || true)"

        if [[ -z "$listener_pid" ]]; then
            printf "${red}●${reset} ${bold}%-24s${reset} ${dim}(%s)${reset}  offline\n" "$name" "$repo"
            continue
        fi

        # Check if a worker is currently active (= job running)
        local worker_pid
        worker_pid="$(pgrep -f "$dir/bin/Runner.Worker" 2>/dev/null || true)"

        if [[ -n "$worker_pid" ]]; then
            # Find the job name from the runner log
            local job_name
            job_name="$(grep "Running job:" "$dir/_diag"/Runner_*.log 2>/dev/null | tail -1 | sed 's/.*Running job: //' || echo "unknown")"
            printf "${yellow}◆${reset} ${bold}%-24s${reset} ${dim}(%s)${reset}  ${yellow}running:${reset} %s\n" "$name" "$repo" "$job_name"
        else
            printf "${green}●${reset} ${bold}%-24s${reset} ${dim}(%s)${reset}  idle\n" "$name" "$repo"
        fi
    done

    # Show running WorkspaceManager app processes (not compilers, not subprocesses)
    local wm_procs
    wm_procs="$(ps -axo pid=,command= | grep -E '/[W]orkspaceManager( |$)' | grep -v 'swift\|swiftpm\|lume\|xctest\|Runner\|grep' || true)"

    if [[ -n "$wm_procs" ]]; then
        printf "\n${bold}WorkspaceManager processes:${reset}\n"
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            local pid cmd
            pid="$(echo "$line" | awk '{print $1}')"
            cmd="$(echo "$line" | awk '{$1=""; print $0}' | sed 's/^ //')"

            if echo "$cmd" | grep -q '/Applications/'; then
                printf "  pid=%-6s ${green}installed app${reset}\n" "$pid"
            elif echo "$cmd" | grep -q '\.build/'; then
                local path_hint
                path_hint="$(echo "$cmd" | grep -oE '[^/]+/\.build' | head -1 | sed 's/\/.build//')"
                printf "  pid=%-6s ${bold}dev build${reset} ${dim}(%s)${reset}\n" "$pid" "$path_hint"
            else
                printf "  pid=%-6s %s\n" "$pid" "$cmd"
            fi
        done <<< "$wm_procs"
    fi

    # Recent jobs on the workspaces runner (last 5)
    local runner_log
    runner_log="$(ls -t "$HOME/.local/share/actions-runner-workspaces/_diag"/Runner_*.log 2>/dev/null | head -1)"
    if [[ -n "$runner_log" ]]; then
        printf "\n${bold}Recent workspaces runner jobs:${reset}\n"
        grep "WRITE LINE.*Running job:" "$runner_log" 2>/dev/null | tail -5 | while IFS= read -r line; do
            local ts job
            ts="$(echo "$line" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}Z' | head -1)"
            job="$(echo "$line" | sed 's/.*Running job: //')"
            printf "  ${dim}%s${reset}  %s\n" "$ts" "$job"
        done
    fi

    printf "\n"
}

if [[ "${1:-}" == "--watch" ]]; then
    while true; do
        clear
        print_status
        printf "${dim}Refreshing every 5s... (Ctrl+C to stop)${reset}\n"
        sleep 5
    done
else
    print_status
fi
