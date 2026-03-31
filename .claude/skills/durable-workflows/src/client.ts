/**
 * DBOSClient wrapper for management operations.
 * Used by CLI tools (dashboard, send, inspect, fork, list) to connect
 * to the database without running a full DBOS application.
 */

import { DBOSClient } from "@dbos-inc/dbos-sdk";
import { readConnectionInfo } from "./db.js";

export type { DBOSClient };

/** Create a DBOSClient from connection.json or DBOS_DATABASE_URL. */
export async function createClient(): Promise<DBOSClient> {
  const url = resolveUrl();
  return await DBOSClient.create({ systemDatabaseUrl: url });
}

function resolveUrl(): string {
  const envUrl = process.env.DBOS_DATABASE_URL;
  if (envUrl) return envUrl;

  const info = readConnectionInfo();
  if (!info) {
    throw new Error(
      "No database connection found. Run `npm run bootstrap` first, " +
        "or set DBOS_DATABASE_URL.",
    );
  }
  return info.databaseUrl;
}
