import { ensureSchema, recordAudit } from "./db";
import { escapeHTML, html, redirect, requireSession } from "./admin";
import type { Env, FeedbackRow } from "./types";

export interface PublishRequest {
  ids: string[];
  title: string;
  body: string;
  actor: string;
  force?: boolean;
}

export type PublishResult =
  | { ok: true; issueURL: string }
  | { ok: false; status: number; error: string; alreadyPublished?: { id: string; url: string }[] };

/**
 * Create one GitHub issue from selected feedback rows, then mark them triaged.
 *
 * Guards against double-publishing: any selected row that already carries a
 * `github_issue_url` blocks the publish (409) unless `force` is set, so a
 * double-click or a retry can't silently mint a duplicate issue. Every
 * affected row gets an audit entry naming the actor.
 */
export async function publishFeedbackAsIssue(env: Env, req: PublishRequest): Promise<PublishResult> {
  const ids = req.ids.map(String).filter(Boolean);
  const title = req.title.trim();
  const body = req.body.trim();
  if (ids.length === 0 || !title || !body) {
    return { ok: false, status: 400, error: "ids, title, and body are required" };
  }
  if (!env.GITHUB_ISSUE_TOKEN) {
    return { ok: false, status: 500, error: "GITHUB_ISSUE_TOKEN is not configured" };
  }

  const rows = await loadRows(env, ids);
  const missing = ids.filter((id) => !rows.some((row) => row.id === id));
  if (missing.length) {
    return { ok: false, status: 404, error: `unknown feedback ids: ${missing.join(", ")}` };
  }

  if (!req.force) {
    const already = rows
      .filter((row) => row.github_issue_url)
      .map((row) => ({ id: row.id, url: row.github_issue_url as string }));
    if (already.length) {
      return {
        ok: false,
        status: 409,
        error: "some feedback already published; pass force to override",
        alreadyPublished: already,
      };
    }
  }

  const issueURL = await createIssue(env, title, buildIssueBody(body, rows), labelsFor(rows));

  for (const id of ids) {
    await env.FEEDBACK_DB.prepare(
      "UPDATE feedback SET github_issue_url = ?, status = 'triaged' WHERE id = ?"
    )
      .bind(issueURL, id)
      .run();
    await recordAudit(env, id, req.actor, "publish", issueURL);
  }

  return { ok: true, issueURL };
}

export async function handlePublish(request: Request, env: Env): Promise<Response> {
  await ensureSchema(env);
  const session = await requireSession(request, env);
  if (!session) return redirect("/admin/login");

  const form = await request.formData();
  const result = await publishFeedbackAsIssue(env, {
    ids: form.getAll("ids").map(String),
    title: String(form.get("title") ?? ""),
    body: String(form.get("body") ?? ""),
    actor: session.login,
  });

  if (!result.ok) {
    const extra = result.alreadyPublished
      ? `<ul>${result.alreadyPublished
          .map((r) => `<li>${escapeHTML(r.id)} → <a href="${escapeHTML(r.url)}">${escapeHTML(r.url)}</a></li>`)
          .join("")}</ul>`
      : "";
    return html(`<p>${escapeHTML(result.error)}</p>${extra}<p><a href="/admin">Back</a></p>`, result.status);
  }

  return html(
    `<p>Published <a href="${escapeHTML(result.issueURL)}">${escapeHTML(result.issueURL)}</a>.</p><p><a href="/admin">Back</a></p>`
  );
}

async function loadRows(env: Env, ids: string[]): Promise<FeedbackRow[]> {
  const rows: FeedbackRow[] = [];
  for (const id of ids) {
    const row = await env.FEEDBACK_DB.prepare("SELECT * FROM feedback WHERE id = ?")
      .bind(id)
      .first<FeedbackRow>();
    if (row) rows.push(row);
  }
  return rows;
}

function labelsFor(rows: FeedbackRow[]): string[] {
  const labels = new Set<string>(["needs-triage"]);
  if (rows.some((row) => row.kind === "bug")) {
    labels.add("bug");
  } else {
    labels.add("enhancement");
  }
  return [...labels];
}

function buildIssueBody(body: string, rows: FeedbackRow[]): string {
  const refs = rows
    .map((row) => `- feedback/${row.id} (${row.kind}, ${new Date(row.created_at).toISOString()})`)
    .join("\n");
  return `${body}\n\n---\nPrivate source feedback references:\n${refs}\n`;
}

async function createIssue(env: Env, title: string, body: string, labels: string[]): Promise<string> {
  const owner = env.GITHUB_OWNER ?? "fairchild";
  const repo = env.GITHUB_REPO ?? "workspaces";
  const apiBase = env.GITHUB_API_BASE ?? "https://api.github.com";
  const response = await fetch(`${apiBase}/repos/${owner}/${repo}/issues`, {
    method: "POST",
    headers: {
      Authorization: `Bearer ${env.GITHUB_ISSUE_TOKEN}`,
      Accept: "application/vnd.github+json",
      "Content-Type": "application/json",
      "User-Agent": "workspaces-feedback-store",
    },
    body: JSON.stringify({ title, body, labels }),
  });
  if (!response.ok) {
    throw new Error(`GitHub issue create failed: ${response.status} ${await response.text()}`);
  }
  const data = (await response.json()) as { html_url?: string };
  if (!data.html_url) throw new Error("GitHub issue response missing html_url");
  return data.html_url;
}
