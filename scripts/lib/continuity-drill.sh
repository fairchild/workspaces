#!/usr/bin/env bash
# continuity-drill.sh — the holder-death matrix behind `continuity-evidence.sh --drill`,
# sourced by that script and sharing its globals and helpers (isolation, launch, kill).
# Each pass opens agent tiles on an isolated socket, kills the holder, relaunches, clicks
# the restored rows as a person would, and writes one summary row per tile from what the
# shells, panes, process table, local-state database and the app's own os_log show.

run_drill() {
    : >"$ROWS_PATH"
    build_products_once
    record_static_row all mixed_window "terminal mode is process-wide (TerminalMultiplexingMode.resolve) until S1b-1, so one window cannot hold tmux and Ghostty-split tiles together"
    local pass
    for pass in $(passes_to_run); do
        run_drill_pass "$pass"
    done
    SUMMARY_WRITTEN=true
    write_drill_summary "completed" ""
    log "Drill complete. Summary: $SUMMARY_PATH"
}

build_products_once() {
    if [[ "$NO_BUILD" == false ]]; then
        log "Building debug products once for every pass..."
        (cd "$REPO_ROOT" && swift build)
    fi
    WS_CLI="$(build_products_dir "$REPO_ROOT")/workspaces"
    [[ -x "$WS_CLI" ]] || fail "workspaces CLI not built at $WS_CLI"
    [[ "$WS_CLI" != *"'"* ]] || fail "the CLI path contains a single quote, which the tile command queue cannot carry: $WS_CLI"
}

record_static_row() {
    jq -nc --arg pass "$1" --arg tile "$2" --arg reason "$3" \
        '{pass: $pass, tile: $tile, drivable: false, status: "not_drivable", reason: $reason}' >>"$ROWS_PATH"
}

passes_to_run() {
    if [[ ${#SELECTED_PASSES[@]} -gt 0 ]]; then
        printf '%s\n' "${SELECTED_PASSES[@]}"
    else
        printf '%s\n' "${ALL_PASSES[@]}"
    fi
}

run_drill_pass() {
    PASS_ID="$1"
    describe_pass "$PASS_ID"
    PASS_DIR="$RUN_DIR/passes/$PASS_ID"
    WS_LAUNCH_PATH=""
    mkdir -p "$PASS_DIR"
    log "Pass $PASS_ID: mode=$PASS_MODE restore_flag=$PASS_FLAG kill_order=$PASS_KILL_ORDER"
    prepare_isolated_home "$SOCKET_LABEL-p$(pass_index "$PASS_ID")" "$PASS_MODE" "$PASS_FLAG"

    set_phase before
    launch_drill_app before
    wait_for_operator_scope
    wait_for_repo_id
    create_tiles
    wait_for_stub_starts
    snapshot_state before
    capture_window "$APP_PID" "$APP_WINDOW_ID" "$PASS_DIR/before-kill.png" || true
    capture_app_log before

    kill_holder "$PASS_KILL_ORDER" "$TMUX_LABEL" "$PASS_DIR"
    set_phase after
    launch_drill_app after
    wait_for_restore_executed
    click_restored_rows
    wait_for_restore_settle
    snapshot_state after
    capture_window "$APP_PID" "$APP_WINDOW_ID" "$PASS_DIR/after-relaunch.png" || true
    capture_app_log after
    record_pass_rows

    terminate_drill_app
    stop_isolated_server "$TMUX_LABEL"
}

describe_pass() {
    case "$1" in
        tmux-*) PASS_MODE="tmux_per_session" ;;
        ghostty-*) PASS_MODE="ghostty_managed_splits" ;;
    esac
    case "$1" in
        *-on*) PASS_FLAG="on" ;;
        *-off*) PASS_FLAG="off" ;;
    esac
    case "$1" in
        *-server) PASS_KILL_ORDER="server-first" ;;
        *) PASS_KILL_ORDER="app-first" ;;
    esac
}

set_phase() {
    printf '%s\n' "$1" >"$ISOLATED_HOME/.drill/phase"
}

launch_drill_app() {
    local phase="$1"
    local output="$PASS_DIR/launch-$phase.log"
    date '+%Y-%m-%d %H:%M:%S' >"$PASS_DIR/launch-$phase.started"
    launch_debug_app "$output" false true
    APP_PID="$(parse_launch_pid "$output")"
    APP_WINDOW_ID="$(parse_launch_window_id "$output")"
    APP_LOG="$(parse_launch_log_path "$output")"
    [[ -n "$APP_PID" && -n "$APP_LOG" ]] || fail "pass $PASS_ID: could not parse the $phase launch pid/log"
    printf '%s\n' "$APP_PID" >"$PASS_DIR/launch-$phase.pid"
}

drill_cli() {
    env -u TMUX -u TMUX_PANE "${ISOLATION_ENV[@]}" "$WS_CLI" "$@"
}

wait_for_operator_scope() {
    local waited=0
    until drill_cli automation workspace list --json >"$PASS_DIR/workspaces-initial.json" 2>"$PASS_DIR/operator-scope.err"; do
        ((waited < 30)) || fail "pass $PASS_ID: operator scope never answered (see $PASS_DIR/operator-scope.err)"
        sleep 1
        waited=$((waited + 1))
    done
}

wait_for_repo_id() {
    local waited=0
    REPO_ID=""
    while ((waited < 30)); do
        REPO_ID="$(app_repo_id)"
        [[ -z "$REPO_ID" ]] || return 0
        sleep 1
        waited=$((waited + 1))
    done
    fail "pass $PASS_ID: the app never imported the scratch repo $DRILL_REPO from its isolated ~/code"
}

app_repo_id() {
    drill_cli automation workspace list --json 2>/dev/null \
        | jq -r --arg path "$DRILL_REPO" '[.repos[] | select((.path | rtrimstr("/")) == $path) | .repoID][0] // empty'
}

app_workspace_id() {
    drill_cli automation workspace list --json 2>/dev/null \
        | jq -r --arg path "$1" '[.workspaces[] | select((.path | rtrimstr("/")) == $path) | .workspaceID][0] // empty'
}

create_tiles() {
    if [[ "$PASS_MODE" == tmux_per_session ]]; then
        create_ws_launch_tile
    else
        record_static_row "$PASS_ID" ws_launch "ws launch always starts a tmux session; in ghostty_managed_splits the app opens its own shell instead of attaching to it"
    fi
    queue_tile_commands
    drill_cli automation repo terminal "$REPO_ID" --json >"$PASS_DIR/repo-terminal-before.json"
    record_static_row "$PASS_ID" cmd_t_tab "no automation verb opens a tab (routes: tile split/focus/close, input write, workspace select/create, repo terminal); cmd+t needs desktop key input, which would take focus"
}

create_ws_launch_tile() {
    drill_cli repo add "$DRILL_REPO" >"$PASS_DIR/repo-add.log"
    drill_cli ws new drill-repo drill-launch --json >"$PASS_DIR/ws-new.json"
    local workspace_id
    workspace_id="$(jq -r '.workspaceID' "$PASS_DIR/ws-new.json")"
    WS_LAUNCH_PATH="$(cd "$(jq -r '.path' "$PASS_DIR/ws-new.json")" && pwd -P)"
    drill_cli ws launch "$workspace_id" --cmd "claude --effort high" --json >"$PASS_DIR/ws-launch.json"
    select_workspace_when_listed "$WS_LAUNCH_PATH" before \
        || fail "pass $PASS_ID: the app never listed the ws launch workspace $WS_LAUNCH_PATH"
}

select_workspace_when_listed() {
    local workspace_path="$1" phase="$2" waited=0 app_workspace_id=""
    while ((waited < 30)); do
        app_workspace_id="$(app_workspace_id "$workspace_path")"
        if [[ -n "$app_workspace_id" ]]; then
            drill_cli automation workspace select "$app_workspace_id" --json >"$PASS_DIR/workspace-select-$phase.json" 2>&1
            return
        fi
        sleep 1
        waited=$((waited + 1))
    done
    return 1
}

queue_tile_commands() {
    local queue split_log="\"\$HOME/.drill/observe/split-\$\$.log\""
    queue="$ISOLATED_HOME/.drill/autorun/${DRILL_REPO//[^A-Za-z0-9]/-}"
    mkdir -p "$queue"
    printf "'%s' automation tile split --right >>%s 2>&1 && '%s' automation tile split --down >>%s 2>&1 && claude --effort medium\n" \
        "$WS_CLI" "$split_log" "$WS_CLI" "$split_log" >"$queue/01.cmd"
    printf 'claude --effort low\n' >"$queue/02.cmd"
    printf 'STUB_AGENT_TURN=held claude --effort xhigh\n' >"$queue/03.cmd"
}

wait_for_stub_starts() {
    local expected=3 waited=0 started=0
    [[ "$PASS_MODE" != tmux_per_session ]] || expected=4
    while ((waited < TILE_TIMEOUT_SECONDS)); do
        started="$(stub_starts | jq -s 'length')"
        ((started < expected)) || return 0
        sleep 1
        waited=$((waited + 1))
    done
    log "pass $PASS_ID: only $started of $expected stub agents started within ${TILE_TIMEOUT_SECONDS}s; recording what exists"
}

stub_starts() {
    local ledger="$ISOLATED_HOME/.claude/stub-agent-ledger.jsonl"
    [[ -f "$ledger" ]] || return 0
    jq -c 'select(.event == "start" and .source == "startup")' "$ledger"
}

snapshot_state() {
    local phase="$1"
    local database
    database="$(find "$DATA_DIR" -name local-state.sqlite -print -quit 2>/dev/null)"
    if [[ -n "$database" ]]; then
        sqlite3 -readonly -json "$database" \
            "SELECT host_session_id, session_key, terminal_mode, tmux_session_name, directory_path,
                    is_active, ended_at, run_id FROM terminal_sessions ORDER BY created_at" \
            >"$PASS_DIR/db-$phase.json" 2>"$PASS_DIR/db-$phase.err" || true
        sqlite3 -readonly -json "$database" \
            "SELECT host_session_id, agent_session_id, origin, event_name, run_state, event_at
             FROM agent_status_events ORDER BY event_at" \
            >"$PASS_DIR/db-$phase-events.json" 2>>"$PASS_DIR/db-$phase.err" || true
    fi
    [[ -s "$PASS_DIR/db-$phase.json" ]] || echo '[]' >"$PASS_DIR/db-$phase.json"
    [[ -s "$PASS_DIR/db-$phase-events.json" ]] || echo '[]' >"$PASS_DIR/db-$phase-events.json"
    tmux -L "$TMUX_LABEL" list-panes -a \
        -F '#{session_id} #{session_name} #{pane_pid} #{pane_current_command} #{pane_current_path}' \
        >"$PASS_DIR/tmux-$phase.txt" 2>&1 || true
    capture_panes "$phase"
}

capture_panes() {
    local phase="$1" pane_id session
    mkdir -p "$PASS_DIR/panes-$phase"
    while read -r pane_id session; do
        [[ -n "$pane_id" ]] || continue
        tmux -L "$TMUX_LABEL" capture-pane -p -J -t "$pane_id" >"$PASS_DIR/panes-$phase/$session-${pane_id#%}.txt" 2>&1 || true
    done < <(tmux -L "$TMUX_LABEL" list-panes -a -F '#{pane_id} #{session_name}' 2>/dev/null || true)
}

capture_app_log() {
    local phase="$1"
    local pid started
    pid="$(cat "$PASS_DIR/launch-$phase.pid")"
    started="$(cat "$PASS_DIR/launch-$phase.started")"
    /usr/bin/log show --predicate "subsystem == \"com.cloudcompute.workspaces\" AND processID == $pid" \
        --start "$started" --info --style compact >"$PASS_DIR/app-$phase.oslog.txt" 2>&1 || true
    grep -E '\[(Restore|Reattach|SurfaceStore)\]|HostSession|resume' "$PASS_DIR/app-$phase.oslog.txt" \
        >"$PASS_DIR/$(restore_log_name "$phase")" || true
}

restore_log_name() {
    if [[ "$1" == after ]]; then
        echo "restore-log.txt"
    else
        echo "restore-log-$1.txt"
    fi
}

wait_for_restore_executed() {
    local waited=0 pid started
    if [[ "$PASS_FLAG" == off ]]; then
        sleep 8
        return 0
    fi
    pid="$(cat "$PASS_DIR/launch-after.pid")"
    started="$(cat "$PASS_DIR/launch-after.started")"
    while ((waited < 40)); do
        if /usr/bin/log show --predicate "subsystem == \"com.cloudcompute.workspaces\" AND processID == $pid" \
            --start "$started" --info --style compact 2>/dev/null \
            | grep -qE '\[Restore\] (executed|no restorable|suppressed banner)'; then
            sleep 2
            return 0
        fi
        sleep 2
        waited=$((waited + 2))
    done
    log "pass $PASS_ID: no [Restore] outcome line within 40s of relaunch"
}

click_restored_rows() {
    REPO_ID="$(app_repo_id)"
    [[ -z "$REPO_ID" ]] || drill_cli automation repo terminal "$REPO_ID" --json >"$PASS_DIR/repo-terminal-after.json" 2>&1 || true
    sleep 4
    capture_window "$APP_PID" "$APP_WINDOW_ID" "$PASS_DIR/after-relaunch-repo.png" || true
    [[ -z "$WS_LAUNCH_PATH" ]] || select_workspace_when_listed "$WS_LAUNCH_PATH" after || true
}

wait_for_restore_settle() {
    local waited=0 missing
    while ((waited < SETTLE_SECONDS)); do
        capture_panes after
        missing=0
        while IFS= read -r conversation_id; do
            [[ -n "$(prefills_for "$conversation_id")" ]] || missing=$((missing + 1))
        done < <(stub_starts | jq -r '.conversation_id')
        ((missing > 0)) || return 0
        sleep 2
        waited=$((waited + 2))
    done
}

prefills_for() {
    local conversation_id="$1" start buffer pane
    for start in "$ISOLATED_HOME"/.drill/observe/shell-*.start; do
        [[ -f "$start" ]] || continue
        grep -qx 'phase=after' "$start" || continue
        buffer="${start%.start}.buffer"
        [[ -f "$buffer" ]] || continue
        if grep -qF -- "--resume $conversation_id" "$buffer"; then
            printf 'shell %s: %s\n' "$(sed -n 's/^host_session_id=//p' "$start")" "$(cat "$buffer")"
        fi
    done
    for pane in "$PASS_DIR"/panes-after/*.txt; do
        [[ -f "$pane" ]] || continue
        grep -F -- "--resume $conversation_id" "$pane" | sed -n 1p | sed "s#^#pane $(basename "$pane" .txt): #" || true
    done
}

record_pass_rows() {
    ps -A -ww -o pid=,command= >"$PASS_DIR/.processes-after.raw"
    local spec tile effort turn
    for spec in "${DRILL_TILES[@]}"; do
        IFS='|' read -r tile effort turn <<<"$spec"
        if [[ "$tile" == ws_launch && "$PASS_MODE" != tmux_per_session ]]; then
            continue
        fi
        record_tile_row "$tile" "$effort" "$turn"
    done
    rm -f "$PASS_DIR/.processes-after.raw"
}

record_tile_row() {
    local tile="$1" effort="$2" turn="$3"
    local start conversation_id cwd host_session_id holders prefill prefill_sources fresh rung hook_socket launch_record
    local successors own_hosts rendered
    start="$(stub_starts | jq -c --arg effort "$effort" 'select(.effort == $effort)' | sed -n 1p)"
    if [[ -z "$start" ]]; then
        jq -nc --arg pass "$PASS_ID" --arg mode "$PASS_MODE" --arg flag "$PASS_FLAG" \
            --arg kill_order "$PASS_KILL_ORDER" --arg tile "$tile" --arg reason "$(not_started_reason "$tile")" \
            '{pass: $pass, mode: $mode, restore_flag: $flag, kill_order: $kill_order, tile: $tile,
              drivable: true, status: "not_started", expected_rung: "resume", rung_taken: null,
              prefill_text: null, reason: $reason}' >>"$ROWS_PATH"
        return 0
    fi
    conversation_id="$(jq -r '.conversation_id' <<<"$start")"
    cwd="$(jq -r '.cwd' <<<"$start")"
    host_session_id="$(jq -r '.host_session_id' <<<"$start")"
    holders="$(conversation_holders "$conversation_id" | tee -a "$PASS_DIR/holders-after.txt" | wc -l | tr -d ' ')"
    prefill_sources="$(prefills_for "$conversation_id")"
    prefill="$(sed -n 1p <<<"$prefill_sources" | sed -E 's/^(shell|pane) [^:]*: //')"
    successors="$(successor_hosts "$host_session_id" "$cwd")"
    own_hosts="$(own_before_hosts "$host_session_id" "$cwd")"
    rendered="$(after_shells_on "$successors"$'\n'"$own_hosts" | wc -l | tr -d ' ')"
    fresh="$(after_shells_on "$successors"$'\n'"$own_hosts" | without_resume | wc -l | tr -d ' ')"
    hook_socket="$(session_start_reached_socket "$conversation_id")"
    launch_record=false
    ! grep -rqF -- "$conversation_id" "$PASS_DIR/xdg/workspaces-cli/launches" 2>/dev/null || launch_record=true
    rung="none"
    if ((holders > 0)); then
        rung="reattach"
    elif [[ -n "$prefill_sources" ]]; then
        rung="resume"
    elif ((fresh > 0)); then
        rung="fresh"
    elif [[ -n "$successors" ]]; then
        rung="restored_unrendered"
    fi
    jq -nc \
        --arg pass "$PASS_ID" --arg mode "$PASS_MODE" --arg flag "$PASS_FLAG" \
        --arg kill_order "$PASS_KILL_ORDER" --arg tile "$tile" --arg effort "$effort" --arg turn "$turn" \
        --arg conversation_id "$conversation_id" --arg cwd "$cwd" --arg host_session_id "$host_session_id" \
        --arg rung "$rung" --arg prefill "$prefill" --arg prefill_sources "$prefill_sources" \
        --argjson holders "$holders" --argjson fresh "$fresh" --argjson hook_socket "$hook_socket" \
        --argjson rendered "$rendered" --arg successors "$successors" --arg own_hosts "$own_hosts" \
        --argjson launch_record "$launch_record" --arg restored "$(restored_session_ids)" \
        --slurpfile db_before "$PASS_DIR/db-before.json" --slurpfile db_after "$PASS_DIR/db-after.json" \
        --slurpfile events "$PASS_DIR/db-before-events.json" \
        'def rows($db): [$db[0][]? | select(if $host_session_id == "" then .directory_path == $cwd
                                          else .host_session_id == $host_session_id end)];
         ($events[0] | map(select(.agent_session_id == $conversation_id))) as $landed
         | ($restored | split("\n") | map(select(. != ""))) as $restored_ids
         | ($prefill_sources | split("\n") | map(select(. != ""))) as $sources
         | ($sources | map(capture("^shell (?<id>[^:]*):").id)) as $prefill_hosts
         | {pass: $pass, mode: $mode, restore_flag: $flag, kill_order: $kill_order, tile: $tile,
          drivable: true, status: "observed", effort: $effort, turn: $turn,
          conversation_id: $conversation_id, cwd: $cwd, host_session_id: $host_session_id,
          hook_had_socket: $hook_socket, app_events_for_conversation: ($landed | length),
          app_event_names: ($landed | map(.event_name)), launch_record_names_conversation: $launch_record,
          identity_source: (if ($landed | length) > 0 then "hook_events"
                            elif $launch_record then "launch_record" else "none" end),
          expected_rung: "resume", rung_taken: $rung,
          prefill_text: (if $prefill == "" then null else $prefill end),
          prefill_sources: $sources,
          prefill_host_sessions: $prefill_hosts,
          prefill_in_os_log_restored_session: ($prefill_hosts | any(.[]; IN($restored_ids[]))),
          resume_via: (if ($prefill_hosts | any(.[]; IN($restored_ids[]))) then "restored_session"
                       elif ($prefill_hosts | any(.[]; IN($own_hosts | split("\n")[]))) then "reused_host_session"
                       elif ($prefill_hosts | length) > 0 then "other_session" else null end),
          os_log_restored_sessions: $restored_ids,
          successor_host_sessions: ($successors | split("\n") | map(select(. != ""))),
          successor_shells: $rendered, successor_shells_without_resume: $fresh,
          holders_after_relaunch: $holders,
          rung_basis: "successor = a new active after-relaunch terminal_sessions row with the session_key and tmux_session_name of this tile'"'"'s row (when several before rows share them, the one active row claims it); shells count on successors and on the tile'"'"'s own host sessions reused after relaunch. reattach = a process still holds the conversation; resume = an after-relaunch shell or pane shows `--resume <id>`; fresh = such a shell holds no resume; restored_unrendered = a successor row exists but no shell started for it; none = neither",
          db_before: rows($db_before), db_after: rows($db_after)}' >>"$ROWS_PATH"
}

restored_session_ids() {
    sed -nE 's/.*Created restored session ([0-9A-F-]{36}).*/\1/p' "$PASS_DIR/restore-log.txt" 2>/dev/null || true
}

not_started_reason() {
    local logs
    logs="$(cat "$ISOLATED_HOME"/.drill/observe/split-*.log 2>/dev/null | tr '\n' ' ')"
    case "$1" in
        split | mid_turn) echo "the stub agent for this tile never started; queued split output: ${logs:-none}" ;;
        *) echo "the stub agent for this tile never started" ;;
    esac
}

conversation_holders() {
    grep -F -- "$1" "$PASS_DIR/.processes-after.raw" \
        | awk '$2 ~ /(^|\/)claude$/ || $3 ~ /(^|\/)claude$/' || true
}

successor_hosts() {
    jq -rn --arg host "$1" --arg cwd "$2" \
        --slurpfile before "$PASS_DIR/db-before.json" --slurpfile after "$PASS_DIR/db-after.json" \
        '($before[0] | map(select(if $host == "" then .directory_path == $cwd else .host_session_id == $host end))) as $mine
         | ($before[0] | map(.host_session_id)) as $old
         | $after[0][]
         | select(.is_active == 1 and .ended_at == null and (.host_session_id | IN($old[]) | not))
         | . as $row
         | ($before[0] | map(select(.session_key == $row.session_key and .tmux_session_name == $row.tmux_session_name))) as $peers
         | ($peers | map(select(.is_active == 1))) as $live
         | select(if ($live | length) == 1 then any($mine[]; .host_session_id == $live[0].host_session_id)
                  else any($mine[]; IN($peers[])) end)
         | .host_session_id'
}

own_before_hosts() {
    jq -rn --arg host "$1" --arg cwd "$2" --slurpfile before "$PASS_DIR/db-before.json" \
        '$before[0][] | select(if $host == "" then .directory_path == $cwd else .host_session_id == $host end)
         | .host_session_id'
}

after_shells_on() {
    local hosts="$1" start
    [[ -n "$hosts" ]] || return 0
    for start in "$ISOLATED_HOME"/.drill/observe/shell-*.start; do
        [[ -f "$start" ]] || continue
        grep -qx 'phase=after' "$start" || continue
        grep -qxF -f <(sed '/^$/d; s/^/host_session_id=/' <<<"$hosts") "$start" || continue
        echo "${start%.start}"
    done
}

without_resume() {
    local shell
    while IFS= read -r shell; do
        [[ -f "$shell.buffer" ]] && grep -qF -- "--resume " "$shell.buffer" && continue
        echo "$shell"
    done
}

session_start_reached_socket() {
    local ledger="$ISOLATED_HOME/.claude/stub-agent-ledger.jsonl"
    jq -s --arg id "$1" \
        'any(.[]; .event == "hook" and .hook == "SessionStart" and .conversation_id == $id and .hooks_socket != "")' \
        "$ledger"
}

terminate_drill_app() {
    [[ -n "$APP_PID" ]] || return 0
    terminate_app_pid "$APP_PID" >/dev/null 2>&1 || true
    wait_for_pid_exit "$APP_PID" || kill -TERM "$APP_PID" 2>/dev/null || true
    wait_for_pid_exit "$APP_PID" || true
    APP_PID=""
}

write_drill_summary() {
    [[ -f "$ROWS_PATH" ]] || : >"$ROWS_PATH"
    jq -n \
        --arg status "$1" \
        --arg failure "$2" \
        --arg run_dir "$RUN_DIR" \
        --arg socket_label "$SOCKET_LABEL" \
        --argjson settle_seconds "$SETTLE_SECONDS" \
        --slurpfile rows "$ROWS_PATH" \
        '{status: $status, failure: $failure, run_dir: $run_dir, socket_label_base: $socket_label,
          settle_seconds: $settle_seconds, rows: $rows}' >"$SUMMARY_PATH"
}
