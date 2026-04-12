/**
 * E2E test harness for the webhook-relay Worker.
 *
 * Orchestrates: mock GitHub API → wrangler dev → test scenarios.
 * Run: bun run test:e2e
 */

import { signJWT } from "../src/github-verify";
import { writeFileSync, existsSync, rmSync } from "fs";
import { resolve } from "path";

const WORKER_PORT = 8787;
const MOCK_PORT = 8788;
const WORKER_URL = `http://localhost:${WORKER_PORT}`;
const WEBHOOK_SECRET = "test-webhook-secret-e2e";
const JWT_SECRET = "test-jwt-secret-e2e";

const projectDir = resolve(import.meta.dir, "..");
const stateDir = resolve(projectDir, ".wrangler/state");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

async function hmacSign(secret: string, payload: string): Promise<string> {
  const enc = new TextEncoder();
  const key = await crypto.subtle.importKey(
    "raw",
    enc.encode(secret),
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign"]
  );
  const sig = await crypto.subtle.sign("HMAC", key, enc.encode(payload));
  const hex = [...new Uint8Array(sig)].map((b) => b.toString(16).padStart(2, "0")).join("");
  return `sha256=${hex}`;
}

async function makeJWT(): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  return signJWT(
    { sub: "1", login: "test-user", orgs: ["test-org"], iat: now, exp: now + 3600 },
    JWT_SECRET
  );
}

/** WebSocket wrapper that buffers incoming messages for reliable consumption. */
class BufferedWS {
  readonly ws: WebSocket;
  private queue: unknown[] = [];
  private waiters: Array<(msg: unknown) => void> = [];

  constructor(ws: WebSocket) {
    this.ws = ws;
    ws.addEventListener("message", (ev) => {
      const parsed = JSON.parse(ev.data as string);
      const waiter = this.waiters.shift();
      if (waiter) { waiter(parsed); } else { this.queue.push(parsed); }
    });
  }

  nextMessage(timeoutMs = 5000): Promise<unknown> {
    const buffered = this.queue.shift();
    if (buffered) return Promise.resolve(buffered);
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error("WebSocket message timeout")), timeoutMs);
      this.waiters.push((msg) => { clearTimeout(timer); resolve(msg); });
    });
  }

  close() { this.ws.close(); }
}

function connectWebSocket(
  owner: string,
  jwt: string,
  githubToken: string
): Promise<BufferedWS> {
  return new Promise((resolve, reject) => {
    const ws = new WebSocket(`${WORKER_URL}/ws/${owner}`, {
      headers: {
        Authorization: `Bearer ${jwt}`,
        "X-GitHub-Token": githubToken,
      },
    } as any);
    const bws = new BufferedWS(ws);
    const timer = setTimeout(() => reject(new Error("WebSocket connect timeout")), 5000);
    ws.addEventListener("open", () => { clearTimeout(timer); resolve(bws); });
    ws.addEventListener("error", (e) => { clearTimeout(timer); reject(e); });
  });
}

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

interface TestResult { name: string; passed: boolean; error?: string }
const results: TestResult[] = [];

async function test(name: string, fn: () => Promise<void>) {
  try {
    await fn();
    results.push({ name, passed: true });
    console.log(`  ✓ ${name}`);
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    results.push({ name, passed: false, error: msg });
    console.log(`  ✗ ${name}: ${msg}`);
  }
}

function assert(condition: boolean, msg: string) {
  if (!condition) throw new Error(msg);
}

async function postWebhook(
  payload: string,
  deliveryId: string,
  eventType = "pull_request"
): Promise<Response> {
  const signature = await hmacSign(WEBHOOK_SECRET, payload);
  return fetch(`${WORKER_URL}/webhook`, {
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "X-GitHub-Event": eventType,
      "X-GitHub-Delivery": deliveryId,
      "X-Hub-Signature-256": signature,
    },
    body: payload,
  });
}

function payloadForPR(
  number: number,
  title: string,
  action: string,
  repo = "test-org/repo-a",
  sender = "test-user"
): string {
  return JSON.stringify({
    action,
    repository: { full_name: repo },
    pull_request: { number, title },
    sender: { login: sender },
  });
}

async function expectNoExtraWebSocketMessage(
  bws: BufferedWS,
  timeoutMs = 750
): Promise<void> {
  try {
    await bws.nextMessage(timeoutMs);
    throw new Error("Unexpected extra WebSocket message");
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    if (message !== "WebSocket message timeout") {
      throw err;
    }
  }
}

async function readCatchupEvents(
  owner: string,
  jwt: string,
  githubToken: string
): Promise<Array<{ summary: string; repo: string }>> {
  const bws = await connectWebSocket(owner, jwt, githubToken);
  try {
    const msg = await bws.nextMessage() as {
      type: string;
      events: Array<{ summary: string; repo: string }>;
    };
    assert(msg.type === "catchup", `Expected catchup, got ${msg.type}`);
    return msg.events;
  } finally {
    bws.close();
  }
}

async function durableObjectSQLitePath(): Promise<string> {
  const proc = Bun.spawn(
    ["find", resolve(stateDir, "v3/do"), "-name", "*.sqlite"],
    { stdout: "pipe", stderr: "ignore" }
  );
  const output = (await new Response(proc.stdout).text()).trim();
  const paths = output.split("\n").filter(Boolean);
  assert(paths.length === 1, `Expected 1 Durable Object sqlite file, found ${paths.length}`);
  return paths[0];
}

async function runSQLite(sqlitePath: string, sql: string): Promise<string> {
  const proc = Bun.spawn(["sqlite3", sqlitePath, sql], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  if (exitCode !== 0) {
    throw new Error(`sqlite3 failed: ${stderr || stdout}`.trim());
  }
  return stdout;
}

// ---------------------------------------------------------------------------
// Lifecycle
// ---------------------------------------------------------------------------

// Ensure .dev.vars exists
const devVarsPath = resolve(projectDir, ".dev.vars");
if (!existsSync(devVarsPath)) {
  writeFileSync(
    devVarsPath,
    `GITHUB_WEBHOOK_SECRET=${WEBHOOK_SECRET}\nJWT_SIGNING_SECRET=${JWT_SECRET}\nGITHUB_API_BASE=http://127.0.0.1:${MOCK_PORT}\n`
  );
}

let mockProc: ReturnType<typeof Bun.spawn> | null = null;
let wranglerProc: ReturnType<typeof Bun.spawn> | null = null;

async function killProcessesOnPort(port: number): Promise<void> {
  try {
    const proc = Bun.spawn(["lsof", "-ti", `:${port}`], { stdout: "pipe", stderr: "ignore" });
    const text = await new Response(proc.stdout).text();
    const pids = text.trim().split("\n").filter(Boolean);
    for (const pid of pids) {
      try { process.kill(Number(pid), 9); } catch {}
    }
  } catch {}
}

async function portHasListener(port: number): Promise<boolean> {
  const proc = Bun.spawn(["lsof", "-ti", `:${port}`], { stdout: "pipe", stderr: "ignore" });
  const text = await new Response(proc.stdout).text();
  return text.trim().length > 0;
}

async function waitForPortToClear(port: number, maxWaitMs = 5000): Promise<void> {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    if (!(await portHasListener(port))) {
      return;
    }
    await Bun.sleep(100);
  }
  throw new Error(`Port ${port} did not clear`);
}

async function stopWorker(): Promise<void> {
  if (wranglerProc) {
    wranglerProc.kill();
    await wranglerProc.exited;
    wranglerProc = null;
  }
  await killProcessesOnPort(WORKER_PORT);
  await waitForPortToClear(WORKER_PORT);
}

async function stopMock(): Promise<void> {
  if (mockProc) {
    mockProc.kill();
    await mockProc.exited;
    mockProc = null;
  }
  await killProcessesOnPort(MOCK_PORT);
  await waitForPortToClear(MOCK_PORT);
}

async function startMock(): Promise<void> {
  if (mockProc) return;
  console.log("Starting mock GitHub API...");
  mockProc = Bun.spawn(["bun", "run", resolve(projectDir, "test/mock-github.ts")], {
    stdout: "inherit",
    stderr: "inherit",
  });
  const start = Date.now();
  while (Date.now() - start < 5000) {
    if (await portHasListener(MOCK_PORT)) {
      return;
    }
    await Bun.sleep(100);
  }
  throw new Error("Mock GitHub API did not become ready");
}

async function startWorker(): Promise<void> {
  if (wranglerProc) return;
  console.log("Starting wrangler dev...");
  const wranglerBin = resolve(projectDir, "node_modules/.bin/wrangler");
  wranglerProc = Bun.spawn(
    [wranglerBin, "dev", "--port", String(WORKER_PORT)],
    {
      cwd: projectDir,
      stdout: "inherit",
      stderr: "inherit",
    }
  );
  await waitForWorker();
}

async function restartWorker(): Promise<void> {
  await stopWorker();
  await startWorker();
}

async function cleanup() {
  await stopWorker();
  await stopMock();
}

async function waitForWorker(maxWaitMs = 30000) {
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    try {
      const resp = await fetch(`${WORKER_URL}/health`);
      if (resp.ok) return;
    } catch {}
    await Bun.sleep(500);
  }
  throw new Error("Worker did not become ready");
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

try {
  await stopWorker();
  await stopMock();
  rmSync(stateDir, { recursive: true, force: true });

  await startMock();
  await startWorker();
  console.log("\nRunning e2e tests...\n");

  // Test 1: Health check
  await test("GET /health returns 200", async () => {
    const resp = await fetch(`${WORKER_URL}/health`);
    assert(resp.status === 200, `Expected 200, got ${resp.status}`);
  });

  // Test 2: Auth session with valid token
  await test("POST /auth/session returns JWT", async () => {
    const resp = await fetch(`${WORKER_URL}/auth/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ github_token: "ghp_test_token" }),
    });
    assert(resp.status === 200, `Expected 200, got ${resp.status}`);
    const body = await resp.json() as { jwt: string; login: string; expires_at: string };
    assert(!!body.jwt, "Missing jwt in response");
    assert(body.login === "test-user", `Expected login test-user, got ${body.login}`);
  });

  // Test 3: Auth session with no-installation token
  await test("POST /auth/session rejects ghp_no_install", async () => {
    const resp = await fetch(`${WORKER_URL}/auth/session`, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ github_token: "ghp_no_install" }),
    });
    assert(resp.status === 403, `Expected 403, got ${resp.status}`);
  });

  // Test 4: WebSocket connects and receives catchup
  await test("WebSocket receives catchup message", async () => {
    const jwt = await makeJWT();
    const bws = await connectWebSocket("test-org", jwt, "ghp_test_token");
    try {
      const msg = await bws.nextMessage() as { type: string };
      assert(msg.type === "catchup", `Expected catchup, got ${msg.type}`);
    } finally {
      bws.close();
    }
  });

  // Test 5: Webhook → WebSocket broadcast
  await test("Webhook event broadcasts to WebSocket", async () => {
    const jwt = await makeJWT();
    const bws = await connectWebSocket("test-org", jwt, "ghp_test_token");
    try {
      // Consume catchup
      await bws.nextMessage();

      const payload = payloadForPR(42, "Test PR", "opened");
      const resp = await postWebhook(payload, "test-delivery-1");
      assert(resp.status === 200, `Webhook POST returned ${resp.status}`);

      const msg = await bws.nextMessage() as { type: string; event: { repo: string } };
      assert(msg.type === "event", `Expected event, got ${msg.type}`);
      assert(msg.event.repo === "test-org/repo-a", `Expected repo-a, got ${msg.event.repo}`);
    } finally {
      bws.close();
    }
  });

  // Test 6: Duplicate webhook delivery is ignored
  await test("Duplicate webhook payload only appears once", async () => {
    const jwt = await makeJWT();
    const payload = payloadForPR(4242, "Duplicate PR", "opened");

    const liveWS = await connectWebSocket("test-org", jwt, "ghp_test_token");
    try {
      await liveWS.nextMessage();

      for (const deliveryId of ["test-delivery-duplicate-1", "test-delivery-duplicate-2"]) {
        const resp = await postWebhook(payload, deliveryId);
        assert(resp.status === 200, `Webhook POST returned ${resp.status}`);
      }

      const msg = await liveWS.nextMessage() as { type: string; event: { summary: string } };
      assert(msg.type === "event", `Expected event, got ${msg.type}`);
      assert(msg.event.summary.includes("Duplicate PR"), "Expected live duplicate test event");
      await expectNoExtraWebSocketMessage(liveWS);
    } finally {
      liveWS.close();
    }

    const events = await readCatchupEvents("test-org", jwt, "ghp_test_token");
    const duplicateEntries = events.filter((event) => event.summary.includes("Duplicate PR"));
    assert(duplicateEntries.length === 1, `Expected 1 duplicate-test event in catchup, got ${duplicateEntries.length}`);
  });

  // Test 7: Equivalent payloads with different key order are deduped
  await test("Semantically equivalent payloads only appear once", async () => {
    const jwt = await makeJWT();
    const payloadA = payloadForPR(4343, "Key Order PR", "opened");
    const payloadB = JSON.stringify({
      sender: { login: "test-user" },
      pull_request: { title: "Key Order PR", number: 4343 },
      repository: { full_name: "test-org/repo-a" },
      action: "opened",
    });

    const liveWS = await connectWebSocket("test-org", jwt, "ghp_test_token");
    try {
      await liveWS.nextMessage();

      const respA = await postWebhook(payloadA, "key-order-delivery-1");
      assert(respA.status === 200, `Webhook POST returned ${respA.status}`);
      const respB = await postWebhook(payloadB, "key-order-delivery-2");
      assert(respB.status === 200, `Webhook POST returned ${respB.status}`);

      const msg = await liveWS.nextMessage() as { type: string; event: { summary: string } };
      assert(msg.type === "event", `Expected event, got ${msg.type}`);
      assert(msg.event.summary.includes("Key Order PR"), "Expected key-order test event");
      await expectNoExtraWebSocketMessage(liveWS);
    } finally {
      liveWS.close();
    }

    const events = await readCatchupEvents("test-org", jwt, "ghp_test_token");
    const matching = events.filter((event) => event.summary.includes("Key Order PR"));
    assert(matching.length === 1, `Expected 1 key-order event in catchup, got ${matching.length}`);
  });

  // Test 8: Distinct lifecycle events for the same PR are preserved
  await test("Distinct events for the same PR are not over-deduped", async () => {
    const jwt = await makeJWT();
    const openedPayload = payloadForPR(5151, "Lifecycle PR", "opened");
    const closedPayload = payloadForPR(5151, "Lifecycle PR", "closed");

    const liveWS = await connectWebSocket("test-org", jwt, "ghp_test_token");
    try {
      await liveWS.nextMessage();

      const openedResp = await postWebhook(openedPayload, "lifecycle-delivery-1");
      assert(openedResp.status === 200, `Webhook POST returned ${openedResp.status}`);
      const closedResp = await postWebhook(closedPayload, "lifecycle-delivery-2");
      assert(closedResp.status === 200, `Webhook POST returned ${closedResp.status}`);

      const first = await liveWS.nextMessage() as { type: string; event: { summary: string } };
      const second = await liveWS.nextMessage() as { type: string; event: { summary: string } };
      assert(first.type === "event", `Expected first event, got ${first.type}`);
      assert(second.type === "event", `Expected second event, got ${second.type}`);
      assert(first.event.summary.includes("Lifecycle PR"), "Expected lifecycle opened event");
      assert(second.event.summary.includes("Lifecycle PR"), "Expected lifecycle closed event");
      assert(first.event.summary !== second.event.summary, "Expected distinct lifecycle summaries");
    } finally {
      liveWS.close();
    }

    const events = await readCatchupEvents("test-org", jwt, "ghp_test_token");
    const matching = events.filter((event) => event.summary.includes("Lifecycle PR"));
    assert(matching.length === 2, `Expected 2 lifecycle events in catchup, got ${matching.length}`);
  });

  // Test 9: Duplicate suppression survives worker restart
  await test("Duplicate suppression survives worker restart", async () => {
    const jwt = await makeJWT();
    const payload = payloadForPR(6262, "Restart Stable PR", "opened");

    const firstResp = await postWebhook(payload, "restart-stable-delivery-1");
    assert(firstResp.status === 200, `Webhook POST returned ${firstResp.status}`);

    await restartWorker();

    const afterRestart = await readCatchupEvents("test-org", jwt, "ghp_test_token");
    const initialMatches = afterRestart.filter((event) => event.summary.includes("Restart Stable PR"));
    assert(initialMatches.length === 1, `Expected 1 restarted event in catchup, got ${initialMatches.length}`);

    const liveWS = await connectWebSocket("test-org", jwt, "ghp_test_token");
    try {
      await liveWS.nextMessage();

      const duplicateResp = await postWebhook(payload, "restart-stable-delivery-2");
      assert(duplicateResp.status === 200, `Webhook POST returned ${duplicateResp.status}`);
      await expectNoExtraWebSocketMessage(liveWS);
    } finally {
      liveWS.close();
    }

    const finalEvents = await readCatchupEvents("test-org", jwt, "ghp_test_token");
    const finalMatches = finalEvents.filter((event) => event.summary.includes("Restart Stable PR"));
    assert(finalMatches.length === 1, `Expected 1 restarted event after duplicate resend, got ${finalMatches.length}`);
  });

  // Test 10: Startup cleanup prunes legacy duplicate rows
  await test("Startup cleanup collapses legacy duplicate rows before catchup", async () => {
    const jwt = await makeJWT();
    const payload = payloadForPR(7373, "Legacy Cleanup PR", "opened");
    const seedResp = await postWebhook(payload, "legacy-cleanup-delivery-1");
    assert(seedResp.status === 200, `Webhook POST returned ${seedResp.status}`);

    await stopWorker();

    const sqlitePath = await durableObjectSQLitePath();
    await runSQLite(
      sqlitePath,
      `
        DROP INDEX IF EXISTS idx_events_idempotency_key;
        UPDATE events
        SET idempotency_key = ''
        WHERE summary LIKE '%Legacy Cleanup PR%';
        INSERT INTO events (
          id, type, action, summary, repo, payload, idempotency_key, delivery_id, sender, clients_sent, created_at
        )
        SELECT
          lower(hex(randomblob(16))),
          type,
          action,
          summary,
          repo,
          payload,
          '',
          'legacy-cleanup-duplicate',
          sender,
          clients_sent,
          created_at - 1
        FROM events
        WHERE summary LIKE '%Legacy Cleanup PR%'
        LIMIT 1;
      `
    );

    await startWorker();

    const events = await readCatchupEvents("test-org", jwt, "ghp_test_token");
    const matching = events.filter((event) => event.summary.includes("Legacy Cleanup PR"));
    assert(matching.length === 1, `Expected 1 legacy-cleanup event in catchup, got ${matching.length}`);
  });

  // Test 11: Per-client repo filtering
  await test("Repo filtering: ghp_repo_b_only only receives repo-b events", async () => {
    const jwt = await makeJWT();
    const bws = await connectWebSocket("test-org", jwt, "ghp_repo_b_only");
    try {
      // Consume catchup
      await bws.nextMessage();

      // Send repo-a event (should be filtered out)
      const payloadA = payloadForPR(99, "Filtered PR", "opened");
      const respA = await postWebhook(payloadA, "test-delivery-2");
      assert(respA.status === 200, `Webhook POST returned ${respA.status}`);

      // Send repo-b event (should be received)
      const payloadB = payloadForPR(100, "Visible PR", "closed", "test-org/repo-b");
      const respB = await postWebhook(payloadB, "test-delivery-3");
      assert(respB.status === 200, `Webhook POST returned ${respB.status}`);

      const msg = await bws.nextMessage() as { type: string; event: { repo: string } };
      assert(msg.type === "event", `Expected event, got ${msg.type}`);
      assert(msg.event.repo === "test-org/repo-b", `Expected repo-b, got ${msg.event.repo}`);
    } finally {
      bws.close();
    }
  });

  // Report
  console.log("\n--- Results ---");
  const passed = results.filter((r) => r.passed).length;
  const failed = results.filter((r) => !r.passed).length;
  console.log(`${passed} passed, ${failed} failed out of ${results.length} tests`);

  await cleanup();

  if (failed > 0) {
    process.exit(1);
  }
} catch (err) {
  await cleanup();
  throw err;
}
