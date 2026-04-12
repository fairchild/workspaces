import { verifyGitHubSignature, signJWT, verifyJWT } from "./github-verify";
import { log } from "./log";
import type { Env } from "./webhook-relay";

export { WebhookRelay } from "./webhook-relay";

const GITHUB_API_HEADERS = {
  Accept: "application/vnd.github+json",
  "User-Agent": "WorkspaceManager-WebhookRelay",
};

function githubAPI(env: Env, path: string): string {
  return `${env.GITHUB_API_BASE ?? "https://api.github.com"}${path}`;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname;

    if (path === "/health") {
      return new Response("OK", { status: 200 });
    }

    if (path === "/auth/session" && request.method === "POST") {
      return handleAuthSession(request, env);
    }

    if (path === "/webhook" && request.method === "POST") {
      return handleWebhook(request, env);
    }

    const wsMatch = path.match(/^\/ws\/([^/]+)$/);
    if (wsMatch && request.headers.get("Upgrade") === "websocket") {
      return handleWebSocket(request, env, wsMatch[1]);
    }

    return new Response("Not Found", { status: 404 });
  },
};

// ---------------------------------------------------------------------------
// Auth session
// ---------------------------------------------------------------------------

async function handleAuthSession(request: Request, env: Env): Promise<Response> {
  try {
    const body = await request.json<{ github_token: string }>();
    if (!body.github_token) {
      log.warn("auth_session_missing_token");
      return Response.json({ error: "Missing github_token" }, { status: 400 });
    }

    const userResp = await fetch(githubAPI(env, "/user"), {
      headers: { Authorization: `Bearer ${body.github_token}`, ...GITHUB_API_HEADERS },
    });

    if (!userResp.ok) {
      log.warn("auth_session_invalid_token", { status: userResp.status });
      return Response.json({ error: "Invalid GitHub token" }, { status: 401 });
    }

    const user = await userResp.json<{ id: number; login: string }>();

    const installResp = await fetch(githubAPI(env, "/user/installations"), {
      headers: { Authorization: `Bearer ${body.github_token}`, ...GITHUB_API_HEADERS },
    });

    if (!installResp.ok) {
      log.warn("auth_session_install_check_failed", { login: user.login, status: installResp.status });
      return Response.json(
        { error: "Cannot verify GitHub App installation" },
        { status: 403 }
      );
    }

    const installations = await installResp.json<{
      total_count: number;
      installations: Array<{ account: { login: string } }>;
    }>();

    if (installations.total_count === 0) {
      log.warn("auth_session_no_installation", { login: user.login });
      return Response.json(
        { error: "No GitHub App installation found for this user" },
        { status: 403 }
      );
    }

    const orgs = installations.installations.map((i) => i.account.login);

    const now = Math.floor(Date.now() / 1000);
    const expiresIn = 8 * 60 * 60; // 8 hours
    const exp = now + expiresIn;

    const jwt = await signJWT(
      { sub: String(user.id), login: user.login, orgs, iat: now, exp },
      env.JWT_SIGNING_SECRET
    );

    log.info("auth_session_created", { login: user.login, orgs_count: orgs.length });

    return Response.json({
      jwt,
      login: user.login,
      expires_at: new Date(exp * 1000).toISOString(),
    });
  } catch (err) {
    log.error("auth_session_error", { detail: String(err) });
    return Response.json(
      { error: "Internal error", detail: String(err) },
      { status: 500 }
    );
  }
}

// ---------------------------------------------------------------------------
// Webhook ingress — forward to org-level DO
// ---------------------------------------------------------------------------

async function handleWebhook(request: Request, env: Env): Promise<Response> {
  const signature = request.headers.get("X-Hub-Signature-256");
  if (!signature) {
    log.warn("webhook_missing_signature");
    return Response.json({ error: "Missing signature" }, { status: 401 });
  }

  const deliveryId = request.headers.get("X-GitHub-Delivery") ?? undefined;
  const eventType = request.headers.get("X-GitHub-Event") ?? "unknown";
  const body = await request.text();

  const valid = await verifyGitHubSignature(env.GITHUB_WEBHOOK_SECRET, body, signature);
  if (!valid) {
    log.warn("webhook_invalid_signature", { delivery_id: deliveryId, event_type: eventType });
    return Response.json({ error: "Invalid signature" }, { status: 401 });
  }

  const payload = JSON.parse(body);
  const fullName = payload.repository?.full_name as string | undefined;
  if (!fullName) {
    log.warn("webhook_no_repository", { delivery_id: deliveryId, event_type: eventType });
    return Response.json({ error: "No repository in payload" }, { status: 400 });
  }

  const owner = fullName.split("/")[0];

  log.info("webhook_received", { delivery_id: deliveryId, event_type: eventType, repo: fullName });

  const doId = env.WEBHOOK_RELAY.idFromName(owner);
  const stub = env.WEBHOOK_RELAY.get(doId);

  return stub.fetch(
    new Request(request.url, { method: "POST", headers: request.headers, body })
  );
}

// ---------------------------------------------------------------------------
// WebSocket — org-level feed with per-client repo filtering
// ---------------------------------------------------------------------------

async function handleWebSocket(
  request: Request,
  env: Env,
  owner: string
): Promise<Response> {
  const authHeader = request.headers.get("Authorization");
  if (!authHeader?.startsWith("Bearer ")) {
    log.warn("ws_missing_auth", { owner });
    return Response.json({ error: "Missing Authorization header" }, { status: 401 });
  }

  const payload = await verifyJWT(authHeader.slice(7), env.JWT_SIGNING_SECRET);
  if (!payload) {
    log.warn("ws_invalid_jwt", { owner });
    return Response.json({ error: "Invalid or expired token" }, { status: 401 });
  }

  const login = (payload.login as string) ?? "unknown";
  const orgs = payload.orgs as string[] | undefined;
  if (!orgs || !orgs.includes(owner)) {
    log.warn("ws_org_denied", { owner, login });
    return Response.json({ error: "Not authorized for this organization" }, { status: 403 });
  }

  const githubToken = request.headers.get("X-GitHub-Token");
  if (!githubToken) {
    log.warn("ws_missing_github_token", { owner, login });
    return Response.json({ error: "Missing X-GitHub-Token header" }, { status: 401 });
  }

  const repos = await fetchAccessibleRepos(env, githubToken, owner);
  if (repos.length === 0) {
    log.warn("ws_no_accessible_repos", { owner, login });
    return Response.json({ error: "No accessible repositories" }, { status: 403 });
  }

  log.info("ws_connect", { owner, login, repos_count: repos.length });

  const headers = new Headers(request.headers);
  headers.set("X-Allowed-Repos", repos.join(","));

  const doId = env.WEBHOOK_RELAY.idFromName(owner);
  return env.WEBHOOK_RELAY.get(doId).fetch(
    new Request(request.url, { method: request.method, headers })
  );
}

async function fetchAccessibleRepos(env: Env, githubToken: string, owner: string): Promise<string[]> {
  const headers = { Authorization: `Bearer ${githubToken}`, ...GITHUB_API_HEADERS };

  // Try org endpoint; fall back to user repos for personal accounts
  let resp = await fetch(
    githubAPI(env, `/orgs/${owner}/repos?per_page=100&sort=pushed`),
    { headers }
  );
  if (!resp.ok) {
    resp = await fetch(
      githubAPI(env, `/users/${owner}/repos?per_page=100&sort=pushed`),
      { headers }
    );
  }
  if (!resp.ok) return [];

  const repos = await resp.json<Array<{ full_name: string }>>();
  return repos.map((r) => r.full_name);
}
