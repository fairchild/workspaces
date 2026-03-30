/**
 * DBOS configuration builder.
 * Builds the config object for DBOS.setConfig() with PGlite-safe defaults.
 */

import type { DBOSConfig } from "@dbos-inc/dbos-sdk";

export interface DurableWorkflowsConfig {
  databaseUrl: string;
  mode?: "embedded" | "external";
  poolSize?: number;
  logLevel?: string;
}

/** Build a DBOS config tuned for PGlite (or external Postgres). */
export function buildDBOSConfig(opts: DurableWorkflowsConfig): DBOSConfig {
  const isEmbedded = opts.mode
    ? opts.mode === "embedded"
    : !process.env.DBOS_DATABASE_URL;

  return {
    systemDatabaseUrl: opts.databaseUrl,
    systemDatabasePoolSize: opts.poolSize ?? (isEmbedded ? 1 : 10),
    useListenNotify: !isEmbedded, // PGlite socket doesn't support LISTEN/NOTIFY
    runAdminServer: false,
    logLevel: opts.logLevel ?? "info",
  };
}
