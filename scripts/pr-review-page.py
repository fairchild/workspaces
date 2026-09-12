#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Build a readable front page for one pull request.

A dense PR body holds everything and shows nothing. This writes a single
self-contained HTML page a person reads in two minutes: what changed and why in
plain language, a diagram of the shape, the diff grouped under the sentence that
explains it, the evidence shown rather than linked, and where the PR stands.

Reads the PR through `gh` (or a recorded fixture, for tests), writes
`<out>/<number>.html`, and on request uploads it to the evidence store and
writes `Review page: <url>` into the PR body.

The prose here is the PR's own: the opening lines are the first sentence of each
Summary bullet and the group headings are those same sentences, so a factory turn
that writes better sentences improves the page without touching this file. Every
text source is `plain_language`.

To draw the shape yourself rather than take the generated graph, put a ```mermaid
fence under a `<!-- review-page:diagram -->` marker in the PR body. The fence is
the only carrier: GitHub renders it there too, and a comment's contents are not
something a parser and a browser agree on.

Usage:
  uv run --script scripts/pr-review-page.py --pr 1602
  uv run --script scripts/pr-review-page.py --pr 1602 --head d13afd8e --upload --link
  uv run --script scripts/pr-review-page.py --fixture scripts/tests/fixtures/pr-review-page/1602
"""

from __future__ import annotations

import argparse
import html
import json
import re
import shutil
import subprocess
import sys
import tempfile
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parents[1]
DEFAULT_OUT = REPO_ROOT / "build" / "pr-review"
DEFAULT_REPO = "fairchild/workspaces"
EVIDENCE_SCRIPT = REPO_ROOT / "scripts" / "evidence.sh"
MERMAID_CDN = "https://cdnjs.cloudflare.com/ajax/libs/mermaid/10.9.1/mermaid.min.js"
GH_TIMEOUT = 120
MMDC_TIMEOUT = 180
UPLOAD_TIMEOUT = 300

PR_FIELDS = (
    "number,title,body,headRefOid,state,isDraft,author,url,labels,reviews,"
    "comments,statusCheckRollup,files,additions,deletions,baseRefName,"
    "headRefName,createdAt,updatedAt"
)

SECTIONS = (
    "What changed and why",
    "The shape of the change",
    "The diff by concern",
    "Evidence",
    "Where it stands",
)
EVERYTHING_ELSE = "Everything else"
LINK_PREFIX = "Review page: "

EVIDENCE_SECTIONS = ("Evidence", "Evidence Status", "Validation")
IMAGE_SUFFIXES = (".png", ".jpg", ".jpeg", ".gif", ".webp", ".svg")
COMMAND_STARTS = (
    "swift", "uv", "pnpm", "npm", "bun", "yarn", "python3", "python", "bash",
    "sh", "mise", "gh", "git", "cargo", "make", "xcrun", "actionlint", "rg",
    "curl", "./scripts", "scripts/", "node", "deno", "ruby", "go",
)

# A code span is where a PR body puts the names that exist in the diff. Four
# characters is the floor because shorter identifiers ("run", "app", "id") match
# half the tree and would claim hunks they have nothing to do with.
TOKEN_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]{3,}")
PATH_RE = re.compile(r"[A-Za-z0-9_][\w./-]*\.(?:swift|py|sh|ts|tsx|js|jsx|yml|yaml|md|json|toml)")
CITATION_RE = re.compile(r"([\w./-]+\.\w+):(\d+)(?:-(\d+))?")
CODE_SPAN_RE = re.compile(r"`([^`]+)`")
IMAGE_MD_RE = re.compile(r"!\[([^\]]*)\]\((\S+?)\)")
LINK_MD_RE = re.compile(r"(?<!!)\[([^\]]+)\]\((\S+?)\)")
HUNK_HEADER_RE = re.compile(r"^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@(.*)$")
# An authored diagram is a ```mermaid fence under a `<!-- review-page:diagram -->`
# marker, and never the inside of a comment. Where a comment ends is not one
# answer: a browser ends it at `--!>` as well as at `-->`, and `-->` is also a
# mermaid edge, so anything reading a comment for content ends up disagreeing
# with the renderer about where that content stopped -- and the text after the
# disagreement is prose to a reader of the PR and diagram source here
# (`py/bad-tag-filter`). The fence has one reading, and GitHub draws it in the
# body as well.
DIAGRAM_MARKER_RE = re.compile(
    r"<!--\s*review-page:diagram\s*-->\s*```mermaid\n(.*?)```", re.DOTALL
)
SENTENCE_SPLIT_RE = re.compile(r"(?<=[.!?])\s+(?=[A-Z\"(])")


@dataclass
class Source:
    """One PR, from `gh` or from a recorded fixture."""

    pr: dict
    diff: str
    threads: list[dict] = field(default_factory=list)


@dataclass
class Hunk:
    path: str
    header: str
    body: str
    old_start: int
    old_end: int

    @property
    def added(self) -> str:
        return "\n".join(line for line in self.body.splitlines() if line.startswith("+"))


@dataclass
class Bullet:
    """A Summary bullet: its whole text claims hunks, its first sentence titles them."""

    text: str
    heading: str
    paths: set[str]
    tokens: set[str]
    citations: list[tuple[str, int, int]]


@dataclass
class Group:
    heading: str
    hunks: list[Hunk]
    bullet: Bullet | None = None


# --------------------------------------------------------------------------
# Reading the PR
# --------------------------------------------------------------------------


def _run(argv: list[str], *, timeout: int) -> str:
    result = subprocess.run(argv, capture_output=True, text=True, timeout=timeout)
    if result.returncode != 0:
        raise RuntimeError(f"{argv[0]} failed ({result.returncode}): {result.stderr.strip()}")
    return result.stdout


def read_pr(number: int, repo: str = DEFAULT_REPO) -> Source:
    pr = json.loads(_run(
        ["gh", "pr", "view", str(number), "--repo", repo, "--json", PR_FIELDS],
        timeout=GH_TIMEOUT,
    ))
    diff = _run(["gh", "pr", "diff", str(number), "--repo", repo], timeout=GH_TIMEOUT)
    return Source(pr=pr, diff=diff, threads=read_threads(number, repo))


def read_threads(number: int, repo: str = DEFAULT_REPO) -> list[dict]:
    """Review threads, which `gh pr view --json` does not carry.

    A page that cannot say whether a conversation is still open is worse than one
    that says it does not know, so a failure here degrades to no threads rather
    than taking the build down with it.
    """
    owner, _, name = repo.partition("/")
    query = """
    query($owner:String!,$repo:String!,$number:Int!){
      repository(owner:$owner,name:$repo){
        pullRequest(number:$number){
          reviewThreads(first:100){
            nodes{ isResolved isOutdated path line
              comments(first:1){ nodes{ author{login} body } } }
          }
        }
      }
    }
    """
    try:
        payload = json.loads(_run(
            [
                "gh", "api", "graphql", "-f", f"query={query}",
                "-F", f"owner={owner}", "-F", f"repo={name}", "-F", f"number={number}",
            ],
            timeout=GH_TIMEOUT,
        ))
    except (RuntimeError, subprocess.SubprocessError, json.JSONDecodeError):
        return []
    return payload["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]


def load_fixture(directory: Path | str) -> Source:
    directory = Path(directory)
    threads_file = directory / "threads.json"
    threads = json.loads(threads_file.read_text()) if threads_file.is_file() else []
    return Source(
        pr=json.loads((directory / "pr.json").read_text()),
        diff=(directory / "pr.diff").read_text(),
        threads=threads,
    )


# --------------------------------------------------------------------------
# The PR body, read as prose
# --------------------------------------------------------------------------


def body_sections(body: str) -> dict[str, str]:
    """Markdown `## ` sections, keyed by heading."""
    sections: dict[str, str] = {}
    heading = ""
    lines: list[str] = []
    for line in body.splitlines():
        if line.startswith("## "):
            if heading:
                sections[heading] = "\n".join(lines)
            heading = line[3:].strip()
            lines = []
        elif heading:
            lines.append(line)
    if heading:
        sections[heading] = "\n".join(lines)
    return sections


def summary_bullets(body: str) -> list[str]:
    """Top-level `- ` items of the Summary section, continuation lines folded in.

    A blank line ends the list. Without that, an indented block further down the
    section -- a diagram, a table, a fenced example -- is indented like a
    continuation and lands inside the last bullet, where it becomes prose the
    page then reads out loud.
    """
    section = body_sections(body).get("Summary", "")
    bullets: list[str] = []
    folding = False
    for line in section.splitlines():
        if re.match(r"^[-*] ", line):
            bullets.append(line[2:].strip())
            folding = True
        elif not line.strip():
            folding = False
        elif folding and bullets and line.startswith((" ", "\t")):
            bullets[-1] += " " + line.strip()
        else:
            folding = False
    return bullets


def readable(text: str) -> str:
    """A body sentence with its citations removed and its code spans unwrapped.

    Deleting the identifiers would leave a sentence about nothing, so the spans
    lose their backticks and keep their words; the parentheses that exist only to
    carry a file path are what goes.
    """
    text = re.sub(r"\(([^()]*)\)", lambda m: "" if PATH_RE.search(m.group(1)) else m.group(0), text)
    text = CODE_SPAN_RE.sub(lambda m: m.group(1), text)
    text = re.sub(r"\*\*([^*]+)\*\*", r"\1", text)
    text = PATH_RE.sub("", text)
    text = re.sub(r"\s+([,.;:])", r"\1", text)
    return re.sub(r"\s+", " ", text).strip()


def first_sentence(text: str) -> str:
    """The opening sentence of already-`readable` text.

    Order matters: a sentence that ends inside a citation ends on `).` followed
    by a code span, and no boundary is visible until the citations and backticks
    are gone. Splitting the raw bullet swallows the whole paragraph.
    """
    parts = SENTENCE_SPLIT_RE.split(text.strip(), maxsplit=1)
    return parts[0].strip() if parts else text.strip()


def plain_language(pr: dict) -> list[str]:
    """The five-line opening, and the only place the page's prose comes from.

    First cut: the first sentence of each Summary bullet. A factory turn that
    writes real plain language replaces this function's body and nothing else.
    """
    lines = [first_sentence(readable(bullet)) for bullet in summary_bullets(pr.get("body") or "")]
    lines = [line for line in lines if line]
    return lines[:5] or [pr.get("title", "").strip()]


def closes_issue(body: str) -> str | None:
    match = re.search(r"(?i)\bcloses\s+#(\d+)", body or "")
    return f"#{match.group(1)}" if match else None


# --------------------------------------------------------------------------
# The diff, grouped by concern
# --------------------------------------------------------------------------


def parse_hunks(diff: str) -> list[Hunk]:
    hunks: list[Hunk] = []
    path = ""
    header = ""
    old_start = old_len = 0
    lines: list[str] = []

    def flush() -> None:
        if header:
            hunks.append(Hunk(
                path=path,
                header=header,
                body="\n".join(lines),
                old_start=old_start,
                old_end=old_start + max(old_len - 1, 0),
            ))

    for line in diff.splitlines():
        if line.startswith("diff --git "):
            flush()
            header = ""
            lines = []
            path = line.split(" b/", 1)[-1].strip()
        elif (match := HUNK_HEADER_RE.match(line)) :
            flush()
            header = line
            lines = []
            old_start = int(match.group(1))
            old_len = int(match.group(2) or 1)
        elif header:
            lines.append(line)
    flush()
    return hunks


def make_bullet(text: str) -> Bullet:
    spans = CODE_SPAN_RE.findall(text)
    paths = {p for span in spans for p in PATH_RE.findall(span)} | set(PATH_RE.findall(text))
    citations = [
        (path, int(start), int(end or start))
        for path, start, end in CITATION_RE.findall(text)
    ]
    tokens = {token for span in spans for token in TOKEN_RE.findall(span)}
    tokens -= {p.split("/")[-1] for p in paths}
    return Bullet(
        text=text,
        heading=first_sentence(readable(text)),
        paths=paths,
        tokens=tokens,
        citations=citations,
    )


def _token_hits(tokens: set[str], text: str) -> int:
    return sum(1 for token in tokens if re.search(rf"\b{re.escape(token)}\b", text))


def claim_score(bullet: Bullet, hunk: Hunk) -> tuple[int, int, int]:
    """How strong this bullet's claim on this hunk is, strongest component first.

    A cited line range is a claim on a place and outranks everything. Otherwise a
    bullet claims a hunk by the names it shares with what the hunk *adds* — what
    the change does is what the sentence is explaining — and a hunk that adds
    nothing recognisable is scored on its whole text instead. Naming the file is
    the weakest claim there is, enough only to keep a hunk out of the leftovers.
    """
    ranged = 0
    for path, start, end in bullet.citations:
        if hunk.path.endswith(path) and start <= hunk.old_end and end >= hunk.old_start:
            ranged = 1
            break
    hits = _token_hits(bullet.tokens, hunk.added)
    if hits == 0:
        hits = _token_hits(bullet.tokens, hunk.body)
    named = 1 if any(hunk.path.endswith(path) for path in bullet.paths) else 0
    return (ranged, hits, named)


def group_hunks(source: Source) -> list[Group]:
    """Hunks filed under the Summary sentence that explains them.

    Ties go to the earlier bullet, so a body that says the same thing twice files
    the hunk under the first telling rather than splitting it.
    """
    bullets = [make_bullet(text) for text in summary_bullets(source.pr.get("body") or "")]
    claimed: dict[int, list[Hunk]] = {index: [] for index in range(len(bullets))}
    leftovers: list[Hunk] = []

    for hunk in parse_hunks(source.diff):
        best_index, best_score = -1, (0, 0, 0)
        for index, bullet in enumerate(bullets):
            score = claim_score(bullet, hunk)
            if score > best_score:
                best_index, best_score = index, score
        if best_index < 0:
            leftovers.append(hunk)
        else:
            claimed[best_index].append(hunk)

    groups = [
        Group(heading=bullets[index].heading, hunks=hunks, bullet=bullets[index])
        for index, hunks in claimed.items()
        if hunks
    ]
    if leftovers:
        groups.append(Group(heading=EVERYTHING_ELSE, hunks=leftovers))
    return groups


# --------------------------------------------------------------------------
# The diagram
# --------------------------------------------------------------------------


def _node_id(path: str) -> str:
    return "n" + re.sub(r"[^A-Za-z0-9]", "", path)[-24:]


def diagram_source(source: Source) -> str:
    """The body's own mermaid fence, or a small graph of what the PR touches."""
    body = source.pr.get("body") or ""
    if match := DIAGRAM_MARKER_RE.search(body):
        return match.group(1).strip()

    paths = [entry["path"] for entry in source.pr.get("files", [])]
    root = closes_issue(body) or f"#{source.pr.get('number', '')}"
    lines = ["graph TD", f'  root["{root}"]']
    for path in paths:
        lines.append(f'  root --> {_node_id(path)}["{Path(path).name}"]')
    for path in paths:
        covered = _covered_by(path, paths)
        if covered:
            lines.append(f"  {_node_id(path)} -. tests .-> {_node_id(covered)}")
    return "\n".join(lines)


def _covered_by(test_path: str, paths: list[str]) -> str | None:
    """The file a test file covers, by this repo's two naming conventions."""
    name = Path(test_path).name
    candidates = []
    if name.endswith("Tests.swift"):
        candidates.append(name[: -len("Tests.swift")] + ".swift")
    if name.startswith("test_"):
        candidates.append(name[len("test_") :])
    for candidate in candidates:
        for path in paths:
            if path != test_path and Path(path).name == candidate:
                return path
    return None


def render_diagram(mermaid: str) -> str:
    """Inline SVG where a renderer exists, else the browser renders it."""
    mmdc = shutil.which("mmdc")
    if mmdc:
        with tempfile.TemporaryDirectory() as work:
            source_file = Path(work) / "diagram.mmd"
            out_file = Path(work) / "diagram.svg"
            source_file.write_text(mermaid)
            try:
                subprocess.run(
                    [mmdc, "-i", str(source_file), "-o", str(out_file),
                     "-b", "transparent", "-t", "neutral"],
                    capture_output=True,
                    text=True,
                    timeout=MMDC_TIMEOUT,
                    check=True,
                )
                return f'<div class="diagram">{out_file.read_text()}</div>'
            except (subprocess.SubprocessError, OSError):
                pass
    return (
        f'<pre class="mermaid">{html.escape(mermaid)}</pre>\n'
        f'<script src="{MERMAID_CDN}"></script>\n'
        '<script>mermaid.initialize({startOnLoad:true,theme:"neutral"});</script>'
    )


# --------------------------------------------------------------------------
# Evidence
# --------------------------------------------------------------------------


@dataclass
class EvidenceItems:
    images: list[tuple[str, str]]
    commands: list[tuple[str, str]]
    links: list[tuple[str, str]]


def _looks_like_command(span: str) -> bool:
    return span.strip().startswith(COMMAND_STARTS)


def evidence_items(pr: dict) -> EvidenceItems:
    sections = body_sections(pr.get("body") or "")
    images: list[tuple[str, str]] = []
    commands: list[tuple[str, str]] = []
    links: list[tuple[str, str]] = []
    seen_commands: set[str] = set()
    seen_links: set[str] = set()

    for name in EVIDENCE_SECTIONS:
        text = sections.get(name)
        if not text:
            continue
        for alt, url in IMAGE_MD_RE.findall(text):
            images.append((url, alt or name))
        for line in text.splitlines():
            stripped = line.strip().lstrip("-*[ ]").strip()
            if not stripped:
                continue
            spans = CODE_SPAN_RE.findall(line)
            command = next((span for span in spans if _looks_like_command(span)), None)
            if command and command not in seen_commands:
                seen_commands.add(command)
                remainder = line.replace(f"`{command}`", "", 1)
                commands.append((command, readable(remainder).lstrip("-:— ").strip()))
        for label, url in LINK_MD_RE.findall(text):
            if url.lower().endswith(IMAGE_SUFFIXES):
                images.append((url, label))
            elif url.startswith("http") and url not in seen_links:
                seen_links.add(url)
                links.append((url, label))
    return EvidenceItems(images=images, commands=commands, links=links)


# --------------------------------------------------------------------------
# Where it stands
# --------------------------------------------------------------------------


def latest_reviews(pr: dict) -> list[tuple[str, str, str]]:
    latest: dict[str, dict] = {}
    for review in pr.get("reviews") or []:
        login = (review.get("author") or {}).get("login", "someone")
        if review.get("state") == "COMMENTED" and login in latest:
            continue
        current = latest.get(login)
        if not current or (review.get("submittedAt") or "") >= (current.get("submittedAt") or ""):
            latest[login] = review
    return [
        (login, review.get("state", "").replace("_", " ").title(), (review.get("submittedAt") or "")[:10])
        for login, review in sorted(latest.items())
    ]


def open_threads(threads: list[dict]) -> list[tuple[str, str, str]]:
    open_ones = []
    for thread in threads:
        if thread.get("isResolved"):
            continue
        comments = (thread.get("comments") or {}).get("nodes") or []
        first = comments[0] if comments else {}
        author = (first.get("author") or {}).get("login", "someone")
        text = (first.get("body") or "").strip().splitlines()
        where = thread.get("path") or "the pull request"
        if thread.get("line"):
            where = f"{where}:{thread['line']}"
        open_ones.append((where, author, text[0] if text else ""))
    return open_ones


def check_summary(pr: dict) -> tuple[dict[str, int], list[tuple[str, str, str]]]:
    latest: dict[str, dict] = {}
    for check in pr.get("statusCheckRollup") or []:
        name = check.get("name") or check.get("context") or "check"
        current = latest.get(name)
        stamp = check.get("completedAt") or check.get("startedAt") or ""
        if not current or stamp >= (current.get("completedAt") or current.get("startedAt") or ""):
            latest[name] = check
    tally: dict[str, int] = {}
    unhappy: list[tuple[str, str, str]] = []
    for name, check in sorted(latest.items()):
        verdict = (check.get("conclusion") or check.get("state") or check.get("status") or "").upper()
        verdict = verdict or "PENDING"
        tally[verdict] = tally.get(verdict, 0) + 1
        if verdict not in {"SUCCESS", "SKIPPED", "NEUTRAL"}:
            unhappy.append((name, verdict.title(), check.get("detailsUrl") or check.get("targetUrl") or ""))
    return tally, unhappy


# --------------------------------------------------------------------------
# The page
# --------------------------------------------------------------------------


STYLE = """
:root {
  color-scheme: light dark;
  --ink: #16191d; --muted: #5c6470; --rule: #dfe3e8; --bg: #fbfbfa;
  --card: #ffffff; --accent: #1c5d99; --add: #e5f4e7; --del: #fbe9e9;
  --addink: #14532d; --delink: #7f1d1d; --chip: #eef1f4;
}
@media (prefers-color-scheme: dark) {
  :root {
    --ink: #e6e8eb; --muted: #9aa3ae; --rule: #2c3238; --bg: #14171a;
    --card: #1a1e22; --accent: #7fb2e5; --add: #16301f; --del: #34191b;
    --addink: #9fe0b4; --delink: #f0a9a9; --chip: #232a30;
  }
}
* { box-sizing: border-box; }
body {
  margin: 0; background: var(--bg); color: var(--ink);
  font: 16px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif;
}
.wrap { max-width: 60rem; margin: 0 auto; padding: 2.5rem 1.25rem 4rem; }
header { border-bottom: 1px solid var(--rule); padding-bottom: 1.25rem; margin-bottom: 2rem; }
.eyebrow { color: var(--muted); font-size: .8rem; letter-spacing: .06em; text-transform: uppercase; margin: 0 0 .4rem; }
h1 { font-size: 1.75rem; line-height: 1.25; margin: 0 0 .5rem; letter-spacing: -.01em; }
h2 { font-size: 1.15rem; margin: 2.5rem 0 .75rem; letter-spacing: -.005em; }
h3 { font-size: 1rem; margin: 1.5rem 0 .5rem; font-weight: 600; }
a { color: var(--accent); }
.meta { color: var(--muted); font-size: .9rem; margin: 0; }
.lede li { margin: .35rem 0; }
.lede { padding-left: 1.1rem; }
.card { background: var(--card); border: 1px solid var(--rule); border-radius: 10px; padding: 1rem 1.1rem; }
.diagram, pre.mermaid { background: var(--card); border: 1px solid var(--rule); border-radius: 10px; padding: 1rem; overflow-x: auto; text-align: center; }
details { border: 1px solid var(--rule); border-radius: 10px; background: var(--card); margin: .75rem 0; }
details > summary { cursor: pointer; padding: .7rem .9rem; font-weight: 600; }
details[open] > summary { border-bottom: 1px solid var(--rule); }
.hunk { margin: 0; padding: .25rem 0 0; }
.hunk figcaption { color: var(--muted); font-size: .78rem; padding: .5rem .9rem .25rem; font-family: ui-monospace, SFMono-Regular, Menlo, monospace; }
pre.diff { margin: 0 0 .5rem; padding: .5rem .9rem .9rem; overflow-x: auto; font: 12.5px/1.55 ui-monospace, SFMono-Regular, Menlo, monospace; }
pre.diff span { display: block; white-space: pre; }
pre.diff .a { background: var(--add); color: var(--addink); }
pre.diff .d { background: var(--del); color: var(--delink); }
pre.diff .h { color: var(--muted); }
.evidence img { max-width: 100%; border: 1px solid var(--rule); border-radius: 8px; display: block; margin: .5rem 0; }
table { border-collapse: collapse; width: 100%; font-size: .92rem; }
td, th { text-align: left; padding: .4rem .6rem; border-bottom: 1px solid var(--rule); vertical-align: top; }
code { font-family: ui-monospace, SFMono-Regular, Menlo, monospace; font-size: .88em; background: var(--chip); padding: .1rem .3rem; border-radius: 4px; }
.chip { display: inline-block; background: var(--chip); border-radius: 999px; padding: .1rem .6rem; font-size: .8rem; color: var(--muted); }
.stands li { margin: .3rem 0; }
footer { margin-top: 3rem; border-top: 1px solid var(--rule); padding-top: 1rem; color: var(--muted); font-size: .85rem; }
"""


def _esc(text: object) -> str:
    return html.escape(str(text), quote=True)


def _diff_html(hunk: Hunk) -> str:
    rows = []
    for line in hunk.body.splitlines():
        css = "a" if line.startswith("+") else "d" if line.startswith("-") else ""
        rows.append(f'<span class="{css}">{_esc(line) or "&nbsp;"}</span>' if css
                    else f"<span>{_esc(line) or '&nbsp;'}</span>")
    caption = f"{hunk.path} {hunk.header.split('@@')[1].strip()}"
    return (
        f'<figure class="hunk"><figcaption>{_esc(caption)}</figcaption>'
        f'<pre class="diff">{"".join(rows)}</pre></figure>'
    )


def build_page(source: Source, head: str | None = None) -> str:
    pr = source.pr
    actual_head = pr.get("headRefOid", "")
    if head and not actual_head.startswith(head.strip()):
        raise ValueError(
            f"--head {head} is not this PR's head ({actual_head}); "
            "the page states the head it was built from, so it will not claim another"
        )

    number = pr.get("number", "")
    title = pr.get("title", "")
    author = (pr.get("author") or {}).get("login", "someone")
    files = pr.get("files") or []
    issue = closes_issue(pr.get("body") or "")
    state = "Draft" if pr.get("isDraft") else (pr.get("state") or "").title()

    parts: list[str] = []
    parts.append("<!doctype html>")
    parts.append('<html lang="en"><head><meta charset="utf-8">')
    parts.append('<meta name="viewport" content="width=device-width, initial-scale=1">')
    parts.append(f"<title>#{_esc(number)} — {_esc(title)}</title>")
    parts.append(f"<style>{STYLE}</style></head><body><div class=\"wrap\">")

    parts.append("<header>")
    parts.append(
        f'<p class="eyebrow">Pull request #{_esc(number)} · head {_esc(actual_head[:8])}</p>'
    )
    parts.append(f"<h1>{_esc(title)}</h1>")
    closes = f" · closes {_esc(issue)}" if issue else ""
    parts.append(
        f'<p class="meta">{_esc(author)} · {_esc(state)} · '
        f'+{_esc(pr.get("additions", 0))} −{_esc(pr.get("deletions", 0))} '
        f"across {len(files)} file{'s' if len(files) != 1 else ''}{closes} · "
        f'<a href="{_esc(pr.get("url", ""))}">the pull request itself</a></p>'
    )
    parts.append("</header><main>")

    # 1. What changed and why
    parts.append(f'<section id="why"><h2>{SECTIONS[0]}</h2><ul class="lede">')
    for line in plain_language(pr):
        parts.append(f"<li>{_esc(line)}</li>")
    parts.append("</ul></section>")

    # 2. The shape of the change
    parts.append(f'<section id="shape"><h2>{SECTIONS[1]}</h2>')
    parts.append(render_diagram(diagram_source(source)))
    parts.append("</section>")

    # 3. The diff by concern
    groups = group_hunks(source)
    parts.append(f'<section id="diff"><h2>{SECTIONS[2]}</h2>')
    if not groups:
        parts.append('<p class="meta">No file changes in this pull request.</p>')
    for index, group in enumerate(groups):
        count = len(group.hunks)
        opened = " open" if index == 0 else ""
        parts.append(f"<details{opened}><summary>{_esc(group.heading)} "
                     f'<span class="chip">{count} hunk{"s" if count != 1 else ""}</span></summary>')
        for hunk in group.hunks:
            parts.append(_diff_html(hunk))
        parts.append("</details>")
    parts.append("</section>")

    # 4. Evidence
    items = evidence_items(pr)
    parts.append(f'<section id="evidence" class="evidence"><h2>{SECTIONS[3]}</h2>')
    if items.images:
        for url, alt in items.images:
            parts.append(f'<figure><img src="{_esc(url)}" alt="{_esc(alt)}">'
                         f"<figcaption>{_esc(alt)}</figcaption></figure>")
    if items.commands:
        parts.append("<h3>What was run</h3><table><tbody>")
        for command, result in items.commands:
            parts.append(f"<tr><td><code>{_esc(command)}</code></td><td>{_esc(result)}</td></tr>")
        parts.append("</tbody></table>")
    if items.links:
        parts.append("<h3>Linked</h3><ul>")
        for url, label in items.links:
            parts.append(f'<li><a href="{_esc(url)}">{_esc(label)}</a></li>')
        parts.append("</ul>")
    if not (items.images or items.commands or items.links):
        parts.append('<p class="meta">The PR body carries no evidence section.</p>')
    parts.append("</section>")

    # 5. Where it stands
    parts.append(f'<section id="stands" class="stands"><h2>{SECTIONS[4]}</h2><ul>')
    reviews = latest_reviews(pr)
    if reviews:
        for login, verdict, when in reviews:
            parts.append(f"<li>{_esc(login)} — {_esc(verdict)}{_esc(' on ' + when if when else '')}</li>")
    else:
        parts.append("<li>No reviews yet.</li>")
    threads = open_threads(source.threads)
    if threads:
        for where, who, text in threads:
            parts.append(f"<li>Open thread on <code>{_esc(where)}</code> — {_esc(who)}: {_esc(text)}</li>")
    else:
        parts.append("<li>No open review threads.</li>")
    tally, unhappy = check_summary(pr)
    if tally:
        counted = ", ".join(f"{count} {verdict.lower()}" for verdict, count in sorted(tally.items()))
        parts.append(f"<li>Checks: {_esc(counted)}.</li>")
        for name, verdict, url in unhappy:
            link = f' — <a href="{_esc(url)}">the run</a>' if url else ""
            parts.append(f"<li>{_esc(name)}: {_esc(verdict)}{link}</li>")
    else:
        parts.append("<li>No checks reported.</li>")
    parts.append("</ul></section></main>")

    built = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")
    parts.append(
        f'<footer>Built by <code>scripts/pr-review-page.py</code> from pull request '
        f"#{_esc(number)} at {_esc(actual_head[:8])}, {_esc(built)}. "
        "The pull request itself remains the record; this is its front.</footer>"
    )
    parts.append("</div></body></html>")
    return "\n".join(parts) + "\n"


# --------------------------------------------------------------------------
# Publishing
# --------------------------------------------------------------------------


def body_with_link(body: str, url: str) -> str:
    """The PR body with `Review page: <url>` as the first line after the byline.

    Every other byte is left alone, hidden blocks included: the line is inserted
    or rewritten in place, never appended, and never written twice.
    """
    lines = body.splitlines()
    line = f"{LINK_PREFIX}{url}"
    for index, existing in enumerate(lines):
        if existing.startswith(LINK_PREFIX):
            lines[index] = line
            return "\n".join(lines) + ("\n" if body.endswith("\n") else "")

    insert_at = 0
    for index, existing in enumerate(lines):
        if not existing.strip():
            continue
        if re.fullmatch(r"\*[^*].*[^*]\*", existing.strip()) or re.fullmatch(r"_[^_].*[^_]_", existing.strip()):
            insert_at = index + 1
        break

    if insert_at == 0:
        block = [line, ""]
    else:
        block = ["", line]
    lines[insert_at:insert_at] = block
    return "\n".join(lines) + ("\n" if body.endswith("\n") else "")


def upload(path: Path, number: int, name: str) -> str:
    """Upload through `evidence.sh`, which is what knows where the token lives."""
    result = subprocess.run(
        [
            str(EVIDENCE_SCRIPT), "--pr", str(number), "--name", name,
            "--file", str(path), "--no-capture",
        ],
        capture_output=True,
        text=True,
        timeout=UPLOAD_TIMEOUT,
    )
    if result.returncode != 0:
        raise RuntimeError(f"upload failed ({result.returncode}): {result.stderr.strip()}")
    urls = [line.strip() for line in result.stdout.splitlines() if line.strip().startswith("http")]
    if not urls:
        raise RuntimeError("upload reported success but printed no URL")
    return urls[-1]


def write_link(number: int, url: str, repo: str) -> None:
    """Insert the link into the body the PR has right now.

    The body read when the page was built is minutes old by the time this runs,
    and writing that one back would silently revert whatever the author changed
    in between.
    """
    body = json.loads(_run(
        ["gh", "pr", "view", str(number), "--repo", repo, "--json", "body"],
        timeout=GH_TIMEOUT,
    ))["body"]
    linked = body_with_link(body, url)
    if linked == body:
        return
    with tempfile.NamedTemporaryFile("w", suffix=".md", delete=False) as handle:
        handle.write(linked)
        body_file = handle.name
    try:
        _run(
            ["gh", "pr", "edit", str(number), "--repo", repo, "--body-file", body_file],
            timeout=GH_TIMEOUT,
        )
    finally:
        Path(body_file).unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--pr", type=int, help="Pull request number")
    parser.add_argument("--head", default=None, help="Refuse to build unless the PR's head is this sha")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help=f"Output directory (default: {DEFAULT_OUT})")
    parser.add_argument("--repo", default=DEFAULT_REPO, help=f"Repository (default: {DEFAULT_REPO})")
    parser.add_argument("--fixture", type=Path, default=None, help="Build from a recorded fixture directory")
    parser.add_argument("--upload", action="store_true", help="Upload the page and print its URL")
    parser.add_argument("--url", default=None, help="An already-uploaded page URL, for --link")
    parser.add_argument("--link", action="store_true", help="Write `Review page: <url>` into the PR body")
    args = parser.parse_args()

    if args.fixture:
        source = load_fixture(args.fixture)
    elif args.pr:
        source = read_pr(args.pr, args.repo)
    else:
        parser.error("one of --pr or --fixture is required")

    number = args.pr or source.pr.get("number")
    try:
        page = build_page(source, head=args.head)
    except ValueError as error:
        print(f"error: {error}", file=sys.stderr)
        return 1

    args.out.mkdir(parents=True, exist_ok=True)
    out_file = args.out / f"{number}.html"
    out_file.write_text(page)
    print(out_file)

    url = args.url
    if args.upload:
        url = upload(out_file, number, f"pr-review-{number}")
        print(url)

    if args.link:
        if not url:
            print("error: --link needs a URL; pass --upload or --url", file=sys.stderr)
            return 1
        if args.fixture:
            print("error: --link edits a live PR body and will not run from a fixture", file=sys.stderr)
            return 1
        write_link(number, url, args.repo)
        print(f"linked from the body of #{number}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
