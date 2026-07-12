# @fairchild/folio

Folio is the calm, document-first conversation interface used by Workspaces.
This workspace package owns presentation and typed view data; its host owns
authentication, persistence, transport, agent execution, repositories, and
publication authority.

The current package is source-first and private while the boundary is proven
inside Workspaces. Follow-up W7 slices add host ports, package-owned styles,
the versioned install artifact, and a real external-consumer proof.

React 19 and AI SDK 7 are peers. Next 15.5 is the tested Workspaces host and is
recorded as advisory compatibility metadata rather than a peer because Folio
itself imports no Next.js API.

Import only from the named entry point:

```tsx
import { SessionView, type SessionViewData } from "@fairchild/folio";
```

Server code that only needs the pure token formatter uses the side-effect-free
format entry instead of loading the React component barrel:

```ts
import { formatTokenCount } from "@fairchild/folio/format";
```

Both entries expose an import condition and a default condition so the
source-first package resolves in Next.js, native ESM, and `tsx` CommonJS graphs.

Package-private source paths are not compatibility surfaces.
