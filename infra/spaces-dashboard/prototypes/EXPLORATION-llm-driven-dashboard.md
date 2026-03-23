# LLM-Driven vs. Deterministic Dashboard: Architecture Exploration

## The Question

Should the Spaces dashboard be a **deterministic template** (fixed layout, data-driven)
or an **LLM-driven dynamic page** (the model decides what to show, how to present it, and
customizes the layout per-situation)?

The answer isn't binary. This document explores the spectrum and recommends a specific point on it.

---

## The Spectrum

```
Fully Deterministic          Hybrid                    Fully Generative
|__________________________|__________________________|
Template + data fill      Template + LLM slots       LLM generates everything
(Prototype A/B/C)         (RECOMMENDED)              (research project)
```

### Level 1: Fully Deterministic (what the prototypes do today)

Fixed HTML templates. Data from GitHub API fills predefined slots. The layout never changes.

```
scan repo → extract agents/skills/config → fill template → render
```

**Pros:** Fast, predictable, cacheable, never breaks layout.
**Cons:** Every repo looks the same regardless of what's interesting. A repo with 4 agents
and active pipeline gets the same layout as one with 1 dormant agent. Can't surface insights
("April has been blocked on PR #190 for 2 days — the pipeline is stuck").

### Level 2: LLM-Curated Slots (the sweet spot)

Fixed shell (nav, layout grid, typography). LLM fills specific **content slots** with
contextual intelligence. The LLM doesn't generate HTML — it generates **structured decisions**
that a deterministic renderer executes.

```
scan repo → build context bundle → LLM produces slot decisions (JSON) → renderer fills template
```

Example LLM output:
```json
{
  "hero_insight": "April has been reviewing PR #190 for 2 hours. Plat's next run is in 28 minutes — this PR will likely get a second review then.",
  "highlighted_agents": ["april", "plat"],
  "dimmed_sections": ["config_files"],
  "promoted_section": "pipeline",
  "callout": {
    "type": "attention",
    "text": "3 issues are agent:ready but no agent has claimed work in 48h. The pipeline may be stalled."
  },
  "card_annotations": {
    "april": "Currently active — reviewing workspace diagnostics PR",
    "peter": "No approved ideas in queue. Consider reviewing open discussions."
  },
  "layout_variant": "pipeline_focused"
}
```

The renderer is still deterministic — it just picks from pre-built layout variants and
fills annotation slots. The LLM never touches HTML.

**Pros:**
- Contextual and insightful without layout risk
- Cacheable (cache the JSON decisions, not the LLM call)
- Fast fallback: if LLM is slow/down, render with empty annotations
- LLM cost is low: small context (repo summary), small output (JSON), can use Haiku
- Testable: you can unit-test the renderer against known JSON shapes

**Cons:**
- Need to design the slot vocabulary upfront
- LLM adds latency to first render (mitigated by SSR shell + streaming slots)

### Level 3: LLM-Generated HTML Fragments

LLM produces actual HTML/markdown that gets injected into designated regions.
This is what Vercel's AI SDK "Generative UI" does — `streamUI()` returns React components
that the model chooses via tool calls.

```
scan repo → build context → LLM streams HTML fragments → inject into DOM regions
```

**Pros:** Maximum flexibility — the LLM can create UI patterns you didn't anticipate.
**Cons:**
- Layout can break (LLM generates bad HTML, unclosed tags, wrong CSS classes)
- Security: must sanitize output (XSS via injected scripts)
- Slow: streaming helps, but TTFB is LLM-latency-bound
- Hard to cache: every render may differ
- Testing is hard: output is non-deterministic

### Level 4: Fully Generative Page

The entire page is LLM-generated. No template at all.

**Not recommended for production.** Mentioned for completeness. This is what v0.dev does
for one-shot prototyping, but it's not suitable for a live dashboard where users expect
consistency.

---

## What Makes This Domain Special

The Spaces dashboard has a unique property: **the data it displays is itself about AI agents**.
This creates an opportunity most dashboards don't have:

1. **The agents have documented personalities and roles.** The LLM can speak in character
   ("April is focused on the terminal keyboard fix she started yesterday").

2. **The coordination workflow is structured.** The idea → plan → execute → review → merge
   pipeline has clear states. The LLM can identify bottlenecks and narrate the story.

3. **Cross-repo patterns emerge.** "April operates in both workspaces and homepage, but
   hasn't touched homepage in 4 days" — a deterministic template can't surface this.

4. **The audience is the repo owner.** This isn't a general-purpose dashboard — it's for
   someone who already understands the agent system. The LLM can be opinionated.

---

## Recommended Architecture: Hybrid (Level 2+)

### The Shell (deterministic, always renders instantly)

```
┌─────────────────────────────────────────────────┐
│  Spaces          [repos chip bar]     [avatar]  │
├─────────────────────────────────────────────────┤
│                                                 │
│  ┌─ INSIGHT SLOT (LLM-filled) ──────────────┐  │
│  │ "April is mid-review on PR #190.          │  │
│  │  Plat runs in 28m — expect second look."  │  │
│  └──────────────────────────────────────────-┘  │
│                                                 │
│  ┌─ AGENT CARDS (data-driven, LLM-annotated) ┐ │
│  │ [April]  [Plat]  [Peter]  [Oliver]        │ │
│  │  ^--- LLM adds contextual one-liner ---^  │ │
│  └──────────────────────────────────────────-┘  │
│                                                 │
│  ┌─ PROMOTED SECTION (LLM chooses which) ────┐ │
│  │ Pipeline / Activity / Skills / Schedule    │ │
│  │ (LLM picks most relevant + provides why)  │ │
│  └──────────────────────────────────────────-┘  │
│                                                 │
│  ┌─ SECONDARY SECTIONS (collapsed by default) ┐ │
│  │ Config Files, Discussions, Other sections  │ │
│  └──────────────────────────────────────────-┘  │
│                                                 │
└─────────────────────────────────────────────────┘
```

### LLM Integration Points

| Slot | What the LLM decides | Fallback if LLM unavailable |
|------|---------------------|-----------------------------|
| **Insight banner** | 1-2 sentence contextual narrative about current state | Hidden (banner doesn't render) |
| **Agent annotations** | Per-agent one-liner context | Show status text from data |
| **Section promotion** | Which section is most relevant right now | Show pipeline first |
| **Callouts** | Warnings/opportunities ("pipeline stalled", "new idea needs review") | None shown |
| **Card ordering** | Which agents/items to emphasize | Default alphabetical |

### Data Flow

```
1. User authenticates via GitHub OAuth
2. Fetch repo list (GitHub API, cached 5min)
3. For each selected repo, scan for .agents/ (GitHub Contents API, cached 15min)
4. Build context bundle: agents, skills, config, recent issues/PRs/discussions
5. Render deterministic shell immediately (SSR)
6. Fire LLM request with context bundle (async, streaming)
7. As LLM JSON arrives, hydrate annotation slots progressively
8. Cache LLM decisions for 10min (keyed on repo + data hash)
```

### The LLM Prompt (sketch)

```
You are the Spaces dashboard narrator. Given the current state of a GitHub
repository's agent setup, produce a JSON object that helps the dashboard
highlight what matters right now.

Context:
- Repository: {repo_name}
- Agents: {agent_list_with_status}
- Open PRs: {pr_summaries}
- Ready issues: {issue_list}
- Recent activity: {last_5_events}
- Schedule: {next_agent_runs}

Produce JSON with these keys:
- hero_insight: string (1-2 sentences, what's the story right now?)
- card_annotations: Record<agent_slug, string> (one-liner per agent)
- promoted_section: "pipeline" | "activity" | "schedule" | "skills"
- promoted_reason: string (why this section matters now)
- callouts: Array<{ type: "info"|"attention"|"success", text: string }>
- card_order: string[] (agent slugs in priority order)
```

### Why This Works Better Than Pure LLM HTML

1. **Instant first render.** The shell loads in ~200ms. LLM annotations stream in over
   1-3 seconds. User sees useful content immediately.

2. **Graceful degradation.** If the LLM is slow, down, or returns garbage, the dashboard
   still works — it just looks like the deterministic version.

3. **No layout risk.** The LLM never produces HTML. It produces decisions. A bad decision
   (wrong section promoted) is annoying but never breaks the page.

4. **Cheap.** The context is small (~2K tokens), the output is small (~500 tokens).
   Haiku-class model at ~$0.001/request. Even at 1000 dashboard loads/day = $1/day.

5. **Cacheable.** Same repo state → same decisions. Cache for 10 minutes. Most page loads
   hit cache, not LLM.

6. **Testable.** Write fixtures: "repo with stalled pipeline" → expect callout with
   type=attention. "repo with active agent" → expect hero_insight mentions the agent.
   The renderer is fully deterministic against known JSON.

---

## What About Fully Generated Pages for `.agents/workspaces/`?

There's a separate, complementary idea: let each repo provide a custom landing page
(the existing `.agents/workspaces/index.html` pattern), but instead of requiring the
repo owner to write HTML, let the LLM **generate the initial page** based on the repo's
agent setup, then let the owner refine it.

This is a **one-shot generation** pattern, not a live rendering pattern:

```
1. User selects repo, clicks "Generate custom dashboard"
2. LLM sees repo's .agents/ structure, agent personas, skills, schedule
3. LLM generates a complete index.html + style.css + app.js
4. User previews, edits, commits to .agents/workspaces/
5. From then on, the page is deterministic (data-driven, like the prototypes)
```

This gives you the best of both worlds:
- The generated page is **tailored** to the repo (a repo with 4 agents gets a team grid;
  a repo with 1 agent gets a simpler layout)
- Once committed, it's **fast and deterministic** (no LLM in the render path)
- The owner can iterate on it manually or regenerate it

---

## Failure Modes & Mitigations

| Failure | Impact | Mitigation |
|---------|--------|------------|
| LLM latency > 5s | Annotations arrive too late | Cache aggressively, show shell immediately, use Haiku |
| LLM returns invalid JSON | Annotations don't render | Validate schema, fall back to defaults |
| LLM hallucinates data | "April merged PR #999" (doesn't exist) | Only pass real data in context; LLM annotates, never invents |
| LLM API down | No annotations | Graceful degradation to pure data-driven template |
| Stale cache | Annotations describe old state | 10-min TTL + invalidate on webhook events |
| Prompt injection via repo data | LLM says something unexpected | Sanitize agent names/PR titles before context injection |

---

## Recommendation

**Start with Level 2 (LLM-curated slots).** Specifically:

1. **Ship the deterministic version first** (pick from prototypes A/B/C, or mix elements).
   This is your baseline and your fallback.

2. **Add one LLM slot: the hero insight banner.** One sentence about what's happening in
   the repo right now. Stream it in after the shell renders. This is low-risk, high-value,
   and validates the whole pattern.

3. **Add agent card annotations next.** Per-agent one-liners that contextualize the
   status dot. "Reviewing PR #190 for 2h" is data. "This PR adds diagnostics April
   identified as a gap last week" is insight.

4. **Add section promotion last.** Let the LLM decide whether pipeline, activity, or
   schedule is most relevant right now. This is the most opinionated decision and needs
   the most tuning.

5. **Defer fully generative pages** to a v2 exploration. The one-shot generation pattern
   for `.agents/workspaces/` overrides is promising but separate from the dashboard.

This approach lets you ship fast (deterministic shell works day one), add intelligence
incrementally (each slot is independent), and fail gracefully (every LLM feature degrades
to the deterministic version).
