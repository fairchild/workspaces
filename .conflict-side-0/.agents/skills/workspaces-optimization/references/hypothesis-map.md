# Workspaces Performance Hypothesis Map

Use this lookup table after you have evidence from the diagnostic zip, `host_perf_probe.py`, or the repo perf scripts.

## Symptom Patterns

### `launch_to_first_prompt` is very large and `repo_hydration` is very small

Interpretation:

- Startup slowdown is concentrated in terminal readiness or focus restoration.
- Repo discovery is not the dominant startup cost.

Common suspects:

- synchronous Ghostty surface creation
- login shell startup
- main-thread starvation before `makeFirstResponder`
- host-side monitoring or security tooling delaying PTY or exec-heavy flows

### Login shell is much slower than clean shell

Interpretation:

- The shell environment is a likely bottleneck.
- The app may only be exposing the same cost earlier and more visibly.

Common suspects:

- `.zshrc`, `.zprofile`, `.zlogin`, or equivalent shell init files
- prompt frameworks
- repo-aware prompt logic
- `direnv`, `mise`, `asdf`, `rbenv`, `pyenv`, `nvm`, or similar startup hooks
- host-side monitoring or policy tooling scanning shell startup or repo traversal

### Terminal.app is slow in the same repo

Interpretation:

- Treat this as host-side or shell-side until proven otherwise.
- Ghostty may still add overhead, but it is not the first thing to blame.

### Terminal.app is fast, clean shell is fast, but Workspaces is slow

Interpretation:

- Focus on the embedded-terminal path inside the app.

Common suspects:

- `ghostty_surface_new(...)`
- synchronous `GhosttySurfaceView` creation on the main actor
- focus retry delays
- app activation and first-responder timing

### `terminal_first_output` is early but `first_prompt_ready` is much later

Interpretation:

- The shell emitted an early readiness signal, but the prompt was not ready immediately afterward.
- The remaining delay is after the first shell response rather than before the terminal wakes up.

Common suspects:

- prompt rendering or prompt-title hooks that run after the first shell signal
- repo-aware prompt logic
- shell integration emitting an early title or PWD update before the prompt is actually usable

### Slow only when `tmux Per Session` is enabled

Interpretation:

- Separate tmux startup or session attach cost from the base shell and Ghostty path.

Common suspects:

- shell init plus tmux
- tmux plugin manager
- session bootstrap commands

### Diagnostic zip has empty `recent-logs.txt`

Interpretation:

- That does not mean the app had no useful events.
- It usually means the exporter did not capture the relevant log channel.

Current limitation:

- older builds pulled a narrower unified-log query, so some important `[Perf]` lines emitted through `NSLog` were easy to miss
- newer builds broaden the export query to include `WorkspaceManager` process logs and `[Perf]` event messages, but a near-empty file still means the report is missing runtime context

### Activity Monitor shows low CPU and the app sample is mostly idle

Interpretation:

- The app is not obviously compute-bound.
- The wall-clock delay may be outside the app's hot path, intermittent, or sitting in a child process that the app-only sample did not capture.

Common suspects:

- child shell or tmux startup and prompt logic
- host-side monitoring or security software around PTY, exec, or repo traversal
- input-path interference from keyboard tools, IMEs, accessibility software, or event taps
- renderer or compositor throttling that only shows up during active typing or redraw, not in an idle sample

What this pattern does **not** prove:

- it does not clear the app itself
- it does not prove the shell is the only issue
- it does not prove host-side monitoring is the cause

Next step:

- capture `sample` for both `WorkspaceManager` and the child shell while reproducing active lag

## Code Paths To Inspect

- `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- `Sources/WorkspaceManager/Terminal/GhosttyTerminalConfig.swift`
- `Sources/WorkspaceManager/Views/Components/TerminalView.swift`
- `Sources/WorkspaceManager/Controllers/TerminalWindowController.swift`
- `Sources/WorkspaceManager/Diagnostics/PerformanceSignposts.swift`

## Decision Rule

Always prefer the explanation that accounts for both:

1. where the measured time moved
2. which environment variants reproduce the slowdown

If a theory explains only one of those, it is not strong enough yet.
