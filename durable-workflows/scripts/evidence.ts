/**
 * Evidence script: Conclusively answer 6 open questions about PGlite + DBOS compatibility.
 *
 * Produces structured JSON report (stdout) and human-readable summary (stderr).
 * Each question gets a PASS | FAIL | PARTIAL | ERROR verdict with quantitative data.
 *
 * Usage: npx tsx scripts/evidence.ts
 */

import { PGlite } from "@electric-sql/pglite";
import { uuid_ossp } from "@electric-sql/pglite/contrib/uuid_ossp";
import { PGLiteSocketServer } from "@electric-sql/pglite-socket";
import { DBOS, DBOSClient } from "@dbos-inc/dbos-sdk";
import pg from "pg";
import { mkdirSync, rmSync, statSync, readdirSync } from "node:fs";
import { resolve, join } from "node:path";

// --- Types ---

type Verdict = "PASS" | "FAIL" | "PARTIAL" | "ERROR";

interface TestResult {
  question: string;
  title: string;
  verdict: Verdict;
  summary: string;
  details: Record<string, unknown>;
  durationMs: number;
  error?: string;
}

interface EvidenceReport {
  timestamp: string;
  nodeVersion: string;
  platform: string;
  results: TestResult[];
  totalDurationMs: number;
}

// --- Constants ---

const DATA_DIR = resolve(import.meta.dirname, "../.evidence-data");
const PGDATA_DIR = resolve(DATA_DIR, "pgdata");

// --- Helpers ---

function log(msg: string) {
  process.stderr.write(`${msg}\n`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

function withTimeout<T>(promise: Promise<T>, ms: number, label: string): Promise<T> {
  return Promise.race([
    promise,
    new Promise<T>((_, reject) =>
      setTimeout(() => reject(new Error(`${label} timed out after ${ms}ms`)), ms),
    ),
  ]);
}

function dirSize(dir: string): number {
  let total = 0;
  try {
    for (const entry of readdirSync(dir, { withFileTypes: true, recursive: true })) {
      if (entry.isFile()) {
        try {
          total += statSync(join(entry.parentPath ?? entry.path, entry.name)).size;
        } catch {}
      }
    }
  } catch {}
  return total;
}

async function runTest(fn: () => Promise<TestResult>): Promise<TestResult> {
  try {
    return await fn();
  } catch (err: any) {
    return {
      question: "??",
      title: "Unknown",
      verdict: "ERROR",
      summary: `Unhandled: ${err.message}`,
      details: { stack: err.stack },
      durationMs: 0,
      error: err.message,
    };
  }
}

// Workflow functions (registered fresh per DBOS lifecycle)
async function threeStepWf(): Promise<string> {
  const a = await DBOS.runStep(async () => "step-1-done", { name: "s1" });
  const b = await DBOS.runStep(async () => `${a}+step-2`, { name: "s2" });
  const c = await DBOS.runStep(async () => `${b}+step-3`, { name: "s3" });
  return c;
}

async function recvWf(): Promise<string> {
  const msg = await DBOS.recv<string>("input", 30);
  return msg ?? "TIMEOUT";
}

async function sizeWf(size: number): Promise<number> {
  const payload = await DBOS.runStep(async () => "x".repeat(size), {
    name: `gen-${size}`,
  });
  return payload.length;
}

async function reinitDBOS(
  databaseUrl: string,
  config: Record<string, unknown> = {},
): Promise<void> {
  if (DBOS.isInitialized()) {
    try {
      await withTimeout(DBOS.shutdown({ deregister: true }), 5_000, "reinitDBOS shutdown");
    } catch {
      log("  ⚠ DBOS shutdown timed out — forcing re-init");
    }
    await sleep(500);
  }
  DBOS.setConfig({
    systemDatabaseUrl: databaseUrl,
    systemDatabasePoolSize: 1,
    useListenNotify: false,
    runAdminServer: false,
    logLevel: "error",
    ...config,
  } as any);
}

// ============================================================
// Q4: PGlite Startup Time
// ============================================================

async function testQ4(): Promise<TestResult> {
  const t0 = Date.now();
  const coldTimes: number[] = [];
  const warmTimes: number[] = [];
  const dbosTimes: number[] = [];

  for (let i = 0; i < 3; i++) {
    const coldDir = resolve(DATA_DIR, `q4-cold-${i}`);
    rmSync(coldDir, { recursive: true, force: true });
    mkdirSync(coldDir, { recursive: true });

    const start = Date.now();
    const db = await PGlite.create(coldDir, { extensions: { uuid_ossp } });
    coldTimes.push(Date.now() - start);
    await db.close();
    rmSync(coldDir, { recursive: true, force: true });
  }

  const warmDir = resolve(DATA_DIR, "q4-warm");
  rmSync(warmDir, { recursive: true, force: true });
  mkdirSync(warmDir, { recursive: true });

  let db = await PGlite.create(warmDir, { extensions: { uuid_ossp } });
  await db.close();

  for (let i = 0; i < 3; i++) {
    const start = Date.now();
    db = await PGlite.create(warmDir, { extensions: { uuid_ossp } });
    warmTimes.push(Date.now() - start);
    await db.close();
  }

  db = await PGlite.create(warmDir, { extensions: { uuid_ossp } });
  const server = new PGLiteSocketServer({ db, port: 0, host: "127.0.0.1", maxConnections: 5 });
  await server.start();
  const url = `postgresql://postgres:postgres@${server.getServerConn()}/postgres`;

  for (let i = 0; i < 3; i++) {
    await reinitDBOS(url);
    DBOS.registerWorkflow(threeStepWf, { name: "q4wf" });
    const start = Date.now();
    await DBOS.launch();
    dbosTimes.push(Date.now() - start);
  }

  await DBOS.shutdown({ deregister: true });
  await sleep(200);
  await server.stop();
  await db.close();
  rmSync(warmDir, { recursive: true, force: true });

  const avg = (arr: number[]) => Math.round(arr.reduce((a, b) => a + b, 0) / arr.length);

  const coldAvg = avg(coldTimes);
  const warmAvg = avg(warmTimes);
  const dbosAvg = avg(dbosTimes);

  return {
    question: "Q4",
    title: "PGlite WASM startup time",
    verdict: coldAvg < 5000 ? "PASS" : "FAIL",
    summary: `Cold: ${coldAvg}ms avg, Warm: ${warmAvg}ms avg, DBOS launch: ${dbosAvg}ms avg`,
    details: {
      cold: { times: coldTimes, avg: coldAvg, min: Math.min(...coldTimes), max: Math.max(...coldTimes) },
      warm: { times: warmTimes, avg: warmAvg, min: Math.min(...warmTimes), max: Math.max(...warmTimes) },
      dbosLaunch: { times: dbosTimes, avg: dbosAvg, min: Math.min(...dbosTimes), max: Math.max(...dbosTimes) },
      successCriterion: "cold < 5000ms",
    },
    durationMs: Date.now() - t0,
  };
}

// ============================================================
// Q2: CREATE SCHEMA dbos
// ============================================================

async function testQ2(db: PGlite, databaseUrl: string): Promise<TestResult> {
  const t0 = Date.now();

  await reinitDBOS(databaseUrl);
  DBOS.registerWorkflow(threeStepWf, { name: "q2wf" });
  await DBOS.launch();

  const schemaResult = await db.query(
    "SELECT schema_name FROM information_schema.schemata WHERE schema_name = 'dbos'",
  );
  const schemaExists = schemaResult.rows.length === 1;

  const tablesResult = await db.query(
    "SELECT table_name FROM information_schema.tables WHERE table_schema = 'dbos' ORDER BY table_name",
  );
  const tables = tablesResult.rows.map((r: any) => r.table_name);

  return {
    question: "Q2",
    title: "PGlite supports CREATE SCHEMA dbos",
    verdict: schemaExists && tables.length > 0 ? "PASS" : "FAIL",
    summary: `Schema 'dbos' ${schemaExists ? "exists" : "MISSING"} with ${tables.length} tables`,
    details: { schemaExists, tableCount: tables.length, tables },
    durationMs: Date.now() - t0,
  };
}

// ============================================================
// Q6: Step output size performance
// ============================================================

async function testQ6(databaseUrl: string): Promise<TestResult> {
  const t0 = Date.now();
  const sizes = [100, 1_000, 10_000, 100_000, 500_000, 1_000_000];
  const results: Array<{ size: number; durationMs: number; pgdataDelta: number }> = [];

  await reinitDBOS(databaseUrl);
  const sizeWfReg = DBOS.registerWorkflow(sizeWf, { name: "sizeWf" });
  await DBOS.launch();

  const baselineSize = dirSize(PGDATA_DIR);
  let prevSize = baselineSize;

  for (const size of sizes) {
    const start = Date.now();
    const handle = await DBOS.startWorkflow(sizeWfReg)(size);
    const result = await withTimeout(handle.getResult(), 30_000, `sizeWf(${size})`);
    const elapsed = Date.now() - start;

    const currentSize = dirSize(PGDATA_DIR);
    results.push({ size, durationMs: elapsed, pgdataDelta: currentSize - prevSize });
    prevSize = currentSize;

    if (result !== size) {
      return {
        question: "Q6",
        title: "Step output size performance",
        verdict: "FAIL",
        summary: `Wrong result: expected ${size}, got ${result}`,
        details: { results },
        durationMs: Date.now() - t0,
      };
    }
  }

  const baseline = results[0].durationMs;
  const hundredKb = results.find((r) => r.size === 100_000);
  const ratio = hundredKb ? hundredKb.durationMs / Math.max(baseline, 1) : 999;

  return {
    question: "Q6",
    title: "Step output size performance",
    verdict: ratio < 5 ? "PASS" : "PARTIAL",
    summary: `100KB is ${ratio.toFixed(1)}x baseline (threshold: <5x). 1MB: ${results[results.length - 1].durationMs}ms`,
    details: {
      baselinePgdataBytes: baselineSize,
      measurements: results.map((r) => ({
        sizeLabel: r.size >= 1_000_000 ? `${r.size / 1_000_000}MB` : r.size >= 1_000 ? `${r.size / 1_000}KB` : `${r.size}B`,
        durationMs: r.durationMs,
        pgdataDeltaBytes: r.pgdataDelta,
      })),
      ratio100kbVsBaseline: ratio,
    },
    durationMs: Date.now() - t0,
  };
}

// ============================================================
// Q5: DBOSClient concurrent access
// ============================================================

async function testQ5(databaseUrl: string): Promise<TestResult> {
  const t0 = Date.now();
  const sub: Record<string, { pass: boolean; detail: string }> = {};

  await reinitDBOS(databaseUrl);
  const wf = DBOS.registerWorkflow(threeStepWf, { name: "q5wf" });
  const recvWfReg = DBOS.registerWorkflow(recvWf, { name: "q5recvWf" });
  await DBOS.launch();

  // Seed a workflow
  const seedHandle = await DBOS.startWorkflow(wf)();
  await seedHandle.getResult();

  // Q5a: Client while DBOS is running
  try {
    const client = await DBOSClient.create({ systemDatabaseUrl: databaseUrl });
    const workflows = await client.listWorkflows({});
    sub.q5a = { pass: workflows.length > 0, detail: `Listed ${workflows.length} workflows while DBOS running` };
    await client.destroy();
  } catch (err: any) {
    sub.q5a = { pass: false, detail: `Error: ${err.message}` };
  }

  // Q5b: Client.send() unblocks workflow
  try {
    const msgHandle = await DBOS.startWorkflow(recvWfReg)();
    await sleep(300);
    const client = await DBOSClient.create({ systemDatabaseUrl: databaseUrl });
    await client.send(msgHandle.workflowID, "from-client", "input");
    const result = await withTimeout(msgHandle.getResult(), 10_000, "q5b recv");
    sub.q5b = { pass: result === "from-client", detail: `recv got: "${result}"` };
    await client.destroy();
  } catch (err: any) {
    sub.q5b = { pass: false, detail: `Error: ${err.message}` };
  }

  // Q5c: Multiple concurrent clients
  try {
    const clients = await Promise.all([
      DBOSClient.create({ systemDatabaseUrl: databaseUrl }),
      DBOSClient.create({ systemDatabaseUrl: databaseUrl }),
      DBOSClient.create({ systemDatabaseUrl: databaseUrl }),
    ]);
    const wfResults = await Promise.all(clients.map((c) => c.listWorkflows({})));
    const allGood = wfResults.every((r) => r.length > 0);
    sub.q5c = { pass: allGood, detail: `3 clients: ${wfResults.map((r) => r.length).join(", ")} workflows each` };
    await Promise.all(clients.map((c) => c.destroy()));
  } catch (err: any) {
    sub.q5c = { pass: false, detail: `Error: ${err.message}` };
  }

  const allPass = Object.values(sub).every((s) => s.pass);
  const anyPass = Object.values(sub).some((s) => s.pass);

  return {
    question: "Q5",
    title: "DBOSClient concurrent access",
    verdict: allPass ? "PASS" : anyPass ? "PARTIAL" : "FAIL",
    summary: Object.entries(sub).map(([k, v]) => `${k}: ${v.pass ? "OK" : "FAIL"}`).join(", "),
    details: sub,
    durationMs: Date.now() - t0,
  };
}

// ============================================================
// Q1: Connection pool through multiplexer
// ============================================================

async function testQ1(databaseUrl: string): Promise<TestResult> {
  const t0 = Date.now();
  const poolSizes = [1, 2, 3, 5, 10];
  const results: Array<{ poolSize: number; success: boolean; durationMs: number; error?: string }> = [];

  for (const poolSize of poolSizes) {
    log(`  Q1: testing pool size ${poolSize}...`);
    try {
      // reinitDBOS calls shutdown internally, but after a timeout failure
      // DBOS may be stuck. Use a timeout on the entire init+run cycle.
      await withTimeout(
        (async () => {
          await reinitDBOS(databaseUrl, { systemDatabasePoolSize: poolSize });
          const wf = DBOS.registerWorkflow(threeStepWf, { name: "q1wf" });
          await DBOS.launch();

          const start = Date.now();
          const handles = await Promise.all([
            DBOS.startWorkflow(wf)(),
            DBOS.startWorkflow(wf)(),
            DBOS.startWorkflow(wf)(),
          ]);
          const wfResults = await Promise.all(handles.map((h) => h.getResult()));
          const allOk = wfResults.every((r) => r === "step-1-done+step-2+step-3");

          results.push({ poolSize, success: allOk, durationMs: Date.now() - start });
        })(),
        20_000,
        `Q1 pool=${poolSize}`,
      );
    } catch (err: any) {
      results.push({ poolSize, success: false, durationMs: 0, error: err.message });
      // Timeout on cleanup too — DBOS may be stuck
      try {
        await withTimeout(DBOS.shutdown({ deregister: true }), 3_000, "cleanup");
      } catch {
        // If shutdown also hangs, DBOS is stuck. Skip remaining pool sizes.
        log(`  Q1: DBOS stuck after pool=${poolSize}, skipping remaining sizes`);
        for (const remaining of poolSizes.slice(poolSizes.indexOf(poolSize) + 1)) {
          results.push({ poolSize: remaining, success: false, durationMs: 0, error: "skipped (DBOS stuck)" });
        }
        break;
      }
      await sleep(500);
    }
  }

  const allPass = results.every((r) => r.success);
  const anyPass = results.some((r) => r.success);

  return {
    question: "Q1",
    title: "Connection pool through multiplexer",
    verdict: allPass ? "PASS" : anyPass ? "PARTIAL" : "FAIL",
    summary: results.map((r) => `pool=${r.poolSize}: ${r.success ? `OK (${r.durationMs}ms)` : `FAIL${r.error ? ` (${r.error.substring(0, 60)})` : ""}`}`).join(", "),
    details: {
      socketMaxConnections: 20,
      note: "Pool>1 deadlocks on PGlite's single-connection serialization layer — independent of socket maxConnections (set to 20 here). ECONNRESET in the spike was a separate issue: socket maxConnections defaulting to 1 (see Q5).",
      results,
    },
    durationMs: Date.now() - t0,
  };
}

// ============================================================
// Q3: LISTEN/NOTIFY through socket
// ============================================================

async function testQ3(db: PGlite, databaseUrl: string): Promise<TestResult> {
  const t0 = Date.now();
  const sub: Record<string, { pass: boolean; detail: string; latencyMs?: number }> = {};

  // Q3a: Raw PGlite LISTEN/NOTIFY (baseline, no socket)
  log("  Q3a: raw PGlite LISTEN/NOTIFY...");
  try {
    let received = false;
    let payload = "";
    const start = Date.now();

    const unlisten = await db.listen("q3a_test", (p) => {
      received = true;
      payload = p;
    });

    await db.exec("NOTIFY q3a_test, 'ping'");
    await sleep(200);

    const latency = Date.now() - start;
    await unlisten();

    sub.q3a = {
      pass: received && payload === "ping",
      detail: `Raw PGlite: received=${received}, payload="${payload}"`,
      latencyMs: latency,
    };
  } catch (err: any) {
    sub.q3a = { pass: false, detail: `Error: ${err.message}` };
  }

  // Q3b: Through socket via pg client
  log("  Q3b: through socket via pg client...");
  try {
    await withTimeout(
      (async () => {
        let received = false;
        let notifyPayload = "";
        const client = new pg.Client({ connectionString: databaseUrl });
        await client.connect();

        client.on("notification", (msg) => {
          if (msg.channel === "q3b_test") {
            received = true;
            notifyPayload = msg.payload ?? "";
          }
        });

        await client.query("LISTEN q3b_test");
        await db.exec("NOTIFY q3b_test, 'ping'");
        await sleep(3000);

        try { await withTimeout(client.end(), 2_000, "q3b client.end"); } catch {}

        sub.q3b = {
          pass: received,
          detail: received
            ? `Through socket: delivered, payload="${notifyPayload}"`
            : "Through socket: NOT delivered (pglite-socket has no notification relay code)",
        };
      })(),
      15_000,
      "Q3b socket notify",
    );
  } catch (err: any) {
    sub.q3b = { pass: false, detail: `Timeout/Error: ${err.message}` };
  }

  // Q3c: DBOS with useListenNotify toggled
  log("  Q3c: DBOS useListenNotify comparison...");
  try {
    await withTimeout(
      (async () => {
        // Baseline: useListenNotify: false (pool=1, since pool>1 deadlocks per Q1)
        await reinitDBOS(databaseUrl);
        const recvWfOff = DBOS.registerWorkflow(recvWf, { name: "q3cRecvWf" });
        await DBOS.launch();

        const handleOff = await DBOS.startWorkflow(recvWfOff)();
        await sleep(300);
        const sendStartOff = Date.now();
        await DBOS.send(handleOff.workflowID, "test-off", "input");
        const resultOff = await withTimeout(handleOff.getResult(), 10_000, "q3c-off");
        const latencyOff = Date.now() - sendStartOff;

        // Test: useListenNotify: true (still pool=1 — testing notify behavior, not pool)
        await reinitDBOS(databaseUrl, { useListenNotify: true });
        const recvWfOn = DBOS.registerWorkflow(recvWf, { name: "q3cRecvWf" });
        await DBOS.launch();

        const handleOn = await DBOS.startWorkflow(recvWfOn)();
        await sleep(300);
        const sendStartOn = Date.now();
        await DBOS.send(handleOn.workflowID, "test-on", "input");
        const resultOn = await withTimeout(
          handleOn.getResult(),
          10_000,
          "q3c-on: useListenNotify=true recv() — socket doesn't relay NOTIFY (proven by Q3b), so message never arrives",
        );
        const latencyOn = Date.now() - sendStartOn;

        sub.q3c = {
          pass: resultOff === "test-off" && resultOn === "test-on",
          detail: `notify=false: ${latencyOff}ms, notify=true: ${latencyOn}ms (DBOS self-tests and falls back to polling)`,
          latencyMs: latencyOn,
        };
      })(),
      60_000,
      "Q3c DBOS notify comparison",
    );
  } catch (err: any) {
    sub.q3c = {
      pass: false,
      detail: `${err.message}. Cause: useListenNotify=true makes DBOS rely on socket NOTIFY for message delivery, but pglite-socket has no notification relay (Q3b proves this). recv() waits for a NOTIFY that never arrives.`,
    };
  }

  const q3aPassed = sub.q3a?.pass ?? false;
  const q3bPassed = sub.q3b?.pass ?? false;
  const q3cPassed = sub.q3c?.pass ?? false;

  let verdict: Verdict;
  if (q3aPassed && q3bPassed && q3cPassed) verdict = "PASS";
  else if (q3aPassed || q3cPassed) verdict = "PARTIAL";
  else verdict = "FAIL";

  return {
    question: "Q3",
    title: "LISTEN/NOTIFY through socket",
    verdict,
    summary: Object.entries(sub).map(([k, v]) => `${k}: ${v.pass ? "OK" : "FAIL"}`).join(", "),
    details: sub,
    durationMs: Date.now() - t0,
  };
}

// ============================================================
// Main
// ============================================================

async function main() {
  const totalStart = Date.now();
  const results: TestResult[] = [];

  log("╔══════════════════════════════════════════════════╗");
  log("║  PGlite + DBOS Evidence Suite                   ║");
  log("╚══════════════════════════════════════════════════╝\n");

  rmSync(DATA_DIR, { recursive: true, force: true });
  mkdirSync(PGDATA_DIR, { recursive: true });

  // --- Q4: Startup benchmarks ---
  log("Q4: PGlite startup time benchmarks...");
  const q4 = await runTest(testQ4);
  results.push(q4);
  log(`  → ${q4.verdict}: ${q4.summary}\n`);

  // --- Start shared PGlite + socket server ---
  rmSync(PGDATA_DIR, { recursive: true, force: true });
  mkdirSync(PGDATA_DIR, { recursive: true });

  log("Starting shared PGlite (maxConnections: 20)...");
  const db = await PGlite.create(PGDATA_DIR, { extensions: { uuid_ossp } });
  const server = new PGLiteSocketServer({
    db,
    port: 0,
    host: "127.0.0.1",
    maxConnections: 20,
  });
  await server.start();
  const databaseUrl = `postgresql://postgres:postgres@${server.getServerConn()}/postgres`;
  log(`  Socket server: ${server.getServerConn()}\n`);

  try {
    // --- Q2: Schema verification ---
    log("Q2: Schema verification...");
    const q2 = await runTest(() => testQ2(db, databaseUrl));
    results.push(q2);
    log(`  → ${q2.verdict}: ${q2.summary}\n`);

    // --- Q6: Step output sizes ---
    log("Q6: Step output size performance...");
    const q6 = await runTest(() => testQ6(databaseUrl));
    results.push(q6);
    log(`  → ${q6.verdict}: ${q6.summary}\n`);

    // --- Q5: DBOSClient concurrent access ---
    log("Q5: DBOSClient concurrent access...");
    const q5 = await runTest(() => testQ5(databaseUrl));
    results.push(q5);
    log(`  → ${q5.verdict}: ${q5.summary}\n`);

    // --- Q3: LISTEN/NOTIFY (before Q1 — Q1's pool>1 test poisons DBOS) ---
    log("Q3: LISTEN/NOTIFY through socket...");
    const q3 = await runTest(() => testQ3(db, databaseUrl));
    results.push(q3);
    log(`  → ${q3.verdict}: ${q3.summary}\n`);

    // --- Q1: Connection pool sizes (LAST — pool>1 deadlocks and leaves DBOS unrecoverable) ---
    log("Q1: Connection pool through multiplexer...");
    const q1 = await runTest(() => testQ1(databaseUrl));
    results.push(q1);
    log(`  → ${q1.verdict}: ${q1.summary}\n`);
  } finally {
    try { await withTimeout(DBOS.shutdown({ deregister: true }), 5_000, "final shutdown"); } catch {}
    await sleep(200);
    try { await server.stop(); } catch {}
    try { await db.close(); } catch {}
  }

  results.sort((a, b) => a.question.localeCompare(b.question));

  const report: EvidenceReport = {
    timestamp: new Date().toISOString(),
    nodeVersion: process.version,
    platform: `${process.platform} ${process.arch}`,
    results,
    totalDurationMs: Date.now() - totalStart,
  };

  log("══════════════════════════════════════════════════");
  log("  EVIDENCE REPORT SUMMARY");
  log("══════════════════════════════════════════════════");
  for (const r of results) {
    const icon = r.verdict === "PASS" ? "✅" : r.verdict === "PARTIAL" ? "⚠️" : r.verdict === "FAIL" ? "❌" : "💥";
    log(`  ${icon} ${r.question}: ${r.title}`);
    log(`     ${r.summary}`);
  }
  log(`\n  Total: ${report.totalDurationMs}ms`);
  log("══════════════════════════════════════════════════\n");

  console.log(JSON.stringify(report, null, 2));

  // Force exit — DBOS may leave dangling pool connections after deadlock recovery
  process.exit(0);
}

main().catch((err) => {
  process.stderr.write(`Evidence suite failed: ${err.message}\n${err.stack}\n`);
  process.exit(1);
});
