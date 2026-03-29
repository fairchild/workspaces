/**
 * Send a message to a waiting workflow.
 *
 * Usage: npx tsx scripts/send.ts --id <workflow-id> --topic <topic> --message '<json>'
 */

import { createClient } from "../src/client.js";

function parseArgs() {
  const args = process.argv.slice(2);
  let id = "", topic = "", message = "";

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--id" && args[i + 1]) id = args[++i];
    else if (args[i] === "--topic" && args[i + 1]) topic = args[++i];
    else if (args[i] === "--message" && args[i + 1]) message = args[++i];
  }

  if (!id) {
    console.error("Usage: send.ts --id <workflow-id> --topic <topic> --message '<json>'");
    process.exit(1);
  }

  let parsed: unknown;
  try {
    parsed = JSON.parse(message || "null");
  } catch {
    parsed = message; // treat as plain string
  }

  return { id, topic: topic || undefined, message: parsed };
}

async function main() {
  const { id, topic, message } = parseArgs();
  const client = await createClient();

  try {
    await client.send(id, message, topic);
    console.log(`✓ Sent to ${id.substring(0, 8)}..${topic ? ` topic="${topic}"` : ""}`);
    console.log(`  Message: ${JSON.stringify(message)}`);
  } finally {
    await client.destroy();
  }
}

main().catch((err) => {
  console.error("Send error:", err.message);
  process.exit(1);
});
