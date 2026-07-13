// Shared logic for the fail-notify-{playwright,lighthouse} jobs in cd.yml.
//
// Called from github-script@v7 as:
//   const { default: failNotify } = await import('./.github/workflows/cd-fail-notify.js');
//   await failNotify({ github, context, core });
//
// Env inputs:
//   VALIDATOR    — "playwright" or "lighthouse"
//   PREVIEW_URL  — preview deployment URL
//   REPRO_HINT   — shell command to reproduce locally
//
// Reads findings.md from the current working directory (downloaded artifact).

import nodeFs from "node:fs";

export default async function failNotify({
	github,
	context,
	core,
	env = process.env,
	fs = nodeFs,
}) {
	const validator = env.VALIDATOR;
	const marker = `<!-- cd-failure:${validator} -->`;
	const findings = fs.existsSync("findings.md")
		? fs.readFileSync("findings.md", "utf8")
		: "_No findings file produced._";

	const title = `CD: ${validator} failures on main`;
	const runUrl = `${context.serverUrl}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;

	const q = `repo:${context.repo.owner}/${context.repo.repo} in:body "${marker}" is:issue`;
	const found = await github.rest.search.issuesAndPullRequests({
		q,
		per_page: 1,
	});
	const existing = found.data.items[0];

	const body = [
		marker,
		`**Commit:** ${context.sha}`,
		`**Run:** ${runUrl}`,
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
