import { describe, expect, it } from "vitest";
import { getUserRepos, hasUserRepos, setUserRepos } from "../repos";

// Unique userId per test so parallel write paths don't collide across tests
// that share the same in-memory DB.
function uniqueUser(): string {
	return `user-${Date.now()}-${Math.random().toString(36).slice(2, 8)}`;
}

describe("setUserRepos (parallel writes)", () => {
	it("persists every row after a multi-repo insert", async () => {
		const userId = uniqueUser();
		const repos = Array.from({ length: 25 }, (_, i) => ({
			owner: "acme",
			repo: `repo-${i}`,
		}));

		await setUserRepos(userId, repos);

		const stored = await getUserRepos(userId);
		expect(stored).toHaveLength(25);
		const names = new Set(stored.map((r) => `${r.owner}/${r.repo}`));
		for (const r of repos) {
			expect(names.has(`${r.owner}/${r.repo}`)).toBe(true);
		}
	});

	it("replaces the previous set on a second call", async () => {
		const userId = uniqueUser();
		await setUserRepos(userId, [
			{ owner: "acme", repo: "a" },
			{ owner: "acme", repo: "b" },
			{ owner: "acme", repo: "c" },
		]);
		await setUserRepos(userId, [{ owner: "acme", repo: "b" }]);

		const stored = await getUserRepos(userId);
		expect(stored.map((r) => r.repo)).toEqual(["b"]);
	});

	it("is empty after clearing", async () => {
		const userId = uniqueUser();
		await setUserRepos(userId, [{ owner: "acme", repo: "a" }]);
		expect(await hasUserRepos(userId)).toBe(true);

		await setUserRepos(userId, []);
		expect(await hasUserRepos(userId)).toBe(false);
	});
});
