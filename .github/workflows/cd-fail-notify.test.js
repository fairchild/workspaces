import assert from "node:assert/strict";
import test from "node:test";

import failNotify from "./cd-fail-notify.js";

function makeContext() {
	return {
		serverUrl: "https://github.com",
		repo: { owner: "fairchild", repo: "workspaces" },
		runId: 123,
		sha: "abc1234def5678",
	};
}

function makeGithub(searchItems) {
	const calls = [];
	return {
		calls,
		rest: {
			search: {
				issuesAndPullRequests: async (params) => {
					calls.push(["search", params]);
					return { data: { items: searchItems } };
				},
			},
			issues: {
				create: async (params) => {
					calls.push(["create", params]);
					return { data: { number: 700 } };
				},
				createComment: async (params) => calls.push(["createComment", params]),
				update: async (params) => calls.push(["update", params]),
			},
		},
	};
}

const core = { notice() {} };
const env = {
	VALIDATOR: "playwright",
	PREVIEW_URL: "https://preview.example.com",
	REPRO_HINT: "mise run web:e2e",
};
const fs = {
	existsSync: () => true,
	readFileSync: () => "playwright failure details",
};

test("failNotify reopens and updates the rolling CD failure issue", async () => {
	const github = makeGithub([{ number: 630, state: "closed" }]);

	const result = await failNotify({
		github,
		context: makeContext(),
		core,
		env,
		fs,
	});

	assert.deepEqual(result, { issueNumber: 630 });
	assert.deepEqual(
		github.calls.map(([name]) => name),
		["search", "update", "createComment"],
	);
	assert.equal(github.calls[1][1].state, "open");
	assert.match(github.calls[2][1].body, /## Factory triage/);
	assert.match(github.calls[2][1].body, /playwright failure details/);
});

test("failNotify opens the first CD failure issue for Factory triage", async () => {
	const github = makeGithub([]);

	const result = await failNotify({
		github,
		context: makeContext(),
		core,
		env,
		fs,
	});

	assert.deepEqual(result, { issueNumber: 700 });
	assert.deepEqual(
		github.calls.map(([name]) => name),
		["search", "create"],
	);
	const create = github.calls[1][1];
	assert.deepEqual(create.labels, [
		"cd-failure",
		"cd-failure:playwright",
		"auto-opened",
	]);
	assert.match(create.body, /issue triage inlet/);
	assert.match(create.body, /Reproduce locally: `mise run web:e2e`/);
});
