# web-next — Design

The current design position for the sessions-first web app. This is the
reference design work is held to; when a design decision changes, change it
here. The runtime is a separate concern — see
`docs/decisions/web-next-harness-runtime.md`.

The prior design era (the "Spaces" chat-tab + dashboard) is archived under
`docs/design/archive/` and no longer describes this product.

## Thesis

The app is a place you **enter a coding session** in the browser — a calm,
focused conversation with an agent that reads, writes, and runs code, with the
same substance as working in a terminal but without the noise most tools of this
kind carry.

The register is **calm and low-distraction**. The interface reveals itself at the
point of need rather than exposing everything at once; the content is the
interface. **iA Writer** is the hero reference — typography-first, generous space,
the transcript reading as a document. **Things** (Cultured Code) is the secondary
reference for the moments that need more UI: soft warmth, gentle depth, controls
that appear on hover. Calm without distraction beats a surface that shows all its
functionality up front.

The design system is named **Folio**. Its canonical expression is the prototype
`prototypes/web-session-redesign/refine-folio.html`.

## Principles

These are the enduring rules; the decisions below are specific applications.

- **Calm over feature-exposure.** Default to the content. Don't surface a control
  until it's useful. A quieter surface that reveals on demand beats a busy one.
- **Progressive disclosure.** Detail folds away and opens on request — the tool
  ledger is one line until you want more; the transcript is prose until a diff or
  a test result earns space.
- **Contextual moments are the star.** The strongest reveal is the one the work
  itself triggers: a diff surfaces because an edit landed, a test panel because a
  command ran. Prefer that to persistent chrome.
- **Structure is meaningful chrome only.** A line that groups decoration earns
  removal; a line that marks a real boundary (a turn) earns its place. Strip the
  first, keep the second — calmer *and* clearer are not in tension.
- **Light and dark are equal citizens.** Both are designed, not inverted. Dark is
  a warm charcoal, not a cold slate.
- **Built for one.** Single-user: no onboarding, no hint chrome, no teaching UI.
  The cursor starts where the next action is. The user knows the shortcuts.

## Decisions

Each is a specific call and the reason for it.

- **The transcript is a document; a turn is a discrete object.** A turn (your
  message + the agent's whole response) reads as one contained thing — a soft
  rounded frame, your message anchoring the top, the live turn lifted and earlier
  turns receding to quiet outlines. This came from wanting a turn to *feel like a
  thing* without the document flow blurring your voice into the agent's. It is
  the figure-ground of the "Aperture" exploration — one thing in focus, the rest
  quiet — **minus its literal blur and pull-to-focus motion**, which fought the
  calm.
- **Quiet masthead, no branding block.** Repo · branch on the left, the session
  title centered in serif italic, agent + sandbox state and the theme toggle on
  the right. No wordmark eating the top-left; the brand doesn't earn prime real
  estate. On narrow widths the decorative title steps aside and the functional
  ends truncate rather than collide.
- **Compose is minimal and autofocused.** No placeholder copy, no `⌘K`/`@`-file
  hint chips — for a single user who knows the tool, that's noise. The cursor
  lands in the field on load. The field still reads clearly as an input (a soft
  raised border, a real send affordance); the minimalism is the removal of
  *guidance*, not of the control.
- **The model lives in a dismissible status line, stated once.** A thin footer
  carries the current model and context size; it never repeats data already in
  the masthead (no second branch, no second sandbox). It collapses to a dot.
- **Turns close with a quiet receipt.** A faint one-line `tools · tokens ·
  duration` at the end of a completed turn — the cost, told softly, never
  competing with the prose.
- **The tool ledger is one line per step, expandable.** Read / Edit / Run as
  quiet rows that open on demand. No decorative left rule — the turn frame now
  carries the grouping, so the rule was chrome without meaning.
- **Diffs and test output are contextual panels**, surfaced when the work
  produces them, not persistent regions.

## Identity

- **Type:** Instrument Serif (display / session title, italic) with JetBrains
  Mono (UI, code, metadata). The serif carries the personality; the mono carries
  the machinery.
- **Color:** warm paper in light, warm charcoal in dark, a single restrained
  accent. Semantic color (diff add/remove, live/error) is desaturated — it
  informs without shouting; red/green never scream.

## Roads not taken (and why)

- **The two-pane "canvas / stage"** (the Atelier / Nocturne explorations — a
  dedicated right-hand panel the work fills). Strong idea, but it commits to a
  fixed app viewport; the single-column document read calmer and truer to the
  thesis.
- **Aperture's literal depth-of-field** (blurred history you pull into focus).
  The *idea* — one turn in focus, the rest receded — was kept; the blur and the
  refocus motion were cut because motion fights calm over a long session.
- **A branding block in the top-left.** Rejected: it takes prime space for
  identity the user doesn't need reminding of.
- **The prior dashboard / multi-tab chat surface.** Off-thesis for a
  sessions-first product; archived.

## Open threads

- **Hybrid framing.** If "every turn is a frame" ever feels heavy in a long
  scroll, the lever is to frame only the *active* turn and let completed turns
  fall back to plain document — the purest Aperture translation. Held, not built.
- **Full mobile pass** (#753) — the masthead narrow-width fix is in; the rest of
  the transcript and compose at phone widths is still to do.
- **Terminal drawer** (#752) — a PTY into the session sandbox; its styling should
  inherit Folio's calm and stay a drawer, not a mode.

## Provenance

Design explorations and comparisons live in
`prototypes/web-session-redesign/` — the Folio prototype (`refine-folio.html`),
the concept galleries, and the turn-structure A/B. This doc is the settled
position distilled from that exploration; the prototypes are the record of how it
was reached.
