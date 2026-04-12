import type { Agent, ConfigFile, Skill } from "./types";

interface TreeEntry {
	path: string;
	type: string;
}

/** Parse YAML frontmatter from SKILL.md content. Simple regex — no YAML lib. */
function parseFrontmatter(content: string): Record<string, string> {
	const match = content.match(/^---\n([\s\S]*?)\n---/);
	if (!match) return {};
	const result: Record<string, string> = {};
	let currentKey = "";
	let currentValue = "";

	for (const line of match[1].split("\n")) {
		// Multi-line continuation (indented or >- style)
		if (currentKey && (line.startsWith("  ") || line.startsWith("\t"))) {
			currentValue += ` ${line.trim()}`;
			result[currentKey] = currentValue.trim();
			continue;
		}
		// New key: value
		const kvMatch = line.match(/^(\w[\w-]*):\s*(.*)$/);
		if (kvMatch) {
			currentKey = kvMatch[1];
			// Strip >- or | block scalar indicators
			currentValue = kvMatch[2].replace(/^[>|]-?\s*/, "").trim();
			if (currentValue) result[currentKey] = currentValue;
		}
	}
	return result;
}

export interface ParsedAgents {
	agents: Agent[];
	skills: Skill[];
	configFiles: ConfigFile[];
}

/**
 * Parse a Git Trees API response (filtered to .agents/ paths) into structured agent data.
 * Each .agents/skills/<name>/ directory = one agent.
 */
export function parseAgentTree(
	treeEntries: TreeEntry[],
	skillContents: Map<string, string>,
): ParsedAgents {
	const skillDirs = new Set<string>();
	const configPaths: string[] = [];

	for (const entry of treeEntries) {
		// Identify skill directories: .agents/skills/<name>/SKILL.md
		const skillMatch = entry.path.match(
			/^\.agents\/skills\/([^/]+)\/SKILL\.md$/,
		);
		if (skillMatch) {
			skillDirs.add(skillMatch[1]);
		}
		// Config files: .agents/config/*.toml
		if (
			entry.path.match(/^\.agents\/config\/[^/]+\.toml$/) &&
			entry.type === "blob"
		) {
			configPaths.push(entry.path);
		}
	}

	const agents: Agent[] = [];
	const skills: Skill[] = [];

	for (const dirName of skillDirs) {
		const skillMdPath = `.agents/skills/${dirName}/SKILL.md`;
		const content = skillContents.get(skillMdPath) ?? "";
		const meta = parseFrontmatter(content);

		const name = meta.name ?? dirName;
		const description = meta.description ?? "";

		skills.push({ name, description });
		agents.push({
			name,
			role: description || null,
			status: "idle", // Caller upgrades to "active" from issue data
			skills: [],
			lastAction: null,
		});
	}

	const configFiles: ConfigFile[] = configPaths.map((p) => ({
		path: p,
		description: p.split("/").pop() ?? p,
	}));

	return { agents, skills, configFiles };
}

/**
 * Extract persona-based agents from references/*.md files in the tree.
 * These use full hyphenated names (e.g. "april-clearwater") to avoid
 * conflicts with real GitHub users.
 */
export function parsePersonaReferences(
	treeEntries: TreeEntry[],
	personaContents: Map<string, string>,
): Agent[] {
	const personaPattern = /^\.agents\/skills\/[^/]+\/references\/([^/]+)\.md$/;
	const agents: Agent[] = [];

	for (const entry of treeEntries) {
		const match = entry.path.match(personaPattern);
		if (!match || entry.type !== "blob") continue;

		const slug = match[1];
		const content = personaContents.get(entry.path) ?? "";

		// Extract role from "# Name — Role" heading
		const roleMatch = content.match(/^#\s+.+?—\s*(.+)$/m);
		const role = roleMatch ? roleMatch[1].trim() : null;

		agents.push({
			name: slug,
			role,
			status: "idle",
			skills: [],
			lastAction: null,
		});
	}

	return agents;
}
