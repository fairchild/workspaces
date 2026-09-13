# WorkSpaces Evidence Store Contract

The evidence worker holds PR review evidence — screenshots, screen recordings,
short text artifacts — at `https://evidence.cloudcompute.com`, so a PR body can
link an image that GitHub renders inline. Writes need a token; reads do not,
because the whole point is that a reviewer can open the link.

Uploads come from `scripts/upload-evidence.py` (wrapped by `scripts/evidence.sh`
and `web-next/scripts/upload-evidence.sh`). `EVIDENCE_UPLOAD_TOKEN` lives in the
repo-root `.env` and in GitHub repo secrets.

## `PUT /<repo>/pr-<n>/<name>.<ext>`

`Authorization: Bearer <EVIDENCE_UPLOAD_TOKEN>` is required; anything else is
`401`. `Content-Length` is required (`411` without it) and may not exceed 50 MiB
(`413`). Cloudflare presents a length to the worker even when the client streams
without declaring one, so the cap holds against a streaming upload too — under
`wrangler dev` the same oversize upload is refused as `411` instead, because
miniflare passes the missing header straight through.

The worker stores the object under a **minted key**, not the path you asked for:
an unguessable 22-character segment is inserted directly above the filename, so
`workspaces/pr-142/shot.png` lands at
`workspaces/pr-142/PRF-zMRuZN3Ih0j14u_o3g/shot.png`. Reads are public, so a
predictable key means a predictable public URL; the minted segment is what keeps
an upload from being reachable by anyone who can guess a repo, a PR number and a
plausible slug.

Because of that, **the response is the only authority on where the object
landed**:

```json
{ "url": "https://evidence.cloudcompute.com/<minted key>", "key": "<minted key>" }
```

Prefer `key` when you need to address the object yourself — `url` is built from
the worker's routed hostname, which under `wrangler dev` is still the production
custom domain.

## `GET /<key>`

Public, no token. Keys are resolved verbatim, so objects uploaded before minted
keys existed still resolve at their original paths. `HEAD` is not implemented
and returns `404`.

Every object is served with its stored `Content-Type` (or one inferred from the
extension) and these five headers, whatever its type:

```http
Cache-Control: public, max-age=31536000, immutable
Access-Control-Allow-Origin: *
Content-Security-Policy: default-src 'none'; img-src 'self' https://evidence.cloudcompute.com https://github.com https://*.githubusercontent.com data:; media-src 'self'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'; sandbox
X-Content-Type-Options: nosniff
Referrer-Policy: no-referrer
```

The policy exists because the store accepts `.html`, and an uploaded page is
active content on the same origin as every screenshot and log. It lets a page
show images from this store, GitHub and `data:` URIs, audio and video from this
store, and inline style, and nothing else: no script, fonts, frames, fetches or
`<base>`. `media-src 'self'` is there for recordings rather than pages: a
browser plays a directly opened `.webm` or `.mp4` through a `<video>` element
the policy governs, so without it every recording link opens to a player that
never loads. `sandbox` is the part a page cannot grant itself — a `<meta>`
policy cannot carry it — and it runs the page in an opaque origin with scripts,
form submission, popups, modals and plugins all off, so a page served here
cannot act as this origin even if its own markup tries. `nosniff` holds each
object to its declared type, and `no-referrer` keeps the minted key out of the
`Referer` a page's links send. The policy is the store's to set; a page's own
policy can only narrow it.

Under `wrangler dev`, miniflare rewrites the production hostname inside response
headers to the local address, so the policy there reads
`https://127.0.0.1:8799` where production reads `https://evidence.cloudcompute.com`.

## `DELETE /<key>`

Takes the same bearer token as `PUT`; anything else is `401`. Deletes are
idempotent — a caller who already holds the token learns nothing from a `204` on
a key that was already gone, so there is no separate `404`. This is the escape
hatch for an upload that should never have been public; without it, a mistaken
upload is permanent.

`DELETE` is deliberately absent from the CORS `Access-Control-Allow-Methods`
list. It is a token-holder operation, not a browser one.

## Retention

Objects expire 30 days after upload. R2 lifecycle rules cannot be declared in
`wrangler.toml`, so this is applied out of band and recorded here:

```bash
cd infra/cloudflare-evidence-store
export CLOUDFLARE_ACCOUNT_ID=9d1a8fe235b13dcab0fa3bcb6181ab0c
./node_modules/.bin/wrangler r2 bucket lifecycle add evidence-screenshots \
  --name expire-evidence --expire-days 30
./node_modules/.bin/wrangler r2 bucket lifecycle list evidence-screenshots
```

`evidence-screenshots-preview` has carried an equivalent `expire-preview` rule
since it was created; this brings production in line with it.

Thirty days is chosen against how long evidence is actually read, not against
storage cost — 300 MB across 1,322 objects costs well under a cent a month, so
cost argues for nothing. Over the last 200 merged PRs the median stayed open
about four hours, the 99th percentile four and a half days, and the longest-lived
one seventeen days. Thirty days is therefore comfortably longer than any PR has
ever stayed open, which means no evidence link has ever expired while its PR was
still under review. What it does cost is archaeology: links in PR bodies older
than a month go dead, and a merged PR read a quarter later has no screenshots.
That is the deliberate trade — the store's job is to carry evidence through
review, and everything it keeps after that is public forever at a stable URL.

## Verifying

`scripts/evidence-roundtrip.sh` exercises the access rules end to end against a
live deployment — token-gated write, public read, token-gated withdrawal, and the
size cap — uploading one small text file and deleting it again:

```bash
./scripts/evidence-roundtrip.sh                                   # production
./scripts/evidence-roundtrip.sh --base-url http://127.0.0.1:8799  # wrangler dev
```

`npm test` covers the same rules as unit tests. Note that `src/evidence.ts`
exists because the Workers runtime refuses to start when the entry module has a
named export that is not a function or an `ExportedHandler` — keeping the limits
and pure helpers out of `index.ts` is what makes `wrangler dev` work.
