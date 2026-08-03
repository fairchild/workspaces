// Shared logic for the fail-notify-{playwright,lighthouse} and
// close-on-green-{playwright,lighthouse} jobs in cd.yml.
//
// Called from github-script@v7 as:
//   const { default: failNotify, closeOnGreen } = await import('./.github/workflows/cd-fail-notify.js');
//   await failNotify({ github, context, core });
//   await closeOnGreen({ github, context, core });
//
// Env inputs:
//   VALIDATOR    — "playwright" or "lighthouse"
//   PREVIEW_URL  — preview deployment URL (failNotify only)
//   REPRO_HINT   — shell command to reproduce locally (failNotify only)
//
// Reads findings.md from the current working directory (downloaded artifact).

import nodeFs from "node:fs";

function markerFor(validator) {
	return `<!-- cd-failure:${validator} -->`;
}

function runUrl(context) {
	return `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
}

async function findRollingIssue(github, context, validator) {
	const q = `repo:${context.repo.owner}/${context.repo.repo} in:body "${markerFor(validator)}" is:issue`;
	const found = await github.rest.search.issuesAndPullRequests({
		q,
		per_page: 1,
	});
	return found.data.items[0];
}

export default async function failNotify({
	github,
	context,
	core,
	env = process.env,
	fs = nodeFs,
}) {
	const validator = env.VALIDATOR;
	const marker = markerFor(validator);
	const findings = fs.existsSync("findings.md")
		? fs.readFileSync("findings.md", "utf8")
		: "_No findings file produced._";

	const title = `CD: ${validator} failures on main`;
	const existing = await findRollingIssue(github, context, validator);

	const body = [
		marker,
		`**Commit:** ${context.sha}`,
		`**Run:** ${runUrl(context)}`,
		`**Preview URL:** ${env.PREVIEW_URL || "(not available)"}`,
		"",
		"## Findings",
		findings,
		"",
		"## Factory triage",
		"This CD failure entered the Factory through its issue triage inlet.",
		`Reproduce locally: \`${env.REPRO_HINT}\``,
		"",
		"## Plan to fix (if root cause is obvious)",
		"- [ ] Root cause: <one sentence>",
		"- [ ] Reproduction: <local command>",
		"- [ ] Fix approach: <one paragraph>",
		"- [ ] Validation: <how we know it is fixed>",
		"",
		"## Plan to explore (if fix is not obvious)",
		"- [ ] Hypothesis: <one sentence>",
		"- [ ] Experiment: <what to run>",
		"- [ ] Decision point: <what result tells us to do what>",
	].join("\n");

	// CD failures enter the Factory as issues, its triage inlet. Auto-dispatching
	// a retired persona workflow was v1 behavior and stays removed.
	if (existing) {
		if (existing.state === "closed") {
			await github.rest.issues.update({
				owner: context.repo.owner,
				repo: context.repo.repo,
				issue_number: existing.number,
				state: "open",
			});
		}
		await github.rest.issues.createComment({
			owner: context.repo.owner,
			repo: context.repo.repo,
			issue_number: existing.number,
			body,
		});
		core.notice(`Updated rolling issue #${existing.number}`);
		return { issueNumber: existing.number };
	}

	const created = await github.rest.issues.create({
		owner: context.repo.owner,
		repo: context.repo.repo,
		title,
		body,
		labels: ["cd-failure", `cd-failure:${validator}`, "auto-opened"],
	});
	core.notice(`Created rolling issue #${created.data.number}`);
	return { issueNumber: created.data.number };
}

export async function closeOnGreen({ github, context, core, env = process.env }) {
	const validator = env.VALIDATOR;
	const existing = await findRollingIssue(github, context, validator);

	if (!existing || existing.state !== "open") {
		core.notice(`No open rolling ${validator} issue to close`);
		return { closed: null };
	}

	const body = [
		markerFor(validator),
		`CD ${validator} validation is green for \`${context.sha}\` in ${runUrl(context)}.`,
		"",
		`Closing this auto-opened rolling issue. The CD auto-opener will reopen it or open a new one if ${validator} regresses again.`,
	].join("\n");

	await github.rest.issues.createComment({
		owner: context.repo.owner,
		repo: context.repo.repo,
		issue_number: existing.number,
		body,
	});
	await github.rest.issues.update({
		owner: context.repo.owner,
		repo: context.repo.repo,
		issue_number: existing.number,
		state: "closed",
		state_reason: "completed",
	});

	core.notice(`Closed rolling issue #${existing.number}`);
	return { closed: existing.number };
}
