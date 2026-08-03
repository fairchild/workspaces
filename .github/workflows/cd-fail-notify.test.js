// Pins cd-fail-notify.js's two issue paths: reopen/update of the rolling CD
// failure issue and first-failure creation. The mock exposes no Actions API,
// so any return of the retired persona auto-dispatch fails these tests.
// Run: node --test .github/workflows/cd-fail-notify.test.js (wired in ci-agents.yml).
import assert from "node:assert/strict";
import test from "node:test";

import failNotify, { closeOnGreen } from "./cd-fail-notify.js";

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

test("closeOnGreen closes the open rolling CD failure issue", async () => {
	const github = makeGithub([{ number: 630, state: "open" }]);

	const result = await closeOnGreen({
		github,
		context: makeContext(),
		core,
		env: { VALIDATOR: "playwright" },
	});

	assert.deepEqual(result, { closed: 630 });
	assert.deepEqual(
		github.calls.map(([name]) => name),
		["search", "createComment", "update"],
	);
	assert.match(github.calls[0][1].q, /"<!-- cd-failure:playwright -->"/);
	assert.equal(github.calls[0][1].per_page, 1);
	assert.equal(github.calls[1][1].issue_number, 630);
	assert.match(github.calls[1][1].body, /<!-- cd-failure:playwright -->/);
	assert.match(github.calls[1][1].body, /CD playwright validation is green/);
	assert.equal(github.calls[2][1].issue_number, 630);
	assert.equal(github.calls[2][1].state, "closed");
	assert.equal(github.calls[2][1].state_reason, "completed");
});

test("closeOnGreen is a no-op when there is no rolling issue", async () => {
	const github = makeGithub([]);

	const result = await closeOnGreen({
		github,
		context: makeContext(),
		core,
		env: { VALIDATOR: "playwright" },
	});

	assert.deepEqual(result, { closed: null });
	assert.deepEqual(
		github.calls.map(([name]) => name),
		["search"],
	);
});

test("closeOnGreen leaves an already-closed rolling issue alone", async () => {
	// Flap protection: a fail → green → fail sequence can leave a closed
	// issue matching the marker if a later run already reopened and
	// re-closed it. Don't double-comment or re-close.
	const github = makeGithub([{ number: 630, state: "closed" }]);

	const result = await closeOnGreen({
		github,
		context: makeContext(),
		core,
		env: { VALIDATOR: "playwright" },
	});

	assert.deepEqual(result, { closed: null });
	assert.deepEqual(
		github.calls.map(([name]) => name),
		["search"],
	);
});
