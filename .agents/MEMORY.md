# Memory

Durable design principles for this repo, loaded into every persona session by
`become-persona`. Incident lessons — what a specific failure cost and how to
avoid repeating it — live in `docs/agents/lessons.md`. Keep them there; this file
is for rules that outlive the incident that taught them.

## CI and Runner Isolation

- Every lane needing macOS runs on GitHub-hosted `macos-15` — build/test, the UI smoke lane, agent evidence, and release/signing/notarization alike. Agent and metadata jobs run `ubuntu-latest`.
- **No self-hosted runner is registered for this repo**, and `.github/actionlint.yaml` allows no self-hosted label, so a `runs-on` naming one fails lint rather than queueing forever. Re-provisioning a lane means adding its label back there first.
- Treat the interactive laptop host as unsuitable for intrusive UI/perf automation by default. Perf benchmarks are the sanctioned exception: laptop-local and opt-in per run (`docs/decisions/perf-measurement-laptop-optin.md`), never a CI lane.

## Terminal-First Product Rules

- Default terminal surfaces to minimal chrome. Extra headers and context bars should disappear unless they add clear value.
- Repo overview and terminal views follow different rules: overview can carry metadata and actions; terminal views should stay almost entirely canvas.
- Sidebar actions should be discoverable but quiet: avoid right-click-only primary actions, but also avoid persistent controls that add noise.

## App State and Navigation

- Persist stable IDs in navigation/restore state, not live SwiftData model objects.
- Reconstruct model references late and validate persisted selections against current data before restoring them.
- Deletion and fallback handling should be centralized and deterministic, especially for repo/workspace/web selection state.

## Release Discipline

- App version metadata, tag version, and packaged artifact version must come from one source of truth and be validated before release.
- Release tooling should refuse no-op releases and tag/version mismatches.

## Debugging Heuristic

- If `WorkspaceManager` opens or closes unexpectedly on a developer machine, check the launching process and executable path first before treating it as an app bug.

## Writing Voice

These rules govern every comment, review body, PR body, issue body, and discussion post an agent writes in this repo. #1420 fixed the shape of review bodies; these rules fix the sentences. They appear once, here — persona references point at this section rather than restating it (#1428).

- Start with the point. Do not announce what the comment is about to do; state the finding, verdict, or request in the first sentence.
- Define jargon and acronyms on first use in a few plain words, or drop the term.
- Use plain words and active voice. In an opening, give each sentence one idea.
- Cut decoration: rhetorical triads, aphorisms, italics for drama, punchline sentences, stacked "not X, but Y" reversals.
- Lead with the concrete case — the file, PR, or behavior at hand — and let any general principle follow it. Readable rather than dry: plain writing removes decoration, not specificity.
