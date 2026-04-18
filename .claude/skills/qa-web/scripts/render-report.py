#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""Aggregate qa-web run artifacts into REPORT.md + report.html.

Walks output/qa-agent/<DATE>/ for finding.md files, groups by severity,
embeds screenshots inline (base64) for the HTML, and emits a decision
menu so the caller can act on each finding.

Usage:
    render-report.py <run-dir>              # e.g. output/qa-agent/2026-04-18
    render-report.py --open <run-dir>       # also opens report.html in browser
"""

from __future__ import annotations

import argparse
import base64
import json
import re
import subprocess
import sys
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path

SEVERITY_ORDER = ["P0", "P1", "gap", "nit"]
SEVERITY_ICON = {"P0": "🚨", "P1": "⚠️", "gap": "🔭", "nit": "💭"}
SEVERITY_LABEL = {
    "P0": "P0 — user-blocking / data-loss / security",
    "P1": "P1 — serious degradation",
    "gap": "gap — uncovered behavior worth automating",
    "nit": "nit — cosmetic",
}
# Map loose severity words (from WCAG, axe, casual usage) onto our 4 buckets.
SEVERITY_ALIASES = {
    "p0": "P0", "critical": "P0", "blocker": "P0",
    "p1": "P1", "serious": "P1", "major": "P1", "high": "P1",
    "gap": "gap",
    "nit": "nit", "minor": "nit", "moderate": "nit",
    "cosmetic": "nit", "low": "nit",
}


@dataclass
class Finding:
    slug: str
    path: Path
    body: str
    severity: str = "nit"
    title: str = ""
    page: str = ""
    viewport: str = ""
    oracle: str = ""
    screenshots: list[Path] = field(default_factory=list)
    axe_counts: dict[str, int] | None = None

    @classmethod
    def from_dir(cls, d: Path) -> Finding | None:
        fm = d / "finding.md"
        if not fm.exists():
            return None
        body = fm.read_text()
        f = cls(slug=d.name, path=fm, body=body)
        header = re.search(r"^#\s+Finding:\s*(.+?)$", body, re.M)
        if header:
            f.title = header.group(1).strip()
        sev = re.search(r"\*\*Severity:\*\*\s*(\w+)", body)
        if sev:
            token = sev.group(1).lower()
            f.severity = SEVERITY_ALIASES.get(token, "nit")
        for field_name in ("Page", "Viewport", "Oracle"):
            m = re.search(rf"\*\*{field_name}:\*\*\s*(.+?)$", body, re.M)
            if m:
                setattr(f, field_name.lower(), m.group(1).strip())
        f.screenshots = sorted(d.glob("*.png"))
        axe_files = sorted(d.glob("*-axe.json"))
        if axe_files:
            try:
                axe_data = json.loads(axe_files[0].read_text())
                f.axe_counts = axe_data.get("counts")
            except (json.JSONDecodeError, KeyError):
                pass
        return f


def _implicit_from_axe(d: Path) -> Finding | None:
    axe_files = sorted(d.glob("*-axe.json"))
    if not axe_files:
        return None
    total_critical = total_serious = total_moderate = 0
    pages_with_issues: list[str] = []
    for af in axe_files:
        try:
            data = json.loads(af.read_text())
        except json.JSONDecodeError:
            continue
        c = data.get("counts", {})
        total_critical += c.get("critical", 0)
        total_serious += c.get("serious", 0)
        total_moderate += c.get("moderate", 0)
        if c.get("critical") or c.get("serious") or c.get("moderate"):
            pages_with_issues.append(af.stem.replace("-axe", ""))
    if total_critical + total_serious + total_moderate == 0:
        return None
    if total_critical:
        sev = "P0"
    elif total_serious:
        sev = "P1"
    else:
        sev = "nit"
    counts = {"critical": total_critical, "serious": total_serious, "moderate": total_moderate}
    pages_str = ", ".join(pages_with_issues)
    body = (
        f"# Finding: axe violations on {pages_str}\n\n"
        f"**Severity:** {sev}\n"
        f"**Page:** {pages_str}\n\n"
        "_Implicit finding (no finding.md written by the probe)._ "
        "Axe counts across the pages in this slug:\n\n"
        + "\n".join(f"- **{k}**: {v}" for k, v in counts.items() if v)
    )
    return Finding(
        slug=d.name,
        path=d,
        body=body,
        severity=sev,
        title=f"axe violations on {pages_str}",
        page=pages_str,
        screenshots=sorted(d.glob("*.png")),
        axe_counts=counts,
    )


def discover(run_dir: Path) -> list[Finding]:
    findings: list[Finding] = []
    for d in sorted(run_dir.iterdir()):
        if not d.is_dir():
            continue
        f = Finding.from_dir(d) or _implicit_from_axe(d)
        if f:
            findings.append(f)
    return findings


def group_by_severity(findings: list[Finding]) -> dict[str, list[Finding]]:
    g: dict[str, list[Finding]] = {s: [] for s in SEVERITY_ORDER}
    for f in findings:
        g.setdefault(f.severity, []).append(f)
    return g


def _finding_summary(f: Finding) -> str:
    parts = [f"**{f.title or f.slug}**"]
    if f.page:
        parts.append(f"`{f.page}`")
    if f.axe_counts:
        axe = ", ".join(f"{k}={v}" for k, v in f.axe_counts.items() if v)
        if axe:
            parts.append(f"axe: {axe}")
    return " · ".join(parts)


def _evidence_urls(f: Finding, run_dir: Path) -> list[tuple[str, str]]:
    """Return (label, url_or_path) for each piece of evidence. Uses remote URLs
    from evidence-urls.json if present, else local relative paths."""
    urls_file = run_dir / "evidence-urls.json"
    remote: dict[str, str] = {}
    if urls_file.exists():
        try:
            remote = json.loads(urls_file.read_text())
        except json.JSONDecodeError:
            pass
    out: list[tuple[str, str]] = []
    for shot in f.screenshots:
        rel = str(shot.relative_to(run_dir))
        out.append((shot.stem, remote.get(rel, rel)))
    return out


def generate_fix_prompt(run_dir: Path, findings: list[Finding]) -> str:
    """Build the 'hand this to an agent session to fix' prompt."""
    grouped = group_by_severity(findings)
    fix_worthy = grouped.get("P0", []) + grouped.get("P1", [])
    if not fix_worthy:
        fix_worthy = findings  # if nothing is P0/P1, cover everything
    urls_file = run_dir / "evidence-urls.json"
    has_remote = urls_file.exists()
    lines: list[str] = []
    lines.append(f"Fix the QA findings from run `{run_dir}`.")
    lines.append("")
    if has_remote:
        lines.append("Screenshots and axe dumps are hosted in R2 — fetch them to see the failing state:")
    else:
        lines.append("Evidence is local under the run directory. If you need an agent without repo access to see it, run `./scripts/evidence.sh --file <path>` to upload each screenshot and paste URLs into this prompt.")
    lines.append("")
    for i, f in enumerate(fix_worthy, 1):
        lines.append(f"## {i}. [{f.severity}] {f.title or f.slug}")
        if f.page:
            lines.append(f"- Page: `{f.page}`")
        if f.viewport:
            lines.append(f"- Viewport: {f.viewport}")
        if f.oracle:
            lines.append(f"- Expected (oracle): {f.oracle}")
        if f.axe_counts:
            axe = ", ".join(f"{k}={v}" for k, v in f.axe_counts.items() if v)
            lines.append(f"- Axe counts: {axe}")
        for label, url in _evidence_urls(f, run_dir):
            lines.append(f"- Screenshot (`{label}`): {url}")
        lines.append(f"- Finding details: `{run_dir}/{f.slug}/finding.md`")
        lines.append("")
    lines.append("For each finding: locate the responsible code, propose a fix that addresses the oracle (not just the symptom), and write a failing test first when practical. Do NOT modify `web/e2e/**`, `web/tests/LEDGER.md`, or `web/specs/**` — those are the qa-web-agent's territory. When done, summarize the fix and ask me to run `/qa heal` if any existing tests need updates.")
    return "\n".join(lines)


def render_markdown(run_dir: Path, findings: list[Finding]) -> str:
    grouped = group_by_severity(findings)
    total = len(findings)
    counts = " · ".join(
        f"{SEVERITY_ICON[s]} {len(grouped.get(s, []))} {s}"
        for s in SEVERITY_ORDER
        if grouped.get(s)
    )
    lines: list[str] = []
    lines.append(f"# qa-web run — {run_dir.name}")
    lines.append("")
    lines.append(f"**Findings:** {total} total — {counts or 'none'}")
    lines.append(f"**Run directory:** `{run_dir}`")
    lines.append(f"**Generated:** {datetime.now(UTC).strftime('%Y-%m-%d %H:%M UTC')}")
    lines.append("")
    lines.append(GLOSSARY_MD)
    lines.append("")
    lines.append("---")
    for sev in SEVERITY_ORDER:
        bucket = grouped.get(sev) or []
        if not bucket:
            continue
        lines.append(f"\n## {SEVERITY_ICON[sev]} {SEVERITY_LABEL[sev]} ({len(bucket)})\n")
        for f in bucket:
            lines.append("<details>")
            lines.append(f"<summary>{_finding_summary(f)}</summary>")
            lines.append("")
            meta = []
            if f.page:
                meta.append(f"**Page:** `{f.page}`")
            if f.viewport:
                meta.append(f"**Viewport:** {f.viewport}")
            if f.oracle:
                meta.append(f"**Oracle:** {f.oracle}")
            if f.axe_counts:
                meta.append("**Axe:** " + ", ".join(f"{k}={v}" for k, v in f.axe_counts.items()))
            if meta:
                lines.append("  ".join(meta) + "\n")
            for shot in f.screenshots:
                rel = shot.relative_to(run_dir)
                lines.append(f"![{shot.stem}]({rel})\n")
            lines.append(f"_Details_: [`{f.slug}/finding.md`]({f.slug}/finding.md)")
            lines.append("")
            lines.append("</details>")
            lines.append("")
    lines.append("\n---\n\n## Decisions\n")
    lines.append("For each finding above, pick one:\n")
    lines.append("- **🔧 Promote** to an automated test — `/qa author <slug>`")
    lines.append("- **📝 Log as [gap]** in `web/tests/LEDGER.md` for later")
    lines.append("- **🐛 Fix in product** — see the fix-prompt block below")
    lines.append("- **✅ Dismiss** — not actionable, document why")
    lines.append("- **🔍 Investigate** further — `/qa explore <area>` scoped tighter")
    lines.append("")
    lines.append("Reply with the mapping, e.g. `dashboard-color-contrast → promote, landing-empty-state → dismiss`.")
    lines.append("")
    lines.append("## Fix prompt (paste into an agent session)")
    lines.append("")
    lines.append("```")
    lines.append(generate_fix_prompt(run_dir, findings))
    lines.append("```")
    lines.append("")
    return "\n".join(lines)


def render_html(run_dir: Path, findings: list[Finding]) -> str:
    grouped = group_by_severity(findings)
    total = len(findings)
    fix_prompt = generate_fix_prompt(run_dir, findings)
    parts: list[str] = []
    parts.append("<!doctype html><html><head><meta charset='utf-8'>")
    parts.append(f"<title>qa-web run — {run_dir.name}</title>")
    parts.append("""<style>
    body{font:14px/1.5 -apple-system,BlinkMacSystemFont,sans-serif;max-width:980px;margin:24px auto;padding:0 24px;color:#222;}
    h1{margin:0 0 4px;font-size:26px}
    h2{margin:28px 0 8px;padding-bottom:4px;border-bottom:1px solid #ddd;font-size:18px}
    header{padding:12px 16px;background:#f6f8fa;border-radius:6px;margin-bottom:24px}
    .meta{color:#555;font-size:13px}
    details.finding{border:1px solid #e1e4e8;border-radius:6px;margin:10px 0;background:#fff}
    details.finding.P0{border-left:4px solid #d73a49}
    details.finding.P1{border-left:4px solid #e36209}
    details.finding.gap{border-left:4px solid #0366d6}
    details.finding.nit{border-left:4px solid #6a737d}
    details.finding > summary{padding:12px 16px;cursor:pointer;font-size:14px;list-style:none;display:flex;align-items:center;gap:8px}
    details.finding > summary::-webkit-details-marker{display:none}
    details.finding > summary::before{content:"▸";color:#888;font-size:12px;transition:transform .15s}
    details.finding[open] > summary::before{transform:rotate(90deg)}
    details.finding > summary .sev{font-size:14px}
    details.finding > summary .title{font-weight:600;margin-right:auto}
    details.finding > summary .sub{color:#666;font-size:12px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace}
    details.finding .body{padding:0 16px 14px;border-top:1px solid #f1f2f4}
    .shot{max-width:100%;border:1px solid #ddd;border-radius:4px;margin:10px 0;cursor:zoom-in;display:block}
    .shot.full{max-width:none;cursor:zoom-out}
    details.inner{margin:8px 0}
    details.inner summary{cursor:pointer;color:#0366d6;font-size:13px}
    pre{background:#f6f8fa;padding:10px;border-radius:4px;overflow:auto;font-size:12px;white-space:pre-wrap;word-break:break-word}
    .pill{display:inline-block;padding:2px 8px;border-radius:10px;background:#eef;font-size:12px;color:#336;margin-right:6px}
    .decisions{margin-top:30px;padding:16px;background:#fffbea;border:1px solid #f4e09a;border-radius:6px}
    .decisions li{margin:4px 0}
    details.glossary{margin:16px 0;padding:0;border:1px solid #e1e4e8;border-radius:6px;background:#fafbfc}
    details.glossary > summary{padding:12px 16px;cursor:pointer;font-weight:600;color:#0366d6;list-style:none}
    details.glossary > summary::-webkit-details-marker{display:none}
    details.glossary > summary::before{content:"▸";margin-right:6px;color:#888;transition:transform .15s;display:inline-block}
    details.glossary[open] > summary::before{transform:rotate(90deg)}
    details.glossary .glossary-body{padding:0 16px 14px;border-top:1px solid #eee}
    details.glossary h3{margin:16px 0 6px;font-size:14px;border:0;padding:0}
    details.glossary p, details.glossary li{font-size:13px}
    details.glossary code{background:#f0f2f5;padding:1px 4px;border-radius:3px;font-size:12px}
    a.term{color:#0366d6;text-decoration:none;border-bottom:1px dotted #0366d6}
    a.term:hover{border-bottom-style:solid}
    .fix-card{margin-top:24px;padding:16px;background:#f0f7ff;border:1px solid #c6dafc;border-radius:6px}
    .fix-card h2{margin:0 0 8px;border:0}
    .fix-card .hint{color:#555;font-size:13px;margin:0 0 10px}
    .copy-row{display:flex;justify-content:flex-end;margin-bottom:6px;gap:6px}
    .copy-btn{font:inherit;padding:6px 12px;border:1px solid #2060c0;background:#2060c0;color:#fff;border-radius:4px;cursor:pointer;font-size:13px}
    .copy-btn:hover{background:#1a4fa0}
    .copy-btn.ok{background:#2ea043;border-color:#2ea043}
    details.fix-raw{margin-top:8px}
    details.fix-raw summary{cursor:pointer;color:#0366d6;font-size:13px}
    </style>""")
    parts.append("""<script>
    document.addEventListener('click', e => {
        if (e.target.classList && e.target.classList.contains('shot')) e.target.classList.toggle('full');
        if (e.target.dataset && e.target.dataset.copyTarget) {
            const pre = document.getElementById(e.target.dataset.copyTarget);
            if (!pre) return;
            const text = pre.innerText;
            const btn = e.target;
            const restore = btn.textContent;
            navigator.clipboard.writeText(text).then(() => {
                btn.textContent = '✓ Copied';
                btn.classList.add('ok');
                setTimeout(() => { btn.textContent = restore; btn.classList.remove('ok'); }, 1500);
            }).catch(() => {
                // fallback: manual selection
                const r = document.createRange(); r.selectNodeContents(pre);
                const s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
                btn.textContent = 'Select & ⌘C';
            });
        }
    });
    </script>""")
    parts.append("</head><body>")
    counts_html = " · ".join(
        f"<span class='pill'>{SEVERITY_ICON[s]} {len(grouped.get(s, []))} {s}</span>"
        for s in SEVERITY_ORDER
        if grouped.get(s)
    ) or "<em>none</em>"
    parts.append("<header>")
    parts.append(f"<h1>qa-web run — {run_dir.name}</h1>")
    parts.append(f"<div class='meta'><strong>{total}</strong> findings · {counts_html}</div>")
    parts.append(f"<div class='meta'>{run_dir} · generated {datetime.now(UTC).strftime('%Y-%m-%d %H:%M UTC')}</div>")
    parts.append("</header>")
    parts.append(GLOSSARY_HTML)
    for sev in SEVERITY_ORDER:
        bucket = grouped.get(sev) or []
        if not bucket:
            continue
        parts.append(f"<h2>{SEVERITY_ICON[sev]} {SEVERITY_LABEL[sev]} ({len(bucket)})</h2>")
        for f in bucket:
            sub_bits: list[str] = []
            if f.page:
                sub_bits.append(_esc(f.page))
            if f.axe_counts:
                axe_str = ", ".join(f"{k}={v}" for k, v in f.axe_counts.items() if v)
                if axe_str:
                    sub_bits.append(f"<a class='term' href='#glossary-axe' title='What is axe? See glossary.'>axe</a> {axe_str}")
            sub = " · ".join(sub_bits)
            parts.append(f"<details class='finding {sev}'>")
            parts.append("<summary>")
            parts.append(f"<span class='sev'>{SEVERITY_ICON[sev]}</span>")
            parts.append(f"<span class='title'>{_esc(f.title or f.slug)}</span>")
            if sub:
                parts.append(f"<span class='sub'>{sub}</span>")
            parts.append("</summary>")
            parts.append("<div class='body'>")
            meta = []
            if f.viewport:
                meta.append(f"viewport {_esc(f.viewport)}")
            if f.oracle:
                meta.append(f"oracle: {_esc(f.oracle)}")
            if meta:
                parts.append(f"<div class='meta'>{' · '.join(meta)}</div>")
            for shot in f.screenshots:
                b64 = base64.b64encode(shot.read_bytes()).decode("ascii")
                parts.append(f"<img class='shot' src='data:image/png;base64,{b64}' alt='{_esc(shot.stem)}'/>")
            parts.append("<details class='inner'><summary>View finding.md</summary>")
            parts.append(f"<pre>{_esc(f.body)}</pre>")
            parts.append("</details>")
            parts.append("</div>")
            parts.append("</details>")
    parts.append("<div class='decisions'>")
    parts.append("<h2>Decisions</h2>")
    parts.append("<ul>")
    parts.append("<li><strong>🔧 Promote</strong> to an automated test — <code>/qa author &lt;slug&gt;</code></li>")
    parts.append("<li><strong>📝 Log as [gap]</strong> in <code>web/tests/LEDGER.md</code> for later</li>")
    parts.append("<li><strong>🐛 Fix in product</strong> — copy the prompt below into an agent session</li>")
    parts.append("<li><strong>✅ Dismiss</strong> — not actionable, document why</li>")
    parts.append("<li><strong>🔍 Investigate</strong> further — <code>/qa explore &lt;area&gt;</code> scoped tighter</li>")
    parts.append("</ul>")
    parts.append("</div>")
    # Fix prompt card — click-to-copy, collapsed raw text
    parts.append("<div class='fix-card'>")
    parts.append("<h2>Hand-off prompt (for an agent session)</h2>")
    parts.append("<p class='hint'>Paste into a fresh Claude Code / Cursor / Codex thread. The receiving agent fixes the product; this skill keeps the tests.</p>")
    parts.append("<div class='copy-row'>")
    parts.append("<button class='copy-btn' data-copy-target='fix-prompt-body' type='button'>📋 Copy prompt</button>")
    parts.append("</div>")
    parts.append(f"<pre id='fix-prompt-body'>{_esc(fix_prompt)}</pre>")
    parts.append("</div>")
    parts.append("</body></html>")
    return "\n".join(parts)


def _esc(s: str) -> str:
    return (
        s.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
    )


GLOSSARY_HTML = """
<details class='glossary' id='glossary' open>
<summary>ℹ️ About this report — what is "axe"? what do the severity levels mean?</summary>
<div class='glossary-body'>

<h3 id='glossary-axe'>axe</h3>
<p><strong>axe-core</strong> is an open-source accessibility testing engine built by
<a href='https://www.deque.com/' target='_blank' rel='noopener'>Deque Systems</a>. It runs
rules derived from the <a href='https://www.w3.org/WAI/standards-guidelines/wcag/' target='_blank' rel='noopener'>Web Content Accessibility Guidelines (WCAG 2.1/2.2)</a>
against a rendered page and reports violations. We use
<a href='https://github.com/dequelabs/axe-core-npm/tree/develop/packages/playwright' target='_blank' rel='noopener'>@axe-core/playwright</a>
to call it from our exploration tests.</p>

<p><strong>Honest caveat:</strong> automated a11y tools like axe catch roughly 30–40% of real WCAG issues —
structural stuff like missing alt text, poor contrast, ARIA misuse, label mismatches. They
can't judge whether copy is understandable, whether a flow makes sense to a screen-reader
user, or whether focus order matches reading order in complex layouts. Pair automated checks
with manual review when a11y is a merge gate.</p>

<h3>Impact levels (axe's terms)</h3>
<p>axe classifies each violation by severity. See
<a href='https://github.com/dequelabs/axe-core/blob/develop/doc/issue_impact.md' target='_blank' rel='noopener'>axe's impact definitions</a>
and browse the full rules at <a href='https://dequeuniversity.com/rules/axe/' target='_blank' rel='noopener'>Deque University</a>.</p>
<ul>
<li><strong>critical</strong> — users can't complete core tasks; often a WCAG failure.</li>
<li><strong>serious</strong> — users will have significant difficulty; e.g. color contrast below 4.5:1.</li>
<li><strong>moderate</strong> — some users will have difficulty; often structural cleanups.</li>
<li><strong>minor</strong> — an inconvenience; usually best practice rather than strict failure.</li>
</ul>

<h3>How this report maps severity</h3>
<p>We fold axe impact into our own 4-bucket priority so axe findings sit next to non-a11y findings the agent makes:</p>
<ul>
<li>axe <em>critical</em> → <strong>🚨 P0</strong> (user-blocking)</li>
<li>axe <em>serious</em> → <strong>⚠️ P1</strong> (serious degradation)</li>
<li>axe <em>moderate</em> / <em>minor</em> → <strong>💭 nit</strong> (cosmetic / best-practice)</li>
<li><strong>🔭 gap</strong> is not an axe term — it marks a behavior worth automating but not a bug today.</li>
</ul>

<h3>What else to read</h3>
<ul>
<li><a href='https://www.w3.org/WAI/fundamentals/accessibility-intro/' target='_blank' rel='noopener'>W3C's intro to accessibility</a> — the concepts behind WCAG.</li>
<li><a href='https://dequeuniversity.com/rules/axe/' target='_blank' rel='noopener'>Deque University — axe rules catalog</a> — the rule IDs in this report link here.</li>
<li><a href='https://web.dev/accessibility/' target='_blank' rel='noopener'>web.dev Accessibility</a> — Google's practical guide.</li>
<li>See <code>.claude/skills/qa-web/references/oracles.md</code> in this repo for our exploratory heuristics (SFDIPOT, FEW HICCUPPS) that complement axe.</li>
</ul>

</div>
</details>
"""

GLOSSARY_MD = """
<details>
<summary><strong>ℹ️ About this report — what is "axe"? what do the severity levels mean?</strong></summary>

### axe
[axe-core](https://github.com/dequelabs/axe-core) is an open-source accessibility testing engine by [Deque Systems](https://www.deque.com/), running rules derived from the [WCAG 2.1/2.2 guidelines](https://www.w3.org/WAI/standards-guidelines/wcag/). We call it via [@axe-core/playwright](https://github.com/dequelabs/axe-core-npm/tree/develop/packages/playwright) during exploration.

Automated tools catch ~30–40% of real WCAG issues (contrast, alt text, ARIA misuse, labels). They can't judge copy clarity or flow coherence — pair with manual review for merge gates.

### Impact levels (axe)
See [axe's impact docs](https://github.com/dequelabs/axe-core/blob/develop/doc/issue_impact.md); browse rules at [Deque University](https://dequeuniversity.com/rules/axe/).

- **critical** — users can't complete core tasks
- **serious** — users will have significant difficulty (e.g. contrast < 4.5:1)
- **moderate** — some users will have difficulty
- **minor** — inconvenience / best-practice

### How this report maps severity
- axe *critical* → **🚨 P0**
- axe *serious* → **⚠️ P1**
- axe *moderate* / *minor* → **💭 nit**
- **🔭 gap** — our own label for behaviors worth automating (not an axe term)

### Further reading
- [W3C's intro to accessibility](https://www.w3.org/WAI/fundamentals/accessibility-intro/)
- [Deque University axe rules catalog](https://dequeuniversity.com/rules/axe/)
- [web.dev Accessibility](https://web.dev/accessibility/)
- `.claude/skills/qa-web/references/oracles.md` — our exploratory heuristics (SFDIPOT, FEW HICCUPPS) that complement axe

</details>
"""


def render_terminal(run_dir: Path, findings: list[Finding], report_md: Path, report_html: Path) -> str:
    grouped = group_by_severity(findings)
    total = len(findings)
    lines: list[str] = []
    lines.append("")
    lines.append("┌─ qa-web report " + "─" * 50)
    lines.append(f"│ Run:       {run_dir}")
    lines.append(f"│ Findings:  {total} total")
    for sev in SEVERITY_ORDER:
        bucket = grouped.get(sev) or []
        if not bucket:
            continue
        lines.append(f"│   {SEVERITY_ICON[sev]} {len(bucket):>2} {sev:<4}")
    lines.append("└" + "─" * 64)
    if findings:
        lines.append("")
        lines.append("Top findings:")
        shown = 0
        for sev in SEVERITY_ORDER:
            for f in grouped.get(sev) or []:
                lines.append(f"  {SEVERITY_ICON[sev]} [{sev}] {f.title or f.slug}")
                if f.page:
                    lines.append(f"      page: {f.page}")
                lines.append(f"      evidence: {f.path.parent}")
                shown += 1
                if shown >= 8:
                    break
            if shown >= 8:
                break
        if total > shown:
            lines.append(f"  ...and {total - shown} more in REPORT.md")
    lines.append("")
    lines.append(f"📄 Full report: {report_md}")
    lines.append(f"🌐 Open in browser: open '{report_html}'")
    lines.append("")
    lines.append("Decide per finding: promote / log-as-gap / fix / dismiss / investigate")
    return "\n".join(lines)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("run_dir", type=Path, nargs="?", help="e.g. output/qa-agent/2026-04-18")
    ap.add_argument("--open", action="store_true", help="open report.html in default browser")
    ap.add_argument("--latest", action="store_true", help="render the most recent date dir under output/qa-agent")
    args = ap.parse_args()

    run_dir = args.run_dir
    if args.latest or run_dir is None:
        root = Path("output/qa-agent")
        if not root.exists():
            print("no output/qa-agent/ directory", file=sys.stderr)
            return 1
        dirs = sorted((d for d in root.iterdir() if d.is_dir()), reverse=True)
        if not dirs:
            print("no runs under output/qa-agent/", file=sys.stderr)
            return 1
        run_dir = dirs[0]

    if not run_dir.is_dir():
        print(f"not a directory: {run_dir}", file=sys.stderr)
        return 1

    findings = discover(run_dir)
    report_md = run_dir / "REPORT.md"
    report_html = run_dir / "report.html"
    report_md.write_text(render_markdown(run_dir, findings))
    report_html.write_text(render_html(run_dir, findings))
    print(render_terminal(run_dir, findings, report_md, report_html))

    if args.open:
        subprocess.run(["open", str(report_html)], check=False)
    return 0


if __name__ == "__main__":
    sys.exit(main())
