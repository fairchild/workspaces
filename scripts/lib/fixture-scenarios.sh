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
# and FIXTURE_SCENARIO_ID for the named scenario. "inline:<agent-states>" passes a raw
# agent-states spec straight through. Returns non-zero (and sets nothing) for an
# unknown name.
fixture_resolve_scenario() {
    local name="$1"
    FIXTURE_AGENT_STATES=""
    FIXTURE_COMMAND_STATUSES=""
    FIXTURE_SEED_RESTORE_BANNER=""
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
    printf '%s\n' phase-1-release m6-status-sliver attention-only restore-banner clean
}
