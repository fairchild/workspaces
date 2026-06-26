---
status: decided
date: 2026-06-06
decision: app-owned-theme-config-applied-live
related:
  - docs/development/libghostty-integration.md
  - docs/development/shortcut-routing.md
---

# App-owned Ghostty config carries WorkSpaces terminal defaults, applied live

## Decision

**WorkSpaces manages embedded-terminal defaults through a small, app-owned
Ghostty config file that it generates and loads itself, and applies live via
`ghostty_app_update_config` / `ghostty_surface_update_config`.** The file holds
only WorkSpaces-owned keys such as scrollbar visibility, mouse scroll speed, and
an optional `theme = light:<L>,dark:<D>` line. It lives under the
`WORKSPACES_DATA_DIR` convention (`<dataDir>/ghostty/workspaces.config`),
separate from the bundled resources directory that supplies terminfo and the
theme catalog.

This was chosen over two alternatives the generic "libghostty" guidance steers
toward — driving colors with OSC escape sequences, or recreating surfaces to
pick up a new theme.

## Why this works here

The repo embeds Ghostty via the **apprt** C API (the same surface the official
Ghostty.app uses), not libghostty-vt. The pinned header (ghostty
`332b2aefc6`) exposes the real reload path:

- `ghostty_config_new()` → `ghostty_config_load_file(path)` → `ghostty_config_finalize()`
- `ghostty_app_update_config(app, cfg)` and `ghostty_surface_update_config(surface, cfg)`
  push a new config — including `theme = …` — to **live** surfaces with no
  recreation and no lost scrollback.

So a behavior or theme change is: rewrite the file, rebuild a fresh
`ghostty_config_t`, broadcast it to the app and every registered surface, then free the previous
config. This mirrors how reload-config works in the real app and gives us all
~460 bundled iTerm2 themes by name plus native dual light/dark, where the active
half follows the macOS appearance via the existing `set_color_scheme` path.

## Tradeoffs

- **Empirical dependency.** The live recolor relies on `surface_update_config`
  re-theming an existing surface in this exact pinned build. Confidence is high
  (it is the official reload path), but it is verified end-to-end before each
  release-relevant change; the fallback — rebuilding the surface — loses
  scrollback and is avoided unless forced.
- **Isolated from `~/.config/ghostty`.** We deliberately do **not** load the
  user's Ghostty config. That keeps the shortcut-routing / keybind contract
  intact (see `docs/development/shortcut-routing.md`) at the cost of not
  inheriting a user's personal Ghostty theme automatically.
- **Config lifetime.** Exactly one `ghostty_config_t` is owned at a time; the
  previous one is freed after each `update_config` broadcast to avoid leaks.
- **Single-sided pairs are invalid.** Ghostty rejects `theme = light:foo`
  without a `dark:` peer, so an unset slot is filled with `Builtin Light` /
  `Builtin Dark`. When neither slot is set, no theme line is written, but the
  WorkSpaces-managed non-theme defaults are still loaded.

## Surface registry

Because the broadcast must reach every open terminal, `GhosttyAppManager` keeps
a weak set of live `GhosttySurfaceView`s (`NSHashTable.weakObjects()`). Surfaces
register on successful `ghostty_surface_new` and drop automatically on
deallocation, so a theme change reaches all of them and a stale surface can
never be visited.
