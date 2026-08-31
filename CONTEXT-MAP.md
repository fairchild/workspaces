# Context Map

## Contexts

- [WorkSpaces Native App](./GLOSSARY.md) — the product domain: repositories, workspaces, terminal sessions, surfaces
- [Agent Factory](./docs/agents/GLOSSARY.md) — the development-process domain: the autonomous loop that triages, prepares, implements, and ships work on this repo

## Relationships

- **Factory → Product**: the Factory's work items are changes to the WorkSpaces product; issue titles and specs use the product context's language
- **Product → Factory**: Feedback submitted through the product (feedback-store) is an inlet of Factory work
- The web/chat "Spaces" context is flagged in the product glossary but has no `GLOSSARY.md` yet

## Ambiguities

- "Agent" belongs to both contexts with different meanings: in the product context it is an AI assistant a user drives inside a Terminal Session; in the Factory context it is an autonomous worker in the development loop. Qualify when crossing contexts.
