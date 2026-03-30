/**
 * Graceful shutdown of PGlite.
 * Reads connection.json to find the PGlite process and signals it.
 *
 * Usage: npx tsx scripts/shutdown.ts
 */

import { readConnectionInfo, getConnectionFile } from "../src/db.js";
import { unlinkSync } from "node:fs";

async function main() {
  const info = readConnectionInfo();

  if (!info) {
    console.log("No active connection found.");
    return;
  }

  if (info.mode === "external") {
    console.log("External Postgres — nothing to shut down.");
    return;
  }

  // Signal the bootstrap process
  try {
    process.kill(info.pid, "SIGTERM");
    console.log(`✓ Sent SIGTERM to PID ${info.pid}`);
  } catch (err: any) {
    if (err.code === "ESRCH") {
      console.log(`Process ${info.pid} not found (already stopped).`);
      try {
        unlinkSync(getConnectionFile());
        console.log("Cleaned up stale connection.json");
      } catch {}
    } else {
      throw err;
    }
  }
}

main().catch((err) => {
  console.error("Shutdown error:", err.message);
  process.exit(1);
});
