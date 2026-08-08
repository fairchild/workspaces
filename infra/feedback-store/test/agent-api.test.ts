/**
 * Agent API behavior: bearer auth gate, list/detail reads, validated
 * status/notes updates with audit entries, and publish routed through the
 * shared guarded core. In-memory D1 fake; stubbed fetch keeps GitHub out.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { handleAgentAPI } from "../src/agent-api";
import type { Env, FeedbackRow } from "../src/types";

class FakeD1 {
  feedback: FeedbackRow[] = [];
  audit: any[] = [];
  prepare(sql: string) {
    return new FakeStatement(this, sql, []);
  }
  async exec() {
    return {} as unknown;
  }
  async batch(statements: FakeStatement[]) {
    return Promise.all(statements.map((statement) => statement.run()));
  }
}

class FakeStatement {
  constructor(private db: FakeD1, private sql: string, private args: unknown[]) {}
  bind(...args: unknown[]) {
    return new FakeStatement(this.db, this.sql, args);
  }
  async first<T>(): Promise<T | null> {
    const row = this.db.feedback.find((r) => r.id === this.args[0]);
    return (row ? { ...row } : null) as T | null;
  }
  async all<T>(): Promise<{ results: T[] }> {
    if (this.sql.includes("FROM feedback_audit")) {
      const rows = this.db.audit.filter((r) => r.feedback_id === this.args[0]);
      return { results: rows as T[] };
    }
    let rows = [...this.db.feedback];
    let arg = 0;
    if (this.sql.includes("status = ?")) {
      const status = this.args[arg++];
      rows = rows.filter((r) => r.status === status);
    }
    if (this.sql.includes("kind = ?")) {
      const kind = this.args[arg++];
      rows = rows.filter((r) => r.kind === kind);
    }
    rows.sort((a, b) => b.created_at - a.created_at);
    if (this.sql.includes("LIMIT ?")) {
      const limit = this.args[arg++];
      // Real SQLite rejects non-integer LIMIT bindings ("datatype mismatch").
      if (!Number.isInteger(limit)) throw new Error("datatype mismatch");
      rows = rows.slice(0, limit as number);
    }
    return { results: rows.map((r) => ({ ...r })) as T[] };
  }
  async run() {
    if (this.sql.startsWith("INSERT INTO feedback_audit")) {
      const [feedback_id, at, actor, action, detail] = this.args;
      this.db.audit.push({ feedback_id, at, actor, action, detail });
    } else if (this.sql.startsWith("UPDATE feedback SET github_issue_url")) {
      const [url, id] = this.args;
      const row = this.db.feedback.find((r) => r.id === id);
      if (row) {
        row.github_issue_url = url as string;
        row.status = "triaged";
      }
    } else if (this.sql.startsWith("UPDATE feedback SET")) {
      const id = this.args[this.args.length - 1];
      const row = this.db.feedback.find((r) => r.id === id);
      if (row) {
        const sets = this.sql
          .slice("UPDATE feedback SET ".length, this.sql.indexOf(" WHERE"))
          .split(", ")
          .map((clause) => clause.split(" = ")[0]);
        sets.forEach((column, index) => {
          (row as any)[column] = this.args[index];
        });
      }
    }
    return {} as unknown;
  }
}

function makeRow(over: Partial<FeedbackRow> = {}): FeedbackRow {
  return {
    id: "fb-1",
    created_at: 1,
    kind: "bug",
    message: "it broke",
    contact_email: null,
    submitter_login: null,
    submitter_id: null,
    app_version: "1.0",
    os_version: "15",
    client: "macos",
    ip_hash: "secret-hash",
    status: "new",
    admin_notes: null,
    github_issue_url: null,
    attachment_prefix: null,
    has_screenshot: 0,
    has_diagnostics: 0,
    ...over,
  };
}

const TOKEN = "test-agent-token";

function makeEnv(db: FakeD1): Env {
  return {
    FEEDBACK_DB: db as unknown as D1Database,
    FEEDBACK_AGENT_TOKEN: TOKEN,
    GITHUB_ISSUE_TOKEN: "gh-token",
  } as Env;
}

function apiRequest(path: string, init: RequestInit = {}, token: string | null = TOKEN): Request {
  const headers = new Headers(init.headers);
  if (token) headers.set("Authorization", `Bearer ${token}`);
  return new Request(`https://feedback.example${path}`, { ...init, headers });
}

const realFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = realFetch;
});

describe("agent API auth", () => {
  test("rejects missing and wrong tokens", async () => {
    const env = makeEnv(new FakeD1());
    expect((await handleAgentAPI(apiRequest("/api/feedback", {}, null), env)).status).toBe(401);
    expect((await handleAgentAPI(apiRequest("/api/feedback", {}, "nope"), env)).status).toBe(401);
  });

  test("503 when the lane is not configured", async () => {
    const env = { ...makeEnv(new FakeD1()), FEEDBACK_AGENT_TOKEN: undefined } as Env;
    expect((await handleAgentAPI(apiRequest("/api/feedback"), env)).status).toBe(503);
  });
});

describe("agent API reads", () => {
  test("lists rows filtered by status, without ip_hash", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a", status: "new", created_at: 2 }));
    db.feedback.push(makeRow({ id: "b", status: "triaged", created_at: 3 }));

    const response = await handleAgentAPI(apiRequest("/api/feedback?status=new"), makeEnv(db));
    const body = (await response.json()) as { rows: Record<string, unknown>[] };

    expect(body.rows.map((r) => r.id)).toEqual(["a"]);
    expect("ip_hash" in body.rows[0]).toBe(false);
  });

  test("detail returns the row plus its audit trail", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a" }));
    db.audit.push({ feedback_id: "a", at: 5, actor: "agent:mara", action: "update", detail: null });

    const response = await handleAgentAPI(apiRequest("/api/feedback/a"), makeEnv(db));
    const body = (await response.json()) as { row: { id: string }; audit: { actor: string }[] };

    expect(body.row.id).toBe("a");
    expect(body.audit[0].actor).toBe("agent:mara");
  });

  test("fractional limit params are floored to a valid integer binding", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a", created_at: 1 }));
    db.feedback.push(makeRow({ id: "b", created_at: 2 }));
    db.feedback.push(makeRow({ id: "c", created_at: 3 }));

    const response = await handleAgentAPI(apiRequest("/api/feedback?limit=2.5"), makeEnv(db));
    const body = (await response.json()) as { rows: { id: string }[] };

    expect(response.status).toBe(200);
    expect(body.rows.map((r) => r.id)).toEqual(["c", "b"]);
  });

  test("detail 404s on unknown ids", async () => {
    const response = await handleAgentAPI(apiRequest("/api/feedback/missing"), makeEnv(new FakeD1()));
    expect(response.status).toBe(404);
  });
});

describe("agent API updates", () => {
  test("updates status and notes, recording an attributed audit entry", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a" }));

    const response = await handleAgentAPI(
      apiRequest("/api/feedback/a", {
        method: "PATCH",
        body: JSON.stringify({ status: "triaged", admin_notes: "dup of #123" }),
        headers: { "X-Agent-Actor": "mara" },
      }),
      makeEnv(db)
    );
    const body = (await response.json()) as { row: { status: string; admin_notes: string } };

    expect(body.row.status).toBe("triaged");
    expect(body.row.admin_notes).toBe("dup of #123");
    expect(db.audit).toHaveLength(1);
    expect(db.audit[0].actor).toBe("agent:mara");
    expect(db.audit[0].action).toBe("update");
  });

  test("admin_notes null clears the field; non-string notes are rejected", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a", admin_notes: "old note" }));
    const env = makeEnv(db);

    const cleared = await handleAgentAPI(
      apiRequest("/api/feedback/a", { method: "PATCH", body: JSON.stringify({ admin_notes: null }) }),
      env
    );
    const body = (await cleared.json()) as { row: { admin_notes: string | null } };
    const rejected = await handleAgentAPI(
      apiRequest("/api/feedback/a", { method: "PATCH", body: JSON.stringify({ admin_notes: 42 }) }),
      env
    );

    expect(body.row.admin_notes).toBeNull();
    expect(rejected.status).toBe(400);
  });

  test("rejects unknown statuses and empty updates", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a" }));
    const env = makeEnv(db);

    const bad = await handleAgentAPI(
      apiRequest("/api/feedback/a", { method: "PATCH", body: JSON.stringify({ status: "bogus" }) }),
      env
    );
    const empty = await handleAgentAPI(
      apiRequest("/api/feedback/a", { method: "PATCH", body: JSON.stringify({}) }),
      env
    );

    expect(bad.status).toBe(400);
    expect(empty.status).toBe(400);
    expect(db.audit).toHaveLength(0);
  });
});

describe("agent API publish", () => {
  test("routes through the guarded core: creates the issue, marks triaged, audits", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a" }));
    globalThis.fetch = (async () =>
      Response.json({ html_url: "https://github.com/fairchild/workspaces/issues/999" })) as unknown as typeof fetch;

    const response = await handleAgentAPI(
      apiRequest("/api/feedback/publish", {
        method: "POST",
        body: JSON.stringify({ ids: ["a"], title: "Fix it", body: "Details" }),
        headers: { "X-Agent-Actor": "mara" },
      }),
      makeEnv(db)
    );
    const body = (await response.json()) as { issueURL: string };

    expect(body.issueURL).toContain("/issues/999");
    expect(db.feedback[0].status).toBe("triaged");
    expect(db.audit[0].action).toBe("publish");
    expect(db.audit[0].actor).toBe("agent:mara");
  });

  test("dedup guard still holds: 409 on already-published rows", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a", github_issue_url: "https://github.com/x/1" }));

    const response = await handleAgentAPI(
      apiRequest("/api/feedback/publish", {
        method: "POST",
        body: JSON.stringify({ ids: ["a"], title: "Again", body: "Details" }),
      }),
      makeEnv(db)
    );

    expect(response.status).toBe(409);
  });
});
