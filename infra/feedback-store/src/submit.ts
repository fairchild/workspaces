import { ensureSchema } from "./db";
import { verifyJWT } from "./github-verify";
import type { Env, FeedbackPayload } from "./types";

const VALID_KINDS = new Set(["bug", "idea", "feedback"]);
const MAX_MESSAGE_LENGTH = 10_000;

interface Submitter {
  login: string | null;
  id: string | null;
}

export async function handleSubmit(request: Request, env: Env): Promise<Response> {
  await ensureSchema(env);

  const auth = request.headers.get("Authorization");
  const submitter = await resolveSubmitter(auth, env);
  if (auth && !submitter) {
    return json({ error: "invalid jwt" }, 401);
  }

  let parsed: Awaited<ReturnType<typeof parseSubmission>>;
  try {
    parsed = await parseSubmission(request);
  } catch {
    return json({ error: "invalid payload" }, 400);
  }
  const { payload, screenshot, diagnostics } = parsed;
  const validation = validatePayload(payload);
  if (validation) {
    return json({ error: validation }, 400);
  }

  if (payload.honeypot?.trim()) {
    return json({ id: "discarded", status: "accepted" }, 202);
  }

  const ipHash = await hashedIP(request, env);
  if (ipHash && (await isRateLimited(env, ipHash))) {
    return json({ error: "rate limited" }, 429);
  }

  const id = crypto.randomUUID();
  const createdAt = Date.now();
  const prefix = `feedback/${id}`;
  const hasScreenshot = screenshot != null ? 1 : 0;
  const hasDiagnostics = diagnostics != null ? 1 : 0;

  await env.FEEDBACK_BUCKET.put(`${prefix}/payload.json`, JSON.stringify(payload, null, 2), {
    httpMetadata: { contentType: "application/json" },
  });
  if (screenshot) {
    await env.FEEDBACK_BUCKET.put(`${prefix}/screenshot.png`, screenshot.stream(), {
      httpMetadata: { contentType: screenshot.type || "image/png" },
    });
  }
  if (diagnostics) {
    await env.FEEDBACK_BUCKET.put(`${prefix}/diagnostics.zip`, diagnostics.stream(), {
      httpMetadata: { contentType: diagnostics.type || "application/zip" },
    });
  }

  await env.FEEDBACK_DB.prepare(
    `INSERT INTO feedback (
      id, created_at, kind, message, contact_email, submitter_login, submitter_id,
      app_version, os_version, client, ip_hash, status, attachment_prefix,
      has_screenshot, has_diagnostics
    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'new', ?, ?, ?)`
  )
    .bind(
      id,
      createdAt,
      payload.kind,
      payload.message.trim(),
      emptyToNull(payload.contact_email),
      submitter?.login ?? null,
      submitter?.id ?? null,
      payload.app_version,
      payload.os_version,
      payload.client,
      ipHash,
      prefix,
      hasScreenshot,
      hasDiagnostics
    )
    .run();

  return json({ id, status: "new" }, 201);
}

async function resolveSubmitter(auth: string | null, env: Env): Promise<Submitter | null | undefined> {
  if (!auth) return undefined;
  const match = auth.match(/^Bearer\s+(.+)$/i);
  if (!match) return null;

  const claims = await verifyJWT(match[1], env.JWT_SIGNING_SECRET);
  if (!claims) return null;

  return {
    login: typeof claims.login === "string" ? claims.login : null,
    id: typeof claims.sub === "string" ? claims.sub : null,
  };
}

async function parseSubmission(request: Request): Promise<{
  payload: FeedbackPayload;
  screenshot: File | null;
  diagnostics: File | null;
}> {
  const contentType = request.headers.get("Content-Type") ?? "";
  if (contentType.includes("multipart/form-data")) {
    const form = await request.formData();
    const rawPayload = form.get("payload");
    if (typeof rawPayload !== "string") {
      throw new Error("missing payload");
    }
    return {
      payload: JSON.parse(rawPayload) as FeedbackPayload,
      screenshot: fileValue(form.get("screenshot")),
      diagnostics: fileValue(form.get("diagnostics")),
    };
  }

  return {
    payload: (await request.json()) as FeedbackPayload,
    screenshot: null,
    diagnostics: null,
  };
}

function validatePayload(payload: FeedbackPayload): string | null {
  if (!VALID_KINDS.has(payload.kind)) return "invalid kind";
  const message = payload.message?.trim() ?? "";
  if (!message) return "message required";
  if (message.length > MAX_MESSAGE_LENGTH) return "message too long";
  if (!payload.app_version?.trim()) return "app_version required";
  if (!payload.os_version?.trim()) return "os_version required";
  if (payload.client !== "macos") return "invalid client";
  return null;
}

function fileValue(value: FormDataEntryValue | null): File | null {
  return value instanceof File && value.size > 0 ? value : null;
}

async function hashedIP(request: Request, env: Env): Promise<string | null> {
  const ip = request.headers.get("CF-Connecting-IP");
  if (!ip) return null;
  const salt = env.FEEDBACK_IP_HASH_SALT ?? env.JWT_SIGNING_SECRET;
  const digest = await crypto.subtle.digest(
    "SHA-256",
    new TextEncoder().encode(`${salt}:${ip}`)
  );
  return [...new Uint8Array(digest)].map((byte) => byte.toString(16).padStart(2, "0")).join("");
}

async function isRateLimited(env: Env, ipHash: string): Promise<boolean> {
  const limit = Number(env.POSTS_PER_HOUR ?? "10");
  const since = Date.now() - 60 * 60 * 1000;
  const result = await env.FEEDBACK_DB.prepare(
    "SELECT COUNT(*) AS count FROM feedback WHERE ip_hash = ? AND created_at >= ?"
  )
    .bind(ipHash, since)
    .first<{ count: number }>();
  return Number(result?.count ?? 0) >= limit;
}

function emptyToNull(value: string | undefined): string | null {
  const trimmed = value?.trim() ?? "";
  return trimmed ? trimmed : null;
}

function json(body: unknown, status: number): Response {
  return Response.json(body, { status });
}
