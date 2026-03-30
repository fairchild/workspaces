/**
 * HTTP server for the workflow dashboard.
 * Serves dashboard.html and JSON API endpoints using DBOSClient.
 */

import { createServer, IncomingMessage, ServerResponse } from "node:http";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { DBOSClient } from "@dbos-inc/dbos-sdk";

const ASSETS_DIR = resolve(import.meta.dirname, "../assets");

let client: DBOSClient | null = null;

function json(res: ServerResponse, data: unknown, status = 200) {
  res.writeHead(status, {
    "Content-Type": "application/json",
    "Access-Control-Allow-Origin": "*",
  });
  res.end(JSON.stringify(data));
}

function html(res: ServerResponse, body: string) {
  res.writeHead(200, { "Content-Type": "text/html; charset=utf-8" });
  res.end(body);
}

async function handleRequest(req: IncomingMessage, res: ServerResponse) {
  const url = new URL(req.url ?? "/", `http://${req.headers.host}`);
  const path = url.pathname;

  try {
    // Static: serve dashboard.html
    if (path === "/" || path === "/index.html") {
      const file = readFileSync(resolve(ASSETS_DIR, "dashboard.html"), "utf-8");
      return html(res, file);
    }

    // API: list workflows
    if (path === "/api/workflows" && req.method === "GET") {
      if (!client) return json(res, { error: "Not connected" }, 503);

      const statusParam = url.searchParams.get("status");
      const filter: Record<string, unknown> = { sortDesc: true, limit: 100 };
      if (statusParam) {
        filter.status = statusParam.split(",");
      }

      const workflows = await client.listWorkflows(filter as any);

      // Enrich with step counts
      const enriched = await Promise.all(
        workflows.map(async (wf) => {
          let stepCount = 0;
          try {
            const steps = await client!.listWorkflowSteps(wf.workflowID);
            stepCount = steps?.length ?? 0;
          } catch {}
          return { ...wf, stepCount };
        }),
      );

      return json(res, enriched);
    }

    // API: get workflow steps
    const stepsMatch = path.match(/^\/api\/workflows\/([^/]+)\/steps$/);
    if (stepsMatch && req.method === "GET") {
      if (!client) return json(res, { error: "Not connected" }, 503);

      const id = stepsMatch[1];
      const [wf, steps] = await Promise.all([
        client.getWorkflow(id),
        client.listWorkflowSteps(id),
      ]);

      if (!wf) return json(res, { error: "Workflow not found" }, 404);

      return json(res, { workflow: wf, steps });
    }

    // API: send message to workflow
    const sendMatch = path.match(/^\/api\/workflows\/([^/]+)\/send$/);
    if (sendMatch && req.method === "POST") {
      if (!client) return json(res, { error: "Not connected" }, 503);

      const id = sendMatch[1];
      const body = await readBody(req);
      const { topic, message } = JSON.parse(body);

      await client.send(id, message, topic);
      return json(res, { ok: true });
    }

    // CORS preflight
    if (req.method === "OPTIONS") {
      res.writeHead(204, {
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
      });
      return res.end();
    }

    // 404
    json(res, { error: "Not found" }, 404);
  } catch (err: any) {
    json(res, { error: err.message ?? "Internal error" }, 500);
  }
}

function readBody(req: IncomingMessage): Promise<string> {
  return new Promise((resolve, reject) => {
    const chunks: Buffer[] = [];
    req.on("data", (chunk) => chunks.push(chunk));
    req.on("end", () => resolve(Buffer.concat(chunks).toString()));
    req.on("error", reject);
  });
}

export interface HttpServerHandle {
  port: number;
  close: () => Promise<void>;
}

/** Start the dashboard HTTP server on an auto-assigned port. */
export async function startHttpServer(databaseUrl: string): Promise<HttpServerHandle> {
  client = await DBOSClient.create({ systemDatabaseUrl: databaseUrl });

  const server = createServer(handleRequest);

  return new Promise((resolve, reject) => {
    server.listen(0, "127.0.0.1", () => {
      const addr = server.address();
      if (!addr || typeof addr === "string") {
        return reject(new Error("Failed to get server address"));
      }

      resolve({
        port: addr.port,
        close: async () => {
          server.close();
          if (client) {
            await client.destroy();
            client = null;
          }
        },
      });
    });

    server.on("error", reject);
  });
}
