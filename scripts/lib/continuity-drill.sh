#!/usr/bin/env bash
# continuity-drill.sh — the holder-death matrix behind `continuity-evidence.sh --drill`,
# sourced by that script and sharing its globals and helpers (isolation, launch, kill).
# Each pass opens agent tiles on an isolated socket, kills the holder, relaunches, clicks
# the restored rows as a person would, and writes one summary row per tile from what the
# shells, panes, process table, local-state database and the app's own os_log show.

run_drill() {
    : >"$ROWS_PATH"
    build_products_once
    record_static_row all mixed_window "terminal mode is process-wide (TerminalMultiplexingMode.resolve), so one window cannot hold tmux and Ghostty-split tiles together"
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
    snapshot_processes before
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
    record_isolated_server "$TMUX_LABEL"
    stop_owned_servers "$TMUX_LABEL"
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
    record_isolated_server "$TMUX_LABEL"
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

snapshot_processes() {
    LC_ALL=C ps -A -ww -o pid=,lstart=,command= \
        | awk -v home="$ISOLATED_HOME/" 'index($0, home) && ($7 ~ /(^|\/)claude$/ || $8 ~ /(^|\/)claude$/) {
                   command = $7
                   for (i = 8; i <= NF; i++) command = command " " $i
                   print $1 "|" $2 " " $3 " " $4 " " $5 " " $6 "|" command
               }' >"$PASS_DIR/processes-$1.txt"
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
    snapshot_processes after
    local spec tile effort turn
    for spec in "${DRILL_TILES[@]}"; do
        IFS='|' read -r tile effort turn <<<"$spec"
        if [[ "$tile" == ws_launch && "$PASS_MODE" != tmux_per_session ]]; then
            continue
        fi
        record_tile_row "$tile" "$effort" "$turn"
    done
}

record_tile_row() {
    local tile="$1" effort="$2" turn="$3"
    local start conversation_id cwd host_session_id prefill_sources hook_socket launch_record
    local assignment own_hosts claimed_hosts rendered fresh other_resumes
    start="$(stub_starts | jq -c --arg effort "$effort" 'select(.effort == $effort)' | sed -n 1p)"
    if [[ -z "$start" ]]; then
        jq -nc --arg pass "$PASS_ID" --arg mode "$PASS_MODE" --arg flag "$PASS_FLAG" \
            --arg kill_order "$PASS_KILL_ORDER" --arg tile "$tile" --arg reason "$(not_started_reason "$tile")" \
            '{pass: $pass, mode: $mode, restore_flag: $flag, kill_order: $kill_order, tile: $tile,
              drivable: true, status: "not_started", rung_taken: null, prefill_text: null, reason: $reason}' >>"$ROWS_PATH"
        return 0
    fi
    conversation_id="$(jq -r '.conversation_id' <<<"$start")"
    cwd="$(jq -r '.cwd' <<<"$start")"
    host_session_id="$(jq -r '.host_session_id' <<<"$start")"
    classify_conversation_processes "$conversation_id"
    prefill_sources="$(prefills_for "$conversation_id")"
    assignment="$(successor_assignment "$host_session_id" "$cwd")"
    own_hosts="$(own_before_hosts "$host_session_id" "$cwd")"
    claimed_hosts="$(jq -r '.successors[]' <<<"$assignment")"$'\n'"$own_hosts"
    rendered="$(after_shells_on "$claimed_hosts" | wc -l | tr -d ' ')"
    fresh="$(after_shells_on "$claimed_hosts" | without_resume | wc -l | tr -d ' ')"
    other_resumes="$(after_shells_on "$claimed_hosts" | resuming_other_than "$conversation_id")"
    hook_socket="$(session_start_reached_socket "$conversation_id")"
    launch_record=false
    ! grep -rqF -- "$conversation_id" "$PASS_DIR/xdg/workspaces-cli/launches" 2>/dev/null || launch_record=true
    jq -nc \
        --arg pass "$PASS_ID" --arg mode "$PASS_MODE" --arg flag "$PASS_FLAG" \
        --arg kill_order "$PASS_KILL_ORDER" --arg tile "$tile" --arg effort "$effort" --arg turn "$turn" \
        --arg conversation_id "$conversation_id" --arg cwd "$cwd" --arg host_session_id "$host_session_id" \
        --arg prefill_sources "$prefill_sources" --arg own_hosts "$own_hosts" --arg claimed "$claimed_hosts" \
        --arg survivor_lines "$SURVIVOR_LINES" --arg resumed_lines "$RESUMED_LINES" --arg other_resumes "$other_resumes" \
        --argjson before_holders "$BEFORE_HOLDERS" --argjson assignment "$assignment" \
        --argjson rendered "$rendered" --argjson fresh "$fresh" --argjson hook_socket "$hook_socket" \
        --argjson launch_record "$launch_record" --arg restored "$(restored_session_ids)" \
        --slurpfile db_before "$PASS_DIR/db-before.json" --slurpfile db_after "$PASS_DIR/db-after.json" \
        --slurpfile events "$PASS_DIR/db-before-events.json" \
        "$(tile_row_program)" >>"$ROWS_PATH"
}

tile_row_program() {
    cat <<'JQ'
def lines($s): $s | split("\n") | map(select(. != ""));
def rows($db): [$db[0][]? | select(if $host_session_id == "" then .directory_path == $cwd
                                   else .host_session_id == $host_session_id end)];
def text: sub("^(shell|pane) [^:]*: "; "");
($events[0] | map(select(.agent_session_id == $conversation_id))) as $landed
| lines($restored) as $restored_ids
| lines($own_hosts) as $own_ids
| lines($claimed) as $claimed_ids
| lines($survivor_lines) as $survivors
| lines($resumed_lines) as $resumed
| [$db_after[0][]? | select(.host_session_id | IN($claimed_ids[])) | .tmux_session_name | select(. != null)] as $claimed_tmux
| [lines($prefill_sources)[]
   | if startswith("shell ") then {source: ., own: (capture("^shell (?<h>[^:]*):").h | IN($claimed_ids[])),
                                   host: capture("^shell (?<h>[^:]*):").h}
     else {source: ., own: (capture("^pane (?<s>.*)-[0-9]+:").s | IN($claimed_tmux[])), host: null} end] as $prefills
| ($prefills | map(select(.own))) as $own_prefills
| ($prefills | map(select(.own | not))) as $foreign_prefills
| lines($other_resumes) as $other_resumes
| (if ($survivors | length) > 0 then "reattach"
   elif $assignment.ambiguous then "ambiguous"
   elif ($own_prefills | length) > 0 or ($resumed | length) > 0 then "resume"
   elif ($foreign_prefills | length) > 0 or ($other_resumes | length) > 0 then "ambiguous"
   elif $fresh > 0 then "fresh"
   elif ($assignment.successors | length) > 0 then "restored_unrendered"
   else "none" end) as $rung
| {pass: $pass, mode: $mode, restore_flag: $flag, kill_order: $kill_order, tile: $tile,
   drivable: true, status: "observed", effort: $effort, turn: $turn,
   conversation_id: $conversation_id, cwd: $cwd, host_session_id: $host_session_id,
   hook_had_socket: $hook_socket, app_events_for_conversation: ($landed | length),
   app_event_names: ($landed | map(.event_name)), launch_record_names_conversation: $launch_record,
   identity_source: (if ($landed | length) > 0 then "hook_events"
                     elif $launch_record then "launch_record" else "none" end),
   rung_taken: $rung,
   ambiguity: (if $rung != "ambiguous" then null
               elif $assignment.ambiguous then "restored rows \($assignment.ambiguous_rows | join(", ")) match this tile and another tile equally"
               elif ($foreign_prefills | length) > 0 then "this conversation's resume landed only in another tile's session: \($foreign_prefills | map(.source) | join("; "))"
               else "this tile's restored shell holds another conversation's resume: \($other_resumes | join("; "))" end),
   prefill_text: (($own_prefills[0].source // null) | if . == null then null else text end),
   own_prefill_sources: ($own_prefills | map(.source)),
   foreign_prefill_sources: ($foreign_prefills | map(.source)),
   resume_via: (if $rung != "resume" then null
                elif ($own_prefills | any(.host != null and (.host | IN($restored_ids[])))) then "restored_session"
                elif ($own_prefills | any(.host != null and (.host | IN($own_ids[])))) then "reused_host_session"
                elif ($own_prefills | length) > 0 then "pane_in_claimed_session"
                else "new_resume_process" end),
   holders_before_kill: $before_holders, surviving_holders: $survivors, new_resume_processes: $resumed,
   successor_host_sessions: $assignment.successors, os_log_restored_sessions: $restored_ids,
   claimed_shells: $rendered, claimed_shells_without_resume: $fresh,
   rung_basis: "successor = an unended after-relaunch terminal_sessions row the os_log says restore created, matched one-to-one to a before-row by session_key and tmux_session_name (then by is_active when several share them; a tie or a before-row claimed twice is ambiguous). Claimed sessions = successors plus the tile's own reused host sessions. reattach = a holder pid with its pre-kill start time is still alive; resume = a claimed shell or pane shows `--resume <id>`, or a new process resumed the conversation; ambiguous = the successor match tied, the resume landed only outside the tile's claimed sessions, or a claimed shell holds another conversation's resume; fresh = a claimed shell holds no resume; restored_unrendered = a successor exists but no shell started; none = neither",
   db_before: rows($db_before), db_after: rows($db_after)}
JQ
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

classify_conversation_processes() {
    local conversation_id="$1" before_keys line key
    before_keys="$(before_holder_keys "$conversation_id")"
    BEFORE_HOLDERS="$(grep -c . <<<"$before_keys" || true)"
    SURVIVOR_LINES=""
    RESUMED_LINES=""
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        key="$(cut -d'|' -f1,2 <<<"$line")"
        if [[ -n "$before_keys" ]] && grep -qxF -- "$key" <<<"$before_keys"; then
            SURVIVOR_LINES+="$line"$'\n'
        elif [[ "$line" == *"--resume $conversation_id"* ]]; then
            RESUMED_LINES+="$line"$'\n'
        fi
    done <"$PASS_DIR/processes-after.txt"
    printf '%s' "$SURVIVOR_LINES" | sed "s/^/$conversation_id survivor /" >>"$PASS_DIR/holders-after.txt"
    printf '%s' "$RESUMED_LINES" | sed "s/^/$conversation_id resumed /" >>"$PASS_DIR/holders-after.txt"
}

before_holder_keys() {
    local conversation_id="$1" pids
    pids=" $(jq -r --arg id "$conversation_id" 'select(.event == "start" and .conversation_id == $id) | .pid' \
        "$ISOLATED_HOME/.claude/stub-agent-ledger.jsonl" 2>/dev/null | tr '\n' ' ')"
    awk -F'|' -v id="$conversation_id" -v pids="$pids" \
        'index(pids, " " $1 " ") || index($3, id) { print $1 "|" $2 }' "$PASS_DIR/processes-before.txt"
}

successor_assignment() {
    jq -cn --arg host "$1" --arg cwd "$2" --arg restored "$(restored_session_ids)" \
        --slurpfile before "$PASS_DIR/db-before.json" --slurpfile after "$PASS_DIR/db-after.json" \
        '($restored | split("\n") | map(select(. != ""))) as $restored_ids
         | $before[0] as $rows
         | ($rows | map(select(if $host == "" then .directory_path == $cwd else .host_session_id == $host end))
                  | map(.host_session_id)) as $mine
         | [$after[0][]
            | select(.ended_at == null and (.host_session_id | IN($restored_ids[])))
            | . as $row
            | ($rows | map(select(.session_key == $row.session_key and .tmux_session_name == $row.tmux_session_name))) as $peers
            | (if ($peers | length) <= 1 then $peers else ($peers | map(select(.is_active == $row.is_active))) end) as $narrow
            | {after: $row.host_session_id,
               candidates: (if ($narrow | length) == 0 then $peers else $narrow end | map(.host_session_id)),
               before: (if ($narrow | length) == 1 then $narrow[0].host_session_id else null end)}] as $pairs
         | ($pairs | map(select(.before != null)) | group_by(.before) | map(select(length > 1) | .[0].before)) as $contested
         | ($pairs | map(select(.before != null and (.before | IN($mine[])) and (.before | IN($contested[]) | not)) | .after)) as $successors
         | ($pairs | map(select((.before == null and any(.candidates[]; IN($mine[])))
                                 or (.before != null and (.before | IN($mine[])) and (.before | IN($contested[])))))
                   | map(.after)) as $ambiguous_rows
         | {successors: $successors, ambiguous: ($ambiguous_rows | length > 0), ambiguous_rows: $ambiguous_rows}'
}

own_before_hosts() {
    jq -rn --arg host "$1" --arg cwd "$2" --slurpfile before "$PASS_DIR/db-before.json" \
        '$before[0][] | select(if $host == "" then .directory_path == $cwd else .host_session_id == $host end)
         | .host_session_id'
}

after_shells_on() {
    local hosts="$1" start
    [[ -n "${hosts//$'\n'/}" ]] || return 0
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

resuming_other_than() {
    local conversation_id="$1" shell
    while IFS= read -r shell; do
        [[ -f "$shell.buffer" ]] || continue
        grep -qF -- "--resume " "$shell.buffer" || continue
        grep -qF -- "--resume $conversation_id" "$shell.buffer" && continue
        printf '%s: %s\n' "$(sed -n 's/^host_session_id=//p' "$shell.start")" "$(cat "$shell.buffer")"
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
    stop_app "$APP_PID" "$(launch_not_before "$APP_PID")" || true
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
