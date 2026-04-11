import { createHash } from "node:crypto";
import type Anthropic from "@anthropic-ai/sdk";
import type { BetaManagedAgentsAgentToolset20260401Params } from "@anthropic-ai/sdk/resources/beta/agents/agents";
import type { BetaCloudConfigParams } from "@anthropic-ai/sdk/resources/beta/environments";
import { getDb } from "../db";

/**
 * In-process + durable cache of Managed Agents `agent` and `environment`
 * IDs, keyed on a hash of the config. First call creates the remote object
 * and persists the mapping; subsequent calls reuse it.
 *
 * The DB row survives process restarts; the in-memory map amortizes hot-path
 * lookups within a single process.
 */

type Kind = "agent" | "environment";

const memoryCache = new Map<string, string>();

let migrated = false;
async function ensureCacheTable(): Promise<void> {
	if (migrated) return;
	const db = getDb();
	await db.schema
		.createTable("managed_agents_cache")
		.ifNotExists()
		.addColumn("kind", "text", (c) => c.notNull())
		.addColumn("hash", "text", (c) => c.notNull())
		.addColumn("remote_id", "text", (c) => c.notNull())
		.addColumn("created_at", "text", (c) => c.notNull())
		.addColumn("metadata", "text")
		.execute();
	await db.schema
		.createIndex("idx_managed_agents_cache_key")
		.ifNotExists()
		.on("managed_agents_cache")
		.columns(["kind", "hash"])
		.execute();
	migrated = true;
}

function sha16(input: string): string {
	return createHash("sha256").update(input).digest("hex").slice(0, 16);
}

function cacheKey(kind: Kind, hash: string): string {
	return `${kind}:${hash}`;
}

async function readCache(kind: Kind, hash: string): Promise<string | null> {
	const hit = memoryCache.get(cacheKey(kind, hash));
	if (hit) return hit;
	await ensureCacheTable();
	const row = await getDb()
		.selectFrom("managed_agents_cache")
		.select("remote_id")
		.where("kind", "=", kind)
		.where("hash", "=", hash)
		.executeTakeFirst();
	if (row?.remote_id) {
		memoryCache.set(cacheKey(kind, hash), row.remote_id);
		return row.remote_id;
	}
	return null;
}

async function writeCache(
	kind: Kind,
	hash: string,
	remoteId: string,
	metadata?: Record<string, unknown>,
): Promise<void> {
	await ensureCacheTable();
	memoryCache.set(cacheKey(kind, hash), remoteId);
	await getDb()
		.insertInto("managed_agents_cache")
		.values({
			kind,
			hash,
			remote_id: remoteId,
			created_at: new Date().toISOString(),
			metadata: metadata ? JSON.stringify(metadata) : null,
		})
		.onConflict((oc) => oc.doNothing())
		.execute();
}

export interface AgentSpec {
	name: string;
	model: string;
	systemPrompt: string;
	toolsetVersion?: string;
	/** Override default toolset with custom tool configs. */
	tools?: unknown[];
	/** MCP server declarations for the agent. */
	mcpServers?: unknown[];
}

export async function getOrCreateAgent(
	client: Anthropic,
	spec: AgentSpec,
): Promise<string> {
	const toolsetVersion = spec.toolsetVersion ?? "agent_toolset_20260401";
	const hash = sha16(
		JSON.stringify({
			model: spec.model,
			system: spec.systemPrompt,
			toolset: toolsetVersion,
			tools: spec.tools,
			mcpServers: spec.mcpServers,
			v: 1,
		}),
	);
	const cached = await readCache("agent", hash);
	if (cached) return cached;

	const tools: unknown[] = spec.tools ?? [
		{
			type: "agent_toolset_20260401",
		} satisfies BetaManagedAgentsAgentToolset20260401Params,
	];
	const agent = await client.beta.agents.create({
		name: `${spec.name}-${hash}`.slice(0, 256),
		model: spec.model,
		system: spec.systemPrompt,
		tools: tools as BetaManagedAgentsAgentToolset20260401Params[],
		...(spec.mcpServers
			? {
					mcp_servers: spec.mcpServers as Parameters<
						typeof client.beta.agents.create
					>[0]["mcp_servers"],
				}
			: {}),
		metadata: { hash, persona: spec.name },
	});
	await writeCache("agent", hash, agent.id, { persona: spec.name });
	return agent.id;
}

export interface EnvironmentSpec {
	name: string;
	config: BetaCloudConfigParams;
}

export async function getOrCreateEnvironment(
	client: Anthropic,
	spec: EnvironmentSpec,
): Promise<string> {
	const hash = sha16(JSON.stringify(stableStringify(spec.config)));
	const cached = await readCache("environment", hash);
	if (cached) return cached;

	const environment = await client.beta.environments.create({
		name: `${spec.name}-${hash}`.slice(0, 256),
		config: spec.config,
		metadata: { hash },
	});
	await writeCache("environment", hash, environment.id);
	return environment.id;
}

function stableStringify(value: unknown): unknown {
	if (value === null || typeof value !== "object") return value;
	if (Array.isArray(value)) return value.map(stableStringify);
	const entries = Object.entries(value as Record<string, unknown>)
		.sort(([a], [b]) => a.localeCompare(b))
		.map(([k, v]) => [k, stableStringify(v)] as const);
	return Object.fromEntries(entries);
}

/** Test-only hook. */
export function __resetCacheForTests(): void {
	memoryCache.clear();
	migrated = false;
}
