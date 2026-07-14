"""Canonical paths whose changes require release-specific validation and review."""

RELEASE_PATHS = frozenset(
    {
        ".github/workflows/release.yml",
        "scripts/build-release.sh",
        "scripts/generate-sparkle-appcast.sh",
        "scripts/install-local.sh",
        "scripts/notarize.sh",
        "scripts/prepare-prerelease.sh",
        "scripts/prepare-release.sh",
        "scripts/release-manifest.sh",
        "scripts/release-preflight.sh",
        "scripts/release-version.sh",
        "scripts/setup-release-secrets.sh",
        "scripts/verify-app-keychain-signing.sh",
        "scripts/verify-installed-perf.sh",
        "scripts/verify-p12.sh",
        "scripts/verify-release-bundle.sh",
        "scripts/verify-sparkle-appcast.swift",
    }
)
