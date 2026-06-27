import { ensureSchema } from "./db";
import { signJWT, verifyJWT } from "./github-verify";
import type { Env, FeedbackRow } from "./types";

interface AdminSession {
  login: string;
  exp: number;
}

export async function handleAdmin(request: Request, env: Env): Promise<Response> {
  await ensureSchema(env);

  const url = new URL(request.url);
  if (url.pathname === "/admin/login") {
    return loginRedirect(url, env);
  }
  if (url.pathname === "/admin/callback") {
    return callback(request, env);
  }
  if (url.pathname === "/admin/logout" && request.method === "POST") {
    return redirect("/admin/login", [["Set-Cookie", "ws_feedback_admin=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Lax"]]);
  }

  const session = await requireSession(request, env);
  if (!session) {
    return redirect("/admin/login");
  }

  if (url.pathname === "/admin" && request.method === "GET") {
    return list(request, env, session);
  }

  const attachmentMatch = url.pathname.match(/^\/admin\/attachment\/([^/]+)\/(screenshot\.png|diagnostics\.zip)$/);
  if (attachmentMatch && request.method === "GET") {
    return attachment(attachmentMatch[1], attachmentMatch[2], env);
  }

  const detailMatch = url.pathname.match(/^\/admin\/([^/]+)$/);
  if (detailMatch && request.method === "GET") {
    return detail(detailMatch[1], env, session);
  }
  if (detailMatch && request.method === "POST") {
    return update(detailMatch[1], request, env);
  }

  return new Response("not found", { status: 404 });
}

async function attachment(id: string, filename: string, env: Env): Promise<Response> {
  const row = await env.FEEDBACK_DB.prepare("SELECT attachment_prefix FROM feedback WHERE id = ?")
    .bind(id)
    .first<{ attachment_prefix: string | null }>();
  if (!row?.attachment_prefix) return new Response("not found", { status: 404 });

  const object = await env.FEEDBACK_BUCKET.get(`${row.attachment_prefix}/${filename}`);
  if (!object) return new Response("not found", { status: 404 });

  return new Response(object.body, {
    headers: {
      "Content-Type": object.httpMetadata?.contentType ?? contentTypeFor(filename),
      "Cache-Control": "private, no-store",
    },
  });
}

export async function requireSession(request: Request, env: Env): Promise<AdminSession | null> {
  const cookie = request.headers.get("Cookie") ?? "";
  const token = cookie.match(/(?:^|;\s*)ws_feedback_admin=([^;]+)/)?.[1];
  if (!token) return null;
  const payload = await verifyJWT(token, env.ADMIN_SESSION_SECRET);
  if (!payload || typeof payload.login !== "string") return null;
  return { login: payload.login, exp: Number(payload.exp ?? 0) };
}

async function loginRedirect(url: URL, env: Env): Promise<Response> {
  const state = crypto.randomUUID();
  const callbackURL = `${url.origin}/admin/callback`;
  const target = new URL("https://github.com/login/oauth/authorize");
  target.searchParams.set("client_id", env.GITHUB_CLIENT_ID);
  target.searchParams.set("redirect_uri", callbackURL);
  target.searchParams.set("state", state);
  target.searchParams.set("scope", "read:user");
  return redirect(target.toString(), [
    ["Set-Cookie", `ws_feedback_oauth_state=${state}; Path=/admin; Max-Age=600; HttpOnly; Secure; SameSite=Lax`],
  ]);
}

async function callback(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const code = url.searchParams.get("code");
  const state = url.searchParams.get("state");
  const cookieState = request.headers.get("Cookie")?.match(/(?:^|;\s*)ws_feedback_oauth_state=([^;]+)/)?.[1];
  if (!code || !state || state !== cookieState) {
    return new Response("invalid oauth state", { status: 400 });
  }

  const tokenResponse = await fetch("https://github.com/login/oauth/access_token", {
    method: "POST",
    headers: {
      Accept: "application/json",
      "Content-Type": "application/json",
      "User-Agent": "workspaces-feedback-store",
    },
    body: JSON.stringify({
      client_id: env.GITHUB_CLIENT_ID,
      client_secret: env.GITHUB_CLIENT_SECRET,
      code,
      redirect_uri: `${url.origin}/admin/callback`,
    }),
  });
  const tokenBody = (await tokenResponse.json()) as { access_token?: string };
  if (!tokenBody.access_token) {
    return new Response("oauth token exchange failed", { status: 401 });
  }

  const userResponse = await fetch("https://api.github.com/user", {
    headers: {
      Authorization: `Bearer ${tokenBody.access_token}`,
      Accept: "application/vnd.github+json",
      "User-Agent": "workspaces-feedback-store",
    },
  });
  const user = (await userResponse.json()) as { login?: string };
  if (!user.login || !allowedAdmins(env).has(user.login)) {
    return new Response("not allowlisted", { status: 403 });
  }

  const exp = Math.floor(Date.now() / 1000) + 8 * 60 * 60;
  const jwt = await signJWT({ login: user.login, exp }, env.ADMIN_SESSION_SECRET);
  return redirect("/admin", [
    ["Set-Cookie", `ws_feedback_admin=${jwt}; Path=/; Max-Age=${8 * 60 * 60}; HttpOnly; Secure; SameSite=Lax`],
    ["Set-Cookie", "ws_feedback_oauth_state=; Path=/admin; Max-Age=0; HttpOnly; Secure; SameSite=Lax"],
  ]);
}

async function list(request: Request, env: Env, session: AdminSession): Promise<Response> {
  const url = new URL(request.url);
  const status = url.searchParams.get("status") ?? "";
  const kind = url.searchParams.get("kind") ?? "";
  let query = "SELECT * FROM feedback";
  const clauses: string[] = [];
  const bindings: string[] = [];
  if (status) {
    clauses.push("status = ?");
    bindings.push(status);
  }
  if (kind) {
    clauses.push("kind = ?");
    bindings.push(kind);
  }
  if (clauses.length) query += ` WHERE ${clauses.join(" AND ")}`;
  query += " ORDER BY created_at DESC LIMIT 100";

  const result = await env.FEEDBACK_DB.prepare(query).bind(...bindings).all<FeedbackRow>();
  const rows = result.results ?? [];
  return html(page("Feedback", session, table(rows, status, kind)));
}

async function detail(id: string, env: Env, session: AdminSession): Promise<Response> {
  const row = await env.FEEDBACK_DB.prepare("SELECT * FROM feedback WHERE id = ?")
    .bind(id)
    .first<FeedbackRow>();
  if (!row) return new Response("not found", { status: 404 });

  const attachments = [
    row.has_screenshot ? `<li><a href="/admin/attachment/${row.id}/screenshot.png">screenshot.png</a></li>` : "",
    row.has_diagnostics ? `<li><a href="/admin/attachment/${row.id}/diagnostics.zip">diagnostics.zip</a></li>` : "",
  ].join("");

  return html(page("Feedback Detail", session, `
    <p><a href="/admin">Back</a></p>
    <article>
      <h2>${escapeHTML(row.kind)} · ${escapeHTML(row.status)}</h2>
      <p class="meta">${new Date(row.created_at).toLocaleString()} · ${escapeHTML(row.submitter_login ?? "anonymous")} · ${escapeHTML(row.app_version)}</p>
      <pre>${escapeHTML(row.message)}</pre>
      <p>Contact: ${escapeHTML(row.contact_email ?? "none")}</p>
      <p>GitHub: ${row.github_issue_url ? `<a href="${escapeHTML(row.github_issue_url)}">${escapeHTML(row.github_issue_url)}</a>` : "none"}</p>
      <ul>${attachments || "<li>No attachments</li>"}</ul>
      <form method="post">
        <label>Status <select name="status">${["new", "triaged", "planned", "resolved", "wont_fix"].map((value) => `<option ${value === row.status ? "selected" : ""}>${value}</option>`).join("")}</select></label>
        <label>Notes <textarea name="admin_notes">${escapeHTML(row.admin_notes ?? "")}</textarea></label>
        <button>Save</button>
      </form>
    </article>
  `));
}

async function update(id: string, request: Request, env: Env): Promise<Response> {
  const form = await request.formData();
  const status = String(form.get("status") ?? "new");
  const notes = String(form.get("admin_notes") ?? "");
  await env.FEEDBACK_DB.prepare("UPDATE feedback SET status = ?, admin_notes = ? WHERE id = ?")
    .bind(status, notes, id)
    .run();
  return redirect(`/admin/${id}`);
}

function table(rows: FeedbackRow[], status: string, kind: string): string {
  return `
    <form class="filters" method="get">
      <input name="status" placeholder="status" value="${escapeHTML(status)}">
      <input name="kind" placeholder="kind" value="${escapeHTML(kind)}">
      <button>Filter</button>
    </form>
    <form method="post" action="/admin/publish">
      <table>
        <thead><tr><th></th><th>Created</th><th>Kind</th><th>Status</th><th>Submitter</th><th>Message</th></tr></thead>
        <tbody>
          ${rows.map((row) => `
            <tr>
              <td><input type="checkbox" name="ids" value="${escapeHTML(row.id)}"></td>
              <td>${new Date(row.created_at).toLocaleString()}</td>
              <td>${escapeHTML(row.kind)}</td>
              <td>${escapeHTML(row.status)}</td>
              <td>${escapeHTML(row.submitter_login ?? "anonymous")}</td>
              <td><a href="/admin/${escapeHTML(row.id)}">${escapeHTML(row.message.slice(0, 120))}</a></td>
            </tr>
          `).join("")}
        </tbody>
      </table>
      <label>Issue title <input name="title" required></label>
      <label>Issue body <textarea name="body" required></textarea></label>
      <button>Publish selected</button>
    </form>
  `;
}

function page(title: string, session: AdminSession, body: string): string {
  return `<!doctype html>
    <html>
      <head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>${escapeHTML(title)}</title>
        <style>
          body { font: 14px system-ui, sans-serif; margin: 24px; color: #171717; }
          header { display: flex; justify-content: space-between; align-items: center; margin-bottom: 20px; }
          table { border-collapse: collapse; width: 100%; margin: 16px 0; }
          th, td { border-bottom: 1px solid #ddd; padding: 8px; text-align: left; vertical-align: top; }
          textarea { display: block; width: 100%; min-height: 120px; margin: 6px 0 12px; }
          input, select, button { font: inherit; }
          label { display: block; margin: 12px 0; }
          pre { white-space: pre-wrap; background: #f6f6f6; padding: 12px; border-radius: 6px; }
          .meta { color: #666; }
          .filters { display: flex; gap: 8px; align-items: center; }
        </style>
      </head>
      <body>
        <header>
          <h1>${escapeHTML(title)}</h1>
          <form method="post" action="/admin/logout"><span>${escapeHTML(session.login)}</span> <button>Logout</button></form>
        </header>
        ${body}
      </body>
    </html>`;
}

function allowedAdmins(env: Env): Set<string> {
  return new Set(env.ADMIN_ALLOWLIST.split(",").map((entry) => entry.trim()).filter(Boolean));
}

function contentTypeFor(filename: string): string {
  if (filename.endsWith(".png")) return "image/png";
  if (filename.endsWith(".zip")) return "application/zip";
  return "application/octet-stream";
}

export function redirect(location: string, headers: [string, string][] = []): Response {
  return new Response(null, {
    status: 302,
    headers: [["Location", location], ...headers],
  });
}

export function html(body: string, status = 200): Response {
  return new Response(body, {
    status,
    headers: { "Content-Type": "text/html; charset=utf-8" },
  });
}

export function escapeHTML(value: string): string {
  return value
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;")
    .replace(/'/g, "&#39;");
}
