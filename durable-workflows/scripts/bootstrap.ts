/**
 * Bootstrap: Start PGlite (or connect to external Postgres), initialize DBOS.
 * Idempotent — if already running, just prints status.
 *
 * Usage: npx tsx scripts/bootstrap.ts [--status]
 */

import { DBOS } from "@dbos-inc/dbos-sdk";
import { resolveDatabaseUrl, readConnectionInfo, removeConnectionInfo, writeConnectionInfo, isBootstrapAlive, shutdownEmbedded } from "../src/db.js";
import { startHttpServer, type HttpServerHandle } from "../src/http-server.js";
import { buildDBOSConfig } from "../src/dbos-config.js";

const statusOnly = process.argv.includes("--status");

async function main() {
  const existing = readConnectionInfo();

  if (existing && existing.mode === "embedded") {
    if (isBootstrapAlive(existing)) {
      // Already running — print status and exit
      console.log(`✓ Already running (PID ${existing.pid}, port ${existing.port})`);
      if (statusOnly) console.log(JSON.stringify(existing, null, 2));
      process.exit(0);
    }
    // Stale connection.json from a dead process — clean up
    removeConnectionInfo();
  } else if (existing && statusOnly) {
    console.log(JSON.stringify(existing, null, 2));
    process.exit(0);
  }

  const databaseUrl = await resolveDatabaseUrl();
  const config = buildDBOSConfig({ databaseUrl });

  DBOS.setConfig(config);
  await DBOS.launch();

  const info = readConnectionInfo();
  console.log(`✓ DBOS ready (${info?.mode} mode)`);
  console.log(`  Database: ${info?.databaseUrl}`);
  console.log(`  PID: ${info?.pid}`);
  console.log(`  Connection file: .dbos/connection.json`);

  // Start dashboard HTTP server
  let httpServer: HttpServerHandle | null = null;
  if (info) {
    try {
      httpServer = await startHttpServer(info.databaseUrl);
      writeConnectionInfo({ ...info, httpPort: httpServer.port });
      console.log(`  Dashboard: http://127.0.0.1:${httpServer.port}`);
    } catch (err: any) {
      console.warn(`  Dashboard server failed: ${err.message}`);
    }
  }

  // Keep process alive for embedded mode
  if (info?.mode === "embedded") {
    console.log("\nPGlite running. Press Ctrl+C to stop.");

    const shutdown = async () => {
      if (httpServer) await httpServer.close();
      console.log("\nShutting down...");
      await DBOS.shutdown();
      await shutdownEmbedded();
      removeConnectionInfo();
      process.exit(0);
    };

    process.on("SIGINT", shutdown);
    process.on("SIGTERM", shutdown);
  } else {
    // External mode — just verify and exit
    await DBOS.shutdown();
    console.log("\nExternal Postgres verified. DBOS system tables ready.");
  }
}

main().catch((err) => {
  console.error("Bootstrap failed:", err.message);
  process.exit(1);
});
