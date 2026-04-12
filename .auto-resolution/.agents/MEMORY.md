# Memory

## CI and Runner Isolation

- Never target bare `self-hosted` in this repo. Every self-hosted workflow job should use an explicit purpose-specific runner label.
- Treat the interactive laptop host as unsuitable for intrusive UI/perf automation by default.
- Keep release/signing on a dedicated host runner lane and move app-launching validation to an isolated lane such as a Tart-backed VM runner.

## Terminal-First Product Rules

- Default terminal surfaces to minimal chrome. Extra headers and context bars should disappear unless they add clear value.
- Repo overview and terminal views follow different rules: overview can carry metadata and actions; terminal views should stay almost entirely canvas.
- Sidebar actions should be discoverable but quiet: avoid right-click-only primary actions, but also avoid persistent controls that add noise.

## App State and Navigation

- Persist stable IDs in navigation/restore state, not live SwiftData model objects.
- Reconstruct model references late and validate persisted selections against current data before restoring them.
- Deletion and fallback handling should be centralized and deterministic, especially for repo/workspace/web selection state.

## Release Discipline

- App version metadata, tag version, and packaged artifact version must come from one source of truth and be validated before release.
- Release tooling should refuse no-op releases and tag/version mismatches.

## Debugging Heuristic

- If `WorkspaceManager` opens or closes unexpectedly on a developer machine, check the launching process and executable path first before treating it as an app bug.
