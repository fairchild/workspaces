#!/bin/bash
# shellcheck disable=SC2034  # FIXTURE_* are outputs consumed by sourcing scripts.
# Single source of truth for named UI-fixture scenarios.
#
# A scenario name maps to the WORKSPACES_UI_FIXTURE_AGENT_STATES and
# WORKSPACES_UI_FIXTURE_COMMAND_STATUSES that stage a deterministic app state.
# Both the evidence self-capture lane (scripts/lib/app-capture.sh) and the
# release-screenshot capture script resolve scenarios through here, so the
# catalog never drifts between the two capture paths.
#
# Grammar for the fixture env values lives in docs/development/ui-fixture-mode.md.

# fixture_resolve_scenario <name>
# Populates FIXTURE_AGENT_STATES, FIXTURE_COMMAND_STATUSES, FIXTURE_SEED_RESTORE_BANNER,
# FIXTURE_SEED_ORPHAN_BANNER, FIXTURE_FILE_TREE_FAILURE, FIXTURE_SIDEBAR_ARRANGEMENT,
# FIXTURE_CMD_T_REPO, FIXTURE_TRIGGER_CMD_T, and FIXTURE_SCENARIO_ID for the named scenario.
# "inline:<agent-states>" passes a raw agent-states spec straight through. Returns
# non-zero (and sets nothing) for an unknown name.
fixture_resolve_scenario() {
    local name="$1"
    FIXTURE_AGENT_STATES=""
    FIXTURE_COMMAND_STATUSES=""
    FIXTURE_SEED_RESTORE_BANNER=""
    FIXTURE_SEED_ORPHAN_BANNER=""
    FIXTURE_FILE_TREE_FAILURE=""
    FIXTURE_SIDEBAR_ARRANGEMENT=""
    FIXTURE_CMD_T_REPO=""
    FIXTURE_TRIGGER_CMD_T=""
    FIXTURE_SCENARIO_ID=""

    if [[ "$name" == inline:* ]]; then
        FIXTURE_AGENT_STATES="${name#inline:}"
        FIXTURE_SCENARIO_ID="inline"
        return 0
    fi

    case "$name" in
        phase-1-release)
            FIXTURE_AGENT_STATES="feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored"
            ;;
        m6-status-sliver)
            FIXTURE_COMMAND_STATUSES="feature-auth:failed"
            ;;
        attention-only)
            FIXTURE_AGENT_STATES="bugfix-422:awaitingInput"
            ;;
        restore-banner)
            # Seeds a synthetic previous-run continuity row (issue #1192) so the
            # cold-start restore banner renders even though --clean-data wipes
            # LocalStateStore before every evidence-lane capture. Also requires the
            # restoreSessionsOnLaunch experiment, which app-capture.sh force-enables
            # alongside the seed.
            FIXTURE_SEED_RESTORE_BANNER=1
            ;;
        orphan-banner)
            # Stages the workspace-orphan cleanup banner via a deterministic synthetic
            # item (issue #1228). The env var reaches the app by inheritance — the
            # evidence lane exports WORKSPACES_UI_FIXTURE_SEED_ORPHAN_BANNER=1 before
            # launching; fixture mode also suppresses the real filesystem orphan scan
            # so dev-machine leftovers never leak into any scenario's capture.
            FIXTURE_SEED_ORPHAN_BANNER=1
            ;;
        sidebar-recent)
            # Flat, date-bucketed sidebar. UIFixtureSeeder spreads the seeded
            # workspaces across now / -3d / -30d, so Today, This Week, and Earlier
            # all render; the agent states match phase-1-release so the two captures
            # show the same activity in the two arrangements.
            FIXTURE_SIDEBAR_ARRANGEMENT="recent"
            FIXTURE_AGENT_STATES="feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored"
            ;;
        file-tree-unavailable)
            FIXTURE_FILE_TREE_FAILURE="unavailable"
            ;;
        file-tree-permission)
            FIXTURE_FILE_TREE_FAILURE="permission"
            ;;
        cmd-t-repo-overview)
            FIXTURE_CMD_T_REPO="workspaces"
            ;;
        cmd-t-repo-terminal)
            FIXTURE_CMD_T_REPO="workspaces"
            FIXTURE_TRIGGER_CMD_T=1
            ;;
        clean)
            ;;
        *)
            return 1
            ;;
    esac

    FIXTURE_SCENARIO_ID="$name"
    return 0
}

# fixture_scenario_names — the known scenario ids, one per line.
fixture_scenario_names() {
    printf '%s\n' phase-1-release m6-status-sliver attention-only restore-banner orphan-banner sidebar-recent file-tree-unavailable file-tree-permission cmd-t-repo-overview cmd-t-repo-terminal clean
}
