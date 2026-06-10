import assert from "node:assert/strict";
import test from "node:test";

import { closeResolvedProdAlerts, postProdAlert } from "./cd-prod-alert.js";

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
			issues: {
				addLabels: async (params) => calls.push(["addLabels", params]),
				create: async (params) => {
					calls.push(["create", params]);
					return { data: { number: 700 } };
				},
				createComment: async (params) => calls.push(["createComment", params]),
				listForRepo: async (params) => {
					calls.push(["listForRepo", params]);
					return { data: searchItems };
				},
				update: async (params) => calls.push(["update", params]),
			},
		},
	};
}

const core = { notice() {} };
const fs = {
	existsSync: () => true,
	readFileSync: () => "prod failure details",
};

test("postProdAlert updates the existing open prod issue", async () => {
	const github = makeGithub([{ number: 630 }]);

	const result = await postProdAlert({
		github,
		context: makeContext(),
		core,
		env: { PROD_URL: "https://spaces.cloudcompute.com" },
		fs,
	});

	assert.deepEqual(result, { issueNumber: 630, created: false });
	assert.equal(github.calls.some(([name]) => name === "create"), false);
	assert.deepEqual(github.calls[0], [
		"listForRepo",
		{
			owner: "fairchild",
			repo: "workspaces",
			state: "open",
			labels: "auto-opened,cd-failure,cd-failure:prod",
			sort: "updated",
			direction: "desc",
			per_page: 1,
		},
	]);
	assert.equal(github.calls[1][0], "addLabels");
	assert.equal(github.calls[1][1].issue_number, 630);
	assert.deepEqual(github.calls[1][1].labels, ["urgent"]);
	assert.equal(github.calls[2][0], "createComment");
	assert.match(github.calls[2][1].body, /<!-- cd-failure:prod -->/);
	assert.match(github.calls[2][1].body, /prod failure details/);
});

test("postProdAlert opens the first prod issue for a failing surface", async () => {
	const github = makeGithub([]);

	const result = await postProdAlert({
		github,
		context: makeContext(),
		core,
		env: { PROD_URL: "https://spaces.cloudcompute.com" },
		fs,
	});

	assert.deepEqual(result, { issueNumber: 700, created: true });
	const create = github.calls.find(([name]) => name === "create");
	assert.deepEqual(create[1].labels, [
		"cd-failure",
		"cd-failure:prod",
		"urgent",
		"auto-opened",
	]);
});

test("closeResolvedProdAlerts comments and closes all open prod issues", async () => {
	const github = makeGithub([{ number: 630 }, { number: 640 }]);

	const result = await closeResolvedProdAlerts({
		github,
		context: makeContext(),
		core,
	});

	assert.deepEqual(result, { closed: [630, 640] });
	const updates = github.calls.filter(([name]) => name === "update");
	assert.deepEqual(
		updates.map(([, params]) => ({
			issue_number: params.issue_number,
			state: params.state,
			state_reason: params.state_reason,
		})),
		[
			{ issue_number: 630, state: "closed", state_reason: "completed" },
			{ issue_number: 640, state: "closed", state_reason: "completed" },
		],
	);
	const comments = github.calls.filter(([name]) => name === "createComment");
	assert.equal(comments.length, 2);
	assert.match(comments[0][1].body, /Prod validation is green/);
});
