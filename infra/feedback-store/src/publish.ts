import { ensureSchema } from "./db";
import { escapeHTML, html, redirect, requireSession } from "./admin";
import type { Env, FeedbackRow } from "./types";

export async function handlePublish(request: Request, env: Env): Promise<Response> {
  await ensureSchema(env);
  const session = await requireSession(request, env);
  if (!session) return redirect("/admin/login");

  const form = await request.formData();
  const ids = form.getAll("ids").map(String).filter(Boolean);
  const title = String(form.get("title") ?? "").trim();
  const body = String(form.get("body") ?? "").trim();
  if (ids.length === 0 || !title || !body) {
    return html(`<p>Missing selected feedback, title, or body.</p><p><a href="/admin">Back</a></p>`, 400);
  }
  if (!env.GITHUB_ISSUE_TOKEN) {
    return html(`<p>GITHUB_ISSUE_TOKEN is not configured.</p><p><a href="/admin">Back</a></p>`, 500);
  }

  const rows = await loadRows(env, ids);
  const labels = labelsFor(rows);
  const issueURL = await createIssue(env, title, buildIssueBody(body, rows), labels);

  for (const id of ids) {
    await env.FEEDBACK_DB.prepare("UPDATE feedback SET github_issue_url = ?, status = 'triaged' WHERE id = ?")
      .bind(issueURL, id)
      .run();
  }

  return html(`<p>Published <a href="${escapeHTML(issueURL)}">${escapeHTML(issueURL)}</a>.</p><p><a href="/admin">Back</a></p>`);
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
