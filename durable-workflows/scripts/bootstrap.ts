/**
 * Bootstrap: Start PGlite (or connect to external Postgres), initialize DBOS.
 * Idempotent — if already running, just prints status.
 *
 * Usage: npx tsx scripts/bootstrap.ts [--status]
 */

import { DBOS } from "@dbos-inc/dbos-sdk";
import { resolveDatabaseUrl, readConnectionInfo, shutdownEmbedded } from "../src/db.js";
import { buildDBOSConfig } from "../src/dbos-config.js";

const statusOnly = process.argv.includes("--status");

async function main() {
  // Check if already running
  const existing = readConnectionInfo();
  if (existing && statusOnly) {
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

  // Keep process alive for embedded mode
  if (info?.mode === "embedded") {
    console.log("\nPGlite running. Press Ctrl+C to stop.");

    const shutdown = async () => {
      console.log("\nShutting down...");
      await DBOS.shutdown();
      await shutdownEmbedded();
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
