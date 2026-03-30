/**
 * Database connection factory.
 * Selects embedded PGlite or external Postgres based on DBOS_DATABASE_URL.
 */

import { PGlite } from "@electric-sql/pglite";
import { uuid_ossp } from "@electric-sql/pglite/contrib/uuid_ossp";
import { PGLiteSocketServer } from "@electric-sql/pglite-socket";
import { readFileSync, writeFileSync, unlinkSync, mkdirSync, existsSync } from "node:fs";
import { resolve } from "node:path";

export interface ConnectionInfo {
  databaseUrl: string;
  port: number | null;
  pid: number;
  mode: "embedded" | "external";
}

const DBOS_DIR = resolve(process.cwd(), ".dbos");
const PGDATA_DIR = resolve(DBOS_DIR, "pgdata");
const CONNECTION_FILE = resolve(DBOS_DIR, "connection.json");

let pgliteInstance: PGlite | null = null;
let socketServer: PGLiteSocketServer | null = null;

export function getConnectionFile(): string {
  return CONNECTION_FILE;
}

export function readConnectionInfo(): ConnectionInfo | null {
  if (!existsSync(CONNECTION_FILE)) return null;
  try {
    return JSON.parse(readFileSync(CONNECTION_FILE, "utf-8"));
  } catch {
    return null;
  }
}

/** Resolve a database URL: use DBOS_DATABASE_URL if set, otherwise start embedded PGlite. */
export async function resolveDatabaseUrl(): Promise<string> {
  const envUrl = process.env.DBOS_DATABASE_URL;
  if (envUrl) {
    writeConnectionInfo({
      databaseUrl: envUrl,
      port: null,
      pid: process.pid,
      mode: "external",
    });
    return envUrl;
  }
  return await startEmbeddedPGlite();
}

/** Start PGlite with filesystem persistence and expose via socket server. */
async function startEmbeddedPGlite(): Promise<string> {
  mkdirSync(PGDATA_DIR, { recursive: true });

  pgliteInstance = await PGlite.create(PGDATA_DIR, {
    extensions: { uuid_ossp },
  });

  socketServer = new PGLiteSocketServer({
    db: pgliteInstance,
    port: 0,
    host: "127.0.0.1",
    maxConnections: 20, // default=1 causes ECONNRESET when DBOSClient connects (evidence Q5)
  });

  await socketServer.start();
  const conn = socketServer.getServerConn();
  const databaseUrl = `postgresql://postgres:postgres@${conn}/postgres`;

  writeConnectionInfo({
    databaseUrl,
    port: parseInt(conn.split(":")[1]),
    pid: process.pid,
    mode: "embedded",
  });

  return databaseUrl;
}

function writeConnectionInfo(info: ConnectionInfo): void {
  mkdirSync(DBOS_DIR, { recursive: true });
  writeFileSync(CONNECTION_FILE, JSON.stringify(info, null, 2));
}

/** Remove connection.json (call on shutdown or stale cleanup). */
export function removeConnectionInfo(): void {
  try {
    unlinkSync(CONNECTION_FILE);
  } catch {}
}

/** Check if the PID in connection.json is still alive. */
export function isBootstrapAlive(info: ConnectionInfo): boolean {
  try {
    process.kill(info.pid, 0);
    return true;
  } catch {
    return false;
  }
}

/** Gracefully shut down PGlite and socket server. */
export async function shutdownEmbedded(): Promise<void> {
  if (socketServer) {
    await socketServer.stop();
    socketServer = null;
  }
  if (pgliteInstance) {
    await pgliteInstance.close();
    pgliteInstance = null;
  }
}
