# libghostty-vt in WorkSpaces

Status as of 2026-11-07: the desktop app builds GhosttyKit from the `vt-1.0.0`
tag, and the mobile variant renders terminal output through libghostty-vt 1.0.0
in a debug-only preview. Check it still holds:
`swift test --package-path ios/Packages/TerminalScreen` passes, and its
`Links libghostty-vt 1.x` test reads the library version at runtime.

## Two libraries, one commit

Ghostty ships two C libraries from the same source tree:

| | GhosttyKit (`ghostty.h`) | libghostty-vt (`ghostty/vt.h`) |
|---|---|---|
| What it is | The full embedded terminal: PTY, renderer, input, config | A headless VT parser and screen model, with no I/O and no renderer |
| ABI | Unversioned; changes with every pin | Stable from 1.0 |
| How we get it | Built from source by `scripts/build-ghosttykit.sh` | Ghostty's signed release xcframework, pinned by URL and checksum |
| Who links it | The macOS app | `ios/Packages/TerminalScreen` |

The `vt-1.0.0` tag (`0fa3d57`) is the 1.0 cut of both, so the desktop pin and
the mobile package now name the same Ghostty commit. They may drift apart
later: the mobile package only has to follow vt releases, while the desktop pin
follows whatever GhosttyKit fixes we need.

## Why vt stays out of the desktop app

GhosttyKit already contains a full terminal. Its embedding API exports no
`ghostty_terminal_*` symbols, and the app reads screen state through the
surface API, so a second emulator in the app would have no caller. Linking the
two static archives together also fails outright. Both carry a Zig runtime, so
the link reports 35 duplicate symbols (the ubsan runtime and `memset`). They
also share 834 symbols from vendored C libraries (wuffs, simdutf, highway).
Making that link work would mean building one of them from source without its
runtime, which costs far more than it returns while nothing on the desktop
needs a headless emulator.

## The mobile package

`ios/Packages/TerminalScreen` is a standalone SwiftPM package that builds
for iOS and macOS. It stays out of the root `Package.swift` for the link reason
above, and `swift test` runs it on a Mac with no simulator. The package has
three layers:

- **`VirtualTerminal`** owns the vt handles. `write(_:)` feeds bytes to the
  parser; it is fine for an escape sequence to span two writes. `snapshot()`
  walks Ghostty's render state into plain Swift values. It returns the cached
  snapshot only when no row, the cursor, or the default colors changed. The
  render state's dirty flag tracks rows only, so a bare cursor move would
  otherwise go unseen.
- **`TerminalSnapshot`** is the screen as values: lines of `TextRun`s with a
  resolved `CellStyle`, the cursor, and the default colors. A run is either
  narrow cells (one `Character` per column) or a single wide cell, so a
  painter can place glyphs on the grid without measuring them.
- **`TerminalScreenView`** paints a snapshot on a fixed cell grid in a
  SwiftUI `Canvas`. Paint-time rules are pure functions with tests:
  `paintedCells()` handles inverse, invisible, faint and the cursor block, and
  `backgroundSpans()` merges adjacent backgrounds. Light box-drawing characters
  are drawn as cell geometry rather than font glyphs (`BoxDrawing.swift`).

Things the vt C API needs that are easy to miss:

- Sized structs need `.size = MemoryLayout<T>.size`, because Swift cannot
  import the `GHOSTTY_INIT_SIZED` macro.
- `GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_UTF8` returns
  `GHOSTTY_OUT_OF_SPACE` when the buffer is too small; grow the buffer and
  retry.
- A wide character is a `WIDE` cell followed by a `SPACER_TAIL` cell, and a
  wide character that wraps leaves a `SPACER_HEAD` cell. Skip the spacer
  cells, but still count their columns.
- The release xcframework's simulator slice is arm64 only, so the mobile
  project excludes x86_64 for the simulator SDK.
- The style flag bits are frozen in the 1.0 ABI, and `StyleFlags` mirrors them:
  bold=0, italic=1, faint=2, blink=3, inverse=4, invisible=5, strikethrough=6,
  overline=7, and underline in bits 8–10.

### Seeing it

In a Debug build of the mobile app, launch with `-terminal-preview`, or open
**Terminal preview** from the paired view's menu. The preview replays
`Fixtures/agent-turn.vt` through the emulator in 24-byte chunks, so in-place
redraws happen live. The fixture is a real PTY recording made by
`ios/Packages/TerminalScreen/scripts/record-fixture.sh`.

The preview has no live data source yet. Host-compute nodes expose no terminal
byte stream, and the web terminal's ttyd stream exists only for sandbox
providers. A live mobile terminal needs that stream first.

## Updating the vt pin

1. Find the release zip under `https://release.files.ghostty.org/libghostty-vt/<version>/`.
2. Compute its checksum: `swift package compute-checksum <zip>`, or
   `shasum -a 256 <zip>`.
3. Update the `url` and `checksum` of the `GhosttyVt` binary target in
   `ios/Packages/TerminalScreen/Package.swift`.
4. Run `swift test --package-path ios/Packages/TerminalScreen`. CI runs the
   same command in `build-and-test`.
5. Regenerate the mobile project (`xcodegen` in `ios/`), build it, and open
   the terminal preview.

Within 1.x the ABI promise means the update needs no Swift changes. A new
major version means rereading `ghostty/vt.h`.
