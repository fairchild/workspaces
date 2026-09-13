# Agent Decision Notifications

## Status

Proposed, 2026-09-13. Implemented behind an experimental feature flag, off by default until it has been
demonstrated and introduced.

## Context

Someone running agents needs a way to be reached: the thing that needs their attention, presented so it is very
easy to act on — yes, or no, or this instead, or A, or B with A recommended — very tight, very simple, with a
link to click to see more.

The need is measurable rather than felt. On 2026-09-13 nine pull requests waited eleven hours on a single click
each. The median time from a decision being asked to being answered, over the previous thirty days, is about
6.7 hours across 24 answered cards. The bottleneck is the person's attention, not the amount of work being produced.

That framing decides the harder half of the problem. A surface that had delivered all nine of that night's pull
requests would be worse than no surface, because it would have been muted inside a week. So this document has to
answer what earns an interruption before it answers how one is delivered.

### What already exists, and is not rebuilt here

The decision object is not ours to invent. An agent decision board serves cards over HTTP, at
`http://127.0.0.1:8791` unless the app is told otherwise. The app reads each card as a JSON document: a
plain-words `title` that is the decision itself, two or three one-line `options`, the agent's `recommended`
option marked before anyone answers, a `topic`, an `order`, a `status`, an `askedAt` stamp and an optional
`detail`.

The answer path is instrumented, and that instrumentation is the reason the whole thing exists. A write to the
card's document makes the board stamp `agreed` — did the answer match the marked prediction — and
`answeredVia`, and append one `answer` record line. That record is how the agent learns which questions it
predicts well enough to stop asking. An answer arriving by some other route, skipping that recording, breaks
the only feedback loop the agent has.

Two hypotheses were stated for this work on 2026-09-13, with their baselines, before any code existed. The
latency hypothesis: notified decisions answered in under a quarter of the unnotified 6.7-hour median, over at
least five notified asks. The muting hypothesis: answer rate on notified cards week over week, killed if the
rate falls while volume rises, which is the muting signature. The board's metric vocabulary already carries a
`notify-sent` event with `id`, `channel` and `queued` fields for this surface. This design exists to produce
those numbers.

Inside this app, `Sources/WorkspaceManager/Services/AgentNotificationPoster.swift` posts plain macOS
notifications for agent permission prompts. It has no `UNNotificationCategory`, no `UNNotificationAction` and
no `UNUserNotificationCenterDelegate`, so today a notification cannot carry a button and a tap has nowhere to
land. That gap is the work.

## Decision

### The app renders a decision; it never authors one

WorkSpaces gains no decision model. A card is decoded from the board's JSON into a read-only value. The app's
entire job is to choose the one card that earns an interruption, render it, and return the tap to the board's
answer route unchanged. Every field the board owns — `recommended`, `agreed`, `order`, `topic` — stays the
board's. If the app ever computed one of them, two surfaces would disagree about the same decision and neither
would be trustworthy.

### The line between what this surface may do and what it must not

The surface never answers, never defers, and never decides. It carries a question and returns a tap. The only
judgement it exercises is which card to show and when to stay silent, and even that judgement is the board's
`order` field rather than the app's opinion.

The question of whether a decision should have been asked at all is settled upstream, before a card is written:
a choice that costs only tokens is built and shown rather than asked, and a choice that costs money, a
credential, a production touch, a public post or a deletion is asked. Nothing in this design moves that line,
and nothing here lets the app act on the person's behalf. A future surface that wanted to answer for them would be
a different document with a different gate.

### The app reads the board on a timer; the agent does not push

`GET /api/collection/decisions` every thirty seconds.

The measure decides this, not taste. The hypothesis this surface has to satisfy is stated in hours, against a
6.7-hour baseline, and is confirmed at roughly 1.7 hours. A thirty-second poll sits three orders of magnitude
inside that tolerance. Any latency a push would buy is invisible to the only number that decides whether the
feature stays.

Polling also makes the app-not-running case ordinary instead of special. The first poll after launch is the
catch-up. There is no queue to drain, nothing delivered late, and no state held on the agent's side about
what the app has and has not already seen.

**What a poller costs in this codebase, stated plainly.** There is no timer-based poller in the app today and
no filesystem watching of any kind — no FSEvents, no `DispatchSource` file source, no `NSFilePresenter`. So a
poller is net-new machinery whichever route we take. The cost is one cancellable `Task` holding a
`while !Task.isCancelled` sleep loop, which already has a precedent in `MobilePairingView`, plus an actor HTTP
client following `NotificationSessionService`, plus teardown. That is small, and it is the smallest of the
three options; it is not free, and calling it free would be the wrong reason to choose it.

**Rejected — the agent pushes through the Automation API.** It is the app's only inbound channel and it is
the wrong one. It is off by default behind Experimental Features, its handle is a capability issued to a
process running inside a terminal tile, and its V1 boundaries explicitly exclude this class of verb (see
[Automation API V1 Decision](./automation-api-v1.md)). Adding one means a new capability that lets an external
process make the app interrupt the person, which deserves its own decision document and its own gate. The app has
to be running for a notification to post regardless, which is the one thing a push was supposed to solve.

**Rejected — Server-Sent Events on the board's `/events`.** This is real and it works; the board page already
consumes it, and it needs no new endpoint on either side. It is the correct upgrade the day a measure needs
seconds instead of hours. It is not worth a streaming client, a reconnect loop and a second failure mode for a
gain the instrument cannot see. It is recorded here so it is found rather than rediscovered.

**Rejected — reading the JSON documents directly, or watching the store.** The app is unsandboxed, so it could.
It would couple the app to the store's on-disk layout instead of the board's HTTP contract, and worse, an
answer would have to be written by editing the file, bypassing the route that stamps `agreed` and appends the
record line. That route is the only path.

### One slot, not one notification per card

The delivered notification's identifier is the constant `agent.decision.current`. Posting with an identifier
that is already delivered replaces it, so "one notification at a time" becomes a property of the identifier
rather than a policy a later edit can forget. The card's own id travels in `userInfo`, which is captured when
the notification is posted and arrives with the response, so the delegate always knows which card was actually
tapped even if the slot has since moved on.

The slot holds the highest-priority open card: lowest `order`, then oldest `askedAt`. When several are waiting
the body carries the count of the rest — "3 more waiting" — because a count is information and a second
notification is an interruption. Posts are coalesced to at most one per thirty seconds, matching the window
`AgentNotificationPoster` already uses, so a burst of card writes cannot strobe the banner.

**Rejected — an identifier per card.** It makes each notification individually addressable, which sounds better
and buys nothing: the surface only ever wants the top one, and per-card identifiers turn the one-at-a-time rule
back into bookkeeping that has to be correct every time.

### Every option, or no options

A notification offers all of the card's options as buttons, or it offers none and only opens the board.

Never a subset. `agreed` is the answer scored against a prediction over a particular set of options. A
notification showing two of three options would be asking a different question than the card asked, and the
alignment record would go on reporting a number for a question nobody was asked. Silently measuring the wrong
thing is worse than measuring nothing.

macOS renders a limited number of actions inline and collapses the rest behind a menu. The exact number is
established by the demonstrated run rather than asserted here. Whatever it is, it sets the cap: cards at or
under it are answerable in one tap, and cards above it get a single "Open on the board" and the default tap.

**This constrains the card writer, not only the app.** Two options is not a matter of style. It is the
difference between a decision the person can answer without leaving what they are doing and one they cannot.
That belongs in the agent's card-writing guidance, and this document is the reason to put it there.

### A tap writes exactly what a click writes

`PATCH /api/doc/decisions/<id>` with the fields the board page sends, plus the channel:

```json
{"status": "answered", "answer": "<the option, verbatim>", "note": "",
 "answeredAt": "<ISO 8601>", "settleAt": "<answeredAt + 8s, ISO 8601>", "answeredVia": "tap"}
```

The app never computes `agreed` — the server does, on this write, exactly as it does for a click.

`tap` is a real answer channel on the board rather than an inference. An earlier draft of this document had the
app send nothing and let the channel be recovered by correlating a `notify-sent` and an `answer` on the same
card id. That join breaks the first time two notifications go out close together, and the hypothesis being
tested compares the channels head to head, so the channel has to be a field rather than a guess.

The default tap, meaning the notification body rather than a button, opens the board. That is the link to click
to see more.

### The undo window is honoured, not skipped

A board click carries `settleAt = answeredAt + 8s` and shows a toast with an Undo for those eight seconds. The
window exists so the agent never acts on a click that is still undoable, and the agent's read of the board
filters on it.

A notification tap has no toast, so the app posts one. Once the write lands, the slot is replaced by a
confirmation notification carrying a single Undo action, withdrawn after eight seconds. Undo sends the page's
exact revert: `{"status": "open", "answer": "", "note": "", "answeredAt": "", "settleAt": ""}`.

This is not a second interruption. It is feedback on an action the person just took, on a surface whose buttons are
small and easy to hit by accident, and it is what makes the channel safe enough to use quickly. A channel where
a mis-tap cannot be taken back gets used slowly, which defeats the point of having it.

### The app withdraws, because the app is holding it

The same poll tick that decides what to post decides what to withdraw. The slot is cleared when the top card
has been answered somewhere else, when it is deleted, or when no open card remains. There is no separate
staleness timer and no stale-card concept: stale means no longer the top open card, which the poll already
knows.

An ignored notification is not an error state. It stays in Notification Center, it is not re-posted, and
nothing else is sent while it stands. The channel going quiet while a decision waits is the honest signal that
the queue is blocked on the person. Re-nagging is precisely the muting signature the muting hypothesis
predicts, so the design does not do it.

### Measurement

On every post, `POST /api/metric` with `{"event": "notify-sent", "id": "<card>", "channel":
"macos-notification", "queued": <count of other open cards>, "visit": "<per-launch id>"}`. The `queued` field
is the one-at-a-time rule making itself measurable.

The `answer` record line the board writes on the PATCH supplies the latency. The pair, matched on the card id,
is what the latency hypothesis reads.

The `answer` record line carries `via: tap`, so the two channels are compared directly rather than by a join
that would break the first time two notifications went out close together.

A card writer is expected to warn when a card carries more than two options, saying at the moment of writing
that the card cannot be sent as a one-tap notification and will wait on the board. A warning rather than a
refusal, because some decisions genuinely have three options and the board can still carry them; the point is
that the cost is stated where the card is written rather than discovered when the notification arrives without
its buttons.

## Shape in this codebase

| Concern | Where it goes | Why there |
|---|---|---|
| Board HTTP client | `Sources/WorkspaceManagerCore/Services/` | All outbound HTTP lives in Core; an `actor` taking `baseURL` and an injected `URLSession`, following `NotificationSessionService`. Core is also the only test target with `MockURLProtocol`. |
| Card value type | `Sources/WorkspaceManagerCore/Services/` | Decoded, `Sendable`, read-only. |
| Notification surface | `Sources/WorkspaceManager/Services/` | `@MainActor`, owns the poll loop, the slot, the category and the delegate. |
| Lifecycle | Its own type, started from `WorkspaceManagerApp.init()` | A sibling of `ClaudeIntegrationLifecycle`, not a passenger inside it: this has nothing to do with Claude hooks, and `ClaudeIntegrationLifecycle.start()` is skipped entirely when `CI` is set. |
| Board URL | `NotificationConstants` | Existing convention of an env-overridable static with a literal fallback. |
| On/off | `ExperimentalFeature` | The house mechanism gives a storage key, a force-on environment key, and Settings rendering for one added case. |

Three constraints inherited from the existing poster. Every `UNUserNotificationCenter` call must sit behind the
same real-`.app`-bundle guard, because an unbundled `swift run` binary raises through the runloop and
terminates the app. The delegate must be assigned during `App.init()`, before launch finishes, or a tap that
launches the app is lost. The delegate object must be retained by the lifecycle, or it is deallocated and the
response never arrives.

### Demonstrating it safely

The standard dev loop cannot post notifications: `launch-dev.sh` runs the raw binary at
`.build/arm64-apple-macosx/debug/WorkspaceManager`, which fails the bundle guard. A real bundle comes from
`scripts/build-release.sh` into `build/WorkSpaces.app`.

The demonstrated run must not disturb the installed app. `/Applications/WorkSpaces.app` is the live daily
driver hosting every agent terminal on this machine, so it is never replaced, reinstalled or restarted for a
demo. A second instance sharing the bundle identifier contends for the automation socket and can delete the
credential the running app minted, which the running app cannot observe. The demo launches the freshly built
bundle in place with an isolated data directory and an isolated automation support directory, and without
binding the hook listener socket.

## What this does not build

- No decision model, ranking, or priority logic in the app. The board's `order` is the priority.
- No new endpoint on either side.
- No notification for anything but decision cards. Agent permission prompts keep their existing, separate
  poster and their own behaviour.
- No escalation, no repeat, no second reminder.
- No in-app decision view. The board is the place a card is read in full.

## Consequences

The app has to be running. A decision asked while it is closed is notified at the next launch. That is right
for a laptop app and wrong for a phone, and the phone is a different arc.

The board has to be up. When it is not, the surface is silent, which is the correct failure mode: silence means
nothing needs attention, and a surface that could not tell "nothing waiting" from "cannot see" would have to say so,
which is a notification about the notifier.

Two-option cards become a soft requirement for one-tap answering.

Shipping off by default behind an experimental flag is the house pattern and the right default for something
that interrupts people, but it carries a known failure: a thing nobody learns to use did not ship. Turning it
on is an introduction someone has to make, not a setting anyone is expected to discover.
