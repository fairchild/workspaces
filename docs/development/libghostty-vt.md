# libghostty-vt in WorkSpaces

Status as of 2026-11-07: the mobile variant renders terminal output through
libghostty-vt 1.0.0 in a debug-only preview, and web-next has a canvas
terminal on the release wasm at `/dev/terminal-vt`, waiting for the drawer to
cut over in #1848. The desktop app still builds
GhosttyKit from its earlier pin; moving it to the `vt-1.0.0` cut is tracked
separately. Check it still holds:
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

The `vt-1.0.0` tag (`0fa3d57`) is the 1.0 cut of both. The two pins are
independent: the mobile package follows vt releases, and the desktop pin
(`GHOSTTY_COMMIT` in `scripts/build-ghosttykit.sh`) follows whatever GhosttyKit
fixes the app needs.

## Why vt stays out of the desktop app

GhosttyKit already contains a full terminal. Its embedding API exports no
`ghostty_terminal_*` symbols, and the app reads screen state through the
surface API, so a second emulator in the app would have no caller. Linking the
two static archives together also fails outright. Both carry a Zig runtime, so
a test link at `vt-1.0.0` reported 35 duplicate symbols (the ubsan runtime and
`memset`). They also share 834 symbols from vendored C libraries (wuffs,
simdutf, highway).
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
`fixtures/terminal-vt/agent-turn.vt` through the emulator in 24-byte chunks,
so in-place redraws happen live. The fixture is a real PTY recording made by
`fixtures/terminal-vt/record-agent-turn.sh`.

The preview has no live data source yet. Host-compute nodes expose no terminal
byte stream, and the web terminal's ttyd stream exists only for sandbox
providers. A live mobile terminal needs that stream first.

## The web binding

`web-next/src/components/terminal/vt/` is the web counterpart of the mobile
package, on Ghostty's signed `ghostty-vt-<version>-small.wasm`
(`docs/decisions/web-terminal-libghostty-vt.md`). `GHOSTTY_VT_RELEASE` in
`ghostty-vt.ts` is the one pin: version, file, SHA-256 and the minisign key it
was verified against. `pnpm ghostty-vt:fetch` downloads the file into
`public/dev/terminal-vt/` (gitignored) and refuses a digest that differs; CI
runs it before the unit tests, so the wasm-backed tests in `vt.test.ts` run on
every PR, and with `CI=true` a missing file fails the suite instead of
skipping it. The release host sends no CORS headers, so the page loads the
file same-origin and checks the digest again before instantiating it.

The layers match the mobile package: `VtTerminal` (`ghostty-vt.ts`) owns the
handles and produces a `TerminalSnapshot` (`snapshot.ts`), `paint.ts` holds
the pure paint rules and the canvas painter, and `CanvasTerminal`
(`canvas-terminal.ts`) is the front end: textarea input, pointer, wheel and
the accessibility mirror. Input goes through the library's encoders: keys,
paste, mouse reports (modes 9, 1000, 1002, 1003 in X10, UTF-8, SGR, urxvt
and SGR-pixels formats) and focus reports (mode 1004). Selection is Ghostty's
gesture API (one click a cell, two a word, three a line), installed on the
terminal with `GHOSTTY_TERMINAL_OPT_SELECTION`, so the terminal tracks it
through scrollback and new output; copy goes through the formatter. A drag
held past the top or bottom edge ticks `AUTOSCROLL_TICK` to select into
history. The snapshot also carries the cursor's shape and blink, OSC 8 link
cells (`hyperlinkAt` resolves the URI), and each row's selected columns.

What the wasm build needs beyond the C notes above:

- Struct offsets, field widths and enum values come from `ghostty_type_json()`
  at runtime; `VtModule.write` and `read` pick the encoding from each field's
  `type`. Nothing is copied out of headers.
- By-value struct arguments (`GhosttyPoint`, `GhosttyMousePosition`,
  `GhosttyTerminalScrollViewport`) are passed by pointer in the wasm32 C ABI.
  `GhosttyCell` and `GhosttyRow` are `u64`, so they cross as `BigInt`.
- The module has no imports. `WRITE_PTY` is a hand-built trampoline module
  installed in `__indirect_function_table`. Replies are queued and sent after
  `ghostty_terminal_vt_write` returns, or a transport that echoes
  synchronously re-enters the parser.
- `GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT` does nothing in the wasm
  build. Every use of it in `src/input/key_encode.zig` sits behind
  `builtin.target.os.tag == .macos`, which is false for wasm32-freestanding,
  so Alt in the event's mods always means Alt. `keyInput()` in
  `canvas-terminal.ts` applies the policy instead: Option as Alt keeps the Alt
  modifier and sends the key's own character (Option+B → `ESC b`); Option
  composing drops Alt and sends the composed text (`∫`). The default is
  `"false"`, Ghostty's default.
- `GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES` defaults to 10,000 bytes,
  which history keeps as one page, a few hundred rows at 80 columns. The
  binding lifts it to `SIZE_MAX` so `scrollbackLines` (10,000 by default)
  is the limit.
- Syncing the mouse encoder from the terminal, and setting its size, both
  clear its last-cell state, so the binding syncs only after a write and sets
  the size only when it changes; otherwise motion within one cell would be
  reported on every pixel.
- On the alternate screen with mode 1007 on, the wheel sends arrow keys
  rather than scrolling, which has nothing to scroll there.
- The library maps mouse pixels to cells with integer cell sizes, and canvas
  cells are fractional CSS pixels, so the front end scales pointer positions
  onto a whole-pixel grid before encoding.

`/dev/terminal-vt` is the comparison harness against ghostty-web until #1848
removes it. `?source=parity` writes the screen `tests/e2e/terminal-vt.spec.ts`
drives with real pointer, keyboard, focus and IME events; its screenshots land
in `web-next/output/terminal-vt/`, uploaded by CI as `terminal-vt-evidence`.

## The shared fixture corpus

`fixtures/terminal-vt/` is the contract both bindings answer to. Each fixture
is a `.vt` byte stream and a `<name>.golden.json` of the final screen;
`corpus.json` gives each one's grid size and `chunk`, the bytes per write
(one write when absent). `FixtureCorpusTests` in the mobile package and
`fixture-corpus.test.ts` in web-next replay every fixture and compare row by
row, so a disagreement names the fixture and the row.

A golden holds only what both snapshots expose: the grid, the default colors,
the cursor's position and whether it sits on the right half of a wide
character, and per row a list of runs with their column, text, width and
style. Each test splits its binding's runs back into cells and rebuilds one
canonical shape: trailing blanks that paint nothing are dropped, and only
narrow cells holding one code point, in one style, merge. Anything only one
binding reports stays out: the web snapshot's overline, hyperlink, cursor
shape and blink, selection and scrollback position. Swift compares text by
code point, since its `String` equality would pass `e` + U+0301 for `é`.

To add a fixture:

1. Write the stream. Synthetic ones are functions in `synthesize.py`, so a
   review reads the bytes; run `uv run --script fixtures/terminal-vt/synthesize.py`.
   A recording from a real program goes in as the `.vt` file it produced.
2. Add an entry to `corpus.json`. Both suites fail on a stream the manifest
   does not list.
3. Write the golden from web-next:
   `UPDATE_VT_GOLDENS=1 pnpm vitest run src/components/terminal/vt/fixture-corpus.test.ts`.
   Read it against Ghostty's semantics before committing it; the writer
   records what the binding did, right or wrong.
4. Run `swift test --package-path ios/Packages/TerminalScreen`. If Swift
   disagrees, one binding is wrong: find which against Ghostty, then fix it
   or record the difference in a test that names it.

To regenerate every golden after a pin bump, run step 3 without adding
anything, review the diff, and run step 4.

`web-next/public/dev/terminal-vt/agent-turn.vt` is a byte-identical copy that
the `/dev/terminal-vt` harness serves and `vt.test.ts` reads; the corpus test
fails if the two drift.

## Updating the vt pin

1. Find the release zip under `https://release.files.ghostty.org/libghostty-vt/<version>/`.
2. Compute its checksum: `swift package compute-checksum <zip>`, or
   `shasum -a 256 <zip>`.
3. Update the `url` and `checksum` of the `GhosttyVt` binary target in
   `ios/Packages/TerminalScreen/Package.swift`.
4. Run `swift test --package-path ios/Packages/TerminalScreen`. CI runs the
   same command in `build-and-test`. It replays the fixture corpus, so a
   changed screen shows up as a golden mismatch.
5. Regenerate the mobile project (`xcodegen` in `ios/`), build it, and open
   the terminal preview.

For the web binding, verify the new `ghostty-vt-<version>-small.wasm` with
`minisign -Vm <file> -P <key>`, then update `version`, `file`, `sha256` and
`origin` in `GHOSTTY_VT_RELEASE` and run `pnpm ghostty-vt:fetch && pnpm test`
in `web-next/`. When the new release changes a screen on purpose, regenerate
the goldens (see the corpus section) and run both suites.

Within 1.x the ABI promise means the update needs no Swift or TypeScript changes. A new
major version means rereading `ghostty/vt.h`.
