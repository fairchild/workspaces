# Evidence Guide

Evidence is a merge gate for all PRs. A screenshot or a recording for anything a
person can see, numbers for anything measured, and for everything else the named
tests that ran with the command and its result line. Upload what needs a link;
a command and its result belong in the PR body.

> **Remote (claude.ai) sessions:** `EVIDENCE_UPLOAD_TOKEN` is not available in those containers. The sanctioned fallback — a green CI run link on the exact branch/commit as hosted evidence, plus session-delivered screenshots for UI changes — is documented in `remote-sessions.md`.

## Quick start

```bash
# App UI evidence — first-choice capture (launch fixture state, snapshot, upload)
./scripts/evidence.sh --pr <number> --fixture phase-1-release

# Capture the live desktop screenshot + upload in one step
./scripts/evidence.sh --pr <number> --name <slug>

# Upload an existing image or video file
./scripts/evidence.sh --pr <number> --name <slug> --file /tmp/screenshot.png
./scripts/evidence.sh --pr <number> --name <slug> --file /tmp/flow.webm

# Via mise
mise run evidence -- --pr <number> --name <slug>
```

The script prints a markdown image link you can paste directly into the PR body.

## App evidence lane (first-choice UI capture)

For any evidence that shows the macOS app's UI, the app evidence lane is the
sanctioned first choice. One command launches the debug build in a named fixture
state with the Automation API and operator scope enabled, waits for readiness,
snapshots the main window through the operator-scope CLI, uploads through the
normal pipeline, and prints the markdown link — then stops the launched app:

```bash
./scripts/evidence.sh --pr <number> --fixture <scenario>
```

Named scenarios (`phase-1-release`, `m6-status-sliver`, `attention-only`,
`restore-banner`, `orphan-banner`, `clean`, or `inline:<agent-states>`) come from
[`scripts/lib/fixture-scenarios.sh`](../../scripts/lib/fixture-scenarios.sh) and
match the release-screenshot catalog; the env grammar behind them lives in
[ui-fixture-mode.md](ui-fixture-mode.md). `--name` defaults to the scenario.

Why this is the default, and how it beats the older fallbacks:

- **Full composited fidelity, no focus steal.** The snapshot is
  `CGWindowListCreateImage` scoped to the app's own window — it captures the
  sidebar chrome *and* the GhosttyKit terminal surface in one PNG at true
  resolution, works with the app backgrounded on a shared desktop (no
  activation), and needs no Screen Recording TCC grant. See
  [automation-api.md § Window snapshot](automation-api.md#window-snapshot) and
  the [operator-scope ADR](../decisions/automation-operator-scope.md).
- **Deterministic state.** Fixture mode stages a known visual state in-memory, so
  the same command yields the same UI every run.

Failure behavior is fast and explicit (never a hang): a clear message when the
app can't launch, when operator scope is missing (no credential minted), when the
snapshot fails, or when `EVIDENCE_UPLOAD_TOKEN` is absent. Readiness waits are
bounded (`--timeout`, default 45s).

**Structural assertion (ui-state goldens).** When the scenario has a golden under
`fixtures/ui-state/<scenario>.json`, the lane also fetches `GET /v1/ui-state`
from the still-running app and diffs the structural state — selection, banner
presence, sidebar rows, pill text, terminal topology — against the golden,
failing the lane on mismatch. A PNG proves the window rendered; the golden diff
proves *what* rendered. Goldens change only through the explicit
`./scripts/ui-state-golden.sh update --scenario <name>` flow (never
auto-regenerated on mismatch); comparison semantics are canonical in the
unit-tested `UIStateGolden` Swift comparator. See `fixtures/ui-state/README.md`.

Some chrome cannot exist at first paint — the orphan banner is decided by the
deferred startup pass that runs ~2s after the window renders — so a golden may
declare a `settle` bound (`{"timeoutSeconds": N, "pollSeconds": M}`). The lane then
re-fetches on that interval until the state matches or the bound elapses, failing
with the bound and the final mismatch rather than racing it. When a settle applies
the lane re-snapshots afterwards, so the PNG shows the state the golden verified
rather than the pre-settle frame. Goldens without deferred chrome declare none and
stay single-shot.

**Tokenless capture (local degrade).** The upload-token gate runs *after*
capture and the ui-state diff, so a worktree without `EVIDENCE_UPLOAD_TOKEN`
still produces the local PNG and the golden verdict. Pass `--no-upload` for an
intentional tokenless run: the script prints the local artifact path, its
sha256, and PR-body-ready markdown (`- Local evidence (tokenless): \`file\` —
sha256 \`hash\``). Without `--no-upload`, a missing token still fails (exit 2)
after printing the same local-artifact report — uploads always require the
token.

**Content gate (permanent contract).** The operator credential proves the automation
listener is up, not that the window has painted its first frame — so the lane retries
the snapshot until the PNG carries rendered content (a bounded luminance-spread check),
and fails with `window never rendered non-blank content` rather than uploading a blank.
This is what catches the locked-screen case below: on a locked screen
`ghostty_surface_new` (Metal) and the composited `CGWindowList` path both fail to
render, so the gate refuses and you fall back to the local VM lane (per
[#915](https://github.com/fairchild/workspaces/issues/915)). This gate exists because a
real blank frame once passed a naive file-exists/dimensions check — never smoke-test a
capture by size alone.

### Fallback hierarchy

Reach for a fallback only when the lane above cannot apply, in this order:

1. **App evidence lane** (`--fixture`) — default for all app-UI evidence.
2. **ImageRenderer test → PNG** — for a *single* SwiftUI view in a transient or
   hover-only state that fixture mode cannot stage as a full window. Renders one
   view, not the composited window.
3. **Local VM lane** (Tart/Lume on your own machine) — the full-fidelity
   fallback for the one case the in-process lane cannot cover: **a locked
   screen.** Every composited capture
   path (`CGWindowList` and ScreenCaptureKit) returns no pixels while the session
   is locked, so locked-screen evidence runs in a VM. This is a VM you start
   locally; the CI `tart-ui` runner lane is retired
   ([../decisions/perf-measurement-laptop-optin.md](../decisions/perf-measurement-laptop-optin.md)).
   Unlocked
   background/occluded windows capture fine with the lane above.

Two properties of the app decide between the app lane (1) and the render lane (2)
before machine availability does, and a third decides whether a lane-2 run proved
anything.

**Scroll position.** The snapshot captures what the window is showing, and the
automation API has no scroll verb, so content below the fold in a scrolling surface
cannot be staged. `WORKSPACES_UI_FIXTURE_OPEN_DIAGNOSTICS=1` opens the Diagnostics
tab (grammar in [ui-fixture-mode.md](ui-fixture-mode.md)) but reaches only the
surface, not a panel further down it — the tab's later panels are out of frame
either way. A view's place in its scroll order is therefore a lane decision, and
the render lane is the answer for anything past the first screenful.

**Bundle-id-keyed scope.** The automation socket and the per-launch operator
credential share one directory keyed by bundle id
(`AutomationListener.defaultSocketURL`, with
`AutomationOperatorCredentialStore.defaultURL` beside it), and the socket is
flock-guarded — so a second instance of the same bundle id goes dormant and never
mints the credential the snapshot needs. "An idle machine" means precisely that no
other instance of that bundle id is running: a debug build cannot take operator
scope next to an installed WorkSpaces, and quitting the installed app is what
unblocks the lane.

**Filtering the render lane.** Swift Testing's `--filter` matches the *type* name,
not the suite's display name. A display-name filter is not an error — it exits 0
with `Test run with 0 tests in 0 suites passed` and writes no PNG — so a script
that trusts the exit code reports success for a run that never happened. Filter by
type name (`--filter AgentHookIngestPanelRenderTests`) and assert the output files
exist afterwards.

### Web UI evidence

The app lane is macOS-app only. Web dashboard evidence still uses
`mise run web:evidence` / Playwright reports and screenshots of the rendered
page (see the web table
below and `web/docs/local-dev.md`).

## Setup

Add `EVIDENCE_UPLOAD_TOKEN` to your `.env` (gitignored):

```
EVIDENCE_UPLOAD_TOKEN=<value>
```

Fresh linked worktrees can symlink the checked-out secret file with:

```bash
./scripts/setup --env-only
```

`scripts/evidence.sh` also searches the canonical checkout and sibling worktrees for `.env` or `.env.local` before failing, so evidence upload should not be marked blocked just because the current worktree is missing its symlink.

The token value is stored in [GitHub repo secrets](https://github.com/fairchild/workspaces/settings/secrets/actions). To rotate it across all three locations:

```bash
TOKEN=$(openssl rand -hex 32)
cd infra/cloudflare-evidence-store && wrangler secret put EVIDENCE_UPLOAD_TOKEN <<< "$TOKEN"
gh secret set EVIDENCE_UPLOAD_TOKEN --repo fairchild/workspaces --body "$TOKEN"
# Then update .env manually
```

## Command reference

### `scripts/evidence.sh`

| Flag | Required | Description |
|------|----------|-------------|
| `--pr <number>` | Yes | PR number (used in R2 path) |
| `--name <slug>` | Yes* | Filename slug (e.g., `test-results`, `before-fix`). *In `--fixture` mode defaults to the scenario. |
| `--fixture <scenario>` | No | App evidence lane: launch a named fixture state, snapshot the main window via operator scope, upload. Known: `phase-1-release`, `m6-status-sliver`, `attention-only`, `clean`, `inline:<agent-states>`. |
| `--timeout <s>` | No | Readiness timeout for the fixture launch (default: 45) |
| `--keep-running` | No | Leave the launched app running after capture (debugging) |
| `--file <path>` | No | Use existing file instead of capturing screenshot |
| `--no-capture` | No | Skip `screencapture` (requires `--file`) |
| `--repo <name>` | No | Repository short name (default: `workspaces`) |

### `scripts/upload-evidence.py`

Lower-level upload client. Accepts `png`, `jpg`, `jpeg`, `gif`, `webp`, `svg`,
`webm`, `mp4`, `txt`, and `html` — a test log goes up as text, not as a picture
of one — with a 50 MiB per-file limit enforced by both the client and
the evidence-store Worker. Uploads carry a fixed `Content-Length`; the Worker
rejects chunked or malformed-length requests so accepted files can stream
directly into R2 without consuming the Worker's memory budget. Called internally
by `evidence.sh`. Images produce inline-image Markdown; videos produce a normal
click-to-play link because GitHub does not render uploaded video URLs inline in
PR bodies.

```bash
uv run scripts/upload-evidence.py <file> --repo workspaces --pr <number> --name <slug>
```

### `scripts/pr-review-page.py`

Builds one PR's review page and, with `--upload`, hosts it here — the store
serves an uploaded `.html` as `text/html`, so the page is a page rather than a
download. `--link` then writes `Review page: <url>` under the PR body's byline.
The page shows the evidence the body already carries; it does not stand in for
capturing any.

## Delivery and provenance

Record capture, delivery, and inspection separately. For each artifact, retain
its hosted URL, digest, source state, and the claim it supports. Use the upload
command's returned URL. The canonical `evidence.cloudcompute.com` host is
supported; GitHub-native attachments are not a universal requirement.

Capture should come from the commit under review. If it used dirty source,
record the patch identity and that limitation; a Git HEAD label alone does not
prove which source produced a binary or screenshot. Refresh evidence after a
relevant code change, or explain why an unchanged artifact still applies.

Inspect the rendered PR for human review. For Factory image review, verify
delivery through a result tied to the same PR and evidence, then require the
Factory reviewer to inspect the images. Until such a result exists, reviewer
access is unknown. An HTTP success, decoded image, or matching digest
establishes delivery properties, not visual correctness. A local path and
digest establish local provenance, not remote availability. The
[review handoff and response workflow](mergeability-standard.md#review-handoff-and-response)
handles failed delivery or unavailable reviewer capabilities.

For recordings, check what the reviewer can inspect. If playback is
unavailable, representative frames can support visual claims; they do not
prove timing or interaction. Keep those claims tied to evidence the reviewer
can inspect, or report the inspection gap.

### Optional laptop delivery preflight

The ordinary `--body-file` readiness check stays offline. For an existing PR,
opt into a local artifact download using Factory's same bounded PNG/JPEG
validation and URL policy:

```bash
uv run --with pillow==12.3.0 --script scripts/pr-readiness.py \
  --check-evidence-delivery <PR> --expected-head <full-head-SHA>
```

The command reads the live PR, linked requested evidence, and required checks
through `gh`; it writes no GitHub state and runs no reviewer. JSON output binds
the result to the PR/head/base and downloaded hashes, then staged files are
removed. A changed head, base, or body during the check prevents success.
`no_images_selected` means the shared policy selected no images, not that any
image was inspected. An unavailable check result remains `null`.

This proves delivery on the laptop only. Factory still needs to deliver and
inspect the artifacts in its own environment before review approval. An
unavailable delivery exits nonzero; the command does not retry automatically.
The explicit Pillow dependency applies only to this opt-in command.

The shared policy accepts at most six PNG/JPEG images from this PR's path on
`evidence.cloudcompute.com`: 8 MiB per image, 24 MiB total, 16 million decoded
pixels, and 8,192 pixels per dimension. Each fetch/decode has a 20-second hard
timeout and at most two redirects within the same URL policy. Animated images
and active formats such as SVG are rejected.

## What counts as evidence

A screenshot or a recording for anything a person can see. Numbers for anything
measured. For everything else, the named tests that ran and what they covered,
plus whatever else you ran locally. Use judgement, and round toward more
evidence.

**An image of text is never evidence.** Rendering a test summary to an SVG or a
PNG so that a gate sees an image was, in Michael's words, "a reward hack I
allowed to go through for a while" — and never again. Paste the command and its
result line; upload the log as text if it helps. An image is evidence of what a
person can see, which means a screenshot is asked for only when the change is
one someone looks at.

Minimum is the floor for that change type, not the ceiling.

| Change type | Minimum evidence | Extras |
|-------------|-----------------|--------|
| Swift UI | Running-app screenshot via the [app evidence lane](#app-evidence-lane-first-choice-ui-capture) (`--fixture`) | Before/after when the visual correction is the point |
| Swift non-UI | The named tests that ran, with the command and its result line | Uploaded `test-output.txt` |
| Web | `pnpm test` output, with the command and its result line | Playwright report for a UI change; the HTML report as an artifact, not a picture of it |
| API-only | The named tests that ran, with the command | — |
| Docs/config | Check "Not a testable change" in PR template | — |
| Performance | Before/after/delta numbers in the PR body — the numbers are the artifact | Metric source and commands |

For web screenshots without auth, start the dev server with:

```bash
DEV_BYPASS_AUTH=1 pnpm dev
```

## Writing a factory issue's `## Requested Evidence`

Each bullet is classified into a kind, and the kind decides who completes it.
Writing an item the classifier recognises is the difference between the factory
finishing the PR and the PR waiting on you.

| Write it like this | Kind | Who completes it |
|---|---|---|
| ``` `swift test --filter FooTests` passes ``` | `test` | the macOS evidence lane runs it |
| `Screenshots of the new sidebar` | `screenshot` | the macOS evidence lane captures it |
| ``` CI: `Lint, Test, Build` green on the PR head ``` | `ci` | `factory-evidence-verify.yml` polls that check |
| ``` The `check-links` check passes on the PR head ``` | `ci` | same |
| `Diff: the README links the overview page` | `diff` | the counterpart review, bound to the review URL and head SHA |
| `The new column appears in the PR diff` | `diff` | same |
| ``` `pnpm test` in `web-next` passes ``` | `test-attested` | you, by stating the command and its result line in the PR body |
| `A test in ``scripts/tests/test_foo.py`` asserting X` | `test-attested` | same |
| `Before/after latency on the same workload` | `perf` | the numbers in the PR body's Performance section |
| `Someone with taste confirms the copy reads well` | `other` | **you**, by hand |
| `... (owner-attested)` | `other` | **you**, by hand — the directive is honoured over any other shape |

Three rules worth knowing:

- **A CI item must name the check in backticks, immediately before `green`, or
  before a CI noun and then a pass word.** ``` `check-links` check passes ``` works;
  "`pnpm check` passes locally" does not, because `pnpm check` is a command, not
  a check name. The classifier fails closed rather than guessing, since an item
  naming a check that does not exist never completes.
- **A `test` or `build` item's command is the backticked span that opens it.**
  In ``` `swift test --filter FooTests` passes ```, the lane runs
  `swift test --filter FooTests` and reads "passes" as you saying what you
  expect of it. A command mentioned mid-sentence is not a request to run it.
- **`(owner-attested)` — or any "owner/maintainer confirms/approves/decides"
  phrasing — keeps the item yours** even when the rest of it looks mechanical.
  If you want the factory to close it, drop the parenthetical and write the
  diff or CI form instead.

**An image of text is never evidence.** The readiness gate used to accept any
embedded image as the whole evidence signal, for any change at all, which is
what made rendering a test summary to an SVG worth doing. An image now
satisfies the gate only where there is something to see, and a `[complete]`
entry whose detail is an image alone closes only a screenshot item. The
producer is gone too: `scripts/pr-evidence.sh` writes its summaries as text,
and `scripts/continuity-evidence.sh` no longer renders its close proof to PNG.

`test-attested` and `perf` are the kinds the factory cannot run for you and
does not park on you either.

A `test-attested` item completes on a statement in the PR body naming the
command and the line it printed — "`pnpm test` — 214 tests passed" is enough.
Both halves are required and the result has to carry a count: a command with no
result is a plan, and "if all tests pass, merge" says nothing ran. The statement
also has to name *this* item's runner or path, so one `pnpm test` line does not
complete a `pytest` item beside it.

A `perf` item completes on a filled-in `Before Summary` and `After Summary` in
the body's Performance section, each carrying a measurement with a unit.

Both are read twice — as the body is written, and as GitHub renders it — and
count only where both readings agree. A statement or a measurement written
inside an HTML comment renders as nothing and states nothing; one inside a
fenced block counts, because that is where `scripts/pr-evidence.sh` pastes the
comparison numbers. The rendered reading is not simply the broader of the two:
markup a pattern stopped at is gone from it, and a block renders in fewer lines
than it occupies. Requiring both is what keeps it able to narrow what completes
and unable to widen it.

Both complete as an attestation, and the status line says so: "attested by the
PR author, not run by the factory". Nothing in the pipeline re-runs the command
to check. That is deliberate — it is the bar for a change nobody has to look at
— and it is why the reviewer is told to read the claim against the diff.

Neither has an event-driven lane. They are read when the factory next writes
the PR body — at PR open, and on each revise turn — so filling the body after
the PR opens completes the entry on the next turn. A status line you edit by
hand is carried forward by that same turn, marked `(carried forward from an
earlier revision)` so a reader can tell it was written before the code under
it. The CI verifier and the macOS lane write only through the hidden metadata,
so a hand edit does not survive a run of those two that rewrites the section;
edit the body again after them.
Until the entry completes both sit `pending-ci`, which is visible and fails the
readiness gate, rather than `blocked`, which puts the PR in front of the owner.

Evidence a person has to produce — by looking, by following a protocol, by
deciding — stays `other` however it is phrased. "A test protocol covering a
manual production restart" names a test and is still yours.

You complete an `other` item by rewriting its line as
`- [complete] <item> -- <what you checked>`, and that line is the record for
the item from the moment it is saved: the factory's accounting, the reviewer's
gate included, reads it over the hidden metadata beside it, so an approval
does not wait for a factory turn to copy it across. A `[blocked]` you write
there holds the review the same way. What you checked has to be said: on an
item nobody runs, a bare status word such as `PASS`, `ok` or `done` is no proof.

Three things decide whether a line is read as yours. The item has to be one the
contributor recorded as `other` in the hidden metadata when it wrote the
section, and one whose own wording reads that way too: where the recorded kind
and the kind the item's rendered text carries disagree, the stricter of the two
decides, so a lane item recorded `other` is not completed by its line. Where
that stricter reading is a `test-attested` or a `perf` kind, the statement of
what ran or the Performance section's numbers completes it instead, the same
form a body without metadata completes it by. An item with no recorded kind is
never read this way. The section is read as CommonMark, by a parser rather than by matching lines,
and wherever reading it would mean guessing at how GitHub renders something,
the read refuses instead. Where a section ends is read the same way, and by
the same call for every reader and every writer of the body: at the next `##`
heading or `---` rule the page shows. A run of dashes written directly under a
line of text is that line's underline rather than a rule, so the lines around
it stay in the section they were written in, and a rewrite of that section
replaces exactly what the read counted. A `##` or `---` inside a code fence is
code, not a boundary -- unless the fence never closes, which runs it to the end
of the body and would put every section below it inside the first; there the
opener is set aside and the section ends at the first boundary the parser then
reports. A raw HTML block that never closes -- a `<!--` with no `-->`, a
`<pre>` or `<script>` with no end tag, a `<?`, `<!X` or `<![CDATA[` -- runs to
the end of the body the same way, and a rewrite of a section whose end is
hidden that way is refused rather than guessed: the body stands and the run
says which line to close. What the page then shows is a heading,
not a measurement: a Performance section whose last measurement line is
followed immediately by `---` still reads as carrying no numbers and still
refuses. The refusal says so -- it names the underline and asks for a blank
line between the last measurement and the rule -- rather than asking for
measurements you already wrote. A status line is a list
item under the one
`## Evidence Status` heading a reader sees, on a single line, whose text reads
`[status] item -- proof`, one per requested item. That is the whole of what
the heading holds: under it a bullet opening with a status token is the
machine's, well-formed or not, and every other block -- a note to a reviewer,
a link to a run, a pasted log excerpt, a `- [x]` box, a bullet naming no
status -- is a note, which a rewrite moves, in the order written, to a
top-level `## Evidence Notes` section directly below. Write your note there
and it stays put; write it under the heading and the next lane run or factory
turn relocates it. A body carrying no such block has no such section. A block
indented under a status bullet is the author's too and moves whole, since it
belongs to the bullet only because the parser folds it there; a status line
soft-wrapped over several source lines is one line on the page and goes with
the rewrite. What moves, moves byte for byte -- indentation, fence markers and
trailing spaces all survive, because text altered looks like your words with
the meaning changed. What does not move is a block the parser cannot end: a
fence with no closing line, and a raw HTML block of kinds 1 to 5 whose closer
never came. Those are deleted by the rewrite as they always were, and every
block not carried is named on the run's output with the line it started on.
Notes that would take the body past the 65,536 characters GitHub stores are
left behind rather than failing the write that carries the status. And a rewrite stands the body down, writing nothing
and naming the line, where a `## Evidence Status` or `## Evidence Notes` line
sits inside a fenced example: the cut takes every occurrence, so cutting from
one would take the block's closing line with it. The section is unreadable,
with the reason named, when anything else sits under the heading -- a code
block, fenced or indented; any HTML block, even one holding only a comment; a
horizontal rule; a paragraph; a nested list; a line naming no requested item --
or when an item carries inline HTML (a comment or `<del>` included), runs onto
a second line, or holds a character reference such as `&#10;` that decodes to
a line break. Inline HTML in the heading makes it unreadable too, and so does
any HTML before the heading other than the factory's own metadata comment: a
`<details>`, a centred `<p>`, an `<img>` or a comment above `## Evidence Status`
leaves the owner's section unread, with the reason named, until the HTML moves
below the section or into a code block. The read never interprets HTML, since
working out which elements are still open is a second renderer. A comment delimiter
inside a code span is text, and emphasis is only what the parser reads as
emphasis: `**item**` is the item, while `** item **` keeps its asterisks. When the section is not readable, no line is read
as yours and no owner item counts as complete from the metadata either, since
the line nobody can read may be your `[blocked]`; fix the section and the next
review reads it. And only an `other` line is read at once. A
`[complete]` written over any other kind reads as the metadata says until a
factory turn or the lane that owns the item writes it, because nothing but a
lane or the factory's own reading of the body completes those. Like any hand
edit, the line is replaced whenever the CI verifier or the macOS lane rewrites
the section.

A body with no evidence metadata -- a PR written by hand, or one whose metadata
comment is missing or indented -- is read as CommonMark the same way, so every
refusal above applies to it too. What a hand-written body can complete depends
on the item's kind, classified as the contributor classifies it, from the item
as the issue writes it and as it renders, the stricter of the two where they
differ: an `other` item completes from a `[complete]` line that names it
as the issue writes it; a `test-attested` item completes from the statement of
the command and the line it printed, and a `perf` item from the Performance
section's before and after numbers. A `ci`, `diff`, `test`, `build` or
`screenshot` item never completes from a hand-written line: its named check, the
approving review or the evidence lane completes it.

The lane makes its own work count on such a body: when it reconciles one that
carries no metadata comment it writes one, recording what that run gathered
alongside what the body already said, so the lines it just rewrote read as the
lane's rather than as hand-written. It needs the contract to do that -- an
entry is an index into the requested evidence -- and it writes nothing where
the metadata would change how any other item reads, a section carrying a line
the reader cannot place included.

The classifier lives in `_evidence_item_kind` (`.agents/skills/cofounder-contributor/scripts/evidence.py`);
`scripts/tests/test_factory_evidence_kinds.py` is the readable corpus of what
does and does not classify.

### What the metadata comment guarantees

The metadata comment is the hidden `<!-- evidence-status:v1 ... -->` block
beside the `## Evidence Status` section, recording a status for evidence items.
Anyone who can edit the pull request description can write or change it, a
recorded completion included.

What it records is not independently authenticated: no signing, no provenance
check. The `verified_head_sha` field binds an entry to a commit, and it is as
editable as the rest of the block.

A recorded completion may be re-checked by a later run — for some kinds, in
some conditions. Which, and when, is the code's to answer rather than this
page's: `ci_entries_needing_verification` in
[`scripts/factory-evidence-verify.py`](../../scripts/factory-evidence-verify.py),
and `evaluate_evidence_accounting` and `_live_ci_evidence_gate_error` in the
contributor skill's scripts. A sentence here describing one of them is a copy
of it that goes stale on its own.

A completion recorded for a named CI check is re-checked against the live
check runs on the head every time the verifier runs, and only a completion
that run verified counts toward clearing `blocked:evidence`
(`ci_entries_needing_verification`, `should_clear_blocked_label`). A
completion of any other kind is not re-checked by anything and counts as the
entry records it: the macOS evidence lane re-resolves only entries still
`pending-ci` (`reconcile_pending_ci_evidence`), so a completion written by
hand for a test, a screenshot or any lane-resolved item survives every later
run and clears the label.

For a reviewer: a completion in the comment is a claim, not a proof. The run
link an entry carries is recorded, not verified, so it takes you
to a run page to read as evidence rather than as proof that the entry is
genuine.

## How it's enforced

Three layers, from gentlest to strongest:

1. **PR template** (`.github/pull_request_template.md`) — Evidence checkboxes and links section prompt authors at creation time.
2. **CI reminder** (`.github/workflows/evidence-reminder.yml`) — Posts a comment with copy-paste commands on PRs missing evidence.
3. **Agent hook** (`.claude/settings.json`) — Fires a warning before `gh pr create` reminding agents to upload evidence first.

## Troubleshooting

| Symptom | Cause | Fix |
|---------|-------|-----|
| `EVIDENCE_UPLOAD_TOKEN not set` | Token missing from this checkout and no sibling checkout has it | Run `./scripts/setup --env-only`, or add it — see [Setup](#setup) |
| `401 unauthorized` on upload | Token mismatch | Rotate token across Worker + GitHub + `.env` |
| Auth redirect on localhost | Web middleware requires session | Use `DEV_BYPASS_AUTH=1 pnpm dev` |
| `screencapture` fails | No display (headless/SSH) | Use the `--fixture` app lane, or `--file` with an existing screenshot |
| `operator credential did not appear` | Fixture launch didn't enable operator scope, or the app failed to start | Check `.dev-data/logs/launch-diagnostics-*`; the lane sets `WORKSPACES_AUTOMATION_API=1` + `WORKSPACES_AUTOMATION_OPERATOR=1` for you |
| Snapshot `unsupported` on a locked screen | Composited capture returns no pixels while locked | Use the local VM fallback lane |
| URL returns 404 | Upload didn't complete | Re-run `evidence.sh`, check network |
| Image renders in the PR but the reviewer cannot inspect it | Establish whether delivery, decoding, or image tools are unavailable | Record the failed capability and repair the review route within your authority. Request human help when needed; prose changes or rehosting without a diagnosed cause do not repair access. |

## Architecture

Evidence files flow through: `evidence.sh` → `upload-evidence.py` (PUT with bearer token) → Cloudflare Worker (`infra/cloudflare-evidence-store/`) → R2 bucket (`evidence-screenshots`) → public URL at `https://evidence.cloudcompute.com/`.
Every object, uploaded HTML included, is served under a sandboxed content security policy that allows images, the store's own audio and video, and inline style, and nothing else; the headers are in [the store's contract](../../infra/cloudflare-evidence-store/CONTRACT.md#get-key).

For infrastructure details (Worker deployment, R2 bucket config, runner setup), see [lume-runner-setup.md § Evidence store](lume-runner-setup.md#evidence-store-r2).
