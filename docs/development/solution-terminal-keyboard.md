# Solution: Terminal Keyboard Input with GhosttyKit

## Summary

Keyboard/focus handling is now implemented directly in `GhosttySurfaceView` using
AppKit responder APIs plus a small local event monitor.

## Current Architecture

- Focus coordinator: `Sources/WorkspaceManager/Controllers/TerminalWindowController.swift`
- Terminal surface: `Sources/WorkspaceManager/Terminal/GhosttySurfaceView.swift`
- Input conversion: `Sources/WorkspaceManager/Terminal/GhosttyInput.swift`
- App runtime callbacks: `Sources/WorkspaceManager/Terminal/GhosttyAppManager.swift`

## Event Flow

```text
User key press
  -> GhosttySurfaceView.keyDown(with:)
  -> ghostty_surface_key_translation_mods(...)
  -> GhosttyInput.keyEvent(...)
  -> ghostty_surface_key(...)
```

For text composition:

```text
interpretKeyEvents(...)
  -> NSTextInputClient insertText / setMarkedText
  -> ghostty_surface_text / ghostty_surface_preedit
```

## Focus Flow

```text
Window/surface appears
  -> TerminalFocusManager.registerWindow(window)
  -> TerminalFocusManager.requestFocus(for: surface)
  -> window.makeFirstResponder(surface)
  -> ghostty_surface_set_focus(surface, true)
```

When the app becomes active/inactive:

- `AppDelegate.applicationDidBecomeActive` -> `ghostty_app_set_focus(app, true)`
- `AppDelegate.applicationDidResignActive` -> `ghostty_app_set_focus(app, false)`

## Local Monitor (Minimal)

`GhosttySurfaceView` installs a local monitor for:

- `.leftMouseDown`: restores first responder when clicking inactive/unfocused window
- `.keyUp`: forwards command-modified keyUp events that AppKit may skip in the normal chain

This keeps interception narrow and avoids broad key event hijacking.

## Why This Replaced the Old Approach

The previous SwiftTerm stack required `NSViewControllerRepresentable` + broad event
monitoring to bypass SwiftUI interception. With GhosttyKit, input/focus is handled in a
single AppKit `NSView` (`GhosttySurfaceView`) that owns surface lifecycle and directly
calls `ghostty_surface_*` APIs.

## Debug Checklist

1. Is `GhosttyAppManager` initialized?
2. Is first responder `GhosttySurfaceView`?
3. Does `GhosttySurfaceView.keyDown(with:)` fire?
4. Are callbacks from `ghostty_runtime_config_s` firing (`wakeup`, `action`, clipboard)?
5. Is `ghostty_app_set_focus` synchronized with app activation state?
