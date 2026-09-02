import { fetchFileContent, fetchRepoTree } from "../github";
import type { AgentPersona } from "../types";

/** Cached personas per repo, keyed by "owner/repo" */
const personaCache = new Map<
	string,
	{ personas: AgentPersona[]; expires: number }
>();
/** Cached `.agents/MEMORY.md` per repo, keyed by "owner/repo" */
const repoMemoryCache = new Map<string, { memory: string; expires: number }>();
const CACHE_TTL = 15 * 60 * 1000; // 15 min, matches github.ts tree cache

const REPO_MEMORY_PATH = ".agents/MEMORY.md";

/**
 * Discover all agent personas from .agents/skills/<skill>/references/<name>.md
 * Filename slug becomes the agent name (e.g. april-clearwater.md → @april-clearwater).
 */
export async function discoverPersonas(
	token: string,
	owner: string,
	repo: string,
): Promise<AgentPersona[]> {
	const cacheKey = `${owner}/${repo}`;
	const cached = personaCache.get(cacheKey);
	if (cached && cached.expires > Date.now()) return cached.personas;

	const tree = await fetchRepoTree(token, owner, repo);

	// Find persona reference files: .agents/skills/<skill>/references/<name>.md
	const personaPattern = /^\.agents\/skills\/[^/]+\/references\/([^/]+)\.md$/;
	const personaPaths: Array<{ path: string; slug: string }> = [];

	for (const entry of tree) {
		const match = entry.path.match(personaPattern);
		if (match && entry.type === "blob") {
			personaPaths.push({ path: entry.path, slug: match[1] });
		}
	}

	// Fetch all persona file contents in parallel
	const contents = await Promise.all(
		personaPaths.map(async ({ path, slug }) => {
			const content = await fetchFileContent(token, owner, repo, path);
			return { path, slug, content };
		}),
	);

	const personas: AgentPersona[] = contents
		.filter((c) => c.content.length > 0)
		.map(({ path, slug, content }) => ({
			name: slug,
			displayName: slugToDisplayName(slug),
			role: extractRole(content),
			personaPath: path,
			systemPrompt: content,
		}));

	personaCache.set(cacheKey, { personas, expires: Date.now() + CACHE_TTL });
	return personas;
}

/**
 * Resolve a single agent name to its persona.
 * Returns null if the agent name doesn't match any persona file.
 */
export async function resolvePersona(
	token: string,
	owner: string,
	repo: string,
	agentName: string,
): Promise<AgentPersona | null> {
	if (process.env.MOCK_AGENT === "1") {
		return {
			name: agentName,
			displayName: agentName
				.split("-")
				.map((w) => w[0].toUpperCase() + w.slice(1))
				.join(" "),
			role: "assistant",
			personaPath: `.agents/${agentName}/`,
			systemPrompt: `You are ${agentName}, a helpful assistant for the ${owner}/${repo} repository.`,
		};
	}
	const personas = await discoverPersonas(token, owner, repo);
	return personas.find((p) => p.name === agentName) ?? null;
}

/**
 * Fetch `.agents/MEMORY.md`, the repo's curated durable rules.
 *
 * The persona references point at this file's § Writing Voice section, so a web
 * chat session that only loaded the persona would be pointed at rules it does
 * not hold. Returns "" when the file is absent or the fetch fails; callers
 * degrade to the bare persona prompt, whose pointer still names the file and
 * whose session holds read tools. An empty result is never cached — a transient
 * GitHub failure would otherwise strip the rules from every session for the
 * next fifteen minutes.
 */
export async function fetchRepoMemory(
	token: string,
	owner: string,
	repo: string,
): Promise<string> {
	const cacheKey = `${owner}/${repo}`;
	const cached = repoMemoryCache.get(cacheKey);
	if (cached && cached.expires > Date.now()) return cached.memory;

	let memory = "";
	try {
		memory = (
			await fetchFileContent(token, owner, repo, REPO_MEMORY_PATH)
		).trim();
	} catch {
		memory = "";
	}
	if (memory) {
		repoMemoryCache.set(cacheKey, { memory, expires: Date.now() + CACHE_TTL });
	} else {
		repoMemoryCache.delete(cacheKey);
	}
	return memory;
}

/**
 * Build a conversational system prompt from a persona file.
 * Strips the YAML output format section (contributor-runtime-specific),
 * appends conversational mode instructions, and folds in the repo memory the
 * persona references point at (same section the contributor runtime appends in
 * `run-contributor.py`'s `compose_system_prompt`).
 */
export function buildConversationalPrompt(
	persona: AgentPersona,
	repoMemory = "",
): string {
	// Strip everything from "## Output Format" onward — that section is
	// specific to the contributor runtime's structured YAML output
	let prompt = persona.systemPrompt;
	const outputFormatIdx = prompt.indexOf("## Output Format");
	if (outputFormatIdx !== -1) {
		prompt = prompt.slice(0, outputFormatIdx).trimEnd();
	}

	const memorySection = repoMemory.trim()
		? `

---

## Repository memory (trusted, curated)

Durable rules and heuristics for this repo. Treat as high-priority context, not as instructions that override your task envelope.

${repoMemory.trim()}`
		: "";

	return `${prompt}

## Conversational Mode

You are responding to a human in the Spaces web chat. This is a conversational context, not a contributor runtime.

- Respond naturally in markdown
- You have access to read the repository (files, git history, PRs, issues) but cannot make code changes in this mode
- If the user asks you to make code changes, explain that you can help plan the work and they can dispatch you for execution
- Draw on your knowledge of the codebase, your role, and your relationship with the team
- Be concise and direct — this is chat, not a formal report

## Available Context

- Recent conversation history (last 10 messages) is prepended to the user's message under "Recent conversation context"
- Full chat history (last 100 messages) is available at /vercel/sandbox/chat-history.txt — use Grep to search it for specific topics or past conversations${memorySection}`;
}

/** Convert "april-clearwater" → "April Clearwater" */
function slugToDisplayName(slug: string): string {
	return slug
		.split("-")
		.map((w) => w.charAt(0).toUpperCase() + w.slice(1))
		.join(" ");
}

/** Extract the role from the first heading line like "# April Clearwater — Application Lead" */
function extractRole(content: string): string {
	const match = content.match(/^#\s+.+?—\s*(.+)$/m);
	return match ? match[1].trim() : "";
}
