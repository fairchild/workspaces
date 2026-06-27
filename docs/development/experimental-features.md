# Experimental Features

Experimental Features is the app-level path for introducing incomplete or
high-risk UI behind an explicit Settings gate. Use it when a feature should be
available for local dogfooding, screenshots, or targeted reviewer testing, but
should not render for users unless they opt in.

This is not a remote rollout system. Registered experiments are compiled into
the app and persisted as app preferences in `UserDefaults`.

## Runtime Model

Experimental feature state has three layers:

1. Environment force-on override
2. Master Settings toggle
3. Per-feature Settings toggle

The environment force-on override wins for the current launch. Otherwise, a
feature resolves on only when the master toggle and that feature's toggle are
both on.

When the master toggle is off, Settings hides the per-feature list but preserves
the stored choices. Turning the master toggle back on restores the previous
per-feature selections.

## When To Use It

Use an experimental feature when:

- the UI is useful for dogfooding before it is ready to ship broadly
- reviewers need a stable switch for side-by-side behavior checks
- the feature changes a shared surface such as toolbar, sidebar, terminal
  chrome, Settings, or navigation
- a developer launch needs an environment flag to force the feature on for
  evidence capture or performance investigation

Do not use it for:

- security controls or safety gates
- data migrations
- server-driven authorization
- permanent product configuration
- code paths that must remain invisible even to local users

## Adding A Feature

1. Add a case to `ExperimentalFeature` in
   `Sources/WorkspaceManager/App/ExperimentalFeatures.swift`.
2. Add metadata:
   - stable `rawValue`
   - user-facing `title`
   - short `description`
   - `defaultEnabled`, usually `false`
   - optional `forceOnEnvironmentKey`
3. Gate SwiftUI rendering with:

   ```swift
   @ExperimentalFeatureFlag(.minimalToolbar)
   private var minimalToolbarEnabled: Bool
   ```

   Then omit the experimental UI path when the flag is false:

   ```swift
   if minimalToolbarEnabled {
       MinimalToolbarView()
   } else {
       StandardToolbarView()
   }
   ```

4. For non-SwiftUI resolver checks, use:

   ```swift
   ExperimentalFeatures.isEnabled(.minimalToolbar)
   ```

5. Add or update tests in `ExperimentalFeaturesTests` for the new metadata and
   resolver behavior.

The Settings UI enumerates `ExperimentalFeature.allCases`, so a registered
feature appears automatically under Settings -> Experimental Features when the
master toggle is on.

The Automation API is an example of a Settings-gated experiment with both user
and maintainer docs. Keep [Automation API Guide](../automation-api.md) and
[Automation API Reference](./automation-api.md) aligned when its feature flag,
environment override, or terminal environment behavior changes.

## Environment Overrides

Use a force-on environment key only for developer-launch and evidence workflows.
The current convention is a descriptive `WORKSPACES_*` key, for example:

```bash
WORKSPACES_PERF_MINIMAL_TOOLBAR=1 ./scripts/launch-dev.sh --no-build
```

Truthy values are `1`, `true`, `yes`, and `on`, case-insensitive. Any other
value is ignored and the resolver falls back to Settings state.

When any registered feature is forced on by the environment, Settings shows a
read-only note for the current launch. The note is not persisted.

## UI Rules

Experimental UI should be absent when disabled, not merely disabled or grayed
out. This keeps screenshots, accessibility trees, and automation behavior
honest for the default product state.

For SwiftUI call sites, prefer `@ExperimentalFeatureFlag` over static process
environment checks. The property wrapper is backed by `@AppStorage`, so views
re-render immediately when Settings changes.

Keep feature metadata user-facing and specific:

- title: short noun phrase, for example `Minimal Toolbar`
- description: one sentence explaining what changes on screen
- raw value: stable identifier; do not rename after release without migrating
  the stored `UserDefaults` key

## Accessibility

Settings exposes stable identifiers for automation:

- `settings.experimental.section`
- `settings.experimental.master-toggle`
- `settings.experimental.force-on-note`
- `settings.experimental.list`
- `settings.experimental.feature.<rawValue>`

When adding feature-specific UI outside Settings, add identifiers to the new
interactive controls when they are important for smoke tests or screenshots.

## Verification

For every new experimental feature:

```bash
swift test --filter ExperimentalFeaturesTests
swift test
```

If the feature affects visible app chrome, also run the local dev loop:

```bash
./scripts/build-ghosttykit.sh
swift build
./scripts/dev-smoke.sh --no-build --trust-mise
```

Capture Settings evidence showing the master toggle and feature row. For PRs,
upload screenshots or test evidence with `./scripts/evidence.sh` and include the
links in the PR body.

## Promotion Or Removal

Before making an experiment the default product behavior:

- remove the Settings gate from the shipping UI path
- remove the feature case if no other call sites need it
- delete obsolete force-on environment handling
- update tests that asserted experimental resolver behavior
- keep or migrate any persisted preference only if users still need it

Before deleting an experiment, search for the raw value, storage key, and
environment key. A removed feature should leave no visible Settings row and no
dead environment flag in production code.
