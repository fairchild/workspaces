/**
 * Token-authenticated JSON API for trusted agents (product triage lane).
 * Read/list feedback rows, update status/notes, and publish through the same
 * guarded core as the admin UI, so dedup and the audit trail hold everywhere.
 */
import { auditStatement, ensureSchema } from "./db";
import { publishFeedbackAsIssue } from "./publish";
import { FEEDBACK_STATUSES, type Env, type FeedbackAuditRow, type FeedbackRow } from "./types";

const LIST_LIMIT_DEFAULT = 50;
const LIST_LIMIT_MAX = 200;

export async function handleAgentAPI(request: Request, env: Env): Promise<Response> {
  if (!env.FEEDBACK_AGENT_TOKEN) {
    return Response.json({ error: "agent API is not configured" }, { status: 503 });
  }
  if (!(await bearerTokenMatches(request, env.FEEDBACK_AGENT_TOKEN))) {
    return Response.json({ error: "unauthorized" }, { status: 401 });
  }

  await ensureSchema(env);
  const url = new URL(request.url);
  const segments = url.pathname.split("/").filter(Boolean);

  if (segments[0] !== "api" || segments[1] !== "feedback") {
    return Response.json({ error: "not found" }, { status: 404 });
  }

  if (request.method === "GET" && segments.length === 2) {
    return list(url, env);
  }
  if (request.method === "POST" && segments.length === 3 && segments[2] === "publish") {
    return publish(request, env);
  }
  if (segments.length === 3) {
    if (request.method === "GET") return detail(segments[2], env);
    if (request.method === "PATCH") return update(segments[2], request, env);
  }

  return Response.json({ error: "not found" }, { status: 404 });
}

async function list(url: URL, env: Env): Promise<Response> {
  const status = url.searchParams.get("status") ?? "";
  const kind = url.searchParams.get("kind") ?? "";
  const limit = Math.floor(
    Math.min(Math.max(Number(url.searchParams.get("limit")) || LIST_LIMIT_DEFAULT, 1), LIST_LIMIT_MAX)
  );

  let query = "SELECT * FROM feedback";
  const clauses: string[] = [];
  const bindings: (string | number)[] = [];
  if (status) {
    clauses.push("status = ?");
    bindings.push(status);
  }
  if (kind) {
    clauses.push("kind = ?");
    bindings.push(kind);
  }
  if (clauses.length) query += ` WHERE ${clauses.join(" AND ")}`;
  query += " ORDER BY created_at DESC LIMIT ?";
  bindings.push(limit);

  const result = await env.FEEDBACK_DB.prepare(query).bind(...bindings).all<FeedbackRow>();
  return Response.json({ rows: (result.results ?? []).map(publicRow) });
}

async function detail(id: string, env: Env): Promise<Response> {
  const row = await env.FEEDBACK_DB.prepare("SELECT * FROM feedback WHERE id = ?")
    .bind(id)
    .first<FeedbackRow>();
  if (!row) return Response.json({ error: "not found" }, { status: 404 });

  const audit = await env.FEEDBACK_DB.prepare(
    "SELECT * FROM feedback_audit WHERE feedback_id = ? ORDER BY at ASC"
  )
    .bind(id)
    .all<FeedbackAuditRow>();

  return Response.json({ row: publicRow(row), audit: audit.results ?? [] });
}

async function update(id: string, request: Request, env: Env): Promise<Response> {
  let body: { status?: string; admin_notes?: string | null };
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 });
  }

  const sets: string[] = [];
  const bindings: (string | null)[] = [];
  if (body.status !== undefined) {
    if (typeof body.status !== "string" || !(FEEDBACK_STATUSES as readonly string[]).includes(body.status)) {
      return Response.json(
        { error: `invalid status; expected one of: ${FEEDBACK_STATUSES.join(", ")}` },
        { status: 400 }
      );
    }
    sets.push("status = ?");
    bindings.push(body.status);
  }
  if (body.admin_notes !== undefined) {
    if (body.admin_notes !== null && typeof body.admin_notes !== "string") {
      return Response.json({ error: "admin_notes must be a string or null" }, { status: 400 });
    }
    sets.push("admin_notes = ?");
    bindings.push(body.admin_notes);
  }
  if (!sets.length) {
    return Response.json({ error: "nothing to update; pass status and/or admin_notes" }, { status: 400 });
  }

  const existing = await env.FEEDBACK_DB.prepare("SELECT * FROM feedback WHERE id = ?")
    .bind(id)
    .first<FeedbackRow>();
  if (!existing) return Response.json({ error: "not found" }, { status: 404 });

  // One D1 batch = one transaction: the row change and its audit entry land or fail together.
  await env.FEEDBACK_DB.batch([
    env.FEEDBACK_DB.prepare(`UPDATE feedback SET ${sets.join(", ")} WHERE id = ?`).bind(...bindings, id),
    auditStatement(env, id, actorFrom(request), "update", JSON.stringify(body)),
  ]);

  const updated = await env.FEEDBACK_DB.prepare("SELECT * FROM feedback WHERE id = ?")
    .bind(id)
    .first<FeedbackRow>();
  return Response.json({ row: updated ? publicRow(updated) : null });
}

async function publish(request: Request, env: Env): Promise<Response> {
  let body: { ids?: string[]; title?: string; body?: string; force?: boolean };
  try {
    body = await request.json();
  } catch {
    return Response.json({ error: "invalid JSON body" }, { status: 400 });
  }

  const result = await publishFeedbackAsIssue(env, {
    ids: Array.isArray(body.ids) ? body.ids.map(String) : [],
    title: String(body.title ?? ""),
    body: String(body.body ?? ""),
    actor: actorFrom(request),
    force: body.force === true,
  });

  if (!result.ok) {
    return Response.json(
      { error: result.error, alreadyPublished: result.alreadyPublished },
      { status: result.status }
    );
  }
  return Response.json({ issueURL: result.issueURL });
}

/** Audit actor: caller-declared identity, constrained to a safe slug. */
function actorFrom(request: Request): string {
  const raw = request.headers.get("X-Agent-Actor") ?? "";
  const slug = raw.toLowerCase().replace(/[^a-z0-9_.:-]/g, "").slice(0, 64);
  return slug ? `agent:${slug}` : "agent:unknown";
}

/** The agent lane never needs the submitter's hashed IP. */
function publicRow(row: FeedbackRow): Omit<FeedbackRow, "ip_hash"> {
  const { ip_hash: _ip_hash, ...rest } = row;
  return rest;
}

async function bearerTokenMatches(request: Request, expected: string): Promise<boolean> {
  const match = (request.headers.get("Authorization") ?? "").match(/^Bearer\s+(.+)$/i);
  if (!match) return false;
  const encoder = new TextEncoder();
  const [a, b] = await Promise.all([
    crypto.subtle.digest("SHA-256", encoder.encode(match[1])),
    crypto.subtle.digest("SHA-256", encoder.encode(expected)),
  ]);
  const av = new Uint8Array(a);
  const bv = new Uint8Array(b);
  let diff = 0;
  for (let i = 0; i < av.length; i += 1) diff |= av[i] ^ bv[i];
  return diff === 0;
}
