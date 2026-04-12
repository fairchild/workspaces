/**
 * Orchestrator pattern: main session dispatches and monitors sub-workflows.
 *
 * The orchestrator starts workflows, monitors their progress, and sends
 * messages to unblock waiting workflows. This is the primary pattern for
 * "Claude Code as orchestrator."
 */

import { DBOS } from "@dbos-inc/dbos-sdk";

// --- Sub-workflows (registered elsewhere, imported here) ---

async function analyzeCodeWorkflow(repoPath: string): Promise<string> {
  const files = await DBOS.runStep(
    async () => {
      // Scan repository files
      return ["src/main.ts", "src/utils.ts", "src/config.ts"];
    },
    { name: "scan-files" },
  );

  const analysis = await DBOS.runStep(
    async () => {
      // Analyze each file
      return files.map((f) => ({ file: f, issues: 0 }));
    },
    { name: "analyze" },
  );

  // Wait for human review before proceeding
  const approval = await DBOS.recv<{ approved: boolean }>("review", 3600);
  if (!approval?.approved) {
    return "Analysis cancelled — not approved.";
  }

  const report = await DBOS.runStep(
    async () => {
      return `Analysis complete: ${analysis.length} files, 0 issues.`;
    },
    { name: "generate-report" },
  );

  return report;
}

async function runTestsWorkflow(testSuite: string): Promise<string> {
  const result = await DBOS.runStep(
    async () => {
      // Run tests
      return { passed: 42, failed: 0, suite: testSuite };
    },
    { name: "run-tests" },
  );

  return `${testSuite}: ${result.passed} passed, ${result.failed} failed`;
}

// --- Registration ---

const analyzeCode = DBOS.registerWorkflow(analyzeCodeWorkflow, {
  name: "analyzeCode",
});
const runTests = DBOS.registerWorkflow(runTestsWorkflow, {
  name: "runTests",
});

// --- Orchestrator ---

/**
 * Example orchestrator usage (run this after DBOS.launch()):
 *
 * ```typescript
 * // Start sub-workflows
 * const analysis = await DBOS.startWorkflow(analyzeCode)("/path/to/repo");
 * const tests = await DBOS.startWorkflow(runTests)("unit");
 *
 * // Monitor progress
 * const workflows = await DBOS.listWorkflows({ status: "PENDING" });
 * for (const wf of workflows) {
 *   const steps = await DBOS.listWorkflowSteps(wf.workflowID);
 *   console.log(`${wf.workflowName}: ${steps.length} steps completed`);
 * }
 *
 * // Unblock the analysis workflow (it's waiting on "review" topic)
 * await DBOS.send(analysis.workflowID, { approved: true }, "review");
 *
 * // Collect results
 * const analysisResult = await analysis.getResult();
 * const testsResult = await tests.getResult();
 * ```
 */

export { analyzeCode, runTests };
