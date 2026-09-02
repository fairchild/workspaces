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
# FIXTURE_SEED_ORPHAN_BANNER, FIXTURE_SEED_RUNAWAY_ALERT, FIXTURE_FILE_TREE_FAILURE,
# FIXTURE_SIDEBAR_ARRANGEMENT,
# FIXTURE_CMD_T_REPO, FIXTURE_TRIGGER_CMD_T, FIXTURE_PINNED, FIXTURE_ARCHIVED,
# FIXTURE_SELECTED, and FIXTURE_SCENARIO_ID for the named scenario.
# "inline:<agent-states>" passes a raw agent-states spec straight through. Returns
# non-zero (and sets nothing) for an unknown name.
fixture_resolve_scenario() {
    local name="$1"
    FIXTURE_AGENT_STATES=""
    FIXTURE_COMMAND_STATUSES=""
    FIXTURE_SEED_RESTORE_BANNER=""
    FIXTURE_SEED_ORPHAN_BANNER=""
    FIXTURE_SEED_RUNAWAY_ALERT=""
    FIXTURE_FILE_TREE_FAILURE=""
    FIXTURE_SIDEBAR_ARRANGEMENT=""
    FIXTURE_CMD_T_REPO=""
    FIXTURE_TRIGGER_CMD_T=""
    FIXTURE_PINNED=""
    FIXTURE_ARCHIVED=""
    FIXTURE_SELECTED=""
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
        runaway-alert)
            # Stages the sidebar's runaway-process strip via a deterministic synthetic
            # alert (issue #1368). The env var reaches the app by inheritance — the
            # evidence lane exports WORKSPACES_UI_FIXTURE_SEED_RUNAWAY_ALERT=1 before
            # launching; fixture mode also suppresses the real process sweep so a
            # genuine runaway on the dev machine never leaks into a capture.
            FIXTURE_SEED_RUNAWAY_ALERT=1
            ;;
        sidebar-recent)
            # Flat, date-bucketed sidebar. UIFixtureSeeder spreads the seeded
            # workspaces across now / -3d / -30d, so Today, This Week, and Earlier
            # all render; the agent states match phase-1-release so the two captures
            # show the same activity in the two arrangements.
            FIXTURE_SIDEBAR_ARRANGEMENT="recent"
            FIXTURE_AGENT_STATES="feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored"
            ;;
        sidebar-pinned)
            # Pinned section above the Recent buckets. The two pinned workspaces are
            # seeded by name (UIFixtureSeeder), so the capture shows both that Pinned
            # renders first and that its rows leave the buckets below.
            FIXTURE_PINNED="feature-auth,skills-v13"
            FIXTURE_SIDEBAR_ARRANGEMENT="recent"
            FIXTURE_AGENT_STATES="feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored"
            ;;
        sidebar-pinned-alphabetical)
            # Same pins under the repo tree: Pinned is a shortcut list, so feature-auth
            # and skills-v13 appear both at the top and inside their repos.
            FIXTURE_PINNED="feature-auth,skills-v13"
            FIXTURE_SIDEBAR_ARRANGEMENT="alphabetical"
            FIXTURE_AGENT_STATES="feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored"
            ;;
        sidebar-archived)
            # Archived rows folded behind the per-repo disclosure pill. The two names
            # cover both readings of it: refactor-state leaves bertram-chat with live
            # siblings above its pill, skills-v13 leaves the skills repo holding nothing
            # but archived work. Neither carries an agent state, so all three states of
            # phase-1-release stay visible in the live rows. Alphabetical because the
            # archived section belongs to the repo tree — Recent has no repo to hang it on.
            FIXTURE_ARCHIVED="refactor-state,skills-v13"
            FIXTURE_SIDEBAR_ARRANGEMENT="alphabetical"
            FIXTURE_AGENT_STATES="feature-auth:thinking,bugfix-422:awaitingInput,refactor-runtime:errored"
            ;;
        sidebar-active-card)
            # The selected workspace as a raised card carrying its live status line.
            # feature-auth is the one named: phase-1-release already drives it to thinking,
            # so the card shows a live session rather than an idle row, and its two siblings
            # stay unselected beside it for the contrast the card is about. Alphabetical
            # because the card belongs to the repo tree the rest of the arc captures.
            FIXTURE_SELECTED="feature-auth"
            FIXTURE_SIDEBAR_ARRANGEMENT="alphabetical"
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
    printf '%s\n' phase-1-release m6-status-sliver attention-only restore-banner orphan-banner runaway-alert sidebar-recent sidebar-pinned sidebar-pinned-alphabetical sidebar-archived sidebar-active-card file-tree-unavailable file-tree-permission cmd-t-repo-overview cmd-t-repo-terminal clean
}
