# @fairchild/folio

Folio is the calm, document-first conversation interface used by Workspaces.
This workspace package owns presentation and typed view data; its host owns
authentication, persistence, transport, agent execution, repositories, and
publication authority.

The current package is source-first and private while the boundary is proven
inside Workspaces. It owns its host ports and scoped styles; the remaining W7
slices create a versioned install artifact and prove a real external consumer.

React 19 and AI SDK 7 are peers. Next 15.5 is the tested Workspaces host and is
recorded as advisory compatibility metadata rather than a peer because Folio
itself imports no Next.js API.

Import only from the named entry point:

```tsx
import { SessionView, type SessionViewData } from "@fairchild/folio";
import "@fairchild/folio/styles.css";
```

The stylesheet compiles utilities from Folio source only and scopes every
selector to `data-folio-root`. `SessionView` supplies its own surface root;
`FolioRoot` is available when composing lower-level exports. Multiple instances
can coexist with host UI without resets or token values escaping the root.

Hosts own font loading and may override the narrow `--folio-*` token seam on an
ancestor or one instance. For example:

```css
:root {
  --folio-font-serif: var(--my-prose-font), Georgia, serif;
  --folio-accent: #8f4f2a;
  --folio-dark-accent: #dfa36c;
}
```

Full session surfaces default to `--folio-min-height: 100dvh`; embedded hosts
can set that token to `100%`, a pane height, or `auto` without changing package
CSS.

Folio currently has no external image or font asset paths: its small interface
marks are text/inline CSS. The exported sheet therefore contains the complete
visual dependency graph.

Hosts integrate through `FolioConversationPort`, not through component-specific
knowledge of their routes or runtimes. The port exposes a durable snapshot,
opaque resume cursor, ordered host-neutral events, and commands whose authority
remains with the host:

```ts
import {
  FolioConversationController,
  type FolioConversationPort,
} from "@fairchild/folio";

const controller = new FolioConversationController(hostPort satisfies FolioConversationPort);
await controller.hydrate();
await controller.follow(render);
```

When an established host runtime already owns and projects the current live
snapshot, seed the controller without a redundant async read, then recreate the
binding when that host snapshot changes. `follow()` begins at the seeded cursor
without calling `readSnapshot()` again:

```ts
const controller = FolioConversationController.fromSnapshot(hostPort, hostSnapshot);
```

Only one `follow()` may own a controller at a time. Hosts reconnect by creating
a controller from their durable snapshot cursor; unknown cursors fail closed
with `FolioUnknownCursorError` instead of replaying the conversation from the
beginning. A command receipt carries the first host cursor known to contain the
effect. Its cursor is `null` when a host accepted the command but an externally
owned projection has not observed it yet; callers then await the next snapshot
instead of assuming the old cursor includes new state.

Send commands carry a unique `requestId` for correlation and optional `retryOf`
UI provenance. A retry is a new send unless the host explicitly provides
stronger semantics; hosts may use `requestId` as a deduplication key, but Folio
does not claim that every transport does so.

`SessionView` receives one `FolioConversationActions` object. Missing callbacks
are missing capabilities; the component never discovers or constructs host
authority itself. A hydrated controller can derive that action membrane with
`createPortBackedConversationActions`, which requires a host error callback for
command failures. Derive it again after a capabilities, workspace, or
publication event so the UI reflects the latest host authority; the error
callback still closes the race if authority changes between render and click.
Tests and external adapters can use the deterministic fake without putting test
code in production imports:

```ts
import { FakeConversationPort } from "@fairchild/folio/testing";
```

Server code that only needs the pure token formatter uses the side-effect-free
format entry instead of loading the React component barrel:

```ts
import { formatTokenCount } from "@fairchild/folio/format";
```

App shells use the narrow theme entry so a home or layout route does not pull
in the conversation component graph:

```tsx
import { ThemeToggle, themeInitScript } from "@fairchild/folio/theme";
```

All entries expose an import condition and a default condition so the
source-first package resolves in Next.js, native ESM, and `tsx` CommonJS graphs.

Package-private source paths are not compatibility surfaces.
