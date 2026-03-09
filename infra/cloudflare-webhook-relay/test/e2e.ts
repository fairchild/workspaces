/**
 * E2E test harness for the webhook-relay Worker.
 *
 * Orchestrates: mock GitHub API → wrangler dev → test scenarios.
 * Run: bun run test:e2e
 */

import { signJWT } from "../src/github-verify";
import { writeFileSync, existsSync } from "fs";
import { resolve } from "path";

const WORKER_PORT = 8787;
const MOCK_PORT = 8788;
const WORKER_URL = `http://localhost:${WORKER_PORT}`;
const WEBHOOK_SECRET = "test-webhook-secret-e2e";
const JWT_SECRET = "test-jwt-secret-e2e";

const projectDir = resolve(import.meta.dir, "..");

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

// Kill stale processes from previous runs
async function killStaleProcesses() {
  for (const port of [WORKER_PORT, MOCK_PORT]) {
    try {
      const proc = Bun.spawn(["lsof", "-ti", `:${port}`], { stdout: "pipe", stderr: "ignore" });
      const text = await new Response(proc.stdout).text();
      const pids = text.trim().split("\n").filter(Boolean);
      for (const pid of pids) {
        try { process.kill(Number(pid), 9); } catch {}
      }
    } catch {}
  }
  if ((await Bun.spawn(["lsof", "-ti", `:${WORKER_PORT}`, "-ti", `:${MOCK_PORT}`], { stdout: "pipe", stderr: "ignore" }).exited) === 0) {
    await Bun.sleep(1000);
  }
}

await killStaleProcesses();

console.log("Starting mock GitHub API...");
const mockProc = Bun.spawn(["bun", "run", resolve(projectDir, "test/mock-github.ts")], {
  stdout: "inherit",
  stderr: "inherit",
});

console.log("Starting wrangler dev...");
const wranglerBin = resolve(projectDir, "node_modules/.bin/wrangler");
const wranglerProc = Bun.spawn(
  [wranglerBin, "dev", "--port", String(WORKER_PORT)],
  {
    cwd: projectDir,
    stdout: "inherit",
    stderr: "inherit",
  }
);

async function cleanup() {
  mockProc.kill();
  wranglerProc.kill();
  // Kill workerd grandchild processes spawned by wrangler
  try {
    const proc = Bun.spawn(["lsof", "-ti", `:${WORKER_PORT}`], { stdout: "pipe", stderr: "ignore" });
    const text = await new Response(proc.stdout).text();
    for (const pid of text.trim().split("\n").filter(Boolean)) {
      try { process.kill(Number(pid), 9); } catch {}
    }
  } catch {}
}

// Poll for worker readiness
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
  await waitForWorker();
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

      // Send webhook
      const payload = JSON.stringify({
        action: "opened",
        repository: { full_name: "test-org/repo-a" },
        pull_request: { number: 42, title: "Test PR" },
        sender: { login: "test-user" },
      });
      const signature = await hmacSign(WEBHOOK_SECRET, payload);

      const resp = await fetch(`${WORKER_URL}/webhook`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-GitHub-Event": "pull_request",
          "X-GitHub-Delivery": "test-delivery-1",
          "X-Hub-Signature-256": signature,
        },
        body: payload,
      });
      assert(resp.status === 200, `Webhook POST returned ${resp.status}`);

      const msg = await bws.nextMessage() as { type: string; event: { repo: string } };
      assert(msg.type === "event", `Expected event, got ${msg.type}`);
      assert(msg.event.repo === "test-org/repo-a", `Expected repo-a, got ${msg.event.repo}`);
    } finally {
      bws.close();
    }
  });

  // Test 6: Per-client repo filtering
  await test("Repo filtering: ghp_repo_b_only only receives repo-b events", async () => {
    const jwt = await makeJWT();
    const bws = await connectWebSocket("test-org", jwt, "ghp_repo_b_only");
    try {
      // Consume catchup
      await bws.nextMessage();

      // Send repo-a event (should be filtered out)
      const payloadA = JSON.stringify({
        action: "opened",
        repository: { full_name: "test-org/repo-a" },
        pull_request: { number: 99, title: "Filtered PR" },
        sender: { login: "test-user" },
      });
      const sigA = await hmacSign(WEBHOOK_SECRET, payloadA);
      await fetch(`${WORKER_URL}/webhook`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-GitHub-Event": "pull_request",
          "X-GitHub-Delivery": "test-delivery-2",
          "X-Hub-Signature-256": sigA,
        },
        body: payloadA,
      });

      // Send repo-b event (should be received)
      const payloadB = JSON.stringify({
        action: "closed",
        repository: { full_name: "test-org/repo-b" },
        pull_request: { number: 100, title: "Visible PR" },
        sender: { login: "test-user" },
      });
      const sigB = await hmacSign(WEBHOOK_SECRET, payloadB);
      await fetch(`${WORKER_URL}/webhook`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-GitHub-Event": "pull_request",
          "X-GitHub-Delivery": "test-delivery-3",
          "X-Hub-Signature-256": sigB,
        },
        body: payloadB,
      });

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
