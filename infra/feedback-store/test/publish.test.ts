/**
 * Unit tests for the shared publish core: dedup guard + audit trail on the
 * admin publish path. Uses a tiny in-memory D1 fake and a stubbed global fetch
 * so publish never hits GitHub. Run with `bun test`.
 */
import { afterEach, describe, expect, test } from "bun:test";
import { publishFeedbackAsIssue } from "../src/publish";
import type { Env, FeedbackRow } from "../src/types";

class FakeD1 {
  feedback: any[] = [];
  audit: any[] = [];
  prepare(sql: string) {
    return new FakeStatement(this, sql, []);
  }
  async exec() {
    return {} as unknown;
  }
}

class FakeStatement {
  constructor(private db: FakeD1, private sql: string, private args: unknown[]) {}
  bind(...args: unknown[]) {
    return new FakeStatement(this.db, this.sql, args);
  }
  async first<T>(): Promise<T | null> {
    const rows = this.db.feedback.filter((r) => r.id === this.args[0]);
    return (rows[0] ? { ...rows[0] } : null) as T | null;
  }
  async run() {
    if (this.sql.startsWith("INSERT INTO feedback_audit")) {
      const [feedback_id, at, actor, action, detail] = this.args;
      this.db.audit.push({ feedback_id, at, actor, action, detail });
    } else if (this.sql.startsWith("UPDATE feedback SET github_issue_url")) {
      const [url, id] = this.args;
      const row = this.db.feedback.find((r) => r.id === id);
      if (row) {
        row.github_issue_url = url;
        row.status = "triaged";
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
    ip_hash: null,
    status: "new",
    admin_notes: null,
    github_issue_url: null,
    attachment_prefix: null,
    has_screenshot: 0,
    has_diagnostics: 0,
    ...over,
  };
}

function makeEnv(db: FakeD1): Env {
  return {
    FEEDBACK_DB: db as unknown as D1Database,
    FEEDBACK_BUCKET: {} as unknown as R2Bucket,
    JWT_SIGNING_SECRET: "x",
    ADMIN_SESSION_SECRET: "x",
    ADMIN_ALLOWLIST: "fairchild",
    GITHUB_CLIENT_ID: "x",
    GITHUB_CLIENT_SECRET: "x",
    GITHUB_ISSUE_TOKEN: "gh-token",
  };
}

const originalFetch = globalThis.fetch;
afterEach(() => {
  globalThis.fetch = originalFetch;
});

describe("publish dedup + audit", () => {
  test("publishes once, then blocks a duplicate unless forced", async () => {
    const db = new FakeD1();
    db.feedback.push(makeRow({ id: "a" }));
    const env = makeEnv(db);
    globalThis.fetch = (async () =>
      Response.json({ html_url: "https://github.com/x/y/issues/1" })) as unknown as typeof fetch;

    const first = await publishFeedbackAsIssue(env, {
      ids: ["a"],
      title: "T",
      body: "B",
      actor: "fairchild",
    });
    expect(first.ok).toBe(true);
    expect(db.feedback[0].github_issue_url).toBe("https://github.com/x/y/issues/1");
    expect(db.feedback[0].status).toBe("triaged");
    expect(db.audit.some((a) => a.action === "publish" && a.actor === "fairchild")).toBe(true);

    const second = await publishFeedbackAsIssue(env, {
      ids: ["a"],
      title: "T",
      body: "B",
      actor: "fairchild",
    });
    expect(second.ok).toBe(false);
    if (!second.ok) {
      expect(second.status).toBe(409);
      expect(second.alreadyPublished?.[0].id).toBe("a");
    }

    const forced = await publishFeedbackAsIssue(env, {
      ids: ["a"],
      title: "T",
      body: "B",
      actor: "fairchild",
      force: true,
    });
    expect(forced.ok).toBe(true);
  });

  test("rejects unknown ids and empty input", async () => {
    const env = makeEnv(new FakeD1());
    const missing = await publishFeedbackAsIssue(env, {
      ids: ["nope"],
      title: "T",
      body: "B",
      actor: "fairchild",
    });
    expect(missing.ok).toBe(false);
    if (!missing.ok) expect(missing.status).toBe(404);

    const empty = await publishFeedbackAsIssue(env, { ids: [], title: "", body: "", actor: "fairchild" });
    expect(empty.ok).toBe(false);
    if (!empty.ok) expect(empty.status).toBe(400);
  });
});
