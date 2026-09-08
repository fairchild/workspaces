#!/bin/bash
# ============================================================================
# release-signing.sh - What a shipped bundle has to be signed with
# ============================================================================
#
# verify-release-bundle.sh enforces this authority on the packaged app, at the
# end of a build. build-release.sh checks the configured identity against it at
# the start of one, so a misconfigured identity costs a second instead of a
# full compile. One definition so the gate and its preflight cannot disagree.
#
# .github/workflows/release.yml selects the CI identity by the same string; it
# reads its own copy because a workflow step cannot source this file before the
# checkout it lives in.
# ============================================================================

RELEASE_SIGNING_AUTHORITY="Developer ID Application"
