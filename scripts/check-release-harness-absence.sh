#!/usr/bin/env bash
#
# Proves the release binary carries none of the debug smoke/fixture harness.
# Scans nm symbol output for the harness types gated behind #if DEBUG (#1235)
# and the strings table for the env keys and JSONL milestones that arm them.
# Exits non-zero, naming each hit, when any leak into the release build.
#
set -euo pipefail

BINARY="${1:-.build/release/WorkspaceManager}"

if [[ ! -f "$BINARY" ]]; then
    echo "error: release binary not found at $BINARY (run: swift build -c release)" >&2
    exit 2
fi

# Harness type names that must be compiled out of release builds. The inert
# SmokeScenarioDriver seam shell intentionally remains (the views call it), so
# these patterns name the gated implementation types, not the seam.
symbol_patterns=(
    DesktopUISmokeAutomation
    DesktopUISmokeEvent
    HostLumeSmokeAutomation
    HostLumeSmokeEvent
    HostLumeSmokeWorkspaceRecord
    UIFixtureSeeder
    UIFixtureContinuitySeeder
    UIFixtureLumeEnvironment
    UIFixtureLumeRuntimeService
    UIFixtureLumeWorkspaceProvider
    UIFixtureDaytonaWorkspaceProvider
)

# Harness-only runtime strings: the env keys that arm the smoke lanes and the
# scenario's synthetic artifacts. WORKSPACES_AUTOMATION_SOCKET / _HANDLE /
# _OPERATOR belong to the production automation API and are expected to remain.
string_patterns=(
    WORKSPACES_AUTOMATION_MODE
    WORKSPACES_AUTOMATION_REPO_PATH
    WORKSPACES_AUTOMATION_EVENTS_PATH
    WORKSPACES_AUTOMATION_SELECT_DRIVER
    WORKSPACES_AUTOMATION_CREATE_DRIVER
    WORKSPACES_UI_FIXTURE_LUME_E2E
    WORKSPACES_UI_FIXTURE_AGENT_STATES
    WORKSPACES_UI_FIXTURE_COMMAND_STATUSES
    WORKSPACES_UI_FIXTURE_SEED_RESTORE_BANNER
    desktop-ui-smoke-web
    host-lume-macos-smoke
)

failures=0

nm_output="$(nm "$BINARY" 2>/dev/null || true)"
for pattern in "${symbol_patterns[@]}"; do
    if grep -q "$pattern" <<<"$nm_output"; then
        echo "FAIL: symbol pattern '$pattern' present in $BINARY (nm)" >&2
        failures=$((failures + 1))
    else
        echo "ok: no '$pattern' symbols"
    fi
done

strings_output="$(strings "$BINARY" 2>/dev/null || true)"
for pattern in "${string_patterns[@]}"; do
    if grep -q "$pattern" <<<"$strings_output"; then
        echo "FAIL: string '$pattern' present in $BINARY (strings)" >&2
        failures=$((failures + 1))
    else
        echo "ok: no '$pattern' strings"
    fi
done

if ((failures > 0)); then
    echo "release harness check FAILED: $failures leak(s)" >&2
    exit 1
fi

echo "release harness check passed: no harness symbols or strings in $BINARY"
