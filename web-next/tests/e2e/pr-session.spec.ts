/*
 * PR-from-session masthead coverage (#820). The full real-credential flow is
 * a validation-lane concern; this local spec seeds the session projection and
 * verifies the visible masthead contract without opening GitHub PRs.
 */
import { createClient } from "@libsql/client";
import { expect, test } from "@playwright/test";
import path from "node:path";
import { randomUUID } from "node:crypto";

function e2eDb() {
	return createClient({
		url: `file:${path.resolve(__dirname, "../../.data/e2e.db")}`,
	});
}

test("a Vercel session renders its PR masthead line and update affordance", async ({
	page,
}) => {
	const db = e2eDb();
	const id = randomUUID();
	const now = new Date().toISOString();
	try {
		await db.batch([
			{
				sql: "INSERT OR IGNORE INTO repos (id, full_name, default_branch, created_at) VALUES (?, ?, ?, ?)",
				args: ["fairchild/workspaces", "fairchild/workspaces", "main", now],
			},
			{
				sql: `INSERT INTO sessions (
					id, repo_id, owner_login, title, first_user_message, provider, status,
					claude_session_id, resume_state, model, approval_policy,
					has_unpushed_work, pr_number, pr_url, pr_state, created_at, last_activity_at
				) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
				args: [
					id,
					"fairchild/workspaces",
					"fairchild",
					"Open a PR from this session",
					null,
					"vercel",
					"active",
					"harness-1",
					'{"parked":true}',
					"claude-opus-4-8",
					"auto",
					1,
					77,
					"https://github.com/fairchild/workspaces/pull/77",
					"open",
					now,
					now,
				],
			},
		]);
	} finally {
		db.close();
	}

	await page.goto(`/sessions/${id}`);

	await expect(page.getByTestId("session-pr-line")).toContainText("PR #77 open");
	await expect(page.getByTestId("session-pr-line")).toContainText(
		"agent/session-",
	);
	await expect(page.getByTestId("session-pr-line")).toContainText("main");
	await expect(page.getByRole("link", { name: "PR #77 open" })).toHaveAttribute(
		"href",
		"https://github.com/fairchild/workspaces/pull/77",
	);
	await expect(page.getByTestId("open-session-pr")).toHaveText("Update PR");
});
