import { DurableObject } from "cloudflare:workers";
import { log } from "./log";

export interface Env {
  WEBHOOK_RELAY: DurableObjectNamespace;
  GITHUB_WEBHOOK_SECRET: string;
  JWT_SIGNING_SECRET: string;
  GITHUB_API_BASE?: string;
}

interface StoredEvent {
  id: string;
  type: string;
  action: string;
  summary: string;
  repo: string;
  payload: string | null;
  delivery_id: string | null;
  sender: string | null;
  clients_sent: number;
  created_at: number;
}

interface ClientAttachment {
  allowedRepos: string[];
}

export class WebhookRelay extends DurableObject<Env> {
  private sql: SqlStorage;

  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    this.sql = ctx.storage.sql;

    this.sql.exec(`
      CREATE TABLE IF NOT EXISTS events (
        id TEXT PRIMARY KEY,
        type TEXT NOT NULL,
        action TEXT NOT NULL,
        summary TEXT NOT NULL,
        repo TEXT NOT NULL,
        payload TEXT,
        delivery_id TEXT,
        sender TEXT,
        clients_sent INTEGER NOT NULL DEFAULT 0,
        created_at INTEGER NOT NULL
      )
    `);
    this.sql.exec(
      `CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at)`
    );

    this.migrateSchema();
  }

  private migrateSchema(): void {
    const cols = new Set<string>();
    for (const row of this.sql.exec(`PRAGMA table_info(events)`)) {
      cols.add(row.name as string);
    }
    if (!cols.has("delivery_id")) {
      this.sql.exec(`ALTER TABLE events ADD COLUMN delivery_id TEXT`);
    }
    if (!cols.has("sender")) {
      this.sql.exec(`ALTER TABLE events ADD COLUMN sender TEXT`);
    }
    if (!cols.has("clients_sent")) {
      this.sql.exec(`ALTER TABLE events ADD COLUMN clients_sent INTEGER NOT NULL DEFAULT 0`);
    }
    if (!cols.has("repo")) {
      this.sql.exec(`ALTER TABLE events ADD COLUMN repo TEXT NOT NULL DEFAULT ''`);
    }
  }

  async fetch(request: Request): Promise<Response> {
    if (request.method === "GET" && request.headers.get("Upgrade") === "websocket") {
      return this.handleWebSocketUpgrade(request);
    }

    if (request.method === "POST") {
      return this.handleWebhookPost(request);
    }

    return new Response("Method not allowed", { status: 405 });
  }

  private handleWebSocketUpgrade(request: Request): Response {
    const pair = new WebSocketPair();
    const [client, server] = Object.values(pair);

    this.ctx.acceptWebSocket(server);
    this.ctx.setWebSocketAutoResponse(
      new WebSocketRequestResponsePair("ping", "pong")
    );

    const allowedRepos = (request.headers.get("X-Allowed-Repos") ?? "").split(",").filter(Boolean);
    server.serializeAttachment({ allowedRepos } satisfies ClientAttachment);

    const recent = this.getRecentEvents(50, allowedRepos);
    server.send(JSON.stringify({ type: "catchup", events: recent }));

    const totalClients = this.ctx.getWebSockets().length;
    log.info("do_ws_connected", { catchup_count: recent.length, total_clients: totalClients });

    return new Response(null, { status: 101, webSocket: client });
  }

  private async handleWebhookPost(request: Request): Promise<Response> {
    const eventType = request.headers.get("X-GitHub-Event") ?? "unknown";
    const deliveryId = request.headers.get("X-GitHub-Delivery") ?? null;
    const body = await request.json<Record<string, unknown>>();
    const action = (body.action as string) ?? "";
    const sender = (body.sender as Record<string, unknown>)?.login as string ?? null;
    const repo = (body.repository as Record<string, unknown>)?.full_name as string ?? "unknown";
    const summary = this.buildSummary(eventType, action, body);

    const event: StoredEvent = {
      id: crypto.randomUUID(),
      type: eventType,
      action,
      summary,
      repo,
      payload: JSON.stringify(body),
      delivery_id: deliveryId,
      sender,
      clients_sent: 0,
      created_at: Date.now(),
    };

    this.sql.exec(
      `INSERT INTO events (id, type, action, summary, repo, payload, delivery_id, sender, clients_sent, created_at)
       VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
      event.id, event.type, event.action, event.summary, event.repo,
      event.payload, event.delivery_id, event.sender, event.clients_sent, event.created_at
    );

    this.pruneOldEvents();

    const broadcast = JSON.stringify({
      type: "event",
      event: {
        id: event.id,
        type: event.type,
        action: event.action,
        summary: event.summary,
        repo: event.repo,
        timestamp: event.created_at,
      },
    });

    const sockets = this.ctx.getWebSockets();
    let clientsSent = 0;

    for (const ws of sockets) {
      const attachment = ws.deserializeAttachment() as ClientAttachment | null;
      if (attachment?.allowedRepos?.length && !attachment.allowedRepos.includes(repo)) {
        continue;
      }
      try {
        ws.send(broadcast);
        clientsSent++;
      } catch {
        // Client disconnected, cleaned up by runtime
      }
    }

    if (clientsSent > 0) {
      this.sql.exec(`UPDATE events SET clients_sent = ? WHERE id = ?`, clientsSent, event.id);
    }

    log.info("do_event_stored", {
      event_id: event.id,
      delivery_id: deliveryId,
      event_type: eventType,
      action,
      sender,
      repo,
      clients_sent: clientsSent,
      total_clients: sockets.length,
    });

    return new Response("OK", { status: 200 });
  }

  webSocketMessage(_ws: WebSocket, _message: string | ArrayBuffer): void {
    // Auto-response handles ping/pong
  }

  webSocketClose(_ws: WebSocket, code: number, _reason: string, _wasClean: boolean): void {
    log.info("do_ws_closed", { code, remaining_clients: this.ctx.getWebSockets().length });
  }

  webSocketError(_ws: WebSocket, error: unknown): void {
    log.error("do_ws_error", { detail: String(error) });
  }

  private getRecentEvents(limit: number, allowedRepos: string[]) {
    let cursor: SqlStorageCursor;

    if (allowedRepos.length > 0) {
      const placeholders = allowedRepos.map(() => "?").join(", ");
      cursor = this.sql.exec(
        `SELECT id, type, action, summary, repo, created_at FROM events
         WHERE repo IN (${placeholders})
         ORDER BY created_at DESC LIMIT ?`,
        ...allowedRepos, limit
      );
    } else {
      cursor = this.sql.exec(
        `SELECT id, type, action, summary, repo, created_at FROM events
         ORDER BY created_at DESC LIMIT ?`,
        limit
      );
    }

    const rows: { id: string; type: string; action: string; summary: string; repo: string; timestamp: number }[] = [];
    for (const row of cursor) {
      rows.push({
        id: row.id as string,
        type: row.type as string,
        action: row.action as string,
        summary: row.summary as string,
        repo: row.repo as string,
        timestamp: row.created_at as number,
      });
    }
    return rows.reverse();
  }

  private pruneOldEvents(): void {
    const sevenDaysAgo = Date.now() - 7 * 24 * 60 * 60 * 1000;
    const cursor = this.sql.exec(
      `SELECT COUNT(*) as cnt FROM events WHERE created_at < ?`, sevenDaysAgo
    );
    let pruned = 0;
    for (const row of cursor) { pruned = row.cnt as number; }
    if (pruned > 0) {
      this.sql.exec(`DELETE FROM events WHERE created_at < ?`, sevenDaysAgo);
      log.info("do_events_pruned", { count: pruned });
    }
  }

  private buildSummary(eventType: string, action: string, body: Record<string, unknown>): string {
    const pr = body.pull_request as Record<string, unknown> | undefined;
    const discussion = body.discussion as Record<string, unknown> | undefined;
    const sender = (body.sender as Record<string, unknown>)?.login as string ?? "unknown";

    switch (eventType) {
      case "pull_request": {
        const number = pr?.number ?? "?";
        const title = pr?.title ?? "";
        return `PR #${number} ${action} by ${sender}: ${title}`;
      }
      case "discussion": {
        const number = discussion?.number ?? "?";
        const title = discussion?.title ?? "";
        return `Discussion #${number} ${action} by ${sender}: ${title}`;
      }
      case "discussion_comment": {
        const number = discussion?.number ?? "?";
        return `Comment on discussion #${number} by ${sender}`;
      }
      case "check_run": {
        const checkRun = body.check_run as Record<string, unknown> | undefined;
        const name = checkRun?.name ?? "check";
        const conclusion = checkRun?.conclusion ?? action;
        return `Check "${name}" ${conclusion}`;
      }
      case "check_suite": {
        const checkSuite = body.check_suite as Record<string, unknown> | undefined;
        const conclusion = checkSuite?.conclusion ?? action;
        return `Check suite ${conclusion}`;
      }
      default:
        return `${eventType} ${action} by ${sender}`;
    }
  }
}
