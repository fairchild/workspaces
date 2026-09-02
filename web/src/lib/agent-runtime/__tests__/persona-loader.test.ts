import { beforeEach, describe, expect, it, vi } from "vitest";

vi.mock("../../github", () => ({
	fetchFileContent: vi.fn(),
	fetchRepoTree: vi.fn(),
}));

import { fetchFileContent } from "../../github";
import type { AgentPersona } from "../../types";
import { buildConversationalPrompt, fetchRepoMemory } from "../persona-loader";

const PERSONA: AgentPersona = {
	name: "april-clearwater",
	displayName: "April Clearwater",
	role: "Application Lead",
	personaPath:
		".agents/skills/cofounder-contributor/references/april-clearwater.md",
	systemPrompt: [
		"# April Clearwater — Application Lead",
		"",
		"Write every review in the voice defined in `.agents/MEMORY.md` § Writing Voice.",
		"",
		"## Output Format",
		"",
		"contributor-runtime YAML that conversational mode must not inherit",
	].join("\n"),
};

const MEMORY = [
	"# Repo Memory",
	"",
	"## Writing Voice",
	"",
	"- Start with the point.",
	"- Cut decoration.",
].join("\n");

describe("buildConversationalPrompt", () => {
	it("folds repo memory in so the persona pointer names rules the session holds", () => {
		const prompt = buildConversationalPrompt(PERSONA, MEMORY);

		expect(prompt).toContain("## Repository memory (trusted, curated)");
		expect(prompt).toContain("- Start with the point.");
		expect(prompt).toContain("- Cut decoration.");
	});

	it("still strips the contributor-runtime output format section", () => {
		const prompt = buildConversationalPrompt(PERSONA, MEMORY);

		expect(prompt).not.toContain("contributor-runtime YAML");
		expect(prompt).toContain("## Conversational Mode");
	});

	it("degrades to the bare persona prompt when repo memory is unavailable", () => {
		const prompt = buildConversationalPrompt(PERSONA, "");

		expect(prompt).not.toContain("## Repository memory");
		expect(prompt).toContain("## Conversational Mode");
	});
});

describe("fetchRepoMemory", () => {
	beforeEach(() => {
		vi.mocked(fetchFileContent).mockReset();
	});

	it("reads .agents/MEMORY.md from the target repo", async () => {
		vi.mocked(fetchFileContent).mockResolvedValue(MEMORY);

		const memory = await fetchRepoMemory("tok", "fairchild", "memory-hit");

		expect(fetchFileContent).toHaveBeenCalledWith(
			"tok",
			"fairchild",
			"memory-hit",
			".agents/MEMORY.md",
		);
		expect(memory).toContain("## Writing Voice");
	});

	it("returns an empty string when the fetch fails", async () => {
		vi.mocked(fetchFileContent).mockRejectedValue(new Error("404"));

		expect(await fetchRepoMemory("tok", "fairchild", "memory-miss")).toBe("");
	});

	it("does not cache a failure, so one bad fetch does not strip the rules for 15 minutes", async () => {
		vi.mocked(fetchFileContent).mockRejectedValueOnce(new Error("502"));
		vi.mocked(fetchFileContent).mockResolvedValueOnce(MEMORY);

		expect(await fetchRepoMemory("tok", "fairchild", "memory-flaky")).toBe("");
		expect(await fetchRepoMemory("tok", "fairchild", "memory-flaky")).toContain(
			"## Writing Voice",
		);
		expect(fetchFileContent).toHaveBeenCalledTimes(2);
	});
});
