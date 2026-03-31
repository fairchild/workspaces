/**
 * Project status workflow — real example using this repo.
 *
 * Gathers open PRs, recent commits, and backlog items into a summary.
 * Each step is checkpointed: if GitHub rate-limits or the process dies,
 * restart picks up where it left off.
 *
 * Usage:
 *   npm run bootstrap  (in another terminal)
 *   npx tsx project-status.ts
 */

import { DBOS } from "@dbos-inc/dbos-sdk";
import { readConnectionInfo } from "./src/db.js";
import { buildDBOSConfig } from "./src/dbos-config.js";
import { execSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

const REPO = "fairchild/workspaces";
const REPO_ROOT = resolve(import.meta.dirname, "..");

// --- Steps ---

async function fetchOpenPRs(): Promise<Array<{ number: number; title: string; author: string; updatedAt: string }>> {
  const raw = execSync(`gh pr list --repo ${REPO} --json number,title,author,updatedAt --limit 10`, {
    encoding: "utf-8",
  });
  return JSON.parse(raw).map((pr: any) => ({
    number: pr.number,
    title: pr.title,
    author: pr.author.login,
    updatedAt: pr.updatedAt,
  }));
}

async function fetchRecentCommits(): Promise<Array<{ sha: string; message: string; date: string }>> {
  const raw = execSync(`git -C "${REPO_ROOT}" log --oneline --format='{"sha":"%h","message":"%s","date":"%ci"}' -5`, {
    encoding: "utf-8",
  });
  return raw
    .trim()
    .split("\n")
    .filter(Boolean)
    .map((line) => JSON.parse(line));
}

async function scanBacklog(): Promise<Array<{ file: string; title: string }>> {
  const backlogDir = resolve(REPO_ROOT, "backlog");
  try {
    return readdirSync(backlogDir)
      .filter((f) => f.endsWith(".md") && f !== "ROADMAP.md")
      .map((f) => {
        const content = readFileSync(resolve(backlogDir, f), "utf-8");
        const titleMatch = content.match(/^#\s+(.+)/m);
        return { file: f, title: titleMatch?.[1] ?? f };
      });
  } catch {
    return [];
  }
}

// --- Workflow ---

async function projectStatusWorkflow(): Promise<string> {
  const prs = await DBOS.runStep(fetchOpenPRs, { name: "fetch-open-prs", retriesAllowed: true, maxAttempts: 3 });
  const commits = await DBOS.runStep(fetchRecentCommits, { name: "fetch-recent-commits" });
  const backlog = await DBOS.runStep(scanBacklog, { name: "scan-backlog" });

  const report = await DBOS.runStep(
    async () => {
      const lines: string[] = [];
      lines.push(`# Project Status — ${new Date().toISOString().split("T")[0]}`);
      lines.push("");

      lines.push(`## Open PRs (${prs.length})`);
      if (prs.length === 0) lines.push("None");
      for (const pr of prs) {
        lines.push(`- #${pr.number} ${pr.title} (@${pr.author})`);
      }
      lines.push("");

      lines.push(`## Recent Commits`);
      for (const c of commits) {
        lines.push(`- \`${c.sha}\` ${c.message}`);
      }
      lines.push("");

      lines.push(`## Backlog Items (${backlog.length})`);
      if (backlog.length === 0) lines.push("None");
      for (const b of backlog) {
        lines.push(`- ${b.title}`);
      }

      return lines.join("\n");
    },
    { name: "build-report" },
  );

  return report;
}

const projectStatus = DBOS.registerWorkflow(projectStatusWorkflow, { name: "projectStatus" });

// --- Run ---

const info = readConnectionInfo();
if (!info) {
  console.error("No database connection. Run `npm run bootstrap` first.");
  process.exit(1);
}

DBOS.setConfig(buildDBOSConfig({ databaseUrl: info.databaseUrl, mode: info.mode }));
await DBOS.launch();

try {
  const handle = await DBOS.startWorkflow(projectStatus)();
  console.log(`Started workflow ${handle.workflowID}\n`);
  const report = await handle.getResult();
  console.log(report);
} finally {
  await DBOS.shutdown();
}
