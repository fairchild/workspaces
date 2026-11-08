#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Writes the corpus's synthetic `.vt` streams, one function per fixture.

The bytes live here as readable Python so a review sees what each fixture
sends; the `.vt` files are this script's output. `agent-turn.vt` is a real
PTY recording made by `record-agent-turn.sh` instead.

    uv run --script fixtures/terminal-vt/synthesize.py
"""

from collections.abc import Callable
from pathlib import Path

ESC = "\x1b"
CSI = ESC + "["
OSC = ESC + "]"
ST = ESC + "\\"
CRLF = "\r\n"


def sgr(params: str, text: str, reset: str = "0") -> str:
    return f"{CSI}{params}m{text}{CSI}{reset}m"


def wide_screen() -> str:
    """Row 0 starts with two wide characters. Row 1's seven narrow cells leave
    one column, too narrow for 完, so it wraps to row 2 and leaves a spacer
    head in row 1's last column."""
    return "完成x" + CRLF + "abcdefg完"


def wide_cursor_left() -> str:
    return wide_screen() + f"{CSI}1;1H"


def wide_cursor_right() -> str:
    return wide_screen() + f"{CSI}1;2H"


def wide_cursor_spacer_head() -> str:
    return wide_screen() + f"{CSI}2;8H"


GRAPHEMES = " ".join(
    [
        "é",
        "ạ̈",
        "\U0001f468‍\U0001f469‍\U0001f467",
        "\U0001f1ef\U0001f1f5",
        "\U0001f44d\U0001f3fd",
        "❤️",
        "क्षि",
    ]
)


def graphemes() -> str:
    """The same clusters with mode 2027 (grapheme clustering) off, then on.
    The trailing bar shows the width each mode gave the line."""
    return (
        f"{CSI}?2027l"
        + "off "
        + GRAPHEMES
        + " |"
        + CRLF
        + f"{CSI}?2027h"
        + "on  "
        + GRAPHEMES
        + " |"
        + CRLF
    )


def split_escape() -> str:
    """Every kind of sequence the parser holds state for between writes. The
    manifest replays it one byte per write, so each sequence, and each
    multi-byte UTF-8 character, arrives split at every possible point."""
    return (
        sgr("1;31", "red")
        + " "
        + sgr("38;2;1;2;3", "tc")
        + " "
        + f"{OSC}0;title\x07"
        + f"{OSC}8;;https://example.com{ST}link{OSC}8;;{ST}"
        + " 完✅"
        + CRLF
        + f"{CSI}5 q"
        + f"{ESC}7"
        + "saved"
        + f"{ESC}8"
        + "S"
        + f"{ESC}P$q m{ST}"
        + f"{CSI}2;20H{CSI}48;5;27m  {CSI}0m"
        + f"{CSI}3;1H"
        + "tail"
    )


def scrollback() -> str:
    """Forty colored lines through a five-row screen, then a prompt with no
    newline: the viewport holds lines 37 to 40 and the prompt."""
    lines = "".join(sgr(f"3{n % 8}", f"line {n:02}") + CRLF for n in range(1, 41))
    return lines + "end"


def sgr_colors() -> str:
    rows = [
        " ".join(
            [
                sgr("1", "bold", "22"),
                sgr("2", "faint", "22"),
                sgr("3", "italic", "23"),
                sgr("4", "under", "24"),
                sgr("4:3", "curly", "4:0"),
                sgr("21", "double", "24"),
            ]
        ),
        " ".join(
            [
                sgr("5", "blink", "25"),
                sgr("7", "inverse", "27"),
                sgr("8", "invisible", "28"),
                sgr("9", "strike", "29"),
                sgr("53", "over", "55"),
            ]
        ),
        sgr("1;3;4;9", "all") + " " + sgr("1;2", "bold+faint") + " " + sgr("7;31;42", "inv-colored"),
        "".join(sgr(str(n), str(n), "39") for n in range(30, 38)),
        "".join(sgr(str(n), str(n), "39") for n in range(90, 98)),
        "".join(sgr(str(n), str(n), "49") for n in range(40, 48)),
        "".join(sgr(str(n), str(n), "49") for n in range(100, 108)),
        "".join(sgr(f"38;5;{n}", f"{n:>4}", "39") for n in (16, 46, 196, 208, 226, 232, 244, 255)),
        "".join(sgr(f"48;5;{n}", f"{n:>4}", "49") for n in (16, 46, 196, 208, 226, 232, 244, 255)),
        sgr("38;2;255;128;0", "orange") + " " + sgr("48;2;0;64;128", "navy") + " " + sgr("38:2::10:20:30", "colon"),
        sgr("58;2;255;0;0;4", "red underline") + " " + sgr("39;49", "defaults"),
        "bg blanks" + sgr("44", "   "),
        "underlined blanks" + sgr("4", "   "),
        "plain blanks" + sgr("1", "   "),
    ]
    return CRLF.join(rows)


FIXTURES: dict[str, Callable[[], str]] = {
    "wide-cursor-left": wide_cursor_left,
    "wide-cursor-right": wide_cursor_right,
    "wide-cursor-spacer-head": wide_cursor_spacer_head,
    "graphemes": graphemes,
    "split-escape": split_escape,
    "scrollback": scrollback,
    "sgr-colors": sgr_colors,
}


def main() -> None:
    here = Path(__file__).resolve().parent
    for name, build in FIXTURES.items():
        path = here / f"{name}.vt"
        path.write_bytes(build().encode())
        print(f"wrote {path.name} ({path.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
