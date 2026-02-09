# Terminal Troubleshooting (GhosttyKit)

## Terminal Library

WorkspaceManager now embeds Ghostty via `GhosttyKit.xcframework`.

For integration internals and upgrade steps, see:
`docs/development/libghostty-integration.md`.

- Runtime glue: `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`
- Surface view: `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- Input mapping: `Sources/WorkspaceManager/Terminal/GhosttyInput.swift`
- SwiftUI bridge: `Sources/WorkspaceManager/Views/Components/TerminalView.swift`

## Common Failures

### 1. `swift build` fails: missing `Frameworks/GhosttyKit.xcframework`

Build GhosttyKit first:

```bash
./scripts/build-ghosttykit.sh
```

The framework is intentionally gitignored and generated locally.

### 2. Ghostty build fails on a fresh machine/CI

Checks:

1. `mise --version`
2. `xcodebuild -version`
3. network access to clone/fetch Ghostty

`build-ghosttykit.sh` will auto-clone Ghostty when `GHOSTTY_DIR` is not set,
pin to the required commit, and run `zig` through `mise`.

### 3. Terminal renders but no keyboard input

Focus pipeline now is:

1. `TerminalFocusManager.requestFocus(for:)`
2. `NSWindow.makeFirstResponder(GhosttySurfaceView)`
3. `GhosttySurfaceView` key overrides call `ghostty_surface_key(...)`

Diagnostic checks:

- App active? (`NSApp.isActive`)
- Window key? (`window.isKeyWindow`)
- First responder is `GhosttySurfaceView`?

### 4. Command key combinations behave inconsistently

`GhosttySurfaceView` installs a minimal local monitor for `.keyUp` and `.leftMouseDown`
to cover AppKit/SwiftUI responder edge cases. If command combos regress, inspect:

- `GhosttySurfaceView.handleLocalEvent(_:)`
- `GhosttySurfaceView.keyDown(with:)`
- `GhosttyInput.ghosttyCharacters(from:)`

### 5. Clipboard paste/read issues

Clipboard callbacks are handled in `GhosttyAppManager`:

- `readClipboard(...)`
- `writeClipboard(...)`
- `confirmReadClipboard(...)`

For debugging, add temporary `NSLog` lines in those callbacks and verify
`ghostty_surface_complete_clipboard_request(...)` is called.

## Useful Commands

```bash
./scripts/build-ghosttykit.sh
swift build
swift test
swift run WorkspaceManager
```

## Notes

- Ghostty C API is pinned by commit in `scripts/build-ghosttykit.sh`.
- `Frameworks/` is generated output and should not be committed.
- The app currently uses surface/runtime config only (font size, command, env, cwd).
