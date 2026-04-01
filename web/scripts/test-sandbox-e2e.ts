#!/usr/bin/env -S npx tsx
/**
 * End-to-end validation of the @agent chat → Vercel Sandbox pipeline.
 *
 * Tests:
 *   1. Sandbox lifecycle (create → clone → run claude → stream → destroy)
 *   2. Persona resolution (discover, resolve, conversational prompt)
 *   3. Provider registry (default, stubs unavailable)
 *   4. Session persistence (create, query, status transitions)
 *   5. Access control (allowlist check)
 *
 * Usage:
 *   npx tsx web/scripts/test-sandbox-e2e.ts              # all tests
 *   npx tsx web/scripts/test-sandbox-e2e.ts --unit-only   # skip sandbox (no Vercel creds needed)
 *   npx tsx web/scripts/test-sandbox-e2e.ts --sandbox-only # only sandbox lifecycle
 *
 * Env:
 *   VERCEL_TOKEN, VERCEL_TEAM_ID, VERCEL_PROJECT_ID  — Vercel Sandbox creds
 *   ANTHROPIC_API_KEY                                  — for Claude inside sandbox
 *   GITHUB_TOKEN                                       — for persona discovery (repo tree)
 */

import fs from "node:fs";
import path from "node:path";

// ---------------------------------------------------------------------------
// Env setup: load web/.env.local if present
// ---------------------------------------------------------------------------
const envPath = path.resolve(__dirname, "../.env.local");
if (fs.existsSync(envPath)) {
	for (const line of fs.readFileSync(envPath, "utf8").split("\n")) {
		const m = line.match(/^([A-Z_][A-Z0-9_]*)=(.+)$/);
		if (m && !process.env[m[1]]) {
			process.env[m[1]] = m[2].replace(/^["']|["']$/g, "");
		}
	}
}

// Also load Vercel project config if present
const vercelProjectPath = path.resolve(__dirname, "../.vercel/project.json");
if (fs.existsSync(vercelProjectPath)) {
	const proj = JSON.parse(fs.readFileSync(vercelProjectPath, "utf8"));
	if (!process.env.VERCEL_TEAM_ID) process.env.VERCEL_TEAM_ID = proj.orgId;
	if (!process.env.VERCEL_PROJECT_ID)
		process.env.VERCEL_PROJECT_ID = proj.projectId;
}

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------
interface TestResult {
	name: string;
	passed: boolean;
	duration: number;
	error?: string;
}

const results: TestResult[] = [];
let currentGroup = "";

function group(name: string) {
	currentGroup = name;
	console.log(`\n${"=".repeat(60)}`);
	console.log(`  ${name}`);
	console.log("=".repeat(60));
}

async function test(name: string, fn: () => Promise<void>) {
	const fullName = currentGroup ? `${currentGroup} > ${name}` : name;
	const start = performance.now();
	try {
		await fn();
		const duration = performance.now() - start;
		results.push({ name: fullName, passed: true, duration });
		console.log(`  ✓ ${name} (${Math.round(duration)}ms)`);
	} catch (err) {
		const duration = performance.now() - start;
		const message = err instanceof Error ? err.message : String(err);
		results.push({ name: fullName, passed: false, duration, error: message });
		console.log(`  ✗ ${name} (${Math.round(duration)}ms)`);
		console.log(`    ${message}`);
	}
}

function assert(condition: boolean, message: string) {
	if (!condition) throw new Error(`Assertion failed: ${message}`);
}

function assertEqual<T>(actual: T, expected: T, label: string) {
	if (actual !== expected) {
		throw new Error(
			`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`,
		);
	}
}

function assertIncludes(haystack: string, needle: string, label: string) {
	if (!haystack.includes(needle)) {
		throw new Error(`${label}: expected to include "${needle}"`);
	}
}

function assertDefined<T>(value: T | null | undefined, label: string): T {
	if (value == null) throw new Error(`${label}: expected defined value`);
	return value;
}

// ---------------------------------------------------------------------------
// Parse flags
// ---------------------------------------------------------------------------
const unitOnly = process.argv.includes("--unit-only");
const sandboxOnly = process.argv.includes("--sandbox-only");

// ---------------------------------------------------------------------------
// 1. Persona resolution (unit-level, needs GITHUB_TOKEN)
// ---------------------------------------------------------------------------
async function testPersonaResolution() {
	group("Persona Resolution");

	const { discoverPersonas, resolvePersona, buildConversationalPrompt } =
		await import("../src/lib/agent-runtime/persona-loader");

	const token = process.env.GITHUB_TOKEN;
	if (!token) {
		console.log("  ⚠ GITHUB_TOKEN not set — skipping persona discovery");
		return;
	}

	const owner = "fairchild";
	const repo = "workspaces";

	await test("discoverPersonas finds persona files", async () => {
		const personas = await discoverPersonas(token, owner, repo);
		assert(personas.length > 0, "expected at least one persona");

		const names = personas.map((p) => p.name);
		assert(
			names.includes("april-clearwater"),
			"expected april-clearwater persona",
		);
	});

	await test("resolvePersona matches by slug", async () => {
		const persona = await resolvePersona(
			token,
			owner,
			repo,
			"april-clearwater",
		);
		const p = assertDefined(persona, "expected persona to be found");
		assertEqual(p.name, "april-clearwater", "persona name");
		assertEqual(p.displayName, "April Clearwater", "display name");
		assert(p.role.length > 0, "expected non-empty role");
		assert(p.systemPrompt.length > 0, "expected non-empty system prompt");
	});

	await test("resolvePersona returns null for unknown agent", async () => {
		const persona = await resolvePersona(
			token,
			owner,
			repo,
			"nonexistent-agent",
		);
		assert(persona === null, "expected null for unknown agent");
	});

	await test("buildConversationalPrompt strips Output Format", async () => {
		const persona = await resolvePersona(
			token,
			owner,
			repo,
			"april-clearwater",
		);
		const p = assertDefined(persona, "expected persona");

		const prompt = buildConversationalPrompt(p);
		assert(
			!prompt.includes("## Output Format"),
			"should strip Output Format section",
		);
		assertIncludes(prompt, "## Conversational Mode", "conversational section");
		assertIncludes(prompt, "read the repository", "read-only instruction");
	});
}

// ---------------------------------------------------------------------------
// 2. Provider registry (unit-level, no creds needed)
// ---------------------------------------------------------------------------
async function testProviderRegistry() {
	group("Provider Registry");

	const { ComputeProviderRegistry } = await import(
		"../src/lib/agent-runtime/provider-registry"
	);
	const { VercelSandboxProvider } = await import(
		"../src/lib/agent-runtime/vercel-sandbox"
	);
	const { DaytonaProvider } = await import("../src/lib/agent-runtime/daytona");
	const { GitHubActionsProvider } = await import(
		"../src/lib/agent-runtime/github-actions"
	);

	const registry = new ComputeProviderRegistry([
		new VercelSandboxProvider(),
		new DaytonaProvider(),
		new GitHubActionsProvider(),
	]);

	await test("default provider is vercel-sandbox", async () => {
		const provider = registry.getDefault();
		assertEqual(
			provider.descriptor.id,
			"vercel-sandbox",
			"default provider id",
		);
	});

	await test("all providers registered", async () => {
		const all = registry.all();
		assertEqual(all.length, 3, "provider count");
		const ids = all.map((p) => p.descriptor.id).sort();
		assert(ids.includes("vercel-sandbox"), "has vercel-sandbox");
		assert(ids.includes("daytona"), "has daytona");
		assert(ids.includes("github-actions"), "has github-actions");
	});

	await test("stub providers report unavailable", async () => {
		const available = await registry.listAvailable();
		for (const entry of available) {
			if (entry.id === "daytona" || entry.id === "github-actions") {
				assert(
					!entry.availability.available,
					`${entry.id} should be unavailable`,
				);
			}
		}
	});

	await test("vercel-sandbox availability depends on creds", async () => {
		const provider = registry.getDefault();
		const avail = await provider.checkAvailability();
		const hasCreds =
			!!process.env.VERCEL_TOKEN || !!process.env.VERCEL_OIDC_TOKEN;
		assertEqual(avail.available, hasCreds, "vercel availability matches creds");
	});
}

// ---------------------------------------------------------------------------
// 3. Session persistence (unit-level, uses local SQLite)
// ---------------------------------------------------------------------------
async function testSessionPersistence() {
	group("Session Persistence");

	// Point DB at a temp file so we don't touch dev data
	const tmpDb = `/tmp/test-sandbox-e2e-${Date.now()}.db`;
	process.env.TURSO_DATABASE_URL = `file:${tmpDb}`;

	// Force fresh module load after env change
	const agentSessions = await import("../src/lib/agent-sessions");

	const sessionId = `test-${Date.now()}`;

	await test("createSession inserts a row", async () => {
		await agentSessions.createSession({
			id: sessionId,
			repo: "fairchild/workspaces",
			agentName: "april-clearwater",
			computeBackend: "vercel-sandbox",
			computeInstanceId: null,
			snapshotId: null,
			threadId: "test-thread-1",
			discussionId: null,
			status: "starting",
			createdAt: new Date().toISOString(),
			lastActivityAt: new Date().toISOString(),
		});

		const session = await agentSessions.getSession(sessionId);
		assert(session !== null, "session should exist");
		assertEqual(session?.id, sessionId, "session id");
		assertEqual(session?.agentName, "april-clearwater", "agent name");
		assertEqual(session?.status, "starting", "status");
	});

	await test("updateSessionStatus transitions status", async () => {
		await agentSessions.updateSessionStatus(sessionId, "streaming");
		const session = await agentSessions.getSession(sessionId);
		assertEqual(session?.status, "streaming", "status after update");
	});

	await test("updateComputeInstance sets instance id", async () => {
		await agentSessions.updateComputeInstance(sessionId, "sbx-test-123");
		const session = await agentSessions.getSession(sessionId);
		assertEqual(
			session?.computeInstanceId,
			"sbx-test-123",
			"compute instance id",
		);
	});

	await test("getActiveSessionForThread finds active session", async () => {
		await agentSessions.updateSessionStatus(sessionId, "active");
		const session = await agentSessions.getActiveSessionForThread(
			"fairchild/workspaces",
			"april-clearwater",
			"test-thread-1",
		);
		assert(session !== null, "should find active session");
		assertEqual(session?.id, sessionId, "session id");
	});

	await test("getActiveSessionForThread ignores completed sessions", async () => {
		await agentSessions.updateSessionStatus(sessionId, "completed");
		const session = await agentSessions.getActiveSessionForThread(
			"fairchild/workspaces",
			"april-clearwater",
			"test-thread-1",
		);
		assert(session === null, "completed session should not be found");
	});

	// Cleanup
	try {
		fs.unlinkSync(tmpDb);
	} catch {}
}

// ---------------------------------------------------------------------------
// 4. Sandbox lifecycle (E2E, needs Vercel + Anthropic creds)
// ---------------------------------------------------------------------------
async function testSandboxLifecycle() {
	group("Sandbox Lifecycle (E2E)");

	const { VercelSandboxProvider } = await import(
		"../src/lib/agent-runtime/vercel-sandbox"
	);
	const { buildConversationalPrompt } = await import(
		"../src/lib/agent-runtime/persona-loader"
	);

	const provider = new VercelSandboxProvider();

	// Check availability first
	const avail = await provider.checkAvailability();
	if (!avail.available) {
		console.log(`  ⚠ Vercel Sandbox unavailable: ${avail.reason}`);
		console.log("  ⚠ Skipping sandbox lifecycle tests");
		return;
	}

	if (!process.env.ANTHROPIC_API_KEY) {
		console.log("  ⚠ ANTHROPIC_API_KEY not set — skipping sandbox lifecycle");
		return;
	}

	let instanceId: string | undefined;

	await test("createSandbox provisions a sandbox", async () => {
		const result = await provider.createSandbox({
			sessionId: `e2e-test-${Date.now()}`,
			repo: "fairchild/workspaces",
			cloneUrl: "https://github.com/fairchild/workspaces.git",
			readOnly: true,
			systemPrompt: "You are a test agent. Answer concisely in one sentence.",
			message: "What is the name of this repository? Reply with just the name.",
			tools: "conversational",
		});

		assert(!!result.instanceId, "expected instanceId");
		assertEqual(result.status, "ready", "status");
		instanceId = result.instanceId;
		console.log(`    instanceId: ${instanceId}`);
	});

	await test("streamOutput returns agent response", async () => {
		const id = assertDefined(instanceId, "need instanceId from createSandbox");

		let text = "";
		let gotDone = false;

		for await (const chunk of provider.streamOutput(id)) {
			if (chunk.type === "text") text += chunk.content;
			if (chunk.type === "done") gotDone = true;
			if (chunk.type === "error")
				throw new Error(`Stream error: ${chunk.content}`);
		}

		assert(text.length > 0, "expected non-empty response");
		assert(gotDone, "expected done chunk");
		console.log(
			`    response (${text.length} chars): ${text.slice(0, 120)}...`,
		);
	});

	await test("sendMessage + streamOutput handles follow-up", async () => {
		const id = assertDefined(instanceId, "need instanceId");

		await provider.sendMessage(
			id,
			"How many source files are in the Sources/ directory? Just the count.",
		);

		let text = "";
		for await (const chunk of provider.streamOutput(id)) {
			if (chunk.type === "text") text += chunk.content;
			if (chunk.type === "error")
				throw new Error(`Stream error: ${chunk.content}`);
		}

		assert(text.length > 0, "expected follow-up response");
		console.log(
			`    follow-up (${text.length} chars): ${text.slice(0, 120)}...`,
		);
	});

	await test("destroySandbox cleans up", async () => {
		const id = assertDefined(instanceId, "need instanceId");
		await provider.destroySandbox(id);
		// Verify it's gone from active instances
		let errorCaught = false;
		for await (const chunk of provider.streamOutput(id)) {
			if (chunk.type === "error") errorCaught = true;
		}
		assert(errorCaught, "expected error after destroy");
	});
}

// ---------------------------------------------------------------------------
// 5. Access control (unit-level)
// ---------------------------------------------------------------------------
async function testAccessControl() {
	group("Access Control");

	await test("route module exports allowlist-gated POST", async () => {
		// We can't import the Next.js route directly (needs request context),
		// but we verify the allowlist is defined correctly
		const routeSource = fs.readFileSync(
			path.resolve(__dirname, "../src/app/api/chat/agent-stream/route.ts"),
			"utf8",
		);

		assertIncludes(
			routeSource,
			"ALLOWED_AGENT_LOGINS",
			"has allowlist constant",
		);
		assertIncludes(routeSource, '"fairchild"', "fairchild in allowlist");
		assertIncludes(routeSource, "status: 403", "returns 403 for unauthorized");
		assertIncludes(
			routeSource,
			"text/event-stream",
			"returns SSE content type",
		);
	});
}

// ---------------------------------------------------------------------------
// Run
// ---------------------------------------------------------------------------
async function main() {
	console.log("Agent Chat Sandbox — E2E Validation");
	console.log(`Time: ${new Date().toISOString()}`);
	console.log(
		`Mode: ${unitOnly ? "unit-only" : sandboxOnly ? "sandbox-only" : "full"}`,
	);

	if (!sandboxOnly) {
		await testProviderRegistry();
		await testPersonaResolution();
		await testSessionPersistence();
		await testAccessControl();
	}

	if (!unitOnly) {
		await testSandboxLifecycle();
	}

	// Summary
	console.log(`\n${"=".repeat(60)}`);
	console.log("  Summary");
	console.log("=".repeat(60));

	const passed = results.filter((r) => r.passed).length;
	const failed = results.filter((r) => !r.passed).length;
	const totalTime = results.reduce((sum, r) => sum + r.duration, 0);

	console.log(
		`  ${passed} passed, ${failed} failed (${Math.round(totalTime)}ms)`,
	);

	if (failed > 0) {
		console.log("\n  Failures:");
		for (const r of results.filter((r) => !r.passed)) {
			console.log(`    ✗ ${r.name}`);
			console.log(`      ${r.error}`);
		}
	}

	console.log();
	process.exit(failed > 0 ? 1 : 0);
}

main().catch((err) => {
	console.error("Fatal:", err);
	process.exit(2);
});
