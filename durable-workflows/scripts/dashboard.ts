/**
 * Dashboard: Show workflow overview table.
 *
 * Usage: npx tsx scripts/dashboard.ts [--json] [--status=PENDING,ERROR]
 */

import { createClient } from "../src/client.js";
import type { DBOSClient } from "@dbos-inc/dbos-sdk";

interface DashboardRow {
  id: string;
  name: string;
  status: string;
  steps: string;
  updated: string;
}

function parseArgs() {
  const args = process.argv.slice(2);
  const json = args.includes("--json");
  const statusArg = args.find((a) => a.startsWith("--status="));
  const statuses = statusArg?.split("=")[1]?.split(",") ?? [];
  return { json, statuses };
}

function formatAge(epochMs: number): string {
  const delta = Date.now() - epochMs;
  if (delta < 1000) return "just now";
  if (delta < 60_000) return `${Math.floor(delta / 1000)}s ago`;
  if (delta < 3600_000) return `${Math.floor(delta / 60_000)} min ago`;
  if (delta < 86400_000) return `${Math.floor(delta / 3600_000)}h ago`;
  return `${Math.floor(delta / 86400_000)}d ago`;
}

function statusIcon(status: string): string {
  switch (status) {
    case "SUCCESS": return "✅";
    case "PENDING": return "🔄";
    case "ERROR": return "❌";
    case "CANCELLED": return "🚫";
    case "ENQUEUED": return "📋";
    case "DELAYED": return "⏱️";
    default: return "❓";
  }
}

async function main() {
  const { json, statuses } = parseArgs();
  const client = await createClient();

  try {
    const filter: Record<string, unknown> = { sortDesc: true, limit: 50 };
    if (statuses.length > 0) {
      filter.status = statuses;
    }

    const workflows = await client.listWorkflows(filter as any);

    if (json) {
      console.log(JSON.stringify(workflows, null, 2));
      return;
    }

    if (workflows.length === 0) {
      console.log("No workflows found.");
      return;
    }

    // Build dashboard rows
    const rows: DashboardRow[] = [];
    for (const wf of workflows) {
      let stepInfo = "—";
      try {
        const steps = await client.listWorkflowSteps(wf.workflowID);
        stepInfo = `${steps.length}`;
      } catch {}

      rows.push({
        id: wf.workflowID.substring(0, 8),
        name: wf.workflowName ?? "unknown",
        status: `${statusIcon(wf.status)} ${wf.status}`,
        steps: stepInfo,
        updated: formatAge(Number(wf.updatedAt ?? wf.createdAt)),
      });
    }

    // Print table
    const cols = {
      id: Math.max(8, ...rows.map((r) => r.id.length)),
      name: Math.max(8, ...rows.map((r) => r.name.length)),
      status: Math.max(8, ...rows.map((r) => r.status.length)),
      steps: Math.max(5, ...rows.map((r) => r.steps.length)),
      updated: Math.max(7, ...rows.map((r) => r.updated.length)),
    };

    const header = [
      "ID".padEnd(cols.id),
      "Workflow".padEnd(cols.name),
      "Status".padEnd(cols.status),
      "Steps".padEnd(cols.steps),
      "Updated".padEnd(cols.updated),
    ].join(" │ ");

    const sep = [
      "─".repeat(cols.id),
      "─".repeat(cols.name),
      "─".repeat(cols.status),
      "─".repeat(cols.steps),
      "─".repeat(cols.updated),
    ].join("─┼─");

    console.log(`\n DBOS Workflow Dashboard\n`);
    console.log(` ${header}`);
    console.log(` ${sep}`);

    for (const row of rows) {
      console.log(
        ` ${[
          row.id.padEnd(cols.id),
          row.name.padEnd(cols.name),
          row.status.padEnd(cols.status),
          row.steps.padEnd(cols.steps),
          row.updated.padEnd(cols.updated),
        ].join(" │ ")}`,
      );
    }

    // Summary
    const pending = workflows.filter((w) => w.status === "PENDING").length;
    const errored = workflows.filter((w) => w.status === "ERROR").length;
    console.log("");
    if (pending > 0) console.log(` Pending: ${pending}`);
    if (errored > 0)
      console.log(` Errored: ${errored} (use inspect <id> to debug)`);
    console.log("");
  } finally {
    await client.destroy();
  }
}

main().catch((err) => {
  console.error("Dashboard error:", err.message);
  process.exit(1);
});
