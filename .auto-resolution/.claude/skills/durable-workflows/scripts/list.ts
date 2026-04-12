/**
 * List workflows with filters (JSON output for programmatic use).
 *
 * Usage: npx tsx scripts/list.ts [--status=PENDING] [--name=myWorkflow] [--limit=10]
 */

import { createClient } from "../src/client.js";

function parseArgs() {
  const args = process.argv.slice(2);
  const filter: Record<string, unknown> = {};

  for (const arg of args) {
    const [key, val] = arg.replace(/^--/, "").split("=");
    if (!val) continue;

    switch (key) {
      case "status":
        filter.status = val.includes(",") ? val.split(",") : val;
        break;
      case "name":
        filter.workflowName = val;
        break;
      case "limit":
        filter.limit = parseInt(val);
        break;
      case "id":
        filter.workflowIDs = [val];
        break;
    }
  }

  return filter;
}

async function main() {
  const filter = parseArgs();
  const client = await createClient();

  try {
    const workflows = await client.listWorkflows(filter as any);
    console.log(JSON.stringify(workflows, null, 2));
  } finally {
    await client.destroy();
  }
}

main().catch((err) => {
  console.error("List error:", err.message);
  process.exit(1);
});
