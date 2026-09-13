# Media for the Compose reference

These assets belong to the self-contained example. The page loads them locally;
the `.dockerignore` allowlist excludes them from image builds. Edit the page,
illustration prompt and guide here without changing the app or a running workspace.

## Environment illustration

`environment-overview.webp` explains the relationship between the definition
directory, a workspace environment, and its two terminal entry points. It is a
concept illustration, not a screenshot of WorkSpaces.

- Model: [`gpt-image-2.5-sunburst`](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst).
- Generated: September 12, 2026, through the OpenAI Images API.
- Workflow: the `image-gen` skill's `generate_openai.py` CLI, with the model selected explicitly.
- Settings: `--size 1536x1024 --quality high --background opaque --output-format webp --output-compression 90`.
- Exact prompt: [environment-overview.prompt.txt](environment-overview.prompt.txt).

To iterate on the concept, edit the prompt and regenerate a sibling image using
the same explicit model. Inspect the labels and connections before replacing the
page's asset. Keep the configuration outside the runtime and show the working
copy as one part of the environment. Do not imply automatic import of arbitrary
Compose projects into WorkSpaces.

## Recorded execution

`compose-sandbox.mp4` is a real 113.64-second VHS recording with synthetic clones
and cached images, at normal playback speed. It shows two independent projects,
guest code and tests, tmux detach/reattach, Postgres persistence, recreation and
scoped teardown. `compose-poster.png` comes from that recording, and `terminal.txt`
contains its transcript with terminal control sequences and trailing whitespace
removed.

`workspaces-provider.mp4` is the separate 89.92-second recording of the production
Swift provider test. `provider-test.txt` preserves the test output, with the local
repository path replaced by `$WORKSPACES_REPO` and trailing whitespace removed.
The test passed in 60.356 seconds with exit code 0.

Both recordings use runtime source from commit `5dca13102c27`. They establish the
terminal and backend behavior shown, not native app interaction or an authenticated
AI model task. The optional Postgres stack belongs to the standalone example;
WorkSpaces currently bundles the agent service alone.
