/**
 * Lint → Approve → Fix → PR workflow with human-in-the-loop.
 *
 * 1. Runs linters and captures findings
 * 2. Reports results
 * 3. Waits for human approval via DBOS.recv()
 * 4. If approved: applies fixes, commits, opens a PR
 *
 * Usage:
 *   npm run bootstrap                    # ensure PGlite is running
 *   npx tsx workflows/lint-and-pr.ts     # start the workflow
 *
 * Then approve via web dashboard (http://127.0.0.1:<httpPort>)
 * or CLI: npm run send -- --id <wf-id> --topic approval --message '{"approved":true}'
 */

import { DBOS } from "@dbos-inc/dbos-sdk";
import { readConnectionInfo } from "../src/db.js";
import { buildDBOSConfig } from "../src/dbos-config.js";
import { execSync } from "node:child_process";

const PROJECT_ROOT = new URL("../../", import.meta.url).pathname.replace(/\/$/, "");

function run(cmd: string, opts?: { cwd?: string; ignoreError?: boolean }): { stdout: string; exitCode: number } {
  try {
    const stdout = execSync(cmd, {
      cwd: opts?.cwd ?? PROJECT_ROOT,
      encoding: "utf-8",
      timeout: 60_000,
      stdio: ["pipe", "pipe", "pipe"],
    });
    return { stdout: stdout.trim(), exitCode: 0 };
  } catch (err: any) {
    if (opts?.ignoreError) {
      return { stdout: (err.stdout ?? "").trim(), exitCode: err.status ?? 1 };
    }
    throw err;
  }
}

// --- Steps ---

async function runLinters(): Promise<{ swift: string; ts: string; issueCount: number }> {
  console.log("Running linters...");

  // Swift: swift-format lint (dry run)
  const swift = run(
    "swift-format lint --recursive Sources/ Tests/ 2>&1 | head -50",
    { ignoreError: true },
  );

  // TypeScript: tsc --noEmit on durable-workflows
  const ts = run(
    "npx tsc --noEmit 2>&1 | head -30",
    { cwd: `${PROJECT_ROOT}/durable-workflows`, ignoreError: true },
  );

  const swiftIssues = (swift.stdout.match(/warning:/g) || []).length;
  const tsIssues = (ts.stdout.match(/error TS/g) || []).length;

  return {
    swift: swift.stdout || "(clean)",
    ts: ts.stdout || "(clean)",
    issueCount: swiftIssues + tsIssues,
  };
}

async function buildReport(lintResult: { swift: string; ts: string; issueCount: number }): Promise<string> {
  const lines = [
    `## Lint Report`,
    ``,
    `**${lintResult.issueCount} issue(s) found**`,
    ``,
    `### Swift (swift-format)`,
    "```",
    lintResult.swift.substring(0, 2000),
    "```",
    ``,
    `### TypeScript (tsc)`,
    "```",
    lintResult.ts.substring(0, 2000),
    "```",
  ];
  const report = lines.join("\n");
  console.log(report);
  return report;
}

async function applyFixes(): Promise<string> {
  console.log("Applying swift-format fixes...");
  run("swift-format format --recursive --in-place Sources/ Tests/", { ignoreError: true });

  const diff = run("git diff --stat", { ignoreError: true });
  console.log(`Files changed:\n${diff.stdout}`);
  return diff.stdout || "(no changes)";
}

async function createPR(report: string, diff: string): Promise<string> {
  const branch = `fix/lint-cleanup-${Date.now()}`;

  // Check if there are actual changes to commit
  const status = run("git status --porcelain", { ignoreError: true });
  if (!status.stdout.trim()) {
    return "No changes to commit — linters found style issues but swift-format produced no diff.";
  }

  run(`git checkout -b ${branch}`);
  run("git add -A Sources/ Tests/");
  run(`git commit -m "style: apply swift-format lint fixes"`);

  // Push and create PR
  run(`git push -u origin ${branch}`);
  const pr = run(
    `gh pr create --title "style: lint cleanup" --body "${report.substring(0, 500)}\n\n---\nDiff:\n\`\`\`\n${diff.substring(0, 500)}\n\`\`\`"`,
    { ignoreError: true },
  );

  // Return to original branch
  run("git checkout -");

  return pr.stdout || "PR creation attempted (check gh auth status if it failed)";
}

// --- Workflow ---

async function lintAndPRWorkflow(): Promise<string> {
  // Step 1: Run linters
  const lintResult = await DBOS.runStep(() => runLinters(), { name: "lint" });

  // Step 2: Build report
  const report = await DBOS.runStep(() => buildReport(lintResult), { name: "report" });

  // Step 3: Wait for human approval (10 min timeout)
  console.log("\n⏳ Waiting for approval...");
  console.log("   Approve via dashboard or CLI:");
  console.log(`   npm run send -- --id ${DBOS.workflowID} --topic approval --message '{"approved":true}'`);

  const decision = await DBOS.recv<{ approved: boolean; note?: string }>("approval", 600);

  if (!decision || !decision.approved) {
    const reason = decision?.note ?? "rejected or timed out";
    console.log(`\n❌ Not approved: ${reason}`);
    return `Rejected: ${reason}`;
  }

  console.log("\n✅ Approved! Applying fixes...");

  // Step 4: Apply fixes
  const diff = await DBOS.runStep(() => applyFixes(), { name: "fix" });

  // Step 5: Create PR
  const prUrl = await DBOS.runStep(() => createPR(report, diff), { name: "open-pr" });

  console.log(`\n🔗 ${prUrl}`);
  return prUrl;
}

// --- Registration ---
export const lintAndPR = DBOS.registerWorkflow(lintAndPRWorkflow, {
  name: "lintAndPR",
});

// --- Run ---
const info = readConnectionInfo();
if (!info) {
  console.error("No database connection. Run `npm run bootstrap` first.");
  process.exit(1);
}

DBOS.setConfig(buildDBOSConfig({ databaseUrl: info.databaseUrl, mode: info.mode }));
await DBOS.launch();

const handle = await DBOS.startWorkflow(lintAndPR)();
console.log(`\nWorkflow: ${handle.workflowID}`);

const result = await handle.getResult();
console.log(`\nDone: ${result}`);
await DBOS.shutdown();
