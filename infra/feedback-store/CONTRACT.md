# WorkSpaces Feedback Store Contract

The feedback worker owns private in-app feedback for WorkSpaces at `https://feedback.cloudcompute.com`.

## `POST /feedback`

Clients submit `multipart/form-data`:

- `payload`: JSON object
- `screenshot`: optional PNG file
- `diagnostics`: optional zip file

`payload`:

```json
{
  "kind": "bug|idea|feedback",
  "message": "required, 1-10000 chars",
  "contact_email": "optional",
  "app_version": "required",
  "os_version": "required",
  "client": "macos",
  "honeypot": "must be empty when present"
}
```

`Authorization: Bearer <notification JWT>` is optional. When present, the worker verifies the HS256 JWT with `JWT_SIGNING_SECRET` and stores `sub` plus `login`; invalid JWTs are rejected with `401`. Anonymous submissions are accepted.

`JWT_SIGNING_SECRET` is intentionally shared with the notification webhook relay.
Keep the same value on Cloudflare Workers `webhook-relay`,
`webhook-relay-preview`, `feedback-store`, and `feedback-store-preview`, and
rotate all four together. If these drift, `/auth/session` can still issue
notification JWTs, but the feedback worker cannot verify them for signed-in
attribution.

Response:

```json
{ "id": "<feedback uuid>", "status": "new" }
```

Abuse controls: message length cap, attachment size caps enforced by Worker request limits, honeypot discard, salted `ip_hash`, and a per-IP D1 rolling hourly limit backed by `POSTS_PER_HOUR`.

## Storage

D1 binding: `FEEDBACK_DB`.

`feedback` table:

- `id` TEXT PRIMARY KEY
- `created_at` INTEGER milliseconds
- `kind` TEXT (`bug|idea|feedback`)
- `message` TEXT
- `contact_email` TEXT nullable
- `submitter_login` TEXT nullable
- `submitter_id` TEXT nullable
- `app_version` TEXT
- `os_version` TEXT
- `client` TEXT (`macos`)
- `ip_hash` TEXT nullable
- `status` TEXT default `new` (`new|triaged|planned|resolved|wont_fix`)
- `admin_notes` TEXT nullable
- `github_issue_url` TEXT nullable
- `attachment_prefix` TEXT nullable
- `has_screenshot` INTEGER
- `has_diagnostics` INTEGER

Indexes: `created_at`, `status`, `kind`.

R2 binding: `FEEDBACK_BUCKET`, bucket `workspaces-feedback`.

R2 keys:

- `feedback/<id>/payload.json`
- `feedback/<id>/screenshot.png`
- `feedback/<id>/diagnostics.zip`

## Admin

Admin UI is served by the worker:

- `GET /admin/login`
- `GET /admin/callback`
- `GET /admin`
- `GET /admin/:id`
- `POST /admin/:id`
- `POST /admin/publish`
- `POST /admin/logout`

Admin auth uses GitHub OAuth with `GITHUB_CLIENT_ID` and
`GITHUB_CLIENT_SECRET`. The Cloudflare secret binding is named
`GITHUB_CLIENT_SECRET`, and it should be populated with the same GitHub OAuth
client secret used by the web WorkSpaces app (`GITHUB_WEB_WORKSPACES_CLIENT_SECRET`
in local operator env files). The callback fetches the GitHub user and requires
their login to be present in comma-separated `ADMIN_ALLOWLIST`. Sessions are
signed HS256 JWT cookies with `ADMIN_SESSION_SECRET`.

Admin publish accepts selected feedback IDs plus editable `title` and `body`, creates an issue in `GITHUB_OWNER/GITHUB_REPO` using `GITHUB_ISSUE_TOKEN`, applies `enhancement` or `bug` and `needs-triage`, and writes the resulting `github_issue_url` back to every selected row.

**Dedup:** publish is guarded against double-publishing — re-publishing a row that already has a `github_issue_url` is rejected with a `409` page listing the existing issue(s), so a double-click or retry can't silently mint a duplicate issue. (The guard lives in the shared `publishFeedbackAsIssue` core, which also supports a `force` override for the rare intentional re-publish.)

## Audit trail

`feedback_audit` (append-only) records every publish from the admin UI, so a triage action is always attributable:

- `id` INTEGER PK, `feedback_id` TEXT, `at` INTEGER ms, `actor` TEXT (the admin login), `action` TEXT (currently `publish`), `detail` TEXT nullable (the issue URL).
